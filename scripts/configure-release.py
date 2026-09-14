#!/usr/bin/env python3
"""Fail closed before packaging; never create a distributable offline app."""
import argparse
import base64
import os
import ipaddress
import plistlib
from pathlib import Path
from urllib.parse import urlsplit

ENV_KEYS = {
    "LOSSLESS_RECORDER_UPDATE_FEED_URL": "SUFeedURL",
    "LOSSLESS_RECORDER_UPDATE_PUBLIC_KEY": "SUPublicEDKey",
    "LOSSLESS_RECORDER_POLICY_URL": "RecorderPolicyURL",
    "LOSSLESS_RECORDER_POLICY_PUBLIC_KEY": "RecorderPolicyPublicKey",
}


def configuration(env):
    result = {}
    for name, key in ENV_KEYS.items():
        value = env.get(name, "").strip()
        if not value:
            raise ValueError(f"缺少必需的发布配置：{name}；拒绝生成纯离线包")
        if name.endswith("URL"):
            url = urlsplit(value)
            host = url.hostname or ""
            try:
                nonpublic_ip = not ipaddress.ip_address(host).is_global
            except ValueError:
                nonpublic_ip = False
            if (nonpublic_ip or url.scheme != "https" or not host or url.username is not None
                    or url.password is not None or url.fragment or url.query
                    or host in {"localhost", "example.com", "example.org", "example.net"}
                    or host.endswith((".localhost", ".invalid", ".test", ".example"))):
                raise ValueError(f"{name} 必须为无账号、无查询参数的正式 HTTPS 地址")
        else:
            try:
                raw = base64.b64decode(value, validate=True)
            except (ValueError, TypeError) as error:
                raise ValueError(f"{name} 不是有效 Base64 公钥") from error
            if len(raw) != 32 or len(set(raw)) == 1:
                raise ValueError(f"{name} 必须为真实的 32 字节 Ed25519 公钥")
        result[key] = value
    result.update(SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                  SUAllowsAutomaticUpdates=False, SUAutomaticallyUpdate=False,
                  SUEnableSystemProfiling=False)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plist", type=Path, help="验证后将配置写入生成的应用 plist")
    args = parser.parse_args()
    try:
        values = configuration(os.environ)
        if args.plist:
            with args.plist.open("rb") as stream:
                info = plistlib.load(stream)
            info.update(values)
            with args.plist.open("wb") as stream:
                plistlib.dump(info, stream)
        print("发布配置完整：强制在线版本验证 + 独立签名更新。")
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
