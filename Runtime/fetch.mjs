// Trusted host broker. Pin DNS results; never follow redirects or inherit proxy settings.
import { lookup } from 'node:dns/promises';
import { BlockList } from 'node:net';
import http from 'node:http';
import https from 'node:https';
export const blocked=new BlockList();
for(const [address,prefix] of [['0.0.0.0',8],['10.0.0.0',8],['100.64.0.0',10],['127.0.0.0',8],['169.254.0.0',16],['172.16.0.0',12],['192.168.0.0',16],['192.0.0.0',24],['198.18.0.0',15],['224.0.0.0',4],['240.0.0.0',4]])blocked.addSubnet(address,prefix,'ipv4');
for(const [address,prefix] of [['::',128],['::1',128],['64:ff9b::',96],['100::',64],['2001::',32],['2002::',16],['fc00::',7],['fe80::',10],['ff00::',8]])blocked.addSubnet(address,prefix,'ipv6');
export async function fetchRequest(c) {
  const u=new URL(c.url);
  if(!['http:','https:'].includes(u.protocol)||u.username||u.password||!c.allowedHosts.includes(u.hostname)||u.port && !['80','443'].includes(u.port))throw new Error('Destination refusée');
  if(!['GET','HEAD'].includes(c.method)&&!c.manual)throw new Error('Cette requête nécessite la prise de contrôle manuelle.');
  const addresses=await lookup(u.hostname.replace(/^\[|\]$/g,''),{all:true});
  if(!addresses.length||addresses.some(a=>blocked.check(a.address,a.family===4?'ipv4':'ipv6')))throw new Error('Réseau privé interdit');
  const selected=addresses[0];
  const headers={...c.headers};for(const key of Object.keys(headers))if(['host','connection','proxy-authorization','proxy-connection','transfer-encoding','content-length','accept-encoding'].includes(key.toLowerCase()))delete headers[key];
  headers['accept-encoding']='identity';
  const body=Buffer.from(c.body||'','base64');if(body.length>1024*1024)throw new Error('Requête trop volumineuse');
  return await new Promise((resolve,reject)=>{
    const request=(u.protocol==='https:'?https:http).request(u,{method:c.method,headers,timeout:20000,
      lookup:(_host,opts,cb)=>opts.all?cb(null,[selected]):cb(null,selected.address,selected.family)},res=>{
      const chunks=[];let length=0;
      res.on('data',chunk=>{length+=chunk.length;if(length>8*1024*1024){res.destroy(new Error('Réponse trop volumineuse'));}else chunks.push(chunk);});
      res.on('error',reject);res.on('end',()=>{
        const resultHeaders={};for(const [key,value] of Object.entries(res.headers))if(!['transfer-encoding','connection','content-length'].includes(key)&&value!==undefined)resultHeaders[key]=Array.isArray(value)?value.join('\n'):value;
        resolve({status:res.statusCode,headers:resultHeaders,body:Buffer.concat(chunks).toString('base64')});
      });
    });
    request.on('error',reject);request.on('timeout',()=>request.destroy(new Error('Délai réseau dépassé')));
    request.end(body.length?body:undefined);
  });
}
if(process.argv[1]===new URL(import.meta.url).pathname){
  const deadline=setTimeout(()=>{console.log(JSON.stringify({error:'Délai réseau dépassé'}));process.exit(1);},25000);
  let input='';for await(const chunk of process.stdin){input+=chunk;if(input.length>2*1024*1024)process.exit(1);}
  try{console.log(JSON.stringify(await fetchRequest(JSON.parse(input))));}catch(e){console.log(JSON.stringify({error:e.message}));}finally{clearTimeout(deadline);}
}
