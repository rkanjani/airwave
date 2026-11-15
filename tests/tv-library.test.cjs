const test=require('node:test'),assert=require('node:assert/strict'),factory=require('../app/tv-library.js');
// A small in-memory IndexedDB: one database, object stores of key -> value, events fired asynchronously like the real one.
function fakeIndexedDB(){
  const stores=new Map();
  return {open(){const request={};setTimeout(()=>{const db={objectStoreNames:{contains:n=>stores.has(n)},createObjectStore(n){stores.set(n,new Map());},close(){},
    transaction(name){const map=stores.get(name),tx={objectStore(){return {get(k){const r={};setTimeout(()=>{r.result=map.get(k);r.onsuccess&&r.onsuccess();finish();});return r;},put(v,k){map.set(k,structuredClone(v));finish();},delete(k){map.delete(k);finish();}};}};
      let done=false;function finish(){if(done)return;done=true;setTimeout(()=>tx.oncomplete&&tx.oncomplete());}return tx;}};
    request.result=db;if(!stores.size){request.transaction={abort(){}};request.onupgradeneeded&&request.onupgradeneeded();}request.onsuccess&&request.onsuccess();});return request;}};
}
const library={version:2,name:'Living room',items:[{id:'a',name:'News',url:'https://tv.example/a.m3u8',kind:'live',group:'US',secret:'dropped'},{id:'b',name:'Film',url:'https://tv.example/b.mp4',kind:'movie',favorite:true}]};
test('the TV library saves, loads and summarises a version 2 library, keeping only catalog fields',async()=>{
  const store=factory({indexedDB:fakeIndexedDB()});
  assert.equal(await store.load(),null);
  const summary=await store.replace(library);
  assert.deepEqual(summary,{version:2,count:2,live:1,movie:1,bytes:summary.bytes,private:true,persistent:true,storage:'tv'});
  const loaded=await store.load();
  assert.equal(loaded.name,'Living room');assert.equal(loaded.storage,'tv');assert.equal(loaded.items[0].secret,undefined);assert.equal(loaded.items[1].favorite,true);
  await store.clear();assert.equal(await store.load(),null);
});
test('an invalid library is refused and the saved one is kept',async()=>{
  const store=factory({indexedDB:fakeIndexedDB()});await store.replace(library);
  await assert.rejects(store.replace({version:2,name:'x',items:[{id:'a',name:'A',url:'javascript:alert(1)',kind:'live'}]}),/invalid title/);
  await assert.rejects(store.replace({version:2,name:'x',items:[library.items[0],library.items[0]]}),/duplicate/);
  await assert.rejects(store.replace({version:1,name:'x',items:[]}),/version 2/);
  assert.equal((await store.load()).items.length,2);
});
test('without IndexedDB the store reports itself unavailable instead of throwing at load',async()=>{
  await assert.rejects(factory({}).load(),/unavailable/);
});
