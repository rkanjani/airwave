const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {upstream,readLimited,readBytes,pipeMedia}=require('../server/network.cjs'),{makeLibrary,rewriteManifest}=require('../server/library.cjs'),{makeArtwork}=require('../server/artwork.cjs'),{makeCast,castHandler,lanAddress}=require('../server/cast.cjs'),{makePreviews,grabFrame,findFfmpeg,ffmpegDecoder}=require('../server/preview.cjs');
const root=path.resolve(__dirname,'../app'),port=Number(process.env.AIRWAVE_PORT)||4317,host='127.0.0.1:'+port,origin='http://'+host,token=crypto.randomBytes(32).toString('hex');
const ffmpeg=process.env.AIRWAVE_LIBRARY_PATH?findFfmpeg():'';
const library=process.env.AIRWAVE_LIBRARY_PATH?makeLibrary(JSON.parse(fs.readFileSync(process.env.AIRWAVE_LIBRARY_PATH,'utf8')),{previews:!!ffmpeg}):null;
const castAddress=process.env.AIRWAVE_CAST==='1'&&library?process.env.AIRWAVE_CAST_HOST||lanAddress():'',castPort=Number(process.env.AIRWAVE_CAST_PORT)||port+1;
const cast=castAddress?makeCast(library,castAddress+':'+castPort):null;
const artwork=makeArtwork({load:async(url,max)=>{const up=(await upstream(url)).response;if(up.statusCode<200||up.statusCode>=300||Number(up.headers['content-length'])>max){up.destroy();return null;}return {type:String(up.headers['content-type']||'').split(';')[0].trim().toLowerCase(),body:await readBytes(up,max)};}});
const decode=ffmpeg&&ffmpegDecoder(ffmpeg),previews=ffmpeg?makePreviews({grab:(url,signal)=>grabFrame(url,{upstream,decode,signal})}):null;
const types={'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.xml':'application/xml','.webmanifest':'application/manifest+json'};
// Shared by the loopback app and the cast listener; register decides which prefix rewritten playlist entries carry.
async function proxy(req,res,pathname,register){const resource=library.resources.get(pathname);if(!resource){res.writeHead(404);return res.end();}
if(resource.kind==='image'){const art=await artwork.get(pathname,resource.url);if(!art){res.writeHead(404);return res.end();}res.setHeader('Content-Type',art.type);res.setHeader('Cache-Control','private, max-age=86400');return res.end(art.body);}if(previews)previews.playing();const headers={};if(req.headers.range&&/^bytes=\d*-\d*$/.test(req.headers.range))headers.Range=req.headers.range;
try{const result=await upstream(resource.url,headers),up=result.response;res.on('close',()=>up.destroy());
if(up.statusCode<200||up.statusCode>=300){up.resume();res.writeHead(502);return res.end('The stream source is unavailable.');}
if(resource.kind==='hls'||/mpegurl/i.test(up.headers['content-type']||'')){const body=rewriteManifest(await readLimited(up,2*1024*1024),result.url,register);res.setHeader('Content-Type','application/vnd.apple.mpegurl');return res.end(body);}
return pipeMedia(up,res);
}catch(e){if(!res.headersSent){res.writeHead(502);res.end('The source could not be reached.');}else res.destroy();}}
const server=http.createServer(async(req,res)=>{res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');
try{if(req.headers.host!==host){res.writeHead(403);return res.end('Invalid host');}const url=new URL(req.url,origin),pathname=decodeURIComponent(url.pathname),castRequest=/^\/api\/cast(?:\/end)?$/.test(pathname);
if(castRequest?req.method!=='POST':!['GET','HEAD'].includes(req.method)){res.writeHead(405);return res.end();}
if(pathname.startsWith('/api/')){const cookie=(req.headers.cookie||'').split(';').map(x=>x.trim()).includes('airwave_session='+token);const site=req.headers['sec-fetch-site'];if(!cookie||req.headers.origin&&req.headers.origin!==origin||site&&site!=='same-origin'){res.writeHead(403);return res.end('Session required');}
if(!library){res.writeHead(404);return res.end();}if(pathname==='/api/library'){res.setHeader('Content-Type','application/json');return res.end(JSON.stringify(library.snapshot));}
if(castRequest){if(!cast){res.writeHead(503);return res.end();}if(pathname==='/api/cast/end'){cast.revoke();res.writeHead(204);return res.end();}const grant=cast.grant(url.searchParams.get('media'),url.searchParams.get('logo'));res.setHeader('Content-Type','application/json');if(!grant){res.writeHead(404);return res.end('{}');}return res.end(JSON.stringify(grant));}
if(pathname.startsWith('/api/preview/')){const source=previews&&library.previews.get(pathname);if(!source){res.writeHead(404);return res.end();}
// Closing the request (the tile scrolled away) abandons the grab.
const gone=new AbortController();res.on('close',()=>{if(!res.writableEnded)gone.abort();});const frame=await previews.get(pathname,source,gone.signal);if(res.destroyed)return;if(!frame){res.writeHead(404);return res.end();}res.setHeader('Content-Type',frame.type);return res.end(frame.body);}
return proxy(req,res,pathname,library.register);
}
const filename=path.resolve(root,'.'+(pathname==='/'?'/index.html':pathname));if(!filename.startsWith(root+path.sep)){res.writeHead(403);return res.end();}
if(pathname==='/'){res.setHeader('Set-Cookie','airwave_session='+token+'; HttpOnly; SameSite=Strict; Path=/');}
fs.readFile(filename,(e,data)=>{if(e){res.writeHead(404);return res.end('Not found');}res.setHeader('Content-Type',types[path.extname(filename)]||'application/octet-stream');res.end(data);});
}catch(e){if(!res.headersSent){res.writeHead(502);res.end('The source could not be reached.');}else res.destroy();}});
server.listen(port,'127.0.0.1',()=>console.log('Airwave preview: '+origin+' · '+(library?library.snapshot.items.length+' private library entries'+(previews?' · live tile previews via '+ffmpeg:' · live tile previews off (no ffmpeg)'):'demo library')));
if(cast)http.createServer(castHandler(cast,proxy)).listen(castPort,castAddress,()=>console.log('Cast relay: http://'+cast.host+' (local network, token-protected)'));
else if(process.env.AIRWAVE_CAST==='1')console.log(library?'Cast relay off: no local network address. Set AIRWAVE_CAST_HOST.':'Cast relay off: it serves only a private library (AIRWAVE_LIBRARY_PATH).');
