const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const base=process.env.PLAYBACK_STATIC || path.join(__dirname,'../jubensha/static');
function setup(screen=false){
  const spoken=[], nodes=new Map(); let handler;
  const node=()=>({classList:{toggle(){},add(){},remove(){}},dataset:{},textContent:'',innerHTML:'',scrollHeight:0,scrollTop:0,clientHeight:0});
  const doc={querySelector(s){if(!nodes.has(s))nodes.set(s,node());return nodes.get(s);}};
  const speech={speak(u){spoken.push(u)},cancel(){},getVoices(){return []}};
  const ctx=vm.createContext({document:doc,window:{speechSynthesis:speech,addEventListener(){}},
    speechSynthesis:speech,SpeechSynthesisUtterance:function(text){this.text=text},setInterval(){}});
  vm.runInContext(fs.readFileSync(path.join(base,'common.js'),'utf8'),ctx);
  const tts=vm.runInContext('TTS',ctx);tts.on=true;
  if(screen){
    ctx.capture=(_,h)=>{handler=h};
    vm.runInContext('connect=capture',ctx);
    const html=fs.readFileSync(path.join(base,'screen.html'),'utf8');
    vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],ctx);
  }
  return {tts,spoken,nodes,handler,ctx};
}
test('multiple sentences queue sequentially and flush remainder',()=>{
  const s=setup();s.tts.feed('第一句。第二句！剩余');s.tts.flush();
  assert.equal(s.spoken.length,1);s.spoken[0].onend();
  assert.equal(s.spoken[1].text,'第二句！');s.spoken[1].onend();
  assert.equal(s.spoken[2].text,'剩余');
});
test('stop clears queue and rejects late completion',()=>{
  const s=setup();s.tts.feed('第一句。第二句。尾巴');const old=s.spoken[0];
  s.tts.stop();s.tts.say('新句');old.onend();
  assert.equal(s.spoken.length,2);assert.equal(s.tts.current.text,'新句');assert.equal(s.tts.buf,'');
});
test('skip advances once despite cancelled callback',()=>{
  const s=setup();s.tts.feed('第一句。第二句。第三句。');const old=s.spoken[0];
  s.tts.skip();old.onerror();assert.equal(s.spoken.length,2);
  s.spoken[1].onend();assert.equal(s.spoken[2].text,'第三句。');
});
test('disabled narration does not buffer past text',()=>{
  const s=setup();s.tts.on=false;s.tts.feed('关闭时的内容');s.tts.on=true;s.tts.flush();
  assert.equal(s.spoken.length,0);
});
test('stop current stream suppresses later deltas but permits next stream',()=>{
  const s=setup(true),event=s.handler.event;
  event({type:'stream_start',id:'a'});event({type:'stream_delta',id:'a',text:'第一句。'});
  s.nodes.get('#ttsStopBtn').onclick();
  event({type:'stream_delta',id:'a',text:'第二句。'});event({type:'stream_end',id:'a'});
  assert.equal(s.spoken.length,1);
  event({type:'stream_start',id:'b'});event({type:'stream_delta',id:'b',text:'新段。'});
  assert.equal(s.spoken.length,2);
});
test('phase change clears audio and ignores old stream deltas',()=>{
  const s=setup(true),event=s.handler.event;
  const view={title:'test',phase:{index:0,started_at:1,title:'one'},players:[],public_clues:[],log:[]};
  s.handler.view(view);event({type:'stream_start',id:'old'});event({type:'stream_delta',id:'old',text:'旧句。'});
  s.handler.view({...view,phase:{index:1,started_at:2,title:'two'}});
  event({type:'stream_delta',id:'old',text:'不应播放。'});
  assert.equal(s.tts.current,null);assert.equal(s.spoken.length,1);
});
test('local playback returns stale response after stop without playing',async()=>{
  const s=setup();let resolve,played=0;
  s.ctx.AbortController=AbortController;
  s.ctx.fetch=()=>new Promise(r=>resolve=r);
  s.ctx.URL={createObjectURL(){throw Error('stale blob used')},revokeObjectURL(){}};
  s.ctx.Audio=function(){this.play=()=>played++};
  s.tts.mode='local';s.tts.say('你好');s.tts.stop();
  resolve({ok:true,blob:async()=>({})});await new Promise(setImmediate);
  assert.equal(played,0);assert.equal(s.tts.current,null);
});
test('local audio plays in order and releases blob URLs',async()=>{
  const s=setup();const audios=[],revoked=[];
  s.ctx.AbortController=AbortController;
  s.ctx.fetch=async()=>({ok:true,blob:async()=>({})});
  s.ctx.URL={createObjectURL:()=> 'blob:audio',revokeObjectURL:u=>revoked.push(u)};
  s.ctx.Audio=function(){audios.push(this);this.play=async()=>{};this.pause=()=>{};this.removeAttribute=()=>{}};
  s.tts.mode='local';s.tts.feed('第一句。第二句。');await new Promise(setImmediate);
  assert.equal(audios.length,1);audios[0].onended();await new Promise(setImmediate);
  assert.equal(audios.length,2);s.tts.stop();assert.equal(revoked.length,2);
});
test('local service failure clears pending audio without changing text',async()=>{
  const s=setup();s.ctx.AbortController=AbortController;
  s.ctx.fetch=async()=>({ok:false,json:async()=>({error:{message:'模型尚未就绪'}})});
  s.tts.mode='local';s.tts.feed('第一句。第二句。');await new Promise(setImmediate);
  assert.equal(s.tts.queue.length,0);assert.equal(s.tts.current,null);
  assert.equal(s.nodes.get('#voiceStatus').textContent,'模型尚未就绪');
  assert.equal(s.tts.on,false);
  s.tts.feed('后续文字不应触发更多请求。');
  assert.equal(s.tts.buf,'');
});
test('browser speech error disables narration and makes retry possible',()=>{
  const s=setup();s.tts.say('测试');s.spoken[0].onerror();
  assert.equal(s.tts.on,false);assert.equal(s.tts.current,null);
  assert.equal(s.nodes.get('#ttsBtn').textContent,'🔇 语音朗读：关');
});
test('local busy response retries instead of dropping next sentence',async()=>{
  const s=setup();let requests=0,played=0;
  s.ctx.AbortController=AbortController;s.ctx.setTimeout=fn=>setImmediate(fn);
  s.ctx.fetch=async()=>++requests===1 ? {status:429} : {ok:true,status:200,blob:async()=>({})};
  s.ctx.URL={createObjectURL:()=> 'blob:audio',revokeObjectURL(){}};
  s.ctx.Audio=function(){this.play=async()=>{played++};this.pause=()=>{};this.removeAttribute=()=>{}};
  s.tts.mode='local';s.tts.say('下一句');
  await new Promise(setImmediate);await new Promise(setImmediate);
  assert.equal(requests,2);assert.equal(played,1);s.tts.stop();
});
