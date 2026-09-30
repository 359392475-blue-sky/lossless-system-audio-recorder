#!/usr/bin/env python3
"""Sign a prepared release and its Sparkle feed without uploading anything."""
import argparse
import hashlib
import json
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--sign-tool", required=True, type=Path)
    parser.add_argument("--account", required=True)
    parser.add_argument("--origin", required=True)
    parser.add_argument("--notes", required=True)
    args = parser.parse_args()
    origin = urlsplit(args.origin)
    if (origin.scheme != "https" or not origin.hostname or origin.username
            or origin.password or origin.query or origin.fragment or origin.path not in ("", "/")):
        parser.error("origin 必须为无路径、无凭据的 HTTPS 地址")
    manifest = json.loads((args.directory / "release-manifest.json").read_text())
    archives = list(args.directory.glob("*-universal.zip"))
    if len(archives) != 1:
        parser.error("目录必须恰有一个最终通用 ZIP")
    archive = archives[0]
    if (archive.stat().st_size != manifest["bytes"]
            or hashlib.sha256(archive.read_bytes()).hexdigest() != manifest["sha256"]):
        parser.error("ZIP 与发布清单不一致")
    feed = args.directory / "appcast.xml"
    if feed.exists():
        parser.error("appcast 已存在，拒绝覆盖")
    command = [str(args.sign_tool), "--account", args.account]
    signature = subprocess.check_output(command + ["-p", str(archive)], text=True).strip()
    subprocess.run(command + ["--verify", str(archive), signature], check=True)
    ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    ET.register_namespace("sparkle", ns)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "无损系统录音机"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = manifest["version"]
    ET.SubElement(item, "description").text = args.notes
    ET.SubElement(item, f"{{{ns}}}minimumSystemVersion").text = "14.2"
    ET.SubElement(item, "enclosure", {
        "url": args.origin.rstrip("/") + "/artifacts/" + archive.name,
        "length": str(manifest["bytes"]), "type": "application/octet-stream",
        f"{{{ns}}}version": str(manifest["build"]),
        f"{{{ns}}}shortVersionString": manifest["version"],
        f"{{{ns}}}edSignature": signature,
    })
    with feed.open("xb") as stream:
        ET.ElementTree(rss).write(stream, encoding="utf-8", xml_declaration=True)
    subprocess.run(command + [str(feed)], check=True)
    subprocess.run(command + ["--verify", str(feed)], check=True)
    print("ZIP 和更新清单签名已验证；尚未上传。")


if __name__ == "__main__":
    main()
