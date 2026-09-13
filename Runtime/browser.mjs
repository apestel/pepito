// Runs ONLY in the networkless browser VM. No arbitrary eval or host paths.
import { chromium } from './playwright-core/index.mjs';
const send=x=>process.stdout.write(JSON.stringify(x)+'\n');
const browser=await chromium.launch({headless:true,args:['--disable-dev-shm-usage']});
const context=await browser.newContext({viewport:{width:1100,height:700},serviceWorkers:'block',acceptDownloads:false});
const page=await context.newPage();
let requests=new Map(), sequence=0, busy=false;
await context.route('**/*',async route=>{
  const request=route.request(),id=String(++sequence);
  try {
    const response=await new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{requests.delete(id);reject(new Error('Network timeout'));},30000);
      requests.set(id,x=>{clearTimeout(timer);resolve(x);});
      send({type:'network',id,url:request.url(),method:request.method(),headers:request.headers(),body:request.postDataBuffer()?.toString('base64')});
    });
    if(response.error) await route.abort('blockedbyclient');
    else await route.fulfill({status:response.status,headers:response.headers,body:Buffer.from(response.body,'base64')});
  } catch { await route.abort().catch(()=>{}); }
});
await context.routeWebSocket('**/*',socket=>socket.close());
async function command(c) {
  if(c.type==='network_result') { requests.get(c.id)?.(c);requests.delete(c.id);return; }
  if(busy) {send({type:'result',id:c.id,error:'Browser busy'});return;}
  busy=true;
  try {
    const a=c.arguments;
    if(a.operation==='open') await page.goto(a.url,{waitUntil:'domcontentloaded',timeout:20000});
    else if(a.operation==='click') {
      if(Number.isFinite(a.x) && Number.isFinite(a.y)) await page.mouse.click(a.x,a.y);
      else await page.locator(a.selector).first().click({timeout:10000});
    } else if(a.operation==='fill') {
      if(a.selector) await page.locator(a.selector).first().fill(a.text,{timeout:10000});
      else await page.keyboard.insertText(a.text);
    } else if(a.operation==='enter') await page.keyboard.press('Enter');
    else if(a.operation==='back') await page.goBack({waitUntil:'domcontentloaded',timeout:15000});
    else if(a.operation!=='snapshot') throw new Error('Unknown operation');
    const text=(await page.locator('body').innerText().catch(()=>'' )).slice(0,12000);
    const elements=await page.locator('a,button,input,textarea,select').evaluateAll(nodes=>nodes.slice(0,70).map(n=>({tag:n.tagName,text:(n.innerText||n.getAttribute('aria-label')||'').slice(0,100),id:n.id,name:n.getAttribute('name'),type:n.getAttribute('type')})));
    send({type:'result',id:c.id,url:page.url(),text:text+'\n'+JSON.stringify(elements),image:(await page.screenshot({type:'jpeg',quality:65})).toString('base64')});
  } catch(e) {send({type:'result',id:c.id,error:String(e.message).slice(0,500)});}
  finally {busy=false;}
}
let buf='';process.stdin.setEncoding('utf8');
process.stdin.on('data',chunk=>{buf+=chunk;if(buf.length>16*1024*1024)process.exit(1);let i;while((i=buf.indexOf('\n'))>=0){const s=buf.slice(0,i);buf=buf.slice(i+1);try{void command(JSON.parse(s));}catch{process.exit(1);}}});
process.stdin.on('end',()=>void browser.close().finally(()=>process.exit(0)));
send({type:'ready'});
