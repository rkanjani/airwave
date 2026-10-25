(function(root){
'use strict';
var pending=new Map(),serial=0;
// Apple posts through a WebKit message handler; Android injects an origin-restricted AirwaveAndroid listener that takes strings.
var apple=!!(root.webkit&&root.webkit.messageHandlers&&root.webkit.messageHandlers.airwave),android=!apple&&!!(root.AirwaveAndroid&&root.AirwaveAndroid.postMessage),native=apple||android;
function post(message){if(apple)root.webkit.messageHandlers.airwave.postMessage(message);else root.AirwaveAndroid.postMessage(JSON.stringify(message));}
function request(action,payload){return new Promise(function(resolve,reject){var id=String(++serial),timer=setTimeout(function(){pending.delete(id);reject(new Error('The native request timed out.'));},action==='importLibrary'?300000:30000);pending.set(id,{resolve:resolve,reject:reject,timer:timer});post({id:id,action:action,payload:payload||{}});});}
root.__airwaveNativeReply=function(id,result,error){var p=pending.get(id);if(!p)return;clearTimeout(p.timer);pending.delete(id);if(error)p.reject(new Error(error));else p.resolve(result);};
root.AirwavePlatform={native:native,name:apple?'Apple native':android?'Android native':root.tizen?'Samsung TV':'Web',request:request,
exit:android?function(){return request('exit');}:null,
loadLibrary:async function(){if(native)return request('library');if(location.protocol!=='http:'&&location.protocol!=='https:')return null;var response=await fetch('/api/library',{credentials:'same-origin'});if(response.status===404)return null;if(!response.ok)throw new Error('The private library could not be loaded.');return response.json();},
importLibrary:async function(){if(!native)throw new Error('Native import is unavailable.');return request('importLibrary');},
fetchText:async function(url,max,signal){if(native)return request('fetchText',{url:url,max:max});var r=await fetch(url,{signal:signal,credentials:'omit',referrerPolicy:'no-referrer'});if(!r.ok)throw new Error('The source returned HTTP '+r.status+'.');if(Number(r.headers.get('Content-Length'))>max)throw new Error('Source file exceeds the size limit.');var text=await r.text();if(text.length>max)throw new Error('Source file exceeds the size limit.');return text;}
};
})(window);
