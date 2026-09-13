#!/usr/bin/env python3
"""Prepare pinned, verified runtime assets. Never runs model-generated commands."""
import hashlib
import pathlib
import shutil
import subprocess
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CACHE = ROOT / '.build' / 'agent-assets'
CACHE.mkdir(parents=True, exist_ok=True)
ASSETS = [
 ('node.tar.gz', 'https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz', 'bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057'),
 ('kernel.tar.zst', 'https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst', '8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5'),
]
for name, url, checksum in ASSETS:
    path = CACHE / name
    if not path.exists():
        partial = path.with_suffix('.download')
        subprocess.run(['/usr/bin/curl', '-fL', '--retry', '2', '-o', str(partial), url], check=True)
        partial.replace(path)
    with path.open('rb') as stream:
        actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    if actual != checksum:
        raise SystemExit(f'Checksum incorrect: {name}. Retirer le cache et réessayer.')
with tarfile.open(CACHE / 'node.tar.gz') as archive:
    for member, output in [('bin/node', 'node'), ('LICENSE', 'NODE-LICENSE')]:
        with archive.extractfile('node-v24.21.0-darwin-arm64/' + member) as source, (CACHE / output).open('wb') as dest:
            shutil.copyfileobj(source, dest)
(CACHE / 'node').chmod(0o755)
with (CACHE / 'vmlinux').open('wb') as dest:
    subprocess.run(['/usr/bin/tar', '-xOf', str(CACHE / 'kernel.tar.zst'), 'opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug'], stdout=dest, check=True)
subprocess.run(['npm', 'ci', '--ignore-scripts', '--prefix', str(ROOT / 'Runtime')], check=True)
print('Runtime Pi, Node et noyau vérifiés.')
