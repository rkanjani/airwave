(function(root,factory){
  if(typeof module==='object'&&module.exports)module.exports=factory;
  else root.AirwaveTVLibrary=factory({indexedDB:root.indexedDB});
})(this,function(options){
  'use strict';
  options=options||{};
  var indexedDB=options.indexedDB,queue=Promise.resolve(),validationMessages=new WeakMap();
  var maxBytes=Math.min(options.maxBytes||100000000,100000000),maxItems=Math.min(options.maxItems||200000,200000);
  var openTimeout=options.openTimeout||10000,transactionTimeout=options.transactionTimeout||60000;
  var database='airwave-tv-library',store='catalog',key='current';
  function failure(message){return new Error(message||'TV library storage is unavailable. Try again.');}
  function invalid(message){var error=failure(message);validationMessages.set(error,message);return error;}
  function ordered(operation){var result=queue.then(operation);queue=result.catch(function(){});return result;}
  function utf8Size(text){var size=0;for(var i=0;i<text.length;i++){var c=text.charCodeAt(i);if(c<128)size++;else if(c<2048)size+=2;else if(c>=55296&&c<=56319&&i+1<text.length&&text.charCodeAt(i+1)>=56320&&text.charCodeAt(i+1)<=57343){size+=4;i++;}else size+=3;if(size>maxBytes)throw invalid('The TV library exceeds the 100 MB size limit.');}return size;}
  function http(value){if(typeof value!=='string'||!value.trim())return false;try{var parsed=new URL(value);return parsed.protocol==='http:'||parsed.protocol==='https:';}catch(e){return false;}}
  function prepare(data){
    try{
      if(!data||data.version!==2||typeof data.name!=='string'||!data.name.trim()||!Array.isArray(data.items)||!data.items.length)throw invalid('Choose a version 2 library with a name and at least one title.');
      if(data.items.length>maxItems)throw invalid('The TV library exceeds the 200,000 title limit.');
      // Bound the entire supplied payload, including metadata that will be discarded.
      var bytes=utf8Size(JSON.stringify(data)),ids=new Set(),live=0,movie=0;
      var items=data.items.map(function(item){
        if(!item||typeof item.id!=='string'||!item.id.trim()||typeof item.name!=='string'||!item.name.trim()||!http(item.url)||(item.kind!=='live'&&item.kind!=='movie'))throw invalid('The TV library contains an invalid title. Nothing was replaced.');
        if(ids.has(item.id))throw invalid('The TV library contains duplicate title IDs. Nothing was replaced.');
        ids.add(item.id);if(item.kind==='live')live++;else movie++;
        var clean={id:item.id,name:item.name,url:item.url,kind:item.kind};
        ['group','epgId','logo'].forEach(function(field){if(item[field]!==undefined){if(typeof item[field]!=='string'||(field==='logo'&&item[field]&&!http(item[field])))throw invalid('The TV library contains invalid title metadata. Nothing was replaced.');clean[field]=item[field];}});
        if(item.favorite!==undefined){if(typeof item.favorite!=='boolean')throw invalid('The TV library contains invalid title metadata. Nothing was replaced.');clean.favorite=item.favorite;}
        if(item.color!==undefined){if(typeof item.color!=='number'||!Number.isFinite(item.color))throw invalid('The TV library contains invalid title metadata. Nothing was replaced.');clean.color=item.color;}
        return clean;
      });
      return {data:{version:2,name:data.name,items:items,private:true,persistent:true,storage:'tv'},summary:{version:2,count:items.length,live:live,movie:movie,bytes:bytes,private:true,persistent:true,storage:'tv'}};
    }catch(error){
      // Do not forward platform/parser exceptions, which may include private values.
      if(validationMessages.has(error))throw failure(validationMessages.get(error));
      throw invalid('The TV library is not valid JSON data. Nothing was replaced.');
    }
  }
  function open(){return new Promise(function(resolve,reject){
    if(!indexedDB||typeof indexedDB.open!=='function'){reject(failure());return;}
    var request,settled=false,timer=setTimeout(function(){finish(failure('TV library storage did not open in time. Try again.'));},openTimeout);
    function finish(error,db){if(settled){if(db)db.close();return;}settled=true;clearTimeout(timer);if(error)reject(error);else resolve(db);}
    try{request=indexedDB.open(database,1);}catch(error){finish(failure());return;}
    request.onblocked=function(){finish(failure('TV library storage is busy. Close other Airwave windows and try again.'));};
    request.onerror=function(){finish(failure());};
    request.onupgradeneeded=function(){if(settled){try{request.transaction.abort();}catch(error){}return;}try{if(!request.result.objectStoreNames.contains(store))request.result.createObjectStore(store);}catch(error){try{request.transaction.abort();}catch(ignore){}finish(failure());}};
    request.onsuccess=function(){var db=request.result;db.onversionchange=function(){db.close();};finish(null,db);};
  });}
  function transact(mode,operation){return open().then(function(db){return new Promise(function(resolve,reject){
    var transaction,settled=false,value,timer;
    function finish(error){if(settled)return;settled=true;clearTimeout(timer);db.close();if(error)reject(error);else resolve(value);}
    try{
      transaction=db.transaction(store,mode);
      transaction.oncomplete=function(){finish();};
      transaction.onabort=function(){finish(failure('The TV library could not be saved or read. Existing data was kept.'));};
      transaction.onerror=function(){/* The abort event is the rollback boundary. */};
      timer=setTimeout(function(){try{transaction.abort();}catch(error){}finish(failure('TV library storage did not finish in time. Try again.'));},transactionTimeout);
      operation(transaction.objectStore(store),function(result){value=result;});
    }catch(error){if(transaction){try{transaction.abort();}catch(ignore){}}finish(failure());}
  });});}
  function read(part){return ordered(function(){return transact('readonly',function(objectStore,done){var request=objectStore.get(key);request.onsuccess=function(){done(request.result?request.result[part]:null);};});});}
  return {
    replace:function(data){var snapshot;try{snapshot=prepare(data);}catch(error){return Promise.reject(error);}return ordered(function(){return transact('readwrite',function(objectStore,done){objectStore.put(snapshot,key);done(snapshot.summary);});});},
    load:function(){return read('data');},
    summary:function(){return read('summary');},
    clear:function(){return ordered(function(){return transact('readwrite',function(objectStore,done){objectStore.delete(key);done(true);});});}
  };
});
