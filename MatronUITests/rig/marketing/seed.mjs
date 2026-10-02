import WebSocket from 'ws'; import fs from 'node:fs';
const HTTP='http://127.0.0.1:9810', WS='ws://127.0.0.1:9810/ws';
const tok=(n)=>fs.readFileSync(`/tmp/shots-demo/agent-${n}.txt`,'utf8').split('token:')[1].trim().split(/\s/)[0];
const client=JSON.parse(fs.readFileSync('/tmp/shots-demo/login-client.json','utf8'));
const sleep=(ms)=>new Promise(r=>setTimeout(r,ms));
const connect=(token)=>new Promise((res,rej)=>{const s=new WebSocket(WS);s.on('open',()=>s.send(JSON.stringify({op:'hello',token,cursor:null})));s.on('message',d=>{const m=JSON.parse(d.toString());if(m.op==='hello_ok')res(s);else if(m.op==='error')console.error('error',m)});s.on('error',rej)});
const mac=await connect(tok('mac-studio')), home=await connect(tok('homelab')), app=await connect(client.token);
let n=0; const frame=async(ws,o)=>{ws.send(JSON.stringify(o));n++;await sleep(90)};
const up=(ws,id,x)=>frame(ws,{op:'convo_upsert',convo_id:id,...x});
const pub=(ws,id,type,payload)=>frame(ws,{op:'publish',convo_id:id,type,payload,idem_key:`mk-${id}-${n}`});
const text=(ws,id,body)=>pub(ws,id,'text',{body});
const say=(id,body)=>frame(app,{op:'send',convo_id:id,type:'text',payload:{body},local_id:`mk-${id}-${n}`});
const read=(id)=>frame(app,{op:'read_marker',convo_id:id,up_to_seq:null});
const http=async(method,path,token,body)=>{const r=await fetch(HTTP+path,{method,headers:{Authorization:`Bearer ${token}`,'content-type':'application/json'},body:body?JSON.stringify(body):undefined});const t=await r.text();if(r.status>=300)console.error(method,path,r.status,t.slice(0,160));await sleep(120);try{return JSON.parse(t)}catch{return {}}};
const A=tok('mac-studio'), U=client.token;

// ---- older conversations (link targets, list filler) ----
await up(home,'mk-nightly',{title:'Nightly build watch',session_state:'done'});
await text(home,'mk-nightly','Nightly run finished: one flaky failure in the upload tests, everything else green.'); await read('mk-nightly');
await up(mac,'mk-docs',{title:'Docs site: search and dark mode',session_state:'done'});
await say('mk-docs','Add search to the docs site and make dark mode follow the system.');
await text(mac,'mk-docs','Done. Search indexes every page at build time, and the theme now follows the system setting.'); await read('mk-docs');
await up(mac,'mk-flaky',{title:'Fix the flaky upload test',session_state:'waiting'});
await say('mk-flaky','The upload test keeps failing on CI but passes locally. Can you take a look?');
await pub(mac,'mk-flaky','tool_output',{command:'npm test -- uploads',exit_code:1,snippet:'1 failed: retries three times before giving up',truncated:false});
await text(mac,'mk-flaky','Found it: the test waits a fixed 500 ms, and the upload worker is sometimes slower on CI. I replaced the sleep with a proper wait.');
await pub(mac,'mk-flaky','diff',{file_path:'upload.spec.ts',diff:'@@ -41,5 +41,5 @@\n-    await sleep(500)\n-    expect(upload.status).toBe("done")\n+    await waitFor(() =>\n+      expect(upload.status).toBe("done"))',added:2,removed:2});
await pub(mac,'mk-flaky','tool_output',{command:'npm test -- uploads',exit_code:0,snippet:'148 passed',truncated:false}); await read('mk-flaky');
await up(mac,'mk-checkout',{title:'Speed up the checkout page',session_state:'done'});
await text(mac,'mk-checkout','Checkout now loads in 1.1 s, down from 2.8 s. The big win was deferring the address lookup script.'); await read('mk-checkout');

// ---- 2. long chat with pills + table ----
await up(mac,'mk-release',{title:'Release checklist for 2.4',session_state:'waiting'});
await say('mk-release','Where are we on the 2.4 release? I’d like to ship on Thursday.');
await text(mac,'mk-release','I went through the checklist. Three things are done and one needs a retry policy before we ship.');
await text(mac,'mk-release','The retry policy is the open one: uploads retry three times with no backoff, so a slow network fails all three within a second.');
await read('mk-release');

