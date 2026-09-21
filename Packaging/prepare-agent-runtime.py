#!/usr/bin/env python3
"""Prepare pinned, verified runtime assets. Never runs model-generated commands."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CACHE = ROOT / '.build' / 'agent-assets'
CACHE.mkdir(parents=True, exist_ok=True)
ASSETS = [
 ('node.tar.gz', 'https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz', 'bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057'),
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
subprocess.run(['npm', 'ci', '--ignore-scripts', '--prefix', str(ROOT / 'Runtime')], check=True)
# Offline Python baseline; wheel hashes come from the npm integrity-locked Pyodide lockfile.
pyodide = ROOT / 'Runtime' / 'node_modules' / 'pyodide'
lock = json.loads((pyodide / 'pyodide-lock.json').read_text())
version = json.loads((pyodide / 'package.json').read_text())['version']
office = json.loads((ROOT / 'Runtime' / 'python-packages.json').read_text())
lock['packages'].update({name: {k: v for k, v in package.items() if k not in ('url', 'description')}
                         for name, package in office.items()})
visited = set()
def wheel(name):
    if name in visited:
        return
    visited.add(name)
    package = lock['packages'][name]
    for dependency in package['depends']:
        wheel(dependency)
    filename = package['file_name']
    cached = CACHE / ('pyodide-' + version) / filename
    cached.parent.mkdir(parents=True, exist_ok=True)
    if not cached.exists():
        partial = cached.with_suffix('.download')
        subprocess.run(['/usr/bin/curl', '-fL', '--retry', '2', '-o', str(partial),
                        office.get(name, {}).get('url', f'https://cdn.jsdelivr.net/pyodide/v{version}/full/{filename}')], check=True)
        partial.replace(cached)
    if hashlib.sha256(cached.read_bytes()).hexdigest() != package['sha256']:
        raise SystemExit(f'Checksum incorrect: {filename}')
    shutil.copy2(cached, pyodide / filename)
for name in ['micropip', 'numpy', 'pandas', 'matplotlib', 'pillow', *office]:
    wheel(name)
# Register pure-Python Office wheels for automatic import loading, including dependencies.
(pyodide / 'pyodide-lock.json').write_text(json.dumps(lock))
# Describe exactly the verified wheels shipped in this build, not the entire CDN catalogue.
lines = [f"Python : Pyodide {version} / CPython {lock['info']['python']} (WebAssembly).",
         "Bibliothèques embarquées, disponibles hors ligne (imports chargés automatiquement) :"]
for name in sorted(visited):
    package = lock['packages'][name]
    imports = ', '.join(package['imports'])
    description = office.get(name, {}).get('description', '')
    lines.append(f"- {package['name']} {package['version']} (imports : {imports}). {description}".rstrip())
(pyodide / 'python-environment.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')
print('Runtime Pi, Node et Pyodide vérifiés.')
