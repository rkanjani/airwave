(function(root,factory){var api=factory();if(typeof module==='object')module.exports=api;else root.AirwaveCore=api;})(this,function(){
  'use strict';
  function httpUrl(value,base){if(!value||!String(value).trim())return '';try{var u=new URL(value,base);return /^(https?:)$/.test(u.protocol)?u.href:'';}catch(e){return '';}}
  function hash(s){var h=2166136261;for(var i=0;i<s.length;i++){h^=s.charCodeAt(i);h=Math.imul(h,16777619);}return (h>>>0).toString(36);}
  function parseM3U(text,base){
    if(text.length>5*1024*1024)throw new Error('Playlist is too large. Use a playlist smaller than 5 MB.');
    if(!/^\s*#EXTM3U/m.test(text))throw new Error('This is not an M3U playlist. It should start with #EXTM3U.');
    var entries=[],pending=null,seen=new Set();
    text.replace(/^\uFEFF/,'').split(/\r?\n/).forEach(function(raw){
      var line=raw.trim();if(!line)return;
      if(line.indexOf('#EXTINF:')===0){
        var quoted=false,comma=-1;for(var i=8;i<line.length;i++){if(line[i]==='"')quoted=!quoted;if(line[i]===','&&!quoted){comma=i;break;}}
        var attrs={};line.slice(0,comma<0?line.length:comma).replace(/([\w-]+)="([^"]*)"/g,function(_,k,v){attrs[k.toLowerCase()]=v;return _;});
        pending={name:comma<0?'Untitled channel':line.slice(comma+1).trim(),group:attrs['group-title']||'Unsorted',epgId:attrs['tvg-id']||'',logo:httpUrl(attrs['tvg-logo']||'',base),duration:parseFloat(line.slice(8)),attrs:attrs};return;
      }
      if(line[0]==='#')return;
      var url=httpUrl(line,base);if(!url||seen.has(url)){pending=null;return;}seen.add(url);
      var p=pending||{name:'Channel '+(entries.length+1),group:'Unsorted',epgId:'',logo:'',duration:-1,attrs:{}};
      var movie=p.duration>0||/\.(mp4|mkv|mov|webm)(\?|$)/i.test(url)||/movie|film|vod/i.test(p.group);
      entries.push({id:hash(url),url:url,name:p.name||'Untitled channel',group:p.group,epgId:p.epgId,logo:p.logo,kind:movie?'movie':'live',color:entries.length%6});pending=null;
    });
    if(!entries.length)throw new Error('No HTTP or HTTPS streams found in this playlist.');
    if(entries.length>10000)throw new Error('This library has over 10,000 entries. Import a smaller playlist.');
    return entries;
  }
  function xmlTime(value){var m=/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?(?:\s*([+-])(\d{2})(\d{2}))?$/.exec((value||'').trim());if(!m)return NaN;var ms=Date.UTC(+m[1],+m[2]-1,+m[3],+m[4],+m[5],+(m[6]||0));var offset=m[7]?(+m[8]*60 + +m[9])*60000*(m[7]==='+'?1:-1):0;return ms-offset;}
  function parseXMLTV(text,Parser){
    if(text.length>10*1024*1024)throw new Error('Guide is too large. Use XMLTV smaller than 10 MB.');
    if(/<!DOCTYPE|<!ENTITY/i.test(text))throw new Error('XML document declarations are not supported.');
    var doc=new Parser().parseFromString(text,'application/xml');if(doc.querySelector('parsererror')||!doc.querySelector('tv'))throw new Error('This is not a valid XMLTV guide.');
    var programs=Object.create(null);Array.prototype.forEach.call(doc.querySelectorAll('programme'),function(p){var channel=p.getAttribute('channel'),start=xmlTime(p.getAttribute('start')),end=xmlTime(p.getAttribute('stop'));if(!channel||!isFinite(start)||!isFinite(end)||end<=start)return;var title=p.querySelector('title'),desc=p.querySelector('desc'),icon=p.querySelector('icon');if(!programs[channel])programs[channel]=[];programs[channel].push({start:start,end:end,title:title?title.textContent:'Untitled',description:desc?desc.textContent:'',icon:icon?httpUrl(icon.getAttribute('src')):''});});
    Object.keys(programs).forEach(function(k){programs[k].sort(function(a,b){return a.start-b.start;});});
    if(!Object.keys(programs).length)throw new Error('No programmes with valid start and stop times were found.');return programs;
  }
  function currentProgram(programs,id,now){return (programs[id]||[]).find(function(p){return p.start<=now&&p.end>now;})||null;}
  function progress(program,now){return program?Math.max(0,Math.min(100,(now-program.start)/(program.end-program.start)*100)):0;}
  function filter(items,query,group,kind){query=(query||'').trim().toLocaleLowerCase();return items.filter(function(x){return (!kind||x.kind===kind)&&(!group||group==='All'||x.group===group)&&(!query||(x.name+' '+x.group).toLocaleLowerCase().indexOf(query)>=0);});}
  // Playlist names carry provider decoration: region prefixes, divider runs, styled Unicode letters and quality tags.
  // Tidying returns the readable name, the quality and stream tags it removed for badges, and the feed notes (RAW, frame
  // rate) it dropped without a badge.
  var QUALITY=[['8K',/^(8k|4320p)$/i],['4K',/^(4k|uhd|2160p)$/i],['FHD',/^(fhd|1080[pi])$/i],['HD',/^(hd|720p)$/i],['SD',/^(sd|480[pi]|576[pi])$/i]];
  var ACRONYMS=/^(A&E|ABC|ACC|AMC|AXN|BBC|BEIN|BET|CBC|CNN|CTV|C-SPAN|DAZN|ESPN|ESPNU|EU|HBO|IFC|ION|ITV|MASN|NASA|NBA|NESN|NFL|OAN|OWN|RAI|RTE|SEC|TUDN|TV|UFC|UK|US|USA|WWE|YES)$/;
  var SMALL=/^(an|and|at|de|del|el|et|for|in|la|le|of|on|the|to|y)$/i;
  function words(s){return String(s||'').normalize('NFKC').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);}
  function shouting(s){var letters=s.replace(/[^A-Za-z]/g,'');return letters.length>=4&&letters===letters.toUpperCase();}
  function smartCase(s){
    var tokens=s.split(' '),last=tokens.length-1;return tokens.map(function(token,i){
      if(ACRONYMS.test(token.replace(/[^A-Za-z&-]/g,''))||/\d/.test(token)||/^(I{2,3}|IV|VI{1,3}|IX)$/.test(token))return token;
      return token.split('-').map(function(part){var bare=part.replace(/[^A-Za-z]/g,'');if(bare.length<2&&!(i&&i<last&&SMALL.test(bare)))return part;if(ACRONYMS.test(bare)||!/[AEIOUY]/.test(bare))return part;if(i&&i<last&&SMALL.test(bare))return part.toLowerCase();return part.charAt(0)+part.slice(1).toLowerCase();}).join('-');
    }).join(' ');
  }
  function tidyName(raw,context){
    context=context||{};var original=String(raw==null?'':raw).trim(),s=original.replace(/([^\s\u02B0-\u02FF\u1D2C-\u1D6A\u1D9B-\u1DBF\u2070-\u209F])([\u02B0-\u02FF\u1D2C-\u1D6A\u1D9B-\u1DBF\u2070-\u209F]+)/g,'$1 $2').normalize('NFKC'),region='',quality='',tags=[],notes=[];
    function addQuality(token){for(var i=0;i<QUALITY.length;i++)if(QUALITY[i][1].test(token)){if(!quality||i<QUALITY.findIndex(function(q){return q[0]===quality;}))quality=QUALITY[i][0];return true;}return false;}
    function addTag(tag,list){list=list||tags;if(list.indexOf(tag)<0)list.push(tag);}
    s=s.replace(/[\p{So}\p{Cf}]/gu,' ').replace(/^[\s#=*~_.•·-]+|[\s#=*~_•·-]+$/g,'');var dropped='';
    // A short code before a pipe or in leading brackets is a region or provider label; a word before a colon is only
    // dropped when the group already names it, or when it is a region code on a live channel, so titles such as "CSI: Miami" keep their prefix.
    var prefix=/^[\[(]?\s*([^|:\[\]()]{1,12}?)\s*(?:[\])]\s*[|:-]?|\|)\s*/.exec(s);
    if(prefix&&prefix[0].length<s.length&&(prefix[0].indexOf('|')>=0||/^[\[(]/.test(prefix[0]))){if(/^[A-Z]{2,3}$/.test(prefix[1]))region=prefix[1];else addQuality(prefix[1]);s=s.slice(prefix[0].length);}
    var lead=/^([^:]{2,24}):\s+/.exec(s),groupWords=words(context.group);
    if(lead&&context.kind==='live'&&/^[A-Z]{2,3}$/.test(lead[1])){region=region||lead[1];dropped=lead[1];s=s.slice(lead[0].length);}
    else if(lead&&words(lead[1]).length&&words(lead[1]).every(function(w){return groupWords.indexOf(w)>=0;})){dropped=lead[1];s=s.slice(lead[0].length);}
    // Resolution tags count anywhere; looser words (HD, RAW, fps) only after the first word, so "Raw Deal" stays whole.
    var parts=s.split(/\s+/),kept=[];
    for(var i=0;i<parts.length;i++){
      var part=parts[i],token=part.replace(/^[\[(]+|[\])]+$/g,''),first=!kept.length,fps=/^(\d{2,3})$/.test(token)&&/^fps$/i.test(parts[i+1]||'')?token:(/^(\d{2,3})fps$/i.exec(token)||[])[1];
      if(fps&&!first){addTag(fps+' FPS',notes);if(/^\d+$/.test(token))i++;continue;}
      if(/^(8k|4k|uhd|2160p|4320p|1080[pi]|720p|576[pi]|480[pi])$/i.test(token)&&addQuality(token))continue;
      if(!first&&addQuality(token))continue;
      if(!first&&/^(hdr|hdr10\+?)$/i.test(token)){addTag('HDR');continue;}
      if(!first&&/^(hevc|h\.?265|x265)$/i.test(token)){addTag('HEVC');continue;}
      if(!first&&/^raw$/i.test(token)){addTag('RAW',notes);continue;}
      kept.push(part);
    }
    s=kept.join(' ').replace(/[\[(]\s*[\])]/g,'').replace(/\s{2,}/g,' ').replace(/^[\s|:#=*~_.,•·–—-]+|[\s|:#=*~_,•·–—-]+$/g,'');
    if(!/[\p{L}\p{N}]/u.test(s))return {name:original,region:region,quality:quality,tags:tags,notes:notes};
    // Capitals are judged on the words that remain plus a dropped prefix, so "SLING: 123 GO!" reads as shouting.
    return {name:shouting(dropped+' '+s)?smartCase(s):s,region:region,quality:quality,tags:tags,notes:notes};
  }
  // Groups keep their region ("US · Sling"). Groups that would read the same keep their tags and notes, then their raw name.
  function tidyGroups(groups){
    var tidy=groups.map(function(g){var t=tidyName(g);return {raw:g,t:t,label:(t.region?t.region+' · ':'')+t.name};}),out=Object.create(null);
    function counts(){var c=Object.create(null);tidy.forEach(function(x){c[x.label]=(c[x.label]||0)+1;});return c;}
    var c=counts();tidy.forEach(function(x){if(c[x.label]>1){var extra=[x.t.quality].concat(x.t.tags,x.t.notes).filter(Boolean);if(extra.length)x.label+=' · '+extra.join(' ');}});
    c=counts();tidy.forEach(function(x){out[x.raw]=c[x.label]>1?x.raw:x.label;});return out;
  }
  function clock(seconds){seconds=Math.max(0,Math.floor(seconds||0));var h=Math.floor(seconds/3600),m=Math.floor(seconds%3600/60),s=String(seconds%60).padStart(2,'0');return h?h+':'+String(m).padStart(2,'0')+':'+s:m+':'+s;}
  return {httpUrl:httpUrl,hash:hash,parseM3U:parseM3U,xmlTime:xmlTime,parseXMLTV:parseXMLTV,currentProgram:currentProgram,progress:progress,filter:filter,tidyName:tidyName,tidyGroups:tidyGroups,clock:clock};
});
