import os, sys, json, hmac, hashlib, base64, time, urllib.request, re
ak, sk = os.environ["ALIYUN_ACCESS_KEY_ID"], os.environ["ALIYUN_ACCESS_KEY_SECRET"]
bucket, key, path = "medme-deploy", "medme-api.zip", sys.argv[1]
host = os.environ.get("OSS_HOST", f"{bucket}.oss-accelerate.aliyuncs.com")
state_path = path + ".mpu.json"
PART = 4 * 1024 * 1024
def req(method, query, data=None, ct=""):
    if data is not None and not ct: ct = "application/octet-stream"
    date = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime())
    res = f"/{bucket}/{key}" + (("?" + query) if query else "")
    sts = f"{method}\n\n{ct}\n{date}\n{res}"
    sig = base64.b64encode(hmac.new(sk.encode(), sts.encode(), hashlib.sha1).digest()).decode()
    h = {"Date": date, "Authorization": f"OSS {ak}:{sig}"}
    if ct: h["Content-Type"] = ct
    r = urllib.request.Request(f"https://{host}/{key}" + (("?" + query) if query else ""), data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=120) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, host, method, query, re.sub(r"<(EncodedDiag|RecommendDoc)[^<]*<[^>]*>", "", e.read()[:2000].decode(errors="replace"))); raise SystemExit(1)
size = os.path.getsize(path); nparts = (size + PART - 1) // PART
st = json.load(open(state_path)) if os.path.exists(state_path) else {}
if "uploadId" not in st:
    _, _, body = req("POST", "uploads")
    st = {"uploadId": re.search(rb"<UploadId>(.*?)</UploadId>", body).group(1).decode(), "etags": {}}
    json.dump(st, open(state_path, "w"))
uid = st["uploadId"]; t0 = time.time()
if os.environ.get("MPU_INIT_ONLY"): print("init ok", host, uid[:8]); raise SystemExit(0)
with open(path, "rb") as f:
    for n in range(1, nparts + 1):
        if str(n) in st["etags"]: continue
        f.seek((n - 1) * PART); chunk = f.read(PART); t = time.time()
        _, hdr, _ = req("PUT", f"partNumber={n}&uploadId={uid}", data=chunk)
        st["etags"][str(n)] = hdr["ETag"]; json.dump(st, open(state_path, "w"))
        print(f"part {n}/{nparts} {len(chunk)/1e6:.1f} MB in {time.time()-t:.1f}s ({len(chunk)/1024/max(time.time()-t,0.01):.0f} KB/s)", flush=True)
xml = "<CompleteMultipartUpload>" + "".join(f"<Part><PartNumber>{n}</PartNumber><ETag>{st['etags'][str(n)]}</ETag></Part>" for n in range(1, nparts + 1)) + "</CompleteMultipartUpload>"
status, _, _ = req("POST", f"uploadId={uid}", data=xml.encode(), ct="application/xml")
print("complete:", status, f"total {time.time()-t0:.0f}s"); os.remove(state_path)
