(function(root,factory){var api=factory();if(typeof module==='object')module.exports=api;else root.AirwavePlayer=api;})(this,function(){
  'use strict';
  // Own every callback by playback generation. Closing or switching invalidates old work.
  function Player(options){this.native=typeof window!=='undefined'&&window.AirwavePlatform&&window.AirwavePlatform.native;this.hls=null;this.video=options.video;this.av=options.av||null;this.emit=options.emit||function(){};this.title=options.title||function(item){return item.name;};this.isFavorite=options.isFavorite||function(){return false;};this.resolve=options.resolve||null;this.diagnose=options.diagnose||null;this.hlsOptions=options.hls||{};this.muted=!!options.muted;if(options.native===false)this.native=false;this.generation=0;this.active=false;this.preparing=false;this.timer=null;this.resumeAt=0;this.listeners=[];}
  Player.prototype.close=function(){
    if(this.native&&this.active)window.AirwavePlatform.request('stop').catch(function(){});if(this.hls){this.hls.destroy();this.hls=null;}this.generation++;this.active=false;clearTimeout(this.timer);this.timer=null;
    if(this.av){try{var s=this.av.getState();if(s==='PLAYING'||s==='PAUSED'||s==='READY')this.av.stop();this.av.close();}catch(e){try{this.av.close();}catch(ignore){}}}
    if(this.video){this.listeners.forEach(function(x){this.video.removeEventListener(x[0],x[1]);},this);this.listeners=[];this.video.pause();this.video.removeAttribute('src');this.video.load();}
    this.preparing=false;this.emit('subtitle','');
  };
  Player.prototype.open=function(item,resume){
    this.close();var self=this,g=this.generation;this.active=true;this.preparing=true;this.resumeAt=resume||0;
    function alive(){return self.active&&self.generation===g;}
    // facts.status is the HTTP status the redirect lookup saw; a diagnoser turns it, and the failure, into a reason the viewer can act on.
    var facts={};
    function fail(cause){
      if(!alive())return;var reason=Player.reason(cause);self.close();
      if(!self.diagnose){self.emit('error',GENERIC);return;}
      var after=self.generation;self.emit('loading','Checking the stream…');
      Promise.resolve().then(function(){return self.diagnose(item.url,{status:facts.status,reason:reason});}).then(null,function(){return null;}).then(function(text){if(self.generation===after&&!self.active)self.emit('error',text||GENERIC);});
    }
    if(this.native){window.__airwaveNativePlayback=function(event,data,token){if(token===g&&alive())self.emit(event,data);};window.AirwavePlatform.request('play',{url:item.url,id:item.id,kind:item.kind,resume:this.resumeAt,token:g,title:this.title(item),favorite:!!this.isFavorite(item)}).then(function(){if(alive()){self.preparing=false;}}).catch(fail);return;}
    this.timer=setTimeout(function(){fail('timeout');},START_TIMEOUT*1000);this.emit('loading','Connecting…');
    if(this.av){
      // AVPlay waits indefinitely on some provider redirects, so the final address is resolved first when a resolver is set.
      // A refused lookup (an account at its stream limit, say) is reported at once when the diagnoser is sure, instead of after AVPlay's timeout.
      if(this.resolve){this.resolve(item.url).then(function(found){
        if(!alive())return;found=typeof found==='string'?{url:found}:found||{};facts.status=found.status;var url=found.url||item.url;
        if(!self.diagnose||!(found.status>=400))return self.start(url,alive,fail);
        Promise.resolve().then(function(){return self.diagnose(item.url,{status:found.status,early:true});}).then(null,function(){return null;}).then(function(text){if(!alive())return;if(!text)return self.start(url,alive,fail);self.close();self.emit('error',text);});
      },function(){if(alive())self.start(item.url,alive,fail);});return;}
      this.start(item.url,alive,fail);return;
    }
    var v=this.video;v.muted=this.muted;
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
      var hls=this.hls=new Hls(Object.assign({enableWorker:true,debug:false,maxBufferLength:30},this.hlsOptions));
      hls.on(Hls.Events.MANIFEST_PARSED,function(){if(alive()){var p=v.play();if(p&&p.catch)p.catch(fail);}});
      hls.on(Hls.Events.ERROR,function(_event,data){if(alive()&&data.fatal)fail();});
      hls.loadSource(item.url);hls.attachMedia(v);return;
    }
    v.src=item.url;var result=v.play();if(result&&result.catch)result.catch(fail);
  };
  Player.prototype.start=function(url,alive,fail){
    var self=this;
    try{
      this.av.open(url);
      // AVPlay waits for 10 s of media before it starts unless told otherwise; 4 s is the smallest amount Samsung allows.
      try{this.av.setBufferingParam('PLAYER_BUFFER_FOR_PLAY','PLAYER_BUFFER_SIZE_IN_SECOND',START_BUFFER);}catch(e){}
      this.av.setDisplayRect(0,0,1920,1080);this.av.setDisplayMethod('PLAYER_DISPLAY_MODE_LETTER_BOX');
      this.av.setListener({onbufferingstart:function(){if(alive())self.emit('loading','Buffering…');},onbufferingprogress:function(percent){if(alive()&&self.preparing&&percent>0&&percent<100)self.emit('loading','Buffering '+Math.round(percent)+'%');},onbufferingcomplete:function(){if(alive())self.emit('ready');},oncurrentplaytime:function(ms){if(alive())self.emit('time',{time:ms/1000,duration:self.av.getDuration()/1000});},onsubtitlechange:function(duration,text){if(alive())self.emit('subtitle',text);},onstreamcompleted:function(){if(alive()){self.close();self.emit('ended');}},onerror:fail});
      this.av.prepareAsync(function(){if(!alive())return;clearTimeout(self.timer);self.preparing=false;try{self.av.play();if(self.resumeAt>0&&self.av.getDuration()>self.resumeAt*1000)self.av.seekTo(self.resumeAt*1000);self.emit('playing');}catch(e){fail();}},fail);
    }catch(e){fail();}
  };
  var GENERIC='Unable to play this stream. Check the link, connection, and supported video format.',START_TIMEOUT=30,START_BUFFER=4;
  // Statuses providers use for "too many connections". 401 and 403 can mean that too, so those ask the account first.
  var LIMIT={429:1,458:1,509:1};
  // What a failure looked like to the player: a timeout, a format it can't decode, a connection it couldn't make, or something else.
  Player.reason=function(cause){
    if(cause==='timeout')return 'timeout';var name=typeof cause==='string'?cause:cause&&(cause.name||cause.type)||'';
    if(/NOT_SUPPORTED|NotSupported/.test(name))return 'format';
    if(/CONNECTION_FAILED|INVALID_URI|NO_SUCH_FILE|InvalidAccess|NetworkError/.test(name))return 'connection';
    return 'error';
  };
  // Request a link and keep only its status and final address: the body is abandoned once headers arrive. status 0 means no answer.
  Player.probe=function(url,fetchImpl,timeout){
    var request=fetchImpl||(typeof fetch==='function'?fetch:null);
    if(!request||!/^https?:\/\//i.test(url)||typeof AbortController!=='function')return Promise.resolve({url:url});
    var controller=new AbortController(),timer=setTimeout(function(){controller.abort();},timeout||8000);
    return Promise.resolve().then(function(){return request(url,{signal:controller.signal,credentials:'omit',referrerPolicy:'no-referrer'});}).then(function(response){
      var status=response&&response.status||0;return {url:response&&response.ok&&response.redirected&&/^https?:\/\//i.test(response.url)?response.url:url,status:status};
    },function(){return {url:url,status:0};}).then(function(found){clearTimeout(timer);controller.abort();return found;});
  };
  // Providers that serve /live/<user>/<pass>/<id>.ts (or /movie/, /series/, or no prefix) answer player_api.php with the account's
  // status, expiry and stream counts. Anything else, or any failure, gives null. The request goes only to the stream's own host.
  Player.account=function(url,fetchImpl,timeout){
    var request=fetchImpl||(typeof fetch==='function'?fetch:null),m=/^(https?:\/\/[^/?#]+)\/(?:(?:live|movie|series)\/)?([^/?#]+)\/([^/?#]+)\/\d+(?:\.\w+)?(?:[?#]|$)/i.exec(url||'');
    if(!request||!m||typeof AbortController!=='function')return Promise.resolve(null);
    var controller=new AbortController(),timer=setTimeout(function(){controller.abort();},timeout||6000);
    return Promise.resolve().then(function(){return request(m[1]+'/player_api.php?username='+m[2]+'&password='+m[3],{signal:controller.signal,credentials:'omit',referrerPolicy:'no-referrer'});}).then(function(response){
      if(!response||!response.ok)return null;return response.json().then(function(body){
        var info=body&&body.user_info;if(!info||typeof info!=='object')return null;
        var number=function(x){var n=Number(x);return isFinite(n)&&x!==''&&x!=null?n:null;};
        return {auth:info.auth===undefined?null:Number(info.auth)===1,status:typeof info.status==='string'?info.status:'',expires:number(info.exp_date),active:number(info.active_cons),max:number(info.max_connections)};
      });
    }).then(null,function(){return null;}).then(function(found){clearTimeout(timer);controller.abort();return found;});
  };
  // Turn what is known into one message. sure marks a cause that no playback attempt would get past.
  Player.explain=function(facts,now){
    var s=facts.status,a=facts.account,reason=facts.reason,tail=' Stop playback on another device, then try again.';
    if(a){
      if(a.auth===false)return {text:"Your provider didn't accept the account in this playlist. Check its username and password.",sure:true};
      if(/expired/i.test(a.status)||(a.expires>0&&a.expires*1000<(now||Date.now())))return {text:'Your provider subscription has expired.',sure:true};
      if(a.status&&!/^active$/i.test(a.status))return {text:'Your provider account is '+a.status.toLowerCase()+'.',sure:true};
      if(a.max>0&&a.active>=a.max)return {text:a.max===1?"Your provider allows 1 stream at a time, and it's already in use."+tail:'Your provider allows '+a.max+' streams at a time, and all '+a.max+' are in use.'+tail,sure:true};
    }
    if(LIMIT[s])return {text:'Your provider is at its limit of streams at once (HTTP '+s+').'+tail,sure:true};
    if(s===401||s===403)return {text:'The provider refused this stream (HTTP '+s+'). Your account may be using all of its streams at once.'+tail};
    if(s===404||s===410)return {text:"The provider doesn't have this stream right now (HTTP "+s+'). It may be off air or removed.'};
    if(s>=500)return {text:"The provider's server had a problem (HTTP "+s+'). Try again in a moment.'};
    if(s>=400)return {text:'The provider refused this stream (HTTP '+s+').'};
    if(s===0)return {text:"Couldn't reach the provider. Check your internet connection, then try again."};
    if(s>=200&&s<400){
      if(reason==='timeout')return {text:"The provider is sending this stream, but it didn't start within "+START_TIMEOUT+' seconds. Try again, or choose another channel.'};
      if(reason==='format')return {text:"The stream is reachable, but this device can't play its format."};
      return {text:"The stream is reachable, but it couldn't be played on this device. Try again, or choose another channel."};
    }
    return {text:GENERIC};
  };
  // Find out why a stream failed. The status the redirect lookup saw is reused for a format error (asking again would count
  // against the account's stream limit while the closed player may still be counted); otherwise the link is asked again once.
  // Early mode runs before playback and answers only when it is sure; anything else lets the player try.
  Player.diagnose=function(url,facts,fetchImpl,now){
    facts=facts||{};var status=facts.status;
    var known=facts.early||(facts.reason==='format'&&status>=200&&status<400);
    return (known?Promise.resolve(status):Player.probe(url,fetchImpl).then(function(found){return found.status;})).then(function(code){
      var ask=code>=400&&code!==404&&code!==410&&(code<500||code===503||code===509);
      return (ask?Player.account(url,fetchImpl):Promise.resolve(null)).then(function(account){
        var found=Player.explain({status:code,reason:facts.reason,account:account},now);return facts.early?(found.sure?found.text:null):found.text;
      });
    });
  };
  // Follow an HTTP(S) redirect and return the final address. The body is abandoned once headers arrive; any failure keeps the original link.
  Player.resolveRedirect=function(url,fetchImpl,timeout){return Player.probe(url,fetchImpl,timeout).then(function(found){return found.url;});};
  // Multiview tiles keep playing silently; only the screen with focus is heard.
  Player.prototype.mute=function(on){this.muted=!!on;if(this.video)this.video.muted=this.muted;};
  Player.prototype.toggle=function(){if(this.native){window.AirwavePlatform.request('toggle').catch(function(){});return;}if(!this.active||this.preparing)return;try{if(this.av){if(this.av.getState()==='PLAYING'){this.av.pause();this.emit('paused');}else if(this.av.getState()==='PAUSED'){this.av.play();this.emit('playing');}}else if(this.video.paused){var p=this.video.play();if(p&&p.catch)p.catch(function(){});}else this.video.pause();}catch(e){this.emit('notice','Playback control is unavailable for this stream.');}};
  Player.prototype.seek=function(delta){if(this.native){window.AirwavePlatform.request('seek',{delta:delta}).catch(function(){});return;}if(!this.active||this.preparing)return;try{var d=this.av?this.av.getDuration()/1000:this.video.duration;var t=this.av?this.av.getCurrentTime()/1000:this.video.currentTime;if(!isFinite(d)||d<=0){this.emit('notice','This live stream cannot be rewound.');return;}var next=Math.max(0,Math.min(d-0.5,t+delta));if(this.av)this.av.seekTo(next*1000);else this.video.currentTime=next;}catch(e){this.emit('notice','Seeking is unavailable for this stream.');}};
  Player.prototype.tracks=function(){if(!this.active||this.preparing)return [];try{if(this.hls)return this.hls.audioTracks.map(function(t,i){return {type:'AUDIO',index:i,extra_info:JSON.stringify({language:t.name||t.lang})};}).concat(this.hls.subtitleTracks.map(function(t,i){return {type:'TEXT',index:i,extra_info:JSON.stringify({language:t.name||t.lang})};}));return this.av?this.av.getTotalTrackInfo().filter(function(t){return t.type==='AUDIO'||t.type==='TEXT';}):[];}catch(e){return [];}};
  Player.prototype.selectTrack=function(type,index){try{if(this.hls){if(type==='AUDIO')this.hls.audioTrack=index;else this.hls.subtitleTrack=index;return;}if(!this.av)return;if(type==='TEXT'&&index<0)this.av.setSilentSubtitle(true);else{this.av.setSelectTrack(type,index);if(type==='TEXT')this.av.setSilentSubtitle(false);}}catch(e){this.emit('notice','This track cannot be selected on this device.');}};
  return Player;
});