// ---- 9. parent with running subagent ----
await up(mac,'mk-auth',{title:'Tidy up the sign-in code',session_state:'running'});
await say('mk-auth','The sign-in code does too much in one file. Can you split it up?');
await text(mac,'mk-auth','Yes. I’ll find every place that calls it first, so nothing breaks when it moves.');
await text(mac,'mk-auth','🔀 Subtask: Find every sign-in call');
await up(mac,'mk-auth-sub',{title:'Find every sign-in call',parent_convo_id:'mk-auth',session_state:'running'});
await text(mac,'mk-auth-sub','Starting with the sign-in module itself, to see what it exports.');
await pub(mac,'mk-auth-sub','tool_output',{command:'wc -l api/src/auth/sign-in.ts',exit_code:0,snippet:'412 api/src/auth/sign-in.ts',truncated:false});
await text(mac,'mk-auth-sub','One file, 412 lines, four jobs: checking the password, issuing the token, starting the session and writing the audit log.');
await text(mac,'mk-auth-sub','Searching the web app, the API and the admin tools for calls to `signIn()`.');
await pub(mac,'mk-auth-sub','tool_output',{command:'rg -n "signIn\\(" --type ts',exit_code:0,snippet:'web/src/pages/login.tsx:24\napi/src/routes/session.ts:51\nadmin/src/auth.ts:12',truncated:false});
await text(mac,'mk-auth-sub','Found 14 call sites so far:\n\n- web app: 8\n- API: 4\n- admin tools: 2\n\nChecking the tests next.');
await pub(mac,'mk-auth-sub','tool_output',{command:'rg -n "signIn\\(" tests/',exit_code:0,snippet:'tests/login.spec.ts:18\ntests/session.spec.ts:40',truncated:false});
await text(mac,'mk-auth-sub','Two test files use it too. Both pass a plain email and password, so they will keep working after the split.');
await read('mk-auth');

// ---- 1. Coordinator ----
await up(mac,'mk-coord',{title:'Coordinator',session_state:'waiting'});
await http('PUT','/coordinator',U,{convo_id:'mk-coord'});
await say('mk-coord','Morning. What needs me today?');
await text(mac,'mk-coord','Good morning. Three sessions worked overnight:\n\n- **Release 2.4**: the checklist is done except the retry policy\n- **Docs site**: search and dark mode are live\n- **Sign-in tidy-up**: a subagent is mapping the call sites now\n\nOne thing needs your decision before Thursday.');

// ---- missions ----
const m1=(await http('POST','/missions',A,{title:'Ship release 2.4',body:'Get 2.4 out on Thursday: finish the checklist, fix the flaky upload test and publish the release notes.',convo_id:'mk-release'})).mission;
await http('POST',`/missions/${m1.id}/join`,A,{convo_id:'mk-flaky'});
const m2=(await http('POST','/missions',A,{title:'Docs site refresh',body:'Make the docs easier to search and read, in light and dark.',convo_id:'mk-docs'})).mission;
const m3=(await http('POST','/missions',A,{title:'Tidy up the sign-in code',body:'Split sign-in into small, tested pieces without changing behaviour.',convo_id:'mk-auth'})).mission;
const m4=(await http('POST','/missions',A,{title:'Faster checkout page',body:'Bring the checkout page under 1.5 s on a mid-range phone.',convo_id:'mk-checkout'})).mission;
const ms=(convo,title,body,kind='progress')=>http('POST','/milestones',A,{convo_id:convo,kind,title,body});
await ms('mk-release','Asked for a Thursday release','Ship 2.4 on Thursday.','user_input');
await ms('mk-flaky','Flaky upload test fixed','Replaced a fixed sleep with a proper wait; 148 tests pass.');
await ms('mk-release','Checklist reviewed: one item open','Everything is done except the upload retry policy.');
await ms('mk-release','Retry numbers measured','Exponential backoff passed 50 of 50 runs on a throttled network.');
await ms('mk-docs','Search added to the docs','Every page is indexed at build time.');
await ms('mk-docs','Dark mode follows the system','The theme switches with the system setting.');
await ms('mk-auth','Mapping the sign-in call sites','A subagent is listing every caller before the split.');
await ms('mk-checkout','Checkout loads in 1.1 s','Down from 2.8 s by deferring the address lookup.');
await http('PATCH',`/missions/${m1.id}`,A,{status:'Checklist done except the upload retry policy. Waiting on your choice of policy, then ready for Thursday.'});
await http('PATCH',`/missions/${m2.id}`,A,{status:'Search and dark mode are live. Next: tidy the getting-started page.'});
await http('PATCH',`/missions/${m3.id}`,A,{status:'A subagent is mapping every sign-in call before the code is split.'});
await http('PATCH',`/missions/${m4.id}`,A,{status:'Checkout loads in 1.1 s, down from 2.8 s. Measuring on slower phones next.'});

