const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {upstream,readLimited}=require('../server/network.cjs'),{makeLibrary,rewriteManifest}=require('../server/library.cjs');
const root=path.resolve(__dirname,'../app'),port=Number(process.env.AIRWAVE_PORT)||4317,host='127.0.0.1:'+port,origin='http://'+host,token=crypto.randomBytes(32).toString('hex');
const library=process.env.AIRWAVE_LIBRARY_PATH?makeLibrary(JSON.parse(fs.readFileSync(process.env.AIRWAVE_LIBRARY_PATH,'utf8'))):null;
const types={'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.xml':'application/xml','.webmanifest':'application/manifest+json'};
const server=http.createServer(async(req,res)=>{res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');
try{if(req.headers.host!==host){res.writeHead(403);return res.end('Invalid host');}if(!['GET','HEAD'].includes(req.method)){res.writeHead(405);return res.end();}const pathname=decodeURIComponent(new URL(req.url,origin).pathname);
if(pathname.startsWith('/api/')){const cookie=(req.headers.cookie||'').split(';').map(x=>x.trim()).includes('airwave_session='+token);const site=req.headers['sec-fetch-site'];if(!cookie||req.headers.origin&&req.headers.origin!==origin||site&&site!=='same-origin'){res.writeHead(403);return res.end('Session required');}
if(!library){res.writeHead(404);return res.end();}if(pathname==='/api/library'){res.setHeader('Content-Type','application/json');return res.end(JSON.stringify(library.snapshot));}
const resource=library.resources.get(pathname);if(!resource){res.writeHead(404);return res.end();}const headers={};if(req.headers.range&&/^bytes=\d*-\d*$/.test(req.headers.range))headers.Range=req.headers.range;
const result=await upstream(resource.url,headers),up=result.response;res.on('close',()=>up.destroy());
if(up.statusCode<200||up.statusCode>=300){up.resume();res.writeHead(502);return res.end('The stream source is unavailable.');}
if(resource.kind==='hls'||/mpegurl/i.test(up.headers['content-type']||'')){const body=rewriteManifest(await readLimited(up,2*1024*1024),result.url,library.register);res.setHeader('Content-Type','application/vnd.apple.mpegurl');return res.end(body);}
if(resource.kind==='image'&&!/^image\//.test(up.headers['content-type']||'')){up.destroy();res.writeHead(415);return res.end();}
res.statusCode=up.statusCode;for(const h of ['content-type','content-length','content-range','accept-ranges'])if(up.headers[h])res.setHeader(h,up.headers[h]);up.on('error',()=>res.destroy());return up.pipe(res);
}
const filename=path.resolve(root,'.'+(pathname==='/'?'/index.html':pathname));if(!filename.startsWith(root+path.sep)){res.writeHead(403);return res.end();}
if(pathname==='/'){res.setHeader('Set-Cookie','airwave_session='+token+'; HttpOnly; SameSite=Strict; Path=/');}
fs.readFile(filename,(e,data)=>{if(e){res.writeHead(404);return res.end('Not found');}res.setHeader('Content-Type',types[path.extname(filename)]||'application/octet-stream');res.end(data);});
}catch(e){if(!res.headersSent){res.writeHead(502);res.end('The source could not be reached.');}else res.destroy();}});
server.listen(port,'127.0.0.1',()=>console.log('Airwave preview: '+origin+' · '+(library?library.snapshot.items.length+' private library entries':'demo library')));
