(function(root,factory){var api=factory();if(typeof module==='object')module.exports=api;else root.AirwaveCast=api;})(this,function(){
  'use strict';
  // Chrome sender for the default media receiver. Direct sources are cast as they are; private-library items
  // get a tokenized LAN address from the opt-in cast relay, so provider URLs never reach this page or the receiver.
  var SDK='https://www.gstatic.com/cv/js/sender/v1/cast_sender.js?loadCastFramework=1';
  var types={mp4:'video/mp4',m4v:'video/mp4',mov:'video/quicktime',webm:'video/webm',mkv:'video/x-matroska',ts:'video/mp2t',m3u8:'application/x-mpegurl'};
  function guessType(url){var m=/\.([a-z0-9]{2,4})(?:[?#]|$)/i.exec(url.split('?')[0]);return types[m&&m[1].toLowerCase()]||'video/mp4';}
  function relayed(url){return /^\/api\/media\/[^/]+$/.test(url||'');}
  function Cast(options){this.win=options.window;this.emit=options.emit||function(){};this.fetch=options.fetch||function(url,init){return options.window.fetch(url,init);};this.context=null;this.remote=null;this.controller=null;this.generation=0;this.active=false;this.preparing=false;this.relay=false;this.device='';this.lastTime=0;this.loading=false;}
  Cast.supported=function(win){var agent=win.navigator&&win.navigator.userAgent||'';return !(win.AirwavePlatform&&win.AirwavePlatform.native)&&!win.tizen&&!!win.isSecureContext&&/Chrome\//.test(agent);};
  // The SDK is fetched on first use of the player, not at startup.
  Cast.prototype.load=function(){if(this.loading)return;this.loading=true;var self=this,win=this.win;win.__onGCastApiAvailable=function(ok){if(ok)self.setup(win.cast.framework,win.chrome.cast);};var script=win.document.createElement('script');script.src=SDK;script.async=true;win.document.head.appendChild(script);};
  Cast.prototype.setup=function(framework,chromeCast){
    var self=this,context=framework.CastContext.getInstance();this.framework=framework;this.chromeCast=chromeCast;this.context=context;
    context.setOptions({receiverApplicationId:chromeCast.media.DEFAULT_MEDIA_RECEIVER_APP_ID,autoJoinPolicy:chromeCast.AutoJoinPolicy.ORIGIN_SCOPED});
    context.addEventListener(framework.CastContextEventType.CAST_STATE_CHANGED,function(e){self.emit('cast-state',e.castState);});
    context.addEventListener(framework.CastContextEventType.SESSION_STATE_CHANGED,function(e){if(e.sessionState===framework.SessionState.SESSION_ENDED)self.ended();});
    this.remote=new framework.RemotePlayer();this.controller=new framework.RemotePlayerController(this.remote);
    this.controller.addEventListener(framework.RemotePlayerEventType.ANY_CHANGE,function(e){self.changed(e.field);});
    this.emit('cast-state',context.getCastState());
  };
  Cast.prototype.connected=function(){return !!(this.context&&this.context.getCurrentSession());};
  Cast.prototype.source=function(item){
    var self=this;
    if(relayed(item.url))return this.fetch('/api/cast?media='+encodeURIComponent(item.url)+(relayed(item.logo)?'&logo='+encodeURIComponent(item.logo):''),{method:'POST',credentials:'same-origin'}).then(function(r){if(r.status===503)throw new Error('Start Airwave with AIRWAVE_CAST=1 to cast your private library.');if(!r.ok)throw new Error('This title cannot be cast.');self.relay=true;return r.json();});
    if(/^https?:\/\//i.test(item.url||''))return Promise.resolve({url:item.url,contentType:guessType(item.url),logo:/^https:\/\//i.test(item.logo||'')?item.logo:''});
    return Promise.reject(new Error('This title cannot be cast.'));
  };
  // Resolves true once the receiver is loading, false if the device picker was dismissed.
  Cast.prototype.start=function(item,time){
    var self=this,g=++this.generation,C=this.chromeCast;if(!this.context)return Promise.reject(new Error('Casting is still starting. Try again in a moment.'));
    var ready=this.connected()?Promise.resolve():this.context.requestSession();
    return ready.then(function(){return self.source(item);},function(e){if(e==='cancel'||e&&e.code==='cancel')return null;throw new Error('Could not connect to the Cast device.');}).then(function(src){
      if(!src||g!==self.generation)return false;var session=self.context.getCurrentSession();if(!session)return false;
      var info=new C.media.MediaInfo(src.url,src.contentType),meta=new C.media.GenericMediaMetadata(),live=item.kind==='live';
      info.streamType=live?C.media.StreamType.LIVE:C.media.StreamType.BUFFERED;meta.title=item.name;if(src.logo)meta.images=[new C.Image(src.logo)];info.metadata=meta;
      var request=new C.media.LoadRequest(info);request.autoplay=true;request.currentTime=live?0:time||0;
      self.active=true;self.preparing=true;self.lastTime=request.currentTime;self.device=session.getCastDevice().friendlyName||'your TV';self.emit('cast-started',self.device);self.emit('loading','Connecting to '+self.device+'…');
      return session.loadMedia(request).then(function(){if(g===self.generation)self.preparing=false;return true;},function(){if(g!==self.generation)return false;self.ended();throw new Error(self.device+' could not play this title. Its format or source may not support casting.');});
    });
  };
  Cast.prototype.changed=function(field){
    if(!this.active||this.preparing)return;var r=this.remote;
    if(field==='currentTime'||field==='duration'){this.lastTime=r.currentTime;this.emit('time',{time:r.currentTime,duration:r.duration||0});}
    else if(field==='isPaused')this.emit(r.isPaused?'paused':'playing');
    else if(field==='playerState'){if(r.playerState==='BUFFERING')this.emit('loading','Buffering…');else if(r.playerState==='PLAYING')this.emit('playing');
      else if(r.playerState==='IDLE'){var session=this.context.getCurrentSession(),media=session&&session.getMediaSession(),reason=media&&media.idleReason;if(reason==='FINISHED'){this.release();this.emit('ended');}else if(reason==='ERROR'){this.ended();this.emit('notice',this.device+' stopped: the stream could not be played there.');}}}
  };
  Cast.prototype.toggle=function(){if(this.active&&!this.preparing)this.controller.playOrPause();};
  Cast.prototype.seek=function(delta){if(!this.active||this.preparing)return;var r=this.remote;if(!r.duration){this.emit('notice','This live stream cannot be rewound.');return;}r.currentTime=Math.max(0,Math.min(r.duration-0.5,r.currentTime+delta));this.controller.seek();};
  Cast.prototype.release=function(){this.generation++;this.active=false;this.preparing=false;if(this.relay){this.relay=false;this.fetch('/api/cast/end',{method:'POST',credentials:'same-origin'}).catch(function(){});}};
  // Stop the title on the receiver but keep the device connected for the next one.
  Cast.prototype.stopMedia=function(){if(!this.active)return;this.release();try{this.controller.stop();}catch(e){}};
  Cast.prototype.disconnect=function(){if(this.context)this.context.endCurrentSession(true);};
  Cast.prototype.ended=function(){if(!this.active)return;var time=this.remote&&this.remote.currentTime||this.lastTime;this.release();this.emit('cast-ended',{time:time});};
  Cast.guessType=guessType;
  return Cast;
});
