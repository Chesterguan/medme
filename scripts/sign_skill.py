#!/usr/bin/env python3
"""给病种 skill 包签名(Ed25519)。

私钥只在本机 `~/.medme_skill_signing_key`(64 个 hex 字符 = 32 字节 seed,
文件权限 600),**永远不进仓库、不进 CI、不进任何日志**。公钥编进 App
(`packages/profile/src/package.rs` 的 `SIGNING_PUBLIC_KEY_HEX`)。

首次使用:
    python3 scripts/sign_skill.py --gen-key      # 只在私钥文件不存在时生成
    python3 scripts/sign_skill.py --pubkey       # 打印公钥 hex,粘进 package.rs

签一个包:
    python3 scripts/sign_skill.py skills/sle/2026.09.1.src.json
        -> 写出 skills/sle/2026.09.1.json(信封),并刷新 skills/index.json

只重签清单(删了一个包之后,不重签任何包内容):
    python3 scripts/sign_skill.py --reindex

自检(临时目录里的一次性密钥,不碰 ~/.medme_skill_signing_key):
    python3 scripts/sign_skill.py --selftest

依赖:标准库 + `cryptography`(`python3 -c 'import cryptography'` 确认已装;
没装就装进虚拟环境,不要装进系统 Python)。
"""
import base64
import json
import os
import pathlib
import re
import shutil
import stat
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

KEY_PATH = pathlib.Path.home() / ".medme_skill_signing_key"
ROOT = pathlib.Path(__file__).resolve().parents[1]
SKILLS = ROOT / "skills"


def _load_key() -> Ed25519PrivateKey:
    if not KEY_PATH.exists():
        sys.exit(f"没有私钥 {KEY_PATH}。先跑 --gen-key(只在你是发布者时)。")
    return Ed25519PrivateKey.from_private_bytes(bytes.fromhex(KEY_PATH.read_text().strip()))


def gen_key() -> None:
    if KEY_PATH.exists():
        sys.exit(f"{KEY_PATH} 已存在 —— 不覆盖。轮换密钥要手动改名备份,别让脚本替你决定。")
    seed = os.urandom(32)
    KEY_PATH.write_text(seed.hex())
    KEY_PATH.chmod(stat.S_IRUSR | stat.S_IWUSR)
    print(f"已生成 {KEY_PATH}(权限 600)。公钥:")
    print_pubkey()


def print_pubkey() -> None:
    from cryptography.hazmat.primitives import serialization

    pub = _load_key().public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
    )
    print(pub.hex())


def _verify_signed(pub: Ed25519PublicKey, env: dict, where: pathlib.Path) -> None:
    """手改过的信封不能被索引——用公钥重新验一遍签,镜像 Rust `verify_envelope`
    (`packages/profile/src/package.rs`)对 `env.package.as_bytes()` 做的同一件事。"""
    try:
        sig = base64.b64decode(env["sig"])
    except Exception as e:
        sys.exit(f"{where}: 签名不是合法 base64:{e}")
    try:
        pub.verify(sig, env["package"].encode("utf-8"))
    except InvalidSignature:
        sys.exit(f"{where}: 签名验证失败 —— 信封被改过,或不是这把私钥签的")


def refresh_index() -> None:
    key = _load_key()
    pub = key.public_key()
    skills = []
    for d in sorted(p for p in SKILLS.iterdir() if p.is_dir()):
        versions = [f for f in sorted(d.glob("*.json")) if not f.name.endswith(".src.json")]
        if len(versions) > 1:
            # 一个目录多个已签名版本时,「清单只收最高版」没有排序保证(文件名不是
            # 排序键,manifest.version 才是),多版本共存也还没设计过降级/并存语义
            # ——先明确拒绝,好过悄悄漏掉一条或悄悄收错一条。
            sys.exit(
                f"{d.name}/ 下有 {len(versions)} 个已签名版本"
                f"({', '.join(v.name for v in versions)})—— 一个目录一次只允许一个"
                "当前版本,先删掉旧版本再重签。"
            )
        for f in versions:
            env = json.loads(f.read_text(encoding="utf-8"))
            _verify_signed(pub, env, f)
            try:
                m = json.loads(env["package"])["manifest"]
                skills.append(
                    {"id": m["id"], "version": m["version"], "min_engine": m["min_engine"],
                     "name": m["display"]["name"]}
                )
            except KeyError as e:
                sys.exit(f"{f}: manifest 缺字段 {e}")
    # 清单与包用**同一种信封**、同一把私钥:不签的话中间人删掉一行就能把用户
    # 按在旧规则上,改一行 version 就能拿它去拼任意路径。
    body = json.dumps({"skills": skills}, ensure_ascii=False, indent=2) + "\n"
    (SKILLS / "index.src.json").write_text(body, encoding="utf-8")
    sig = base64.b64encode(key.sign(body.encode("utf-8"))).decode()
    (SKILLS / "index.json").write_text(
        json.dumps({"sig": sig, "package": body}, ensure_ascii=False), encoding="utf-8"
    )
    print(f"index.json: {len(skills)} 个包(已签名)")


