#!/usr/bin/env python3
"""Create the deployment manifest only from a signed, notarized, audited bundle."""
import argparse
import hashlib
import importlib.util
import json
import plistlib
import re
import subprocess
import uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location('release_audit', Path(__file__).with_name('audit-release.py'))
audit_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit_module)


def generate(app, archive, receipt):
    audit_module.audit(app)
    if receipt.get('status') != 'Accepted':
        raise ValueError('Notarization not accepted')
    notary_id = str(uuid.UUID(receipt['id']))
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    detail = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], capture_output=True, text=True, check=True)
    team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', detail.stderr + detail.stdout, re.M)
    if not team:
        raise ValueError('Signing team unavailable')
    digest = hashlib.sha256()
    with archive.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return {'schema': 1, 'product': 'lossless-system-audio-recorder',
            'version': info['CFBundleShortVersionString'], 'build': int(info['CFBundleVersion']),
            'sha256': digest.hexdigest(), 'bytes': archive.stat().st_size,
            'bundleID': info['CFBundleIdentifier'], 'policyPublicKey': info['RecorderPolicyPublicKey'],
            'signingTeamID': team.group(1), 'notarizationID': notary_id}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'archive', 'notary_result', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    result = generate(args.app, args.archive, json.loads(args.notary_result.read_text()))
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    args.output.chmod(0o600)
    print('已生成与公证制品绑定的部署清单。')
