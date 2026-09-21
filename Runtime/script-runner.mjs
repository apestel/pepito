// Trusted supervisor. The model's code only runs after sandbox-exec has applied the policy.
import { spawn } from 'node:child_process';
import { realpathSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
export function profile(root, runtime, network = false) {
  const quote = s => JSON.stringify(s);
  const reads = ['/System/Library', '/System/Volumes/Preboot/Cryptexes/OS', '/usr/lib', '/usr/bin', '/usr/share', '/bin', '/sbin',
    '/Library/Developer', '/Library/Apple', '/Applications/Xcode.app/Contents/Developer', root, runtime];
  return `(version 1)
(deny default)
(allow process-exec process-fork)
(allow signal (target same-sandbox))
${network ? '(allow network-outbound) (allow mach-lookup (global-name "com.apple.SystemConfiguration.configd") (global-name "com.apple.networkd") (global-name "com.apple.trustd.agent")) (allow file-read* (literal "/private/etc/resolv.conf") (literal "/private/etc/hosts") (literal "/private/etc/services") (subpath "/private/etc/ssl"))' : ''}
(allow sysctl-read)
(allow file-read-metadata)
(allow file-read* ${reads.map(p => `(subpath ${quote(p)})`).join(' ')})
(allow file-read* (literal "/") (literal ${quote(process.execPath)}) (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random"))
(allow file-write* (subpath ${quote(root)}) (literal "/dev/null"))
(allow mach-lookup (global-name "com.apple.system.logger") (global-name "com.apple.system.notification_center"))`;
}
export async function runScript(request, signal) {
  const root = realpathSync(request.root), runtime = dirname(fileURLToPath(import.meta.url));
  if (typeof request.code !== 'string' || Buffer.byteLength(request.code) > 262144) throw Error('Script trop volumineux');
  const python = ['/Applications/Xcode.app/Contents/Developer/usr/bin/python3','/Library/Developer/CommandLineTools/usr/bin/python3'].find(existsSync);
  if (request.language === 'python' && !python) throw Error('Python 3 absent. Installez les outils de développement Apple.');
  const command = {python:[python,'-I','-B','-c'], javascript:[process.execPath,'-e'], shell:['/bin/bash','--noprofile','--norc','-c']}[request.language];
  if (!command) throw Error('Langage inconnu');
  const timeout = Math.max(100, Math.min(180000, request.timeout_ms ?? 60000));
  const temp = join(root,'.tmp'); mkdirSync(temp,{recursive:true,mode:0o700});
  return await new Promise((resolve,reject) => {
    const start = performance.now();
    const child = spawn('/usr/bin/sandbox-exec',['-p',profile(root,runtime,request.network === true),'/bin/bash','--noprofile','--norc','-c','ulimit -f 204800; ulimit -t 60; exec "$@"','pepito',...command,request.code],{
      cwd:root, detached:true, env:{PATH:`${runtime}:/usr/bin:/bin:/usr/sbin:/sbin`,HOME:root,TMPDIR:temp,
        PEPITO_WORKSPACE:root,LANG:'en_US.UTF-8'}, stdio:['ignore','pipe','pipe']});
    let stdout='',stderr='',bytes=0,reason;
    const kill = () => { try { process.kill(-child.pid,'SIGKILL'); } catch {} };
    const abort = () => { reason='Exécution annulée'; kill(); };
    signal?.addEventListener('abort',abort,{once:true});
    if (signal?.aborted) abort();
    const timer=setTimeout(()=>{reason='Délai d’exécution dépassé';kill();},timeout);
    const collect = key => chunk => {
      bytes += Buffer.byteLength(chunk);
      if (bytes > 4*1024*1024) {reason='Sortie supérieure à 4 Mio';kill();return;}
      if(key==='stdout') stdout+=chunk; else stderr+=chunk;
    };
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data',collect('stdout'));child.stderr.on('data',collect('stderr'));
    child.once('error',error=>{clearTimeout(timer);signal?.removeEventListener('abort',abort);reject(error);});
    // Terminate descendants even if the parent exits while background processes hold its pipes.
    child.once('exit',kill);
    child.once('close',(code,exitSignal)=>{
      clearTimeout(timer);signal?.removeEventListener('abort',abort);
      resolve({stdout,stderr:stderr+(reason ? `\n${reason}` : exitSignal ? `\nSignal : ${exitSignal}` : ''),exitCode:reason ? -1 : (code ?? -1),duration:(performance.now()-start)/1000});
    });
  });
}
if(process.argv[1]===fileURLToPath(import.meta.url)) {
  const controller=new AbortController();let input='',started=false;
  process.stdin.setEncoding('utf8');
  process.stdin.on('data',chunk=>{
    if(started)return; input+=chunk;
    if(input.length>1048576)process.exit(1);
    if(!input.includes('\n'))return; started=true;
    void (async()=>{try {process.stdout.write(JSON.stringify(await runScript(JSON.parse(input),controller.signal))+'\n');}
      catch(e){process.stdout.write(JSON.stringify({stdout:'',stderr:e.message,exitCode:-1,duration:0})+'\n');}
      finally{process.exit(0);}})();
  });
  process.stdin.on('end',()=>controller.abort());
  process.on('SIGTERM',()=>controller.abort());
}