// ---- items ----
const item=(convo,kind,title,body,extra={})=>http('POST','/items',A,{kind,title,body,convo_id:convo,...extra});
await item('mk-release','task','Write the 2.4 release notes','Group the changes by area and keep each line to one sentence.');
await item('mk-release','task','Tag the release and publish','After the retry change is merged.');
await item('mk-flaky','question','Merge the upload test fix?','The fix is green on CI: 148 tests pass, five runs in a row.',{actions:['Merge it','Not yet']});
await item('mk-release','decision','Ship on Thursday, not Friday','Thursday leaves a working day to watch the release before the weekend.');
await item('mk-docs','question','Keep the old tutorial pages?','Twelve tutorial pages predate the new guide. Redirect them, or keep both?',{actions:['Redirect','Keep both']});
await item('mk-docs','task','Tidy the getting-started page','Shorter steps, one screenshot per step.');
await item('mk-auth','task','Split sign-in into token and session modules','Keep behaviour identical; tests must stay green.');
await item('mk-checkout','task','Measure checkout on slower phones','Target: under 1.5 s.');

// ---- memories ----
const mem=(name,description,body)=>http('PUT',`/memories/${name}`,U,{description,body,type:'feedback'});
await mem('ask-before-merging','Ask before merging anything into main.','**Why:** I like to read the diff first.\n\n**How to apply:** open the pull request, then file a question.');
await mem('british-spelling','Use British spelling in docs and release notes.','**Why:** our readers are mostly in the UK.');
await mem('no-friday-releases','Never release on a Friday.','**Why:** nobody is around to watch it over the weekend.');
await mem('run-tests-first','Run the full test suite before saying something is fixed.','**Why:** a green slice is not a green build.');
await mem('short-reports','Keep reports short: what changed, what is next, what needs me.','**Why:** I read them on my phone.');

const q=(await item('mk-release','question','Which retry policy for uploads?','Uploads retry three times with no backoff, so a slow network fails all three within a second.\n\n- **Exponential**: passed 50 of 50 runs, slowest 4.1 s\n- **Fixed 1 s**: passed 48 of 50, slowest 3.4 s\n\nI recommend exponential.',{actions:['Exponential','Fixed 1 s']})).item;
await http('POST',`/items/${q.id}/comments`,U,{body:'Does exponential slow down the normal case?'});
await http('POST',`/items/${q.id}/comments`,A,{body:'No. The first attempt is unchanged; backoff only applies after a failure. A healthy upload still takes 0.4 s.'});
await http('PATCH',`/items/${q.id}`,A,{awaiting:'user'});
// the release chat's closing exchange arrives after its mission cards, so the table and the pills end the chat
await say('mk-release','What do the retry numbers look like with backoff?');
await text(mac,'mk-release','I ran the upload suite 50 times under a throttled network:\n\n| Policy | Passed | Slowest |\n|:--|--:|--:|\n| No backoff | 41 / 50 | 1.2 s |\n| Fixed 1 s | 48 / 50 | 3.4 s |\n| Exponential | 50 / 50 | 4.1 s |\n\nExponential backoff passes every run, and the slowest retry is still well inside the timeout.');
await say('mk-release','Good. Use exponential. What else is left?');
await text(mac,'mk-release','Here is where each thread stands:\n\n- [upload test](matron://convo/mk-flaky): fixed, waiting for your go to merge\n- [docs site](matron://convo/mk-docs): search and dark mode are live\n- [checkout speed](matron://convo/mk-checkout): done, 1.1 s\n- [nightly build](matron://convo/mk-nightly): green two nights running\n\nOnce the retry change is merged we are ready for Thursday.');
await read('mk-release');
await text(mac,'mk-coord','The upload retry policy is the last open item for 2.4. Exponential backoff passed every run in my tests.');
await pub(mac,'mk-coord','prompt',{question:'Which retry policy should we ship?',options:['Exponential backoff','Fixed 1 s delay'],allows_free_text:true});
await read('mk-coord');
console.log('seeded',n,'frames; question',q&&q.num);
mac.close();home.close();app.close();
