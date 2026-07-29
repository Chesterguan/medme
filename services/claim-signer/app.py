"""独立 HTTP 服务版的签名端点(阿里云函数计算「自定义运行时」用)。

自定义运行时要求进程自己起一个 HTTP Server 并监听指定端口(FC 通过 `PORT` 环境变量
告知,默认 9000),而不是实现某个框架约定的 handler。好处是**不绑定任何平台**:同一份
代码放 VPS、容器、别家 serverless 都能跑。

签名逻辑全部在 `handler.py`,这里只负责收发 HTTP —— 两者共用同一套实现,自检
(`test_handler.py`)覆盖的就是那一套。

启动命令:`python3 app.py`   监听端口:`9000`
环境变量见 README。
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from handler import (
    PRESIGN_TTL_SECONDS,
    build_presigned_put,
    initiate_multipart,
    new_object_key,
)

PORT = int(os.environ.get("PORT", "9000"))


class Handler(BaseHTTPRequestHandler):
    # 默认实现会把 HTTP/1.0 当默认,导致每次响应都断连;声明 1.1 让 FC 的前置能复用连接。
    protocol_version = "HTTP/1.1"

    def _json(self, status: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self):
        # 健康检查:FC 与探活会打根路径,别让它们也去签名。
        if self.path.rstrip("/") in ("", "/health"):
            return self._json(200, {"ok": True})

        ak = os.environ.get("OSS_ACCESS_KEY_ID", "").strip()
        sk = os.environ.get("OSS_ACCESS_KEY_SECRET", "").strip()
        bucket = os.environ.get("OSS_BUCKET", "").strip()
        endpoint = os.environ.get("OSS_ENDPOINT", "").strip()
        if not (ak and sk and bucket and endpoint):
            # 配置缺失是部署问题,不是调用方的问题——明确报 500,别伪装成签名失败。
            return self._json(500, {"error": "server_not_configured"})

        # 可选共享口令:挡不住反编译(口令也在 App 里),但能挡住扫互联网的脚本。
        expected = os.environ.get("MEDME_UPLOAD_TOKEN", "").strip()
        if expected:
            import hmac

            got = self.headers.get("X-MedMe-Token", "")
            if not hmac.compare_digest(got, expected):
                return self._json(403, {"error": "forbidden"})

        # /multipart?size=N —— 分片上传(可续传)。断网重连时已成功的片不必重传,
        # 这是「上传不该断」这条要求的地基。简单 PUT 留着给小载荷和兜底。
        if self.path.split("?")[0].rstrip("/").endswith("/multipart"):
            from urllib.parse import parse_qs, urlparse

            q = parse_qs(urlparse(self.path).query)
            try:
                size = int(q.get("size", ["0"])[0])
            except ValueError:
                size = 0
            if size <= 0:
                return self._json(400, {"error": "size_required"})
            try:
                out = initiate_multipart(
                    access_key_id=ak, access_key_secret=sk,
                    bucket=bucket, endpoint=endpoint,
                    key=new_object_key(), size=size,
                )
            except Exception as e:  # 发起失败要如实报,别让客户端以为拿到了可用的地址
                return self._json(502, {"error": "initiate_failed", "detail": str(e)[:200]})
            return self._json(200, out)

        key = new_object_key()
        expires_at = int(time.time()) + PRESIGN_TTL_SECONDS
        url = build_presigned_put(
            access_key_id=ak,
            access_key_secret=sk,
            bucket=bucket,
            endpoint=endpoint,
            key=key,
            expires_at=expires_at,
        )
        self._json(
            200,
            {
                "id": key[len("c/") :],
                "uploadUrl": url,
                "contentType": "application/octet-stream",
                "expiresIn": PRESIGN_TTL_SECONDS,
            },
        )

    def do_GET(self):
        self._handle()

    def do_POST(self):
        # 有的客户端习惯 POST;两种都收,行为一致(请求体不读,签名不依赖它)。
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length:
            self.rfile.read(length)
        self._handle()

    def log_message(self, fmt, *args):
        # 默认实现会把每条请求打到 stderr,含完整 path。这里的 path 不带敏感信息,
        # 但函数日志会长期留存,没必要留 —— 静音。
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
