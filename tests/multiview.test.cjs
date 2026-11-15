const test=require('node:test'),assert=require('node:assert/strict'),MV=require('../app/multiview.js'),S=require('../app/sports.js');
const channel=(id,name)=>({id,name,kind:'live',group:'Sports',url:'https://media.example/'+id+'.m3u8'});
const side=(name,abbr,score)=>({name,short:name.split(' ').pop(),nickname:name.split(' ').pop(),abbr,score,logo:'',winner:false});
const game=(id,state,home,away,broadcasts)=>({id,league:'nba',leagueName:'NBA',name:away.name+' at '+home.name,state,scheduled:false,detail:'Q3 4:12',start:Date.now()-3600000,home,away,homeFirst:false,broadcasts});
const match=(g,items)=>S.matchChannels(g,items,{},{});

test('layouts place every screen on the grid and leave the spare cell for Add',()=>{
  assert.deepEqual(MV.layout(1,'grid').cells,['1 / 1 / span 1 / span 1']);
  assert.equal(MV.layout(2,'grid').columns,'repeat(2,minmax(0,1fr))');
  const three=MV.layout(3,'grid');assert.equal(three.cells.length,3);assert.equal(three.add,'2 / 2 / span 1 / span 1');
  assert.equal(MV.layout(4,'grid').add,null);assert.equal(new Set(MV.layout(4,'grid').cells).size,4);
  const focus=MV.layout(4,'focus',2);assert.equal(focus.cells[2],'1 / 1 / span 3 / span 1');assert.deepEqual([focus.cells[0],focus.cells[1],focus.cells[3]],['1 / 2 / span 1 / span 1','2 / 2 / span 1 / span 1','3 / 2 / span 1 / span 1']);
  const full=MV.layout(4,'focus',0,3);assert.deepEqual(full.cells,[null,null,null,'1 / 1 / span 1 / span 1']);
  assert.equal(MV.layout(0,'grid').add,'1 / 1 / span 1 / span 1');
});

test('adding caps at four, never opens a channel twice, and replacing keeps the slot',()=>{
  let tiles=[];for(let i=0;i<4;i++)tiles=MV.add(tiles,channel('c'+i,'Channel '+i)).tiles;
  assert.equal(tiles.length,MV.MAX);assert.equal(new Set(tiles.map(t=>t.key)).size,4);
  assert.equal(MV.add(tiles,channel('c9','More')).reason,'full');
  const again=MV.add(tiles,channel('c1','Channel 1'));assert.equal(again.reason,'present');assert.equal(again.index,1);assert.equal(again.tiles,tiles);
  const swapped=MV.add(tiles,channel('c9','More'),2);assert.equal(swapped.reason,'replaced');assert.equal(swapped.tiles[2].item.id,'c9');assert.notEqual(swapped.tiles[2].key,tiles[2].key);assert.equal(swapped.tiles.length,4);
  const restarted=MV.restart(tiles,0);assert.equal(restarted[0].item,tiles[0].item);assert.notEqual(restarted[0].key,tiles[0].key);
});

test('a screen shows the followed game its channel carries, and live games pair with distinct channels',()=>{
  const espn=channel('e','ESPN'),tnt=channel('t','TNT'),other=channel('o','Cooking');
  const live=game('nba:1','in',side('New York Knicks','NYK','84'),side('Boston Celtics','BOS','88'),['ESPN']);
  const late=game('nba:2','in',side('Phoenix Suns','PHX','66'),side('Los Angeles Lakers','LAL','61'),['TNT','ESPN']);
  const soon=game('nba:3','pre',side('Chicago Bulls','CHI',''),side('Miami Heat','MIA',''),['TNT']);
  assert.equal(MV.gameFor(espn,[soon,live],match),live);assert.equal(MV.gameFor(other,[live,late],match),null);
  assert.equal(MV.gameFor(tnt,[soon],match),null,'a game that has not started is not shown on a screen');
  assert.deepEqual(MV.watchable([live,late,soon],[espn,tnt,other],match).map(w=>w.item.id),['e','t']);
});

function fakePlayer(log){return function(options){this.options=options;this.muted=options.muted;log.push(this);this.open=item=>{this.item=item;};this.mute=on=>{this.muted=on;};this.close=()=>{this.closed=true;};};}

test('web screens get one player each, only the audio screen is unmuted, and removed screens close',()=>{
  const players=[],events=[];const session=new MV.Session({native:false,Player:fakePlayer(players),emit:(k,e,d)=>events.push([k,e,d])});
  const tiles=[{key:'a',item:channel('1','One'),video:{}},{key:'b',item:channel('2','Two'),video:{}}];
  session.sync(tiles,'a');assert.equal(players.length,2);assert.deepEqual(players.map(p=>p.muted),[false,true]);assert.equal(players[0].options.native,false);assert.ok(players[0].options.hls.capLevelToPlayerSize);
  session.sync(tiles,'b');assert.equal(players.length,2,'focus moves audio without reopening streams');assert.deepEqual(players.map(p=>p.muted),[true,false]);
  players[1].options.emit('playing');assert.deepEqual(events.pop(),['b','playing',undefined]);
  session.sync([tiles[1]],'b');assert.equal(players[0].closed,true);players[0].options.emit('error','late');assert.ok(!events.some(e=>e[0]==='a'));
  session.close();assert.equal(players[1].closed,true);players[1].options.emit('playing');assert.equal(events.length,0);
});

test('native screens send rectangles and the audio key, and a closed session drops late events',async()=>{
  const requests=[],events=[];global.window={};
  try{
    const session=new MV.Session({native:true,request:(a,p)=>{requests.push([a,p]);return Promise.resolve(true);},emit:(k,e,d)=>events.push([k,e,d])});
    session.sync([{key:'a',item:{id:'x',url:'airwave-native://x',kind:'live'},rect:{x:8,y:8,w:400,h:225}},{key:'b',item:{id:'y',url:'airwave-native://y',kind:'live'},rect:null}],'a');
    assert.equal(requests[0][0],'multiview');assert.equal(requests[0][1].audio,'a');assert.deepEqual(requests[0][1].tiles[0],{key:'a',id:'x',url:'airwave-native://x',kind:'live',x:8,y:8,w:400,h:225});assert.equal(requests[0][1].tiles[1].w,0);
    window.__airwaveMultiview(session.token,'a','playing',null);window.__airwaveMultiview(session.token-1,'a','error','stale');assert.deepEqual(events,[['a','playing',null]]);
    session.close();assert.deepEqual(requests[1],['multiviewStop',{token:session.token}]);window.__airwaveMultiview(session.token,'a','error','late');assert.equal(events.length,1);
    const failing=new MV.Session({native:true,request:()=>Promise.reject(new Error('Unsupported native action.')),emit:(k,e)=>events.push([k,e])});failing.sync([{key:'c',item:{id:'z',kind:'live'},rect:null}],'c');await new Promise(r=>setImmediate(r));assert.deepEqual(events.pop(),['c','error']);
  }finally{delete global.window;}
});
