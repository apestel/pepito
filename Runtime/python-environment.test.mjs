import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

test('model inventory matches shipped wheels, not the whole Pyodide catalogue', () => {
  const runtime = process.env.PEPITO_TEST_RUNTIME ?? fileURLToPath(new URL('.', import.meta.url));
  const root = join(runtime, 'node_modules/pyodide');
  const lock = JSON.parse(readFileSync(join(root, 'pyodide-lock.json'), 'utf8'));
  const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  const prompt = readFileSync(join(root, 'python-environment.txt'), 'utf8');
  assert(prompt.includes(`Pyodide ${version} / CPython ${lock.info.python}`));
  const declared = prompt.split('\n').filter(line => line.startsWith('- '));
  const shipped = Object.values(lock.packages).filter(p => existsSync(join(root, p.file_name)));
  assert.equal(declared.length, shipped.length);
  for (const packageInfo of shipped) {
    assert(declared.some(line => line.startsWith(`- ${packageInfo.name} ${packageInfo.version} (imports : ${packageInfo.imports.join(', ')}).`)));
  }
  // Human guidance is sourced from the same manifest as the wheels.
  const office = JSON.parse(readFileSync(new URL('./python-packages.json', import.meta.url), 'utf8'));
  for (const packageInfo of Object.values(office)) {
    if (packageInfo.description) assert(prompt.includes(packageInfo.description));
  }
});
