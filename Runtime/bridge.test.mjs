import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, readdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';

for (const outcome of ['success','refused','cancelled']) test('Pi round trip: '+outcome, {timeout:30000}, async () => {
  const dir=await mkdtemp(join(tmpdir(),'pepito-pi-'));
  let calls=0;
  const server=createServer(async(req,res)=>{
    let raw=''; for await (const chunk of req) raw+=chunk;
    const body=JSON.parse(raw); calls++;
    assert.equal(body.model,'test-model');
    assert.deepEqual(body.tools.map(t=>t.function.name),['probe']);
    res.writeHead(200,{'Content-Type':'text/event-stream'});
    const chunk=(delta,finish_reason=null)=>res.write('data: '+JSON.stringify({id:'c',object:'chat.completion.chunk',choices:[{index:0,delta,finish_reason}]})+'\n\n');
    if (calls===1) {
      chunk({role:'assistant',tool_calls:[{index:0,id:'probe-1',type:'function',function:{name:'probe',arguments:'{"value":"hello"}'}}]});
      chunk({},'tool_calls');
    } else {
      assert.ok(body.messages.some(m=>m.role==='tool' && m.content.includes(outcome==='refused'?'Refus utilisateur':'hello')));
      chunk({role:'assistant',content:'Vérifié\u2028correctement'}); chunk({},'stop');
    }
    res.end('data: [DONE]\n\n');
  }).listen(0,'127.0.0.1');
  await once(server,'listening');
  const child=spawn(process.execPath,[new URL('./bridge.mjs',import.meta.url).pathname],{stdio:['pipe','pipe','pipe'],env:{PATH:process.env.PATH,HOME:dir}});
  let output='', errors=''; child.stderr.on('data',x=>errors+=x);
  const send=x=>child.stdin.write(JSON.stringify(x)+'\n');
  try {
    const done=new Promise((resolve,reject)=>{
      let buf='';
      child.stdout.on('data',chunk=>{
        buf+=chunk; let i;
        while((i=buf.indexOf('\n'))>=0){
          const e=JSON.parse(buf.slice(0,i));buf=buf.slice(i+1);
          if(e.type==='error') { if(outcome==='cancelled' && /abort|annul/i.test(e.text)) resolve(); else reject(new Error(e.text)); }
          if(e.type==='ready') send({type:'prompt',text:'Call probe with hello then report.'});
          if(e.type==='tool') {
            if(outcome==='cancelled') send({type:'abort'});
            else send({type:'tool_result',id:e.id,...(outcome==='refused'?{error:'Refus utilisateur'}:{text:e.arguments.value})});
          }
          if(e.type==='delta') output+=e.text;
          if(e.type==='done') resolve();
        }
      });
      child.on('exit',code=>reject(new Error(`Exit ${code}: ${errors}`)));
    });
    const start=JSON.stringify({type:'start',endpoint:`http://127.0.0.1:${server.address().port}/v1`,model:'test-model',token:'test-token',budget:24000,sessionDirectory:dir,probe:true,systemPrompt:'Test assistant.'})+'\n';
    // Split framing deliberately.
    child.stdin.write(start.slice(0,31)); child.stdin.write(start.slice(31));
    await done;
    assert.equal(calls,outcome==='cancelled'?1:2);
    assert.equal(output,outcome==='cancelled'?'':'Vérifié\u2028correctement');
    for (const path of await readdir(dir,{recursive:true,withFileTypes:true})) if(path.isFile()) {
      assert.ok(!(await readFile(join(path.parentPath,path.name),'utf8')).includes('test-token'));
    }
  } finally { child.kill('SIGKILL'); server.closeAllConnections(); server.close(); await rm(dir,{recursive:true,force:true}); }
});

test('Pi resumes the same local session after process exit', {timeout:30000}, async()=>{
  const dir=await mkdtemp(join(tmpdir(),'pepito-resume-'));
  let calls=0;
  const server=createServer(async(req,res)=>{
    let raw='';for await(const chunk of req)raw+=chunk;
    const body=JSON.parse(raw);calls++;
    if(calls===2) assert.ok(body.messages.some(m=>m.role==='user'&&JSON.stringify(m.content).includes('first instruction')));
    res.writeHead(200,{'Content-Type':'text/event-stream'});
    for(const [delta,finish_reason] of [[{role:'assistant',content:'Ready'},null],[{},'stop']]) res.write('data: '+JSON.stringify({id:'r',object:'chat.completion.chunk',choices:[{index:0,delta,finish_reason}]})+'\n\n');
    res.end('data: [DONE]\n\n');
  }).listen(0,'127.0.0.1');
  await once(server,'listening');
  try {
    for(const text of ['first instruction','second instruction']) {
      const child=spawn(process.execPath,[new URL('./bridge.mjs',import.meta.url).pathname],{stdio:['pipe','pipe','pipe'],env:{HOME:dir,PATH:process.env.PATH}});
      const exited=once(child,'exit');
      const send=x=>child.stdin.write(JSON.stringify(x)+'\n');
      try {
        const done=new Promise((resolve,reject)=>{
          let buf='';child.stdout.on('data',chunk=>{buf+=chunk;let i;while((i=buf.indexOf('\n'))>=0){
            const e=JSON.parse(buf.slice(0,i));buf=buf.slice(i+1);
            if(e.type==='ready')send({type:'prompt',text});
            if(e.type==='done')resolve();
            if(e.type==='error')reject(new Error(e.text));
          }});
          child.on('exit',()=>reject(new Error('Premature process exit')));
        });
        send({type:'start',endpoint:`http://127.0.0.1:${server.address().port}/v1`,model:'test-model',token:'temporary-key',budget:24000,sessionDirectory:dir,systemPrompt:'Test.'});
        await done;child.stdin.end();
        const [code]=await exited;assert.equal(code,0);
      } finally { if(child.exitCode===null)child.kill('SIGKILL'); }
    }
    assert.equal(calls,2);
  } finally { server.closeAllConnections();server.close();await rm(dir,{recursive:true,force:true}); }
});
