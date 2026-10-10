import WebSocket from 'ws'; import fs from 'node:fs';
const tok=(n)=>fs.readFileSync(`/tmp/shots-demo/agent-${n}.txt`,'utf8').split('token:')[1].trim().split(/\s/)[0];
const hr=(h)=>new Date(Date.now()+h*3600000).toISOString();
const MODELS=[{value:'claude-fable-5-1',label:'Fable 5.1'},{value:'claude-opus-5-5',label:'Opus 5.5'},{value:'claude-sonnet-5',label:'Sonnet 5'},{value:'claude-haiku-4-5',label:'Haiku 4.5'}];
const EFFORTS=[{value:'low',label:'Low'},{value:'medium',label:'Medium'},{value:'high',label:'High'},{value:'max',label:'Max'}];
const status=(convo,tokens,extra={})=>({op:'status',convo_id:convo,status:{model:'claude-fable-5-1',workdir:'~/dev/web-app',context:{tokens,window:1000000,pct:Math.round(tokens/10000)},
  limits:[{id:'session',label:'Session',percent:34,resets:'6pm',resets_at:hr(3)},{id:'week_all_models',label:'Week (all models)',percent:12,resets:'Thu 3am',resets_at:hr(60)}],
  model_options:MODELS,effort_levels:EFFORTS,effort:'high',...extra}});
const FOLDERS={'mac-studio':[['~/dev/web-app',6],['~/dev/api-server',120],['~/dev/docs-site',1500]],'homelab':[['~/builds/nightly',40],['~/dev/api-server',540]],'cloud-dev':[['~/dev/web-app',200]]};
const CAP={'mac-studio':[3,34,12],'homelab':[1,8,41],'cloud-dev':[0,0,5]};
function run(name){const ws=new WebSocket('ws://127.0.0.1:9810/ws');let t;
  ws.on('open',()=>ws.send(JSON.stringify({op:'hello',token:tok(name),cursor:null})));
  ws.on('message',d=>{const m=JSON.parse(d.toString());
    if(m.op==='hello_ok'){console.log(name,'connected');if(name==='mac-studio'){const send=()=>{for(const [c,k] of [['mk-release',184000],['mk-coord',96000],['mk-flaky',142000],['mk-auth',230000]])ws.send(JSON.stringify(status(c,k)));ws.send(JSON.stringify(status('mk-auth-sub',48000,{model:'claude-sonnet-5'})))};send();t=setInterval(send,30000)}}
    else if(m.kind==='rpc'&&m.request){const {request_id,from_device_id,method}=m.request;const reply=(ok,b)=>ws.send(JSON.stringify({op:'agent_response',request_id,to_device_id:from_device_id,ok,...b}));
      if(method==='recent_folders')reply(true,{result:{folders:FOLDERS[name].map(([path,min])=>({path,last_used:Date.now()-min*60000})),activity:{live_sessions:CAP[name][0]},limits:{lines:[{id:'session',label:'Session',percent:CAP[name][1],resets_at:hr(3)},{id:'week_all_models',label:'Week',percent:CAP[name][2],resets_at:hr(60)}]}}});else reply(false,{error:{code:'unknown_method'}});console.log(name,'answered',method)}
    else if(m.op==='error')console.error(name,'error',JSON.stringify(m))});
  ws.on('close',()=>{clearInterval(t);setTimeout(()=>run(name),2000)});ws.on('error',e=>console.error(name,e.message))}
['mac-studio','homelab','cloud-dev'].forEach(run);
