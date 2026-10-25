const crypto=require('node:crypto'),os=require('node:os');
// Opt-in LAN listener for a Cast receiver. It can't send the loopback session cookie, so access is a URL token instead.
// One token is active at a time: each cast rotates it, stopping revokes it, and it expires after 12 hours.
const TTL=12*60*60*1000,mediaPath=/^\/api\/media\/[a-f0-9]{36}\.(?:m3u8|bin|img)$/;
const types={mp4:'video/mp4',m4v:'video/mp4',mov:'video/quicktime',webm:'video/webm',mkv:'video/x-matroska',ts:'video/mp2t',mp3:'audio/mpeg',aac:'audio/aac'};
function lanAddress(interfaces=os.networkInterfaces()){for(const list of Object.values(interfaces))for(const x of list||[])if((x.family==='IPv4'||x.family===4)&&!x.internal)return x.address;return '';}
function contentType(url,kind){if(kind==='hls'||/\.m3u8(?:\?|$)/i.test(url))return 'application/x-mpegurl';const ext=(/\.([a-z0-9]{2,4})$/i.exec(new URL(url).pathname)||[])[1];return types[(ext||'').toLowerCase()]||'video/mp4';}
function makeCast(library,host,now=Date.now){let active=null;
function grant(media,logo){const resource=mediaPath.test(media||'')&&library.resources.get(media);if(!resource||resource.kind==='image')return null;active={token:crypto.randomBytes(24).toString('hex'),expires:now()+TTL};const base='http://'+host+'/cast/'+active.token,image=mediaPath.test(logo||'')&&library.resources.get(logo);return {url:base+media,contentType:contentType(resource.url,resource.kind),logo:image&&image.kind==='image'?base+logo:''};}
function resolve(pathname){const m=/^\/cast\/([a-f0-9]{48})(\/api\/media\/[^/]+)$/.exec(pathname);if(!m||!active||now()>active.expires||!crypto.timingSafeEqual(Buffer.from(m[1]),Buffer.from(active.token))||!mediaPath.test(m[2])||!library.resources.has(m[2]))return null;const prefix='/cast/'+m[1];return {path:m[2],register:(url,kind)=>{const path=library.register(url,kind);return path&&prefix+path;}};}
return {host,grant,resolve,revoke(){active=null;}};}
function castHandler(cast,proxy){return async(req,res)=>{for(const [k,v] of [['Access-Control-Allow-Origin','*'],['Access-Control-Allow-Headers','Range'],['Access-Control-Expose-Headers','Content-Length, Content-Range, Accept-Ranges'],['Cache-Control','no-store'],['X-Content-Type-Options','nosniff'],['Referrer-Policy','no-referrer']])res.setHeader(k,v);
if(req.headers.host!==cast.host){res.writeHead(403);return res.end();}if(req.method==='OPTIONS'){res.setHeader('Access-Control-Allow-Methods','GET, HEAD');res.writeHead(204);return res.end();}if(!['GET','HEAD'].includes(req.method)){res.writeHead(405);return res.end();}
const access=cast.resolve(new URL(req.url,'http://'+cast.host).pathname);if(!access){res.writeHead(404);return res.end();}return proxy(req,res,access.path,access.register);};}
module.exports={makeCast,castHandler,contentType,lanAddress};
