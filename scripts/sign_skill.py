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

依赖:标准库 + `cryptography`(`python3 -c 'import cryptography'` 确认已装;
没装就装进虚拟环境,不要装进系统 Python)。
"""
import base64
import json
import os
import pathlib
import stat
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

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


def refresh_index() -> None:
    skills = []
    for d in sorted(p for p in SKILLS.iterdir() if p.is_dir()):
        for f in sorted(d.glob("*.json")):
            if f.name.endswith(".src.json"):
                continue
            env = json.loads(f.read_text(encoding="utf-8"))
            m = json.loads(env["package"])["manifest"]
            skills.append(
                {"id": m["id"], "version": m["version"], "min_engine": m["min_engine"],
                 "name": m["display"]["name"]}
            )
    (SKILLS / "index.json").write_text(
        json.dumps({"skills": skills}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"index.json: {len(skills)} 个包")


def sign(src: pathlib.Path) -> None:
    if not src.name.endswith(".src.json"):
        sys.exit("输入必须是 <ver>.src.json(仓库里作者维护的那一份)")
    body = src.read_text(encoding="utf-8")
    manifest = json.loads(body)["manifest"]  # 先确认是合法 JSON 且有 manifest,再签
    out = src.with_name(src.name[: -len(".src.json")] + ".json")
    if out.stem != manifest["version"]:
        sys.exit(f"文件名 {out.stem} 与 manifest.version {manifest['version']} 不一致")
    sig = base64.b64encode(_load_key().sign(body.encode("utf-8"))).decode()
    out.write_text(
        json.dumps({"sig": sig, "package": body}, ensure_ascii=False), encoding="utf-8"
    )
    print(f"已签名 -> {out.relative_to(ROOT)}")
    refresh_index()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    arg = sys.argv[1]
    if arg == "--gen-key":
        gen_key()
    elif arg == "--pubkey":
        print_pubkey()
    else:
        sign(pathlib.Path(arg).resolve())
