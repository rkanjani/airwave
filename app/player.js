(function(root,factory){var api=factory();if(typeof module==='object')module.exports=api;else root.AirwavePlayer=api;})(this,function(){
  'use strict';
  // Own every callback by playback generation. Closing or switching invalidates old work.
  function Player(options){this.native=typeof window!=='undefined'&&window.AirwavePlatform&&window.AirwavePlatform.native;this.hls=null;this.video=options.video;this.av=options.av||null;this.emit=options.emit||function(){};this.isFavorite=options.isFavorite||function(){return false;};this.generation=0;this.active=false;this.preparing=false;this.timer=null;this.resumeAt=0;this.listeners=[];}
  Player.prototype.close=function(){
    if(this.native&&this.active)window.AirwavePlatform.request('stop').catch(function(){});if(this.hls){this.hls.destroy();this.hls=null;}this.generation++;this.active=false;clearTimeout(this.timer);this.timer=null;
    if(this.av){try{var s=this.av.getState();if(s==='PLAYING'||s==='PAUSED'||s==='READY')this.av.stop();this.av.close();}catch(e){try{this.av.close();}catch(ignore){}}}
    if(this.video){this.listeners.forEach(function(x){this.video.removeEventListener(x[0],x[1]);},this);this.listeners=[];this.video.pause();this.video.removeAttribute('src');this.video.load();}
    this.preparing=false;this.emit('subtitle','');
  };
  Player.prototype.open=function(item,resume){
    this.close();var self=this,g=this.generation;this.active=true;this.preparing=true;this.resumeAt=resume||0;
    function alive(){return self.active&&self.generation===g;}
    function fail(){if(!alive())return;self.close();self.emit('error','Unable to play this stream. Check the link, connection, and supported video format.');}
    if(this.native){window.__airwaveNativePlayback=function(event,data,token){if(token===g&&alive())self.emit(event,data);};window.AirwavePlatform.request('play',{url:item.url,id:item.id,kind:item.kind,resume:this.resumeAt,token:g,title:item.name,favorite:!!this.isFavorite(item)}).then(function(){if(alive()){self.preparing=false;}}).catch(fail);return;}
    this.timer=setTimeout(fail,30000);this.emit('loading','Connecting…');
    if(this.av){
      try{
        this.av.open(item.url);this.av.setDisplayRect(0,0,1920,1080);this.av.setDisplayMethod('PLAYER_DISPLAY_MODE_LETTER_BOX');
        this.av.setListener({onbufferingstart:function(){if(alive())self.emit('loading','Buffering…');},onbufferingcomplete:function(){if(alive())self.emit('ready');},oncurrentplaytime:function(ms){if(alive())self.emit('time',{time:ms/1000,duration:self.av.getDuration()/1000});},onsubtitlechange:function(duration,text){if(alive())self.emit('subtitle',text);},onstreamcompleted:function(){if(alive()){self.close();self.emit('ended');}},onerror:fail});
        this.av.prepareAsync(function(){if(!alive())return;clearTimeout(self.timer);self.preparing=false;try{self.av.play();if(self.resumeAt>0&&self.av.getDuration()>self.resumeAt*1000)self.av.seekTo(self.resumeAt*1000);self.emit('playing');}catch(e){fail();}},fail);
      }catch(e){fail();}
      return;
    }
    var v=this.video;
    function listen(name,fn){v.addEventListener(name,fn);self.listeners.push([name,fn]);}
    listen('loadedmetadata',function(){if(!alive())return;if(self.resumeAt>0&&isFinite(v.duration)&&self.resumeAt<v.duration)v.currentTime=self.resumeAt;});
    listen('playing',function(){if(alive()){clearTimeout(self.timer);self.preparing=false;self.emit('playing');}});
    listen('waiting',function(){if(alive())self.emit('loading','Buffering…');});
    listen('pause',function(){if(alive())self.emit('paused');});
    listen('timeupdate',function(){if(alive())self.emit('time',{time:v.currentTime,duration:v.duration});});
    listen('ended',function(){if(alive()){self.close();self.emit('ended');}});listen('error',fail);
    if(/\.m3u8(\?|$)/i.test(item.url)&&!v.canPlayType('application/vnd.apple.mpegurl')){
      var Hls=typeof window!=='undefined'&&window.Hls;
      if(!Hls||!Hls.isSupported()){this.close();this.emit('error','HLS playback is unavailable on this device.');return;}
      var hls=this.hls=new Hls({enableWorker:true,debug:false,maxBufferLength:30});
      hls.on(Hls.Events.MANIFEST_PARSED,function(){if(alive()){var p=v.play();if(p&&p.catch)p.catch(fail);}});
      hls.on(Hls.Events.ERROR,function(_event,data){if(alive()&&data.fatal)fail();});
      hls.loadSource(item.url);hls.attachMedia(v);return;
    }
    v.src=item.url;var result=v.play();if(result&&result.catch)result.catch(fail);
  };
  Player.prototype.toggle=function(){if(this.native){window.AirwavePlatform.request('toggle').catch(function(){});return;}if(!this.active||this.preparing)return;try{if(this.av){if(this.av.getState()==='PLAYING'){this.av.pause();this.emit('paused');}else if(this.av.getState()==='PAUSED'){this.av.play();this.emit('playing');}}else if(this.video.paused){var p=this.video.play();if(p&&p.catch)p.catch(function(){});}else this.video.pause();}catch(e){this.emit('notice','Playback control is unavailable for this stream.');}};
  Player.prototype.seek=function(delta){if(this.native){window.AirwavePlatform.request('seek',{delta:delta}).catch(function(){});return;}if(!this.active||this.preparing)return;try{var d=this.av?this.av.getDuration()/1000:this.video.duration;var t=this.av?this.av.getCurrentTime()/1000:this.video.currentTime;if(!isFinite(d)||d<=0){this.emit('notice','This live stream cannot be rewound.');return;}var next=Math.max(0,Math.min(d-0.5,t+delta));if(this.av)this.av.seekTo(next*1000);else this.video.currentTime=next;}catch(e){this.emit('notice','Seeking is unavailable for this stream.');}};
  Player.prototype.tracks=function(){if(!this.active||this.preparing)return [];try{if(this.hls)return this.hls.audioTracks.map(function(t,i){return {type:'AUDIO',index:i,extra_info:JSON.stringify({language:t.name||t.lang})};}).concat(this.hls.subtitleTracks.map(function(t,i){return {type:'TEXT',index:i,extra_info:JSON.stringify({language:t.name||t.lang})};}));return this.av?this.av.getTotalTrackInfo().filter(function(t){return t.type==='AUDIO'||t.type==='TEXT';}):[];}catch(e){return [];}};
  Player.prototype.selectTrack=function(type,index){try{if(this.hls){if(type==='AUDIO')this.hls.audioTrack=index;else this.hls.subtitleTrack=index;return;}if(!this.av)return;if(type==='TEXT'&&index<0)this.av.setSilentSubtitle(true);else{this.av.setSelectTrack(type,index);if(type==='TEXT')this.av.setSilentSubtitle(false);}}catch(e){this.emit('notice','This track cannot be selected on this device.');}};
  return Player;
});
