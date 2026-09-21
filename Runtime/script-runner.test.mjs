import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,writeFileSync,rmSync,existsSync,realpathSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import http from 'node:http';
import {runScript,profile} from './script-runner.mjs';

test('profile grants network only on explicit request',()=>{
  assert(!profile('/private/tmp/task','/runtime').includes('(allow network-outbound)'));
  assert(profile('/private/tmp/task','/runtime',true).includes('(allow network-outbound)'));
});
test('profile no longer grants access to Apple developer tools',()=>{
  assert(!profile('/private/tmp/task','/runtime').includes('/Library/Developer'));
});
test('native isolation, scratchpad persistence, network grant and timeout', {skip:process.platform!=='darwin'},async()=>{
  const base=realpathSync(mkdtempSync(join(tmpdir(),'pepito-isolation-')));
  const root=join(base,'work');const {mkdirSync}=await import('node:fs');mkdirSync(root);
  const secret=join(base,'secret.txt');writeFileSync(secret,'fake-secret-for-test');
  const run=(language,code,extra={})=>runScript({root,language,code,...extra});
  try {
    for(const [language,code] of [['python','print(6*7)'],['javascript','console.log(6*7)'],['shell','printf 42']]){
      const r=await run(language,code);assert.equal(r.exitCode,0,r.stderr);assert.equal(r.stdout.trim(),'42');
    }
    const denied=await run('python',`import os\ntry: open(${JSON.stringify(secret)}).read()\nexcept OSError: print('denied')\nelse: raise Exception('escaped')\nassert not any('TOKEN' in k or 'KEY' in k for k in os.environ)\nopen('result.txt','w').write('persisted')`);
    assert.equal(denied.exitCode,0,denied.stderr);assert.match(denied.stdout,/denied/);
    assert.equal(readFileSync(join(root,'result.txt'),'utf8'),'persisted');
    const pythonAgain=await run('python',"import sys\nassert sys.platform == 'emscripten'\nassert open('result.txt').read() == 'persisted'\nimport numpy as np\nassert int(np.sum([20,22])) == 42");
    assert.equal(pythonAgain.exitCode,0,pythonAgain.stderr);
    const libraries=await run('python',"import pandas as pd\nimport matplotlib.pyplot as plt\nimport micropip\nawait micropip.install('pillow')\nassert pd.DataFrame({'n':[42]}).n.sum() == 42\nplt.plot([1,2]); plt.savefig('chart.png')");
    assert.equal(libraries.exitCode,0,libraries.stderr);assert(existsSync(join(root,'chart.png')));
    const pythonTimeout=await run('python','while True: pass',{timeout_ms:1500});
    assert.notEqual(pythonTimeout.exitCode,0);assert.match(pythonTimeout.stderr,/Délai/);
    const alias=await run('shell',`cat ${JSON.stringify('/System/Volumes/Data'+secret)}`);
    assert.notEqual(alias.exitCode,0,'Data volume alias must not grant access to user files');
    const link=await run('shell',`ln ${JSON.stringify(secret)} linked.txt && cat linked.txt`);
    assert.notEqual(link.exitCode,0,'Hard links must not import unauthorized content');
    assert.equal((await run('shell','cat result.txt')).stdout,'persisted');
    const outside=await run('shell',`echo bad > ${JSON.stringify(join(base,'outside'))}`);
    assert.notEqual(outside.exitCode,0);assert(!existsSync(join(base,'outside')));
    const server=http.createServer((req,res)=>res.end('network-ok'));await new Promise(r=>server.listen(0,'127.0.0.1',r));
    try {
      const pythonFetch=`from pyodide.http import pyfetch\nr = await pyfetch('http://127.0.0.1:${server.address().port}')\nprint(await r.string())`;
      assert.notEqual((await run('python',pythonFetch)).exitCode,0);
      const fetched=await run('python',pythonFetch,{network:true});
      assert.equal(fetched.exitCode,0,fetched.stderr);assert.match(fetched.stdout,/network-ok/);
      const command=`/usr/bin/curl --noproxy '*' --max-time 2 -fsS http://127.0.0.1:${server.address().port}`;
      assert.notEqual((await run('shell',command)).exitCode,0);
      const allowed=await run('shell',command,{network:true});assert.equal(allowed.exitCode,0,allowed.stderr);assert.equal(allowed.stdout,'network-ok');
    } finally {server.close();}
    const timed=await run('shell','sleep 10',{timeout_ms:150});assert.notEqual(timed.exitCode,0);assert.match(timed.stderr,/Délai/);assert(timed.duration<3);
    const controller=new AbortController();const pending=runScript({root,language:'shell',code:'sleep 10'},controller.signal);setTimeout(()=>controller.abort(),150);
    assert.match((await pending).stderr,/annulée/);
    const descendants=await run('shell','(sleep 1; echo leaked > late.txt) & exit 0');
    assert(descendants.duration<3);await new Promise(r=>setTimeout(r,1100));assert(!existsSync(join(root,'late.txt')));
    const flood=await run('python',"print('x'*5000000)");assert.notEqual(flood.exitCode,0);assert.match(flood.stderr,/4 Mio/);
  } finally {rmSync(base,{recursive:true,force:true});}
});

test('supervisor flushes large JSON results before exiting', {skip:process.platform!=='darwin', timeout:10000}, async()=>{
  const {spawn}=await import('node:child_process');
  const root=realpathSync(mkdtempSync(join(tmpdir(),'pepito-result-')));
  try {
    const child=spawn(process.execPath,[new URL('./script-runner.mjs',import.meta.url).pathname],{stdio:['pipe','pipe','pipe']});
    let output='',errors='';
    child.stdout.setEncoding('utf8');child.stderr.setEncoding('utf8');
    child.stdout.on('data',chunk=>output+=chunk);child.stderr.on('data',chunk=>errors+=chunk);
    const done=new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',resolve);});
    child.stdin.write(JSON.stringify({root,language:'javascript',code:"console.log('x'.repeat(1000000))"})+'\n');
    assert.equal(await done,0,errors);
    const result=JSON.parse(output);
    assert.equal(result.exitCode,0,result.stderr);
    assert.equal(result.stdout,'x'.repeat(1000000)+'\n');
  } finally {rmSync(root,{recursive:true,force:true});}
});
