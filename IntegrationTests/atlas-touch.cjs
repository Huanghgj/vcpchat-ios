// Run from the repo root with puppeteer-core and CHROME_BIN set to a Chromium executable.
const puppeteer = require('puppeteer-core');
const {pathToFileURL} = require('node:url');
const assert = require('node:assert/strict');
(async()=>{
const browser=await puppeteer.launch({executablePath:process.env.CHROME_BIN || '/usr/bin/google-chrome',headless:true,args:process.getuid?.() === 0 ? ['--no-sandbox'] : []});
try {
 const p=await browser.newPage();
 await p.setViewport({width:375,height:650,isMobile:true,hasTouch:true,deviceScaleFactor:2});
 const errors=[];p.on('pageerror',err=>errors.push(String(err)));
 await p.evaluateOnNewDocument(()=>{
  const f={ids:[1,2,3],labels:['春','夏','秋'],count:3,flags:[0,1,0],group:[0,0,0],angle:[0,2,4],radius:[.4,.5,.6],radiusRange:[.35,.65],outside:[],groups:[{start:0,end:4,label:'季节',count:3}],snapshot:{degree:2,dimension:3},distanceCheck:{ok:true,identical:2},geometry:{kappa:2,phi0:1.5,alpha:.15}};
  window.requests=[];
  window.webkit={messageHandlers:{atlasRead:{postMessage:async route=>{
    requests.push(route);
    if (window.holdQuery && route.includes('/query?')) {
        window.holdQuery = false;
        await new Promise(resolve=>{window.finishQuery=resolve;});
    }
    if(route==='/status')return JSON.stringify({fields:{tag:{available:true},chunk:{available:true}},messages:{available:true}});
    if(/^\/field\/(tag|chunk)$/.test(route))return JSON.stringify(f);
    if(route==='/field/chunk/node/1')return JSON.stringify({id:1,index:0,label:'春',diary:'日记',path:'test.md',inField:true,group:0,radius:.4,text:'示例正文',tags:[],navigation:[]});
    if(window.rejectNextQuery && route.includes('/query?')) {window.rejectNextQuery=false; throw new Error('消息没有可用向量');}
    if(route.includes('/query?'))return JSON.stringify({query:{id:1,index:0,radius:.4,label:'春'},theta:[0,40,80],distance:[0,.55,.4],contours:[]});
    if(route.startsWith('/messages'))return JSON.stringify({rows:[{hash:'abcd1234',at:0,text:'一条测试消息'}]});
    throw new Error('unexpected '+route);
  }}}};
 });
 await p.goto(pathToFileURL(process.cwd()+'/Sources/VChatRendering/FieldAtlas/index.html').href);
 await p.waitForFunction('typeof atlas !== "undefined" && atlas.inspect().nodesOnScreen === 3');
 for (const [w,h] of [[375,650],[844,335],[375,650]]) {
  await p.setViewport({width:w,height:h,isMobile:true,hasTouch:true,deviceScaleFactor:2});
  await p.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
  const dims=await p.evaluate(()=>{const r=s=>document.querySelector(s).getBoundingClientRect().toJSON();return {stage:r('.wa-stage'),side:r('.wa-side'),width:document.documentElement.scrollWidth};});
  assert(dims.width<=w && dims.stage.height>150 && dims.side.height>100);
 }
 const clickText=async(label)=>{await p.evaluate(label=>[...document.querySelectorAll('button')].find(b=>b.textContent===label).click(),label);};
 await clickText('查询');
 await p.waitForSelector('.wa-list .wa-stack');
 await p.evaluate(()=>{window.rejectNextQuery=true;});
 await p.click('.wa-list .wa-stack');
 await p.waitForFunction('document.querySelector(".wa-message").textContent === "消息没有可用向量"');
 await p.evaluate(()=>atlas.flush());
 assert.equal(await p.$eval('.wa-message',e=>e.hidden ? '' : e.textContent),'消息没有可用向量');
 await clickText('全景');
 const scale=()=>p.evaluate('atlas.inspect().camera.scale');
 const base=await scale();
 await p.click('[aria-label="放大场图"]');assert(await scale()>base);
 await clickText('复位');assert.equal(await scale(),base);
 const stage=await p.$eval('.wa-stage',e=>e.getBoundingClientRect().toJSON());
 const cdp=await p.createCDPSession();
 const touches=(gap)=>[1,-1].map((s,i)=>({x:stage.x+stage.width/2+gap*s,y:stage.y+stage.height/2,id:i+1}));
 await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:touches(25)});
 await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:touches(55)});
 await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
 assert(await scale()>base*1.5);assert.equal(await p.evaluate('atlas.inspect().selected'),null);
 await clickText('Chunk 场');await p.waitForFunction('atlas.inspect().kind==="chunk" && document.querySelector(".wa-side").textContent.includes("节点")');
 await p.type('.wa-search input','春');await p.waitForSelector('.wa-search-list button');await p.click('.wa-search-list button');
 await p.waitForFunction('document.querySelector(".wa-side").textContent.includes("示例正文")');
 await p.evaluate(()=>atlas.flush());
 await clickText('以此为查询');await p.waitForFunction('atlas.inspect().view==="query"');
 assert.deepEqual(await p.evaluate('atlas.inspect().query.top'),[3,2]);
 await clickText('黎曼切片');await p.waitForFunction('document.querySelector(".wa-plate-note").textContent.includes("黎曼") || document.querySelector(".wa-side [aria-pressed=true]").textContent.includes("黎曼")');
 await p.waitForSelector('.wa-input');await p.type('.wa-input','你好');await p.waitForFunction('requests.includes("/messages?q=%E4%BD%A0%E5%A5%BD")');
 await p.click('.wa-list .wa-stack');await p.waitForFunction('requests.includes("/field/chunk/query?message=abcd1234")');
 await clickText('全景');
 await p.evaluate(()=>{ window.holdQuery=true; window.pending=atlas.runQuery(1); });
 await p.waitForFunction('typeof window.finishQuery==="function"');
 await clickText('Tag 场');
 await p.evaluate(async()=>{ window.finishQuery(); await window.pending; });
 assert.equal(await p.evaluate('atlas.inspect().view'),'panorama');
 assert.equal(await p.evaluate('atlas.inspect().kind'),'tag');
 assert.deepEqual(errors,[]);
 console.log('PASS phone portrait/landscape, local resources, Tag/Chunk, zoom buttons + multi-touch, detail, node + message query, metric projection');
}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
