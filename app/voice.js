(function(root,factory){var api=factory();if(typeof module==='object')module.exports=api;else root.AirwaveVoice=api;})(this,function(){
  'use strict';
  // Voice input arrives two ways. Samsung TVs (Tizen 6.0+) pass the remote's voice assistant to the app through
  // webapis.voiceinteraction; browsers that offer speech recognition fill the search box from the microphone.
  // Both become plain commands; the app decides what each means on the screen in front of the viewer.
  var NAV={NAV_LEFT:'left',NAV_RIGHT:'right',NAV_UP:'up',NAV_DOWN:'down',NAV_PREVIOUS:'previous',NAV_NEXT:'next',NAV_SHOW_MORE:'more'};
  var STATES={home:'Home',list:'List',player:'Player',search:'Search',settings:'Setting'};
  var PAGES={Home:'home',Search:'search',Setting:'settings'};
  // app: {state() -> home|list|player|search|settings, context() -> [{x,y,title,alias,focused}], command(type,value) -> handled}.
  // Each callback returns true only when the app handled it, so the TV falls back to its own action (usually a remote key) otherwise.
  function connectSamsung(win,app){
    var vi=win&&win.webapis&&win.webapis.voiceinteraction;if(!vi)return false;
    try{vi.getVersion();}catch(e){return false;}
    function run(type,value){try{return app.command(type,value)===true;}catch(e){return false;}}
    function term(t,field,key){try{if(vi.getDataFromSearchTerm){var v=vi.getDataFromSearchTerm(t,field);if(v)return String(v);}}catch(e){}return t&&t[key]?String(t[key]):'';}
    var callbacks={
      onupdatestate:function(){return STATES[app.state()]||'List';},
      onnavigation:function(n){return NAV[n]?run('navigate',NAV[n]):false;},
      onselection:function(i){return run('select',Number(i));},
      ontitleselection:function(t){return t?run('title',String(t)):false;},
      onrequestcontentcontext:function(){var items=[];try{items=app.context()||[];}catch(e){}
        if(vi.buildVoiceInteractionContentContextItem&&vi.buildVoiceInteractionContentContextResponse)return vi.buildVoiceInteractionContentContextResponse(items.map(function(x){return vi.buildVoiceInteractionContentContextItem(x.x,x.y,x.title,x.alias||[],!!x.focused);}));
        return JSON.stringify(items.map(function(x){return {positionX:x.x,positionY:x.y,title:x.title,alias:x.alias||[],bFocused:!!x.focused};}));},
      onplay:function(){return run('play');},
      onpause:function(){return run('pause');},
      onstop:function(){return run('stop');},
      onrestart:function(){return run('restart');},
      onfastforward:function(){return run('seek',30);},
      onrewind:function(){return run('seek',-30);},
      onskipforward:function(s){return run('seek',Math.abs(Number(s))||10);},
      onskipbackward:function(s){return run('seek',-(Math.abs(Number(s))||10));},
      onsetplayposition:function(s){return isFinite(Number(s))?run('position',Number(s)):false;},
      onchangenexttrack:function(){return run('channel',1);},
      onchangeprevioustrack:function(){return run('channel',-1);},
      onchangesubtitlemode:function(m){return run('subtitles',m==='MEDIA_FUNCTION_ON');},
      onchangeappstate:function(s){return PAGES[s]?run('page',PAGES[s]):false;},
      onadditiontolist:function(){return run('favorite',true);},
      onremovalfromlist:function(){return run('favorite',false);},
      // Older firmware sent spoken searches here; current documentation no longer lists it, so it is only a bonus.
      onsearch:function(t){var q=term(t,'SEARCH_TERM_TITLE','title')||term(t,'SEARCH_TERM_UTTERANCE','utterance');return q?run('search',q):false;}
    };
    try{vi.setCallback(callbacks);vi.listen();return true;}catch(e){return false;}
  }
  // Browser speech recognition for the search box. Returns null where the browser has none.
  function speech(win,lang){
    var Recognition=win&&(win.SpeechRecognition||win.webkitSpeechRecognition);if(!Recognition)return null;
    return function listen(onPartial){
      var r=new Recognition(),done=false,best='',settle;
      var result=new Promise(function(resolve,reject){settle=function(error){if(done)return;done=true;if(error)reject(error);else resolve(best.trim());};});
      r.lang=lang||'';r.interimResults=true;r.continuous=false;r.maxAlternatives=1;
      r.onresult=function(e){var text='';for(var i=0;i<e.results.length;i++)text+=e.results[i][0].transcript;best=text;if(onPartial)onPartial(text.trim());};
      r.onerror=function(e){var code=e&&e.error;settle(code==='no-speech'||code==='aborted'?null:new Error(code==='not-allowed'||code==='service-not-allowed'?'Microphone access is off for Airwave. Allow it in your browser to search by voice.':'Voice search stopped. Try again, or type instead.'));};
      r.onend=function(){settle(null);};
      try{r.start();}catch(e){settle(new Error('Voice search is unavailable right now.'));}
      return {result:result,stop:function(){try{r.stop();}catch(e){settle(null);}}};
    };
  }
  return {connectSamsung:connectSamsung,speech:speech};
});
