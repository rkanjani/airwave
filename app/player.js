(function(root,factory){var api=factory();if(typeof module==='object')module.exports=api;else root.AirwavePlayer=api;})(this,function(){
  'use strict';
  // Own every callback by playback generation. Closing or switching invalidates old work.
  function Player(options){this.native=typeof window!=='undefined'&&window.AirwavePlatform&&window.AirwavePlatform.native;this.hls=null;this.video=options.video;this.av=options.av||null;this.emit=options.emit||function(){};this.title=options.title||function(item){return item.name;};this.isFavorite=options.isFavorite||function(){return false;};this.pickSubtitle=options.pickSubtitle||function(list){return list.length?0:-1;};this.subtitle=null;this.generation=0;this.active=false;this.preparing=false;this.timer=null;this.resumeAt=0;this.listeners=[];}
  Player.prototype.close=function(){
    if(this.native&&this.active)window.AirwavePlatform.request('stop').catch(function(){});if(this.hls){this.hls.destroy();this.hls=null;}this.generation++;this.active=false;clearTimeout(this.timer);this.timer=null;
    if(this.av){try{var s=this.av.getState();if(s==='PLAYING'||s==='PAUSED'||s==='READY')this.av.stop();this.av.close();}catch(e){try{this.av.close();}catch(ignore){}}}
    if(this.video){this.listeners.forEach(function(x){x[2].removeEventListener(x[0],x[1]);});this.listeners=[];textTracks(this.video).forEach(function(t){t.mode='disabled';});this.video.pause();this.video.removeAttribute('src');this.video.load();}
    this.preparing=false;this.subtitle=null;this.audio=null;this.emit('subtitle','');
  };
  Player.prototype.open=function(item,resume){
    this.close();var self=this,g=this.generation,movie=item.kind==='movie';this.active=true;this.preparing=true;this.resumeAt=resume||0;
    function alive(){return self.active&&self.generation===g;}
    function fail(){if(!alive())return;self.close();self.emit('error','Unable to play this stream. Check the link, connection, and supported video format.');}
    if(this.native){window.__airwaveNativePlayback=function(event,data,token){if(token===g&&alive())self.emit(event,data);};window.AirwavePlatform.request('play',{url:item.url,id:item.id,kind:item.kind,resume:this.resumeAt,token:g,title:this.title(item),favorite:!!this.isFavorite(item)}).then(function(){if(alive()){self.preparing=false;}}).catch(fail);return;}
    this.timer=setTimeout(fail,30000);this.emit('loading','Connecting…');
    if(this.av){
      try{
        this.av.open(item.url);this.av.setDisplayRect(0,0,1920,1080);this.av.setDisplayMethod('PLAYER_DISPLAY_MODE_LETTER_BOX');
        this.av.setListener({onbufferingstart:function(){if(alive())self.emit('loading','Buffering…');},onbufferingcomplete:function(){if(alive())self.emit('ready');},oncurrentplaytime:function(ms){if(alive())self.emit('time',{time:ms/1000,duration:self.av.getDuration()/1000});},onsubtitlechange:function(duration,text){if(alive())self.emit('subtitle',text);},onstreamcompleted:function(){if(alive()){self.close();self.emit('ended');}},onerror:fail});
        this.av.prepareAsync(function(){if(!alive())return;clearTimeout(self.timer);self.preparing=false;try{self.av.play();if(self.resumeAt>0&&self.av.getDuration()>self.resumeAt*1000)self.av.seekTo(self.resumeAt*1000);self.emit('playing');}catch(e){fail();return;}self.autoSubtitle(movie);},fail);
      }catch(e){fail();}
      return;
    }
    var v=this.video;
    function listen(name,fn,target){target=target||v;target.addEventListener(name,fn);self.listeners.push([name,fn,target]);}
    listen('loadedmetadata',function(){if(!alive())return;if(self.resumeAt>0&&isFinite(v.duration)&&self.resumeAt<v.duration)v.currentTime=self.resumeAt;if(!self.hls)self.autoSubtitle(movie);});
    if(v.textTracks&&v.textTracks.addEventListener)listen('addtrack',function(){if(alive()&&!self.hls)self.autoSubtitle(movie);},v.textTracks);
    listen('playing',function(){if(alive()){clearTimeout(self.timer);self.preparing=false;self.emit('playing');}});
    listen('waiting',function(){if(alive())self.emit('loading','Buffering…');});
    listen('pause',function(){if(alive())self.emit('paused');});
    listen('timeupdate',function(){if(alive())self.emit('time',{time:v.currentTime,duration:v.duration});});
    listen('ended',function(){if(alive()){self.close();self.emit('ended');}});listen('error',fail);
    // HLS.js goes first wherever it runs: browsers' own HLS (Safari, Chrome 142+) does not always list subtitle and audio renditions.
    var Hls=typeof window!=='undefined'&&window.Hls;
    if(/\.m3u8(\?|$)/i.test(item.url)&&!(Hls&&Hls.isSupported())&&!v.canPlayType('application/vnd.apple.mpegurl')){this.close();this.emit('error','HLS playback is unavailable on this device.');return;}
    if(/\.m3u8(\?|$)/i.test(item.url)&&Hls&&Hls.isSupported()){
      var hls=this.hls=new Hls({enableWorker:true,debug:false,maxBufferLength:30});
      hls.on(Hls.Events.MANIFEST_PARSED,function(){if(alive()){var p=v.play();if(p&&p.catch)p.catch(fail);}});
      hls.on(Hls.Events.SUBTITLE_TRACKS_UPDATED,function(){if(alive())self.autoSubtitle(movie);});
      hls.on(Hls.Events.ERROR,function(_event,data){if(!alive()||!data.fatal)return;
        // A playlist HLS.js may not fetch (no CORS) can still play through the browser's own HLS, without track choices.
        if(data.details===Hls.ErrorDetails.MANIFEST_LOAD_ERROR&&v.canPlayType('application/vnd.apple.mpegurl')){hls.destroy();self.hls=null;v.src=item.url;var p=v.play();if(p&&p.catch)p.catch(fail);return;}
        fail();});
      hls.loadSource(item.url);hls.attachMedia(v);return;
    }
    v.src=item.url;var result=v.play();if(result&&result.catch)result.catch(fail);
  };
  Player.prototype.toggle=function(){if(this.native){window.AirwavePlatform.request('toggle').catch(function(){});return;}if(!this.active||this.preparing)return;try{if(this.av){if(this.av.getState()==='PLAYING'){this.av.pause();this.emit('paused');}else if(this.av.getState()==='PAUSED'){this.av.play();this.emit('playing');}}else if(this.video.paused){var p=this.video.play();if(p&&p.catch)p.catch(function(){});}else this.video.pause();}catch(e){this.emit('notice','Playback control is unavailable for this stream.');}};
  Player.prototype.seek=function(delta){if(this.native){window.AirwavePlatform.request('seek',{delta:delta}).catch(function(){});return;}if(!this.active||this.preparing)return;try{var d=this.av?this.av.getDuration()/1000:this.video.duration;var t=this.av?this.av.getCurrentTime()/1000:this.video.currentTime;if(!isFinite(d)||d<=0){this.emit('notice','This live stream cannot be rewound.');return;}var next=Math.max(0,Math.min(d-0.5,t+delta));if(this.av)this.av.seekTo(next*1000);else this.video.currentTime=next;}catch(e){this.emit('notice','Seeking is unavailable for this stream.');}};
  // Tracks inside the stream: HLS.js renditions, the browser's own text tracks, or AVPlay's. Movies start on the
  // subtitle track pickSubtitle prefers; after that Off or another track is the viewer's choice for this title.
  function textTracks(v){return Array.prototype.filter.call(v&&v.textTracks||[],function(t){return t.kind==='subtitles'||t.kind==='captions'||t.kind==='forced';});}
  function avTracks(av,type){return av.getTotalTrackInfo().filter(function(t){return t.type===type;}).map(function(t){var x={};try{x=JSON.parse(t.extra_info||'{}');}catch(e){}return {id:String(t.index),language:x.track_lang||x.language||'',label:'',forced:false};});}
  function ready(p){return p.active&&!(p.av&&p.preparing);}
  Player.prototype.subtitleTracks=function(){if(!ready(this))return [];try{if(this.hls)return this.hls.subtitleTracks.map(function(t,i){return {id:String(i),language:t.lang||'',label:t.name||'',forced:!!t.forced};});if(this.av)return avTracks(this.av,'TEXT');return textTracks(this.video).map(function(t,i){return {id:String(i),language:t.language||'',label:t.label||'',forced:t.kind==='forced'};});}catch(e){return [];}};
  Player.prototype.subtitleChoice=function(){if(!ready(this))return 'off';try{if(this.hls)return this.hls.subtitleTrack>=0&&this.hls.subtitleDisplay!==false?String(this.hls.subtitleTrack):'off';if(this.av)return this.subtitle||'off';var shown=textTracks(this.video).map(function(t){return t.mode;}).indexOf('showing');return shown<0?'off':String(shown);}catch(e){return 'off';}};
  Player.prototype.selectSubtitle=function(id){var index=id==='off'?-1:Number(id);this.subtitle=id;try{if(this.hls){this.hls.subtitleDisplay=index>=0;this.hls.subtitleTrack=index;}else if(this.av){if(index<0)this.av.setSilentSubtitle(true);else{this.av.setSelectTrack('TEXT',index);this.av.setSilentSubtitle(false);}}else textTracks(this.video).forEach(function(t,i){t.mode=i===index?'showing':'disabled';});}catch(e){this.emit('notice','This subtitle track cannot be selected on this device.');}this.emit('subtitles');};
  Player.prototype.autoSubtitle=function(movie){if(!movie||this.subtitle!==null)return;var list=this.subtitleTracks(),i=list.length?this.pickSubtitle(list):-1;if(i>=0)this.selectSubtitle(list[i].id);};
  Player.prototype.audioTracks=function(){if(!ready(this))return [];try{if(this.hls)return this.hls.audioTracks.map(function(t,i){return {id:String(i),language:t.lang||'',label:t.name||''};});if(this.av)return avTracks(this.av,'AUDIO');}catch(e){}return [];};
  Player.prototype.audioChoice=function(){try{if(this.hls)return String(this.hls.audioTrack);}catch(e){}return this.audio||'';};
  Player.prototype.selectAudio=function(id){this.audio=id;try{if(this.hls)this.hls.audioTrack=Number(id);else if(this.av)this.av.setSelectTrack('AUDIO',Number(id));}catch(e){this.emit('notice','This audio track cannot be selected on this device.');}};
  return Player;
});