def sign(src: pathlib.Path) -> None:
    if not src.name.endswith(".src.json"):
        sys.exit("输入必须是 <ver>.src.json(仓库里作者维护的那一份)")
    body = src.read_text(encoding="utf-8")
    manifest = json.loads(body)["manifest"]  # 先确认是合法 JSON 且有 manifest,再签
    out = src.with_name(src.name[: -len(".src.json")] + ".json")
    if out.stem != manifest["version"]:
        sys.exit(f"文件名 {out.stem} 与 manifest.version {manifest['version']} 不一致")
    # id 必须等于目录名、且只含小写字母/数字/下划线——与 Rust 侧 `valid_id`
    # (packages/profile/src/package.rs)同一条规则。这里不挡,签出来的包能通过
    # repo_packages_verify(目录名与 index.json 只是碰巧一致),但设备上
    # `cache_store` 会用 `manifest.id` 拼缓存路径,id 里有大写/不合规字符时
    # 直接 `Malformed` 拒绝——包签得出来,却永远缓存不下来。
    if manifest["id"] != out.parent.name or not re.fullmatch(r"[a-z0-9_]+", manifest["id"]):
        sys.exit(
            f"manifest.id {manifest['id']!r} 必须等于目录名 {out.parent.name!r},"
            "且只含小写字母/数字/下划线"
        )
    rel_out = out.relative_to(ROOT)  # 先算完相对路径:src 在仓库外时这里就报错,不留半成品
    sig = base64.b64encode(_load_key().sign(body.encode("utf-8"))).decode()
    out.write_text(
        json.dumps({"sig": sig, "package": body}, ensure_ascii=False), encoding="utf-8"
    )
    print(f"已签名 -> {rel_out}")
    refresh_index()


def _fixture(id_: str, version: str) -> str:
    """自检用的最小合法包体,与 packages/profile/src/package.rs 测试里的 MINIMAL 同构。"""
    return json.dumps(
        {
            "manifest": {
                "id": id_, "family": "immune", "version": version, "min_engine": 1,
                "display": {"name": "自检病", "short": "自检"},
                "disclaimer": "仅整理你的病历,不做诊断",
                "sources": [{"id": "S1", "cite": "test", "url": None}],
            },
            "triggers": {"diagnosis_patterns": [], "serology_any_two": []},
            "terms": {"aliases": {}, "analytes": []},
            "markers": [], "drugs": [],
            "rules": {
                "activity": {"window_days": 10, "max": 18, "items": []},
                "states": [], "monitoring": [], "milestones": [],
            },
            "views": {"sections": [], "handoff": []},
        },
        ensure_ascii=False,
    )


def _expect_refused(fn, desc: str) -> None:
    try:
        fn()
    except SystemExit:
        print(f"  ok: {desc} —— 被拒绝")
        return
    sys.exit(f"selftest 失败:{desc} —— 本该被拒绝,但没有报错退出")


