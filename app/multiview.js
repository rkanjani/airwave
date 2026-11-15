(function(root,factory){var api=factory();if(typeof module==='object')module.exports=api;else root.AirwaveMultiview=api;})(this,function(){
  'use strict';
  // Up to four live channels at once. Each screen holds its own provider connection, so the cap stays low.
  var MAX=4,serial=0,sessions=0;
  function newKey(){return 'mv'+(++serial);}
  function cell(row,col,rows,cols){return row+' / '+col+' / span '+(rows||1)+' / span '+(cols||1);}
  // CSS grid placement for each screen. Grid: one screen fills the view, two sit side by side, three or four make a 2×2
  // (three leave the fourth cell for Add). Focus: the main screen takes the left three quarters and the rest stack on the
  // right. Full screen shows one screen alone; the others keep playing, hidden.
  function layout(count,mode,main,full){
    var cells=[],i;
    if(!count)return {columns:'minmax(0,1fr)',rows:'minmax(0,1fr)',cells:cells,add:cell(1,1)};
    if(full!=null&&full>=0&&full<count){for(i=0;i<count;i++)cells.push(i===full?cell(1,1):null);return {columns:'minmax(0,1fr)',rows:'minmax(0,1fr)',cells:cells,add:null};}
    if(mode==='focus'&&count>1){
      main=main>=0&&main<count?main:0;var row=1;
      for(i=0;i<count;i++)cells.push(i===main?cell(1,1,count-1,1):cell(row++,2));
      return {columns:'minmax(0,3fr) minmax(0,1fr)',rows:'repeat('+(count-1)+',minmax(0,1fr))',cells:cells,add:null};
    }
    if(count===1)return {columns:'minmax(0,1fr)',rows:'minmax(0,1fr)',cells:[cell(1,1)],add:null};
    if(count===2)return {columns:'repeat(2,minmax(0,1fr))',rows:'minmax(0,1fr)',cells:[cell(1,1),cell(1,2)],add:null};
    for(i=0;i<count;i++)cells.push(cell(Math.floor(i/2)+1,i%2+1));
    return {columns:'repeat(2,minmax(0,1fr))',rows:'repeat(2,minmax(0,1fr))',cells:cells,add:count<4?cell(2,2):null};
  }
  // Adds a channel, or replaces the screen at `at`. A channel already on screen is not opened twice.
  function add(tiles,item,at){
    var present=tiles.findIndex(function(t){return t.item.id===item.id;});
    if(present>=0&&present!==at)return {tiles:tiles,index:present,reason:'present'};
    var next=tiles.slice(),tile={key:newKey(),item:item};
    if(at!=null&&at>=0&&at<tiles.length){next[at]=tile;return {tiles:next,index:at,reason:'replaced'};}
    if(tiles.length>=MAX)return {tiles:tiles,index:-1,reason:'full'};
    next.push(tile);return {tiles:next,index:next.length-1,reason:'added'};
  }
  // A retry restarts a screen as a new tile (new key), so stale engine events cannot reach it.
  function restart(tiles,index){var next=tiles.slice();next[index]={key:newKey(),item:tiles[index].item};return next;}
  // The followed game a screen is showing: live games first, then the latest finished. `match(game, items)` is
  // AirwaveSports.matchChannels bound to the guide and display names.
  function gameFor(item,games,match){var found=null;['in','post'].some(function(state){return games.some(function(g){if(g.state===state&&match(g,[item]).length)found=g;return found;});});return found;}
  // Live games paired with their best channel, each channel once, for "watch these at once".
  function watchable(games,channels,match,limit){var out=[],used={};games.forEach(function(g){if(g.state!=='in'||out.length>=(limit||MAX))return;var best=match(g,channels).find(function(m){return !used[m.item.id];});if(best){used[best.item.id]=true;out.push({game:g,item:best.item});}});return out;}

  // Plays the screens on the platform. The web uses one Player and <video> per screen; Apple native draws its own grid
  // under the transparent page at the rectangles sent here. Only the `audio` screen is heard. Events reach `emit(key,
  // event, data)` while the session is open; closing invalidates its token so late native events are dropped.
  function Session(options){
    var self=this,host=typeof window!=='undefined'?window:{};
    this.native=!!options.native;this.request=options.request;this.emit=options.emit||function(){};this.Player=options.Player;this.title=options.title;
    this.players={};this.token=++sessions;this.open=true;this.audio=null;
    if(this.native)host.__airwaveMultiview=function(token,key,event,data){if(self.open&&token===self.token)self.emit(key,event,data);};
  }
  // tiles: [{key, item, video, rect: {x, y, w, h}}]. A missing or empty rect hides that screen without stopping it.
  Session.prototype.sync=function(tiles,audio){
    if(!this.open)return;var self=this,keep={};this.audio=audio;
    if(this.native){
      this.request('multiview',{token:this.token,audio:audio,tiles:tiles.map(function(t){var r=t.rect||{};return {key:t.key,id:t.item.id,url:t.item.url,kind:t.item.kind,x:r.x||0,y:r.y||0,w:r.w||0,h:r.h||0};})}).catch(function(){if(self.open)tiles.forEach(function(t){self.emit(t.key,'error','Multiview is unavailable in this version of Airwave.');});});
      return;
    }
    tiles.forEach(function(t){
      keep[t.key]=true;var p=self.players[t.key];
      if(p){p.mute(t.key!==audio);return;}
      p=self.players[t.key]=new self.Player({video:t.video,native:false,muted:t.key!==audio,title:self.title,hls:{maxBufferLength:12,capLevelToPlayerSize:true},emit:function(event,data){if(self.open&&self.players[t.key]===p)self.emit(t.key,event,data);}});
      p.open(t.item,0);
    });
    Object.keys(this.players).forEach(function(k){if(!keep[k]){var p=self.players[k];delete self.players[k];p.close();}});
  };
  Session.prototype.close=function(){
    if(!this.open)return;var self=this;this.open=false;
    Object.keys(this.players).forEach(function(k){var p=self.players[k];delete self.players[k];p.close();});
    if(this.native)this.request('multiviewStop',{token:this.token}).catch(function(){});
  };
  return {MAX:MAX,layout:layout,add:add,restart:restart,gameFor:gameFor,watchable:watchable,Session:Session};
});
