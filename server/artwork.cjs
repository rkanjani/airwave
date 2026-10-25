// Tile artwork for the local relay: one fetch per image, kept in a bounded in-memory LRU.
// Failures are remembered for a day so broken provider logos are not retried on every scroll.
function makeArtwork({load,maxEntry=2*1024*1024,maxTotal=64*1024*1024,failFor=24*3600*1000,now=Date.now}){const cache=new Map(),failed=new Map(),pending=new Map();let total=0;
function store(key,art){cache.set(key,art);total+=art.body.length;for(const [oldKey,old] of cache){if(total<=maxTotal)break;cache.delete(oldKey);total-=old.body.length;}}
async function get(key,url){const hit=cache.get(key);if(hit){cache.delete(key);cache.set(key,hit);return hit;}if(now()-(failed.get(key)??-Infinity)<failFor)return null;if(pending.has(key))return pending.get(key);
const job=load(url,maxEntry).then(art=>{if(!art||!/^image\//.test(art.type)||!art.body.length||art.body.length>maxEntry)throw new Error('Not usable artwork');failed.delete(key);store(key,art);return art;}).catch(()=>{failed.set(key,now());return null;}).finally(()=>pending.delete(key));
pending.set(key,job);return job;}
return {get,size:()=>total};}
module.exports={makeArtwork};