def selftest() -> None:
    """自检:manifest.id 校验(×2)、清单本身也是签名信封、manifest 缺字段给清楚报错、
    一目录多版本给清楚报错、篡改信封拒绝索引。只在临时目录里生成一把一次性密钥,
    不读、不碰、不派生 ~/.medme_skill_signing_key。"""
    import tempfile

    global KEY_PATH, ROOT, SKILLS
    real_key, real_root, real_skills = KEY_PATH, ROOT, SKILLS
    try:
        with tempfile.TemporaryDirectory() as td:
            KEY_PATH = pathlib.Path(td) / "throwaway.key"
            ROOT = pathlib.Path(td)
            SKILLS = ROOT / "skills"
            SKILLS.mkdir()
            gen_key()
            pub = _load_key().public_key()

            # 1. manifest.id 与目录名不符
            (SKILLS / "sle").mkdir()
            bad_dir_src = SKILLS / "sle" / "1.0.0.src.json"
            bad_dir_src.write_text(_fixture("lupus", "1.0.0"), encoding="utf-8")
            _expect_refused(lambda: sign(bad_dir_src), "manifest.id 与目录名不符")
            assert not (SKILLS / "sle" / "1.0.0.json").exists(), "被拒绝的签名不该留下输出文件"

            # 2. manifest.id 含大写(目录名同步用同一个大写值,专测字符集这条规则本身,
            # id==dirname 那一半是过的)。目录名故意不用 "SLE"——macOS 默认文件系统
            # 大小写不敏感,"SLE" 会撞上上一条已建好的 "sle",不是脚本的 bug。
            (SKILLS / "ZZZ").mkdir()
            upper_src = SKILLS / "ZZZ" / "1.0.0.src.json"
            upper_src.write_text(_fixture("ZZZ", "1.0.0"), encoding="utf-8")
            _expect_refused(lambda: sign(upper_src), "manifest.id 含大写")
            assert not (SKILLS / "ZZZ" / "1.0.0.json").exists(), "被拒绝的签名不该留下输出文件"

            # 3. 正常签一份,再手改信封内容——refresh_index 必须拒绝索引
            (SKILLS / "ok").mkdir()
            ok_src = SKILLS / "ok" / "1.0.0.src.json"
            ok_src.write_text(_fixture("ok", "1.0.0"), encoding="utf-8")
            sign(ok_src)  # 先证明正常路径没被前两条的校验挡住

            # 4. 清单本身也是签名信封(不是裸 {"skills":[...]}),同一把私钥验得过。
            idx_env = json.loads((SKILLS / "index.json").read_text(encoding="utf-8"))
            assert set(idx_env) == {"sig", "package"}, "index.json 必须是签名信封"
            _verify_signed(pub, idx_env, SKILLS / "index.json")
            assert json.loads(idx_env["package"])["skills"], "清单里应至少有 ok 这个包"
            print("  ok: 清单也是签过名的信封")

            # 5. manifest 缺字段(min_engine)——refresh_index 必须给出清楚的 sys.exit,
            # 不是 KeyError 堆栈。用完立刻删掉:refresh_index 每次都扫全树,留着这个
            # 坏目录会让后面每一步都因为它而报错,而不是因为各自在测的那件事。
            (SKILLS / "badkey").mkdir()
            bad_manifest = json.loads(_fixture("badkey", "1.0.0"))
            del bad_manifest["manifest"]["min_engine"]
            badkey_src = SKILLS / "badkey" / "1.0.0.src.json"
            badkey_src.write_text(json.dumps(bad_manifest, ensure_ascii=False), encoding="utf-8")
            _expect_refused(lambda: sign(badkey_src), "manifest 缺 min_engine")
            shutil.rmtree(SKILLS / "badkey")

            # 6. 一个目录两个已签名版本——refresh_index 必须报错(不是悄悄只挑一个)。
            # 同样用完就删,不留给后面的步骤添乱。
            (SKILLS / "twover").mkdir()
            v1_src = SKILLS / "twover" / "1.0.0.src.json"
            v1_src.write_text(_fixture("twover", "1.0.0"), encoding="utf-8")
            sign(v1_src)  # 第一版正常
            v2_src = SKILLS / "twover" / "1.0.1.src.json"
            v2_src.write_text(_fixture("twover", "1.0.1"), encoding="utf-8")
            _expect_refused(lambda: sign(v2_src), "一个目录出现两个已签名版本")
            shutil.rmtree(SKILLS / "twover")

            # 7. 正常签的信封被手改——refresh_index 必须拒绝索引。放最后:这一步会让
            # "ok" 永久验不过签,后面不能再指望 refresh_index() 对全树成功。
            ok_env_path = SKILLS / "ok" / "1.0.0.json"
            env = json.loads(ok_env_path.read_text(encoding="utf-8"))
            env["package"] = env["package"].replace("自检病", "被篡改")
            ok_env_path.write_text(json.dumps(env, ensure_ascii=False), encoding="utf-8")
            _expect_refused(refresh_index, "篡改过的信封被 refresh_index 索引")

        print(
            "selftest: 6/6 通过(manifest.id 校验 ×2,清单签名 ×1,manifest 缺字段 ×1,"
            "一目录多版本 ×1,篡改信封拒绝索引 ×1)"
        )
    finally:
        KEY_PATH, ROOT, SKILLS = real_key, real_root, real_skills


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    arg = sys.argv[1]
    if arg == "--gen-key":
        gen_key()
    elif arg == "--pubkey":
        print_pubkey()
    elif arg == "--selftest":
        selftest()
    elif arg == "--reindex":
        refresh_index()
    else:
        sign(pathlib.Path(arg).resolve())
