import argparse
import base64
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse


def manifest(version, url, signature, notes):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?', version):
        raise ValueError('Invalid release version')
    parsed = urlparse(url)
    if parsed.scheme != 'https' or parsed.netloc != 'github.com' or not parsed.path.startswith('/ibreez3/orbit/releases/download/'):
        raise ValueError('Updater asset must be an HTTPS release asset in ibreez3/orbit')
    if not parsed.path.endswith('.exe'):
        raise ValueError('Expected an NSIS installer')
    decoded = base64.b64decode(signature.strip(), validate=True).decode('utf-8')
    if not decoded.startswith('untrusted comment:') or 'trusted comment:' not in decoded:
        raise ValueError('Invalid Tauri signature file')
    if not notes.strip():
        raise ValueError('Release notes must not be empty')
    return {'version': version, 'notes': notes.strip(), 'pub_date': datetime.now(timezone.utc).isoformat(),
            'platforms': {'windows-x86_64': {'signature': signature.strip(), 'url': url}}}


def main():
    parser = argparse.ArgumentParser()
    for name in ['version', 'url', 'signature', 'notes', 'output']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    result = manifest(args.version, args.url, Path(args.signature).read_text(encoding='utf-8'), Path(args.notes).read_text(encoding='utf-8'))
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
