// Live tile previews for the local relay: one still from a channel's newest HLS segment, decoded by a local ffmpeg.
// Providers often allow one or two connections per account, so grabs run one at a time with a gap between them,
// wait while anything plays (playback aborts a running grab and requeues it), and are kept for minutes.
const {spawn,spawnSync}=require('node:child_process');
const videoCodec=/avc|hvc|hev|vp0?9|av01|mp4v/i;
// Next step from a playlist: the smallest video variant at least 360 lines tall, or the newest segment and its init map.
function pickSegment(text,base){if(!text.trimStart().startsWith('#EXTM3U'))throw new Error('Not an HLS playlist');const lines=text.split(/\r?\n/).map(x=>x.trim()),variants=[];let map='',encrypted=false,segment=null;
for(let i=0;i<lines.length;i++){const line=lines[i];if(!line)continue;
if(line.startsWith('#EXT-X-STREAM-INF:')){const uri=lines.slice(i+1).find(x=>x&&x[0]!=='#'),codecs=(/CODECS="([^"]*)"/.exec(line)||[])[1];if(uri&&(!codecs||videoCodec.test(codecs)))variants.push({url:new URL(uri,base).href,bandwidth:Number((/BANDWIDTH=(\d+)/.exec(line)||[])[1])||0,height:Number((/RESOLUTION=\d+x(\d+)/.exec(line)||[])[1])||0});continue;}
if(line.startsWith('#EXT-X-KEY:')){encrypted=!/METHOD=NONE/.test(line);continue;}
if(line.startsWith('#EXT-X-MAP:')){const uri=(/URI="([^"]+)"/.exec(line)||[])[1];map=uri?new URL(uri,base).href:'';continue;}
if(line[0]!=='#'&&!variants.length)segment={url:new URL(line,base).href,init:map,encrypted};}
if(variants.length){variants.sort((a,b)=>a.bandwidth-b.bandwidth);const sized=variants.filter(v=>v.height).sort((a,b)=>a.height-b.height);return {variant:(sized.length?sized.find(v=>v.height>=360)||sized[sized.length-1]:variants[0]).url};}
if(!segment)throw new Error('Playlist has no segments');if(segment.encrypted)throw new Error('Encrypted segments are not previewed');return {segment:segment.url,init:segment.init};}
// A frame needs only the start of a segment, so reads stop at the cap instead of failing.
async function readHead(response,max){const chunks=[];let bytes=0;for await(const chunk of response){chunks.push(chunk);bytes+=chunk.length;if(bytes>=max)break;}response.destroy();return Buffer.concat(chunks).subarray(0,max);}
// Every request goes through the relay's upstream boundary, one after another; ffmpeg only ever reads stdin.
async function grabFrame(url,{upstream,decode,signal,maxBytes=3*1024*1024}){
async function fetchHead(target,max){const {response,url:at}=await upstream(target,{},0,signal);if(response.statusCode<200||response.statusCode>=300){response.resume();throw new Error('Source returned HTTP '+response.statusCode);}return {body:await readHead(response,max),url:at};}
for(let hop=0;hop<3;hop++){const first=await fetchHead(url,maxBytes);if(first.body[0]===0x47)return decode(first.body,signal);
const next=pickSegment(first.body.toString('utf8'),first.url);if(next.variant){url=next.variant;continue;}
const init=next.init?(await fetchHead(next.init,1024*1024)).body:Buffer.alloc(0);return decode(Buffer.concat([init,(await fetchHead(next.segment,maxBytes)).body]),signal);}
throw new Error('Too many nested playlists');}
// ffmpeg is optional: AIRWAVE_FFMPEG or ffmpeg on PATH; without it the relay offers no previews.
function findFfmpeg(env=process.env){if(env.AIRWAVE_PREVIEWS==='0')return '';const bin=env.AIRWAVE_FFMPEG||'ffmpeg',probe=spawnSync(bin,['-hide_banner','-version'],{stdio:'ignore',timeout:5000});return probe.status===0?bin:'';}
// Interlaced broadcasts are deinterlaced; the width is fixed and the height follows the display aspect.
function ffmpegDecoder(bin,{width=640,timeout=10000,maxOutput=1024*1024}={}){return (input,signal)=>new Promise((resolve,reject)=>{
const child=spawn(bin,['-hide_banner','-loglevel','error','-protocol_whitelist','pipe','-i','pipe:0','-map','0:v:0','-frames:v','1','-vf','yadif=deint=interlaced,scale='+width+':trunc('+width+'/dar/2)*2,setsar=1','-q:v','4','-f','image2pipe','-c:v','mjpeg','pipe:1'],{stdio:['pipe','pipe','ignore'],timeout,signal});
const out=[];let size=0;child.stdout.on('data',chunk=>{size+=chunk.length;if(size>maxOutput)child.kill();else out.push(chunk);});child.stdin.on('error',()=>{});child.on('error',reject);
child.on('close',code=>{const body=Buffer.concat(out);if(code===0&&body.length&&size<=maxOutput)resolve({type:'image/jpeg',body});else reject(new Error('No frame decoded'));});child.stdin.end(input);});}
function makePreviews({grab,fresh=10*60*1000,failFor=30*60*1000,gap=1000,quiet=15000,maxQueue=24,maxTotal=32*1024*1024,now=Date.now,sleep=ms=>new Promise(r=>setTimeout(r,ms))}){
const cache=new Map(),failed=new Map(),jobs=new Map(),queue=[];let total=0,active=null,running=false,lastPlay=-Infinity,lastGrab=-Infinity;
function store(key,frame){const old=cache.get(key);if(old){cache.delete(key);total-=old.body.length;}cache.set(key,{type:frame.type,body:frame.body,at:now()});total+=frame.body.length;for(const [oldKey,entry] of cache){if(total<=maxTotal)break;cache.delete(oldKey);total-=entry.body.length;}}
function settle(job){if(jobs.get(job.key)===job)jobs.delete(job.key);job.finish(cache.get(job.key)||null);}
// A stale frame beats no frame: it is returned when a new grab fails, is refused, or is abandoned.
function get(key,url,signal){const hit=cache.get(key);if(hit&&now()-hit.at<fresh)return Promise.resolve(hit);if(now()-(failed.get(key)??-Infinity)<failFor)return Promise.resolve(hit||null);
let job=jobs.get(key);if(!job){if(queue.length>=maxQueue)return Promise.resolve(hit||null);job={key,url,waiters:0,controller:null,requeue:false};job.done=new Promise(r=>{job.finish=r;});jobs.set(key,job);queue.push(job);pump();}
job.waiters++;
// The tile left the screen: a queued grab is dropped and a running one stops, freeing the provider connection.
if(signal)signal.addEventListener('abort',()=>{if(--job.waiters>0||jobs.get(key)!==job)return;const i=queue.indexOf(job);if(i>=0)queue.splice(i,1);else if(job.controller)job.controller.abort();settle(job);},{once:true});
return job.done;}
async function pump(){if(running)return;running=true;try{while(queue.length){const wait=Math.max(lastPlay+quiet,lastGrab+gap)-now();if(wait>0){await sleep(wait);continue;}
const job=queue.shift();job.controller=new AbortController();active=job;let frame=null;
try{frame=await grab(job.url,job.controller.signal);if(!frame||frame.type!=='image/jpeg'||!frame.body||!frame.body.length)throw new Error('No frame');}catch(e){frame=null;}
active=null;lastGrab=now();if(jobs.get(job.key)!==job)continue;
if(job.requeue){job.requeue=false;job.controller=null;queue.unshift(job);continue;}
if(frame){failed.delete(job.key);store(job.key,frame);}else if(!job.controller.signal.aborted)failed.set(job.key,now());settle(job);}}finally{running=false;}}
// Called for every playback request the relay serves (local or cast).
function playing(){lastPlay=now();if(active&&!active.requeue){active.requeue=true;active.controller.abort();}}
return {get,playing,size:()=>total,pending:()=>queue.length+(active?1:0)};}
module.exports={pickSegment,grabFrame,readHead,findFfmpeg,ffmpegDecoder,makePreviews};
