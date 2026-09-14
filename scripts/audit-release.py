#!/usr/bin/env python3
"""Validate a notarized universal bundle before public distribution."""
import argparse
import importlib.util
from pathlib import Path
import plistlib
import re
import subprocess

spec = importlib.util.spec_from_file_location("release_configuration", Path(__file__).with_name("configure-release.py"))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True, check=True)
    return result.stdout + result.stderr


def audit(app):
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    config.configuration({env: info.get(key, "") for env, key in config.ENV_KEYS.items()})
    if not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("缺少强制签名验证配置")
    if info.get("CFBundleIdentifier") != "app.lowpower.lossless-system-audio-recorder":
        raise ValueError("应用身份不匹配")
    if int(info.get("CFBundleVersion", "0")) < 5:
        raise ValueError("拒绝发布不包含在线准入的旧版本")
    executable = contents / "MacOS" / info["CFBundleExecutable"]
    binaries = {executable.resolve()}
    for candidate in (contents / "Frameworks").rglob("*"):
        if candidate.is_file() and "Mach-O" in run("file", "-b", str(candidate)):
            binaries.add(candidate.resolve())
    for binary in binaries:
        architectures = run("lipo", "-archs", str(binary)).split()
        if not {"arm64", "x86_64"}.issubset(architectures):
            raise ValueError(f"主程序与所有更新组件必须含双架构：{binary}")
        for arch in ("arm64", "x86_64"):
            commands = run("otool", "-arch", arch, "-l", str(binary))
            versions = re.findall(r"^\s+minos\s+(\d+\.\d+(?:\.\d+)?)", commands, re.M) + re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+\.\d+(?:\.\d+)?)", commands)
            if not versions or any(tuple(map(int, value.split("."))) > (14, 2, 0)
                                   for value in versions):
                raise ValueError(f"组件最低系统高于声明的 macOS 14.2，或无法验证：{binary} ({arch})")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    identity = run("codesign", "-dv", "--verbose=4", str(app))
    if "Authority=Developer ID Application:" not in identity:
        raise ValueError("正式包必须使用 Developer ID Application 签名")
    for name in ("LICENSE.txt", "Privacy.md", "Sparkle-LICENSE.txt"):
        if not (contents / "Resources" / name).is_file():
            raise ValueError(f"缺少随包说明：{name}")
    run("xcrun", "stapler", "validate", str(app))
    run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        audit(args.app)
        print("发布静态检查通过：在线配置、版本、双架构、Developer ID、公证票据和 Gatekeeper。仍需线上与真实升级验收。")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"发布检查失败：{error}\n")
