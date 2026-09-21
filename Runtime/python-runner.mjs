// Runs inside the same Seatbelt process boundary as JavaScript and shell.
import { loadPyodide } from 'pyodide';
import { mkdirSync, readdirSync, copyFileSync, constants } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

try {
  const root = process.cwd();
  const cache = join(root, '.pyodide-cache');
  mkdirSync(cache, { recursive: true, mode: 0o700 });
  const bundled = fileURLToPath(new URL('./node_modules/pyodide/', import.meta.url));
  for (const name of readdirSync(bundled).filter(name => name.endsWith('.whl') || name.endsWith('.zip') && name !== 'python_stdlib.zip')) {
    try { copyFileSync(join(bundled, name), join(cache, name), constants.COPYFILE_EXCL); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
  }
  const python = await loadPyodide({
    packageCacheDir: cache,
    jsglobals: Object.freeze({ fetch, AbortController, AbortSignal, Object, Request, Headers }),
    stdout: text => process.stdout.write(text + '\n'),
    stderr: text => process.stderr.write(text + '\n'),
  });
  // Only the mission is mounted. Seatbelt also enforces the boundary for JS bridges.
  python.FS.mkdir('/workspace');
  python.mountNodeFS('/workspace', root);
  python.FS.chdir('/workspace');
  python.runPython("import os\nos.environ['PEPITO_WORKSPACE'] = '/workspace'\nos.environ['MPLBACKEND'] = 'Agg'\nos.environ['HOME'] = '/workspace'\nos.environ['TMPDIR'] = '/tmp'");
  const code = process.argv[2];
  await python.loadPackagesFromImports(code, { messageCallback: () => {}, errorCallback: text => process.stderr.write(text + '\n') });
  const result = await python.runPythonAsync(code);
  result?.destroy?.();
} catch (error) {
  process.stderr.write(String(error) + '\n');
  process.exitCode = 1;
}
