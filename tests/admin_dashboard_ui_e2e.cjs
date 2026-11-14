// Build web first. Synthetic data is confined to this local browser fixture.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const http=require('node:http'),fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'../web/dist');
const pages={'/admin':'admin','/admin/nodes':'admin_nodes','/admin/users':'admin_users','/admin/announcements':'admin_announcements'};
const server=http.createServer((req,res)=>{
 const name=new URL(req.url,'http://localhost').pathname,file=path.resolve(root,'.'+(pages[name]?'/pages/'+pages[name]+'.html':name));
 if(!file.startsWith(root+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return}
 res.setHeader('Content-Type',({'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css','.svg':'image/svg+xml'})[path.extname(file)]||'application/octet-stream');fs.createReadStream(file).pipe(res);
});
(async()=>{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
 try{
  browser=await chromium.launch({headless:true,...(process.env.NEKOPASS_BROWSER?{executablePath:process.env.NEKOPASS_BROWSER}:{})});
  const page=await browser.newPage({viewport:{width:1720,height:1080}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>localStorage.setItem('nekopass-theme-v3','dark'));
  let revision=0,active=0,maxActive=0;const ranges=[],requests=[];
  function dashboard(range){
   const now=Date.now(),at=Math.floor(now/1000),day=Math.floor((at+28800)/86400)*86400-28800;
   return {generated_at:new Date(now+revision).toISOString(),timezone:'Asia/Shanghai',range,unit:'bytes',stats:{users:1284+revision,new_users:12,nodes:20,enabled_nodes:20,online_nodes:18,offline_nodes:2,rules:312,connections:8642,today_traffic:5*1024**4},traffic:range==='24h'?Array.from({length:25},(_,i)=>({at:Math.floor(at/3600)*3600-(24-i)*3600,bytes:(200+i*15)*1024**2})):Array.from({length:range==='7d'?7:30},(_,i)=>({at:day-((range==='7d'?6:29)-i)*86400,bytes:(i+1)*1024**3})),nodes:['香港 01','香港 02','东京 01'].map((name,i)=>({id:i+1,name,enabled:true,online:i!==1}))};
  }
  await page.route('**/api/v1/**',async route=>{
   const url=new URL(route.request().url()),endpoint=url.pathname;requests.push(url.pathname+url.search);
   if(endpoint.endsWith('/me'))return route.fulfill({json:{id:1,username:'管理员',is_admin:true}});
   if(endpoint.endsWith('/admin/dashboard')){
    const range=url.searchParams.get('range')||'24h';ranges.push(range);active++;maxActive=Math.max(maxActive,active);await new Promise(r=>setTimeout(r,80));const data=dashboard(range);active--;return route.fulfill({json:data});
   }
   if(endpoint.endsWith('/admin/nodes'))return route.fulfill({json:[{id:1,name:'在线节点',enabled:true,online:true},{id:2,name:'离线节点',enabled:true,online:false}]});
   if(endpoint.endsWith('/admin/users')||endpoint.endsWith('/admin/node-groups')||endpoint.endsWith('/admin/announcements'))return route.fulfill({json:[]});
   return route.fulfill({json:{site_name:'Nekopass'}});
  });
  const base='http://127.0.0.1:'+server.address().port;
  await page.goto(base+'/admin');await page.getByTestId('admin-overview').waitFor();
  for(const text of ['后台概览','全网流量','节点概况'])assert.equal(await page.getByText(text,{exact:true}).isVisible(),true,text);
  assert.equal(await page.locator('.dashboard-stat').count(),4);
  const traffic=page.getByTestId('dashboard-traffic-chart');
  await traffic.locator('[data-series="rx"]').waitFor();
  await page.getByRole('button',{name:'7 天',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.dashboard-chart-legend')?.textContent.includes('每日累计流量'));
  await page.getByRole('button',{name:'30 天',exact:true}).click();await page.waitForTimeout(200);await page.getByRole('button',{name:'24 小时',exact:true}).click();await page.waitForTimeout(200);
  assert.ok(ranges.includes('7d')&&ranges.includes('30d'));assert.equal(maxActive,1);
  revision=1;await page.getByRole('button',{name:'刷新',exact:true}).click();await page.waitForFunction(()=>document.querySelector('[data-testid="dashboard-users"]')?.textContent.includes('1,285'));
  const output=path.resolve(__dirname,'../.local/dashboard-preview');fs.mkdirSync(output,{recursive:true});
  await page.screenshot({path:path.join(output,'desktop-dark.png'),fullPage:true});
  await page.getByRole('button',{name:'切换浅色模式'}).click();await page.waitForTimeout(220);await page.screenshot({path:path.join(output,'desktop-light.png'),fullPage:true});
  await page.setViewportSize({width:390,height:1080});await page.waitForFunction(()=>document.querySelector('.sidebar').getBoundingClientRect().right<=1);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'mobile page overflow');await page.screenshot({path:path.join(output,'mobile.png'),fullPage:true});
  await page.setViewportSize({width:320,height:1080});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'small mobile page overflow');
  await page.setViewportSize({width:1440,height:1000});
  await page.getByRole('button',{name:'刷新',exact:true}).click();await page.waitForTimeout(200);
  await page.goto(base+'/admin/nodes?status=offline');await page.getByText('仅显示已启用的离线节点',{exact:false}).waitFor();assert.equal(await page.locator('.el-table__body-wrapper').getByText('在线节点',{exact:true}).count(),0);await page.getByRole('button',{name:'显示全部节点'}).click();await page.locator('.el-table__body-wrapper').getByText('在线节点',{exact:true}).waitFor();
  for(const target of ['nodes','users','announcements']){await page.goto(base+'/admin/'+target+'?create=1');const dialog=page.getByRole('dialog');await dialog.waitFor();assert.equal(new URL(page.url()).searchParams.has('create'),false,'create shortcut was not consumed');await page.getByRole('button',{name:'取消',exact:true}).count().then(async n=>{if(n)await page.getByRole('button',{name:'取消',exact:true}).last().click()})}
  assert.deepEqual(errors,[]);console.log('PASS dashboard overview, traffic, nodes, dark/light/mobile layout');
 }finally{if(browser)await browser.close();await new Promise(r=>server.close(r))}
})().catch(e=>{console.error(e);process.exitCode=1});
