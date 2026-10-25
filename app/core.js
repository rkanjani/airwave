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
  // Provider playlists decorate names with separator hashes, superscript tags and shared prefixes ("NF - ", "SLING: ").
  var SUP='ᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻ⁰¹²³⁴⁵⁶⁷⁸⁹',PLAIN='ABDEGHIJKLMNOPRTUVWabcdefghijklmnoprstuvwxyz0123456789';
  var QUALITY=/^(?:SD|HD|FHD|UHD|[48]K|HDR|HEVC|H\.?26[45]|RAW|\d{2,3}\s?FPS)$/i;
  function badge(token){token=token.replace(/\s+/g,'');var fps=/^(\d+)fps$/i.exec(token);if(fps)return fps[1]+' fps';if(/^(?:raw)$/i.test(token))return 'Raw';return token.toUpperCase();}
  function leadTag(name){var m=/^\s*([A-Za-z0-9]{2,6})\s*(?::|\||\s-\s)\s*\S/.exec(name||'');return m?m[1].toUpperCase():'';}
  // A lead tag counts as a prefix when it starts at least three names and half of its group.
  function commonTags(items){var counts=Object.create(null),sizes=Object.create(null),tags=new Set();items.forEach(function(x){var g=x.group||'',t=leadTag(x.name);sizes[g]=(sizes[g]||0)+1;if(t){var k=g+'\n'+t;counts[k]=(counts[k]||0)+1;}});Object.keys(counts).forEach(function(k){var g=k.slice(0,k.lastIndexOf('\n'));if(counts[k]>=3&&counts[k]*2>=sizes[g])tags.add(k.slice(k.lastIndexOf('\n')+1));});return tags;}
  function cleanName(name,tags){var raw=String(name||'').trim(),badges=[],year='';
    var text=raw.replace(/[ᴬ-ᵂᵃ-ᶻʰʲʳˡˢˣʷʸⁱⁿ⁰¹²³⁴-⁹ⱽ][ᴬ-ᵂᵃ-ᶻʰʲʳˡˢˣʷʸⁱⁿ⁰¹²³⁴-⁹ⱽ\s]*/g,function(run){run.trim().split(/\s+/).forEach(function(t){var plain=t.split('').map(function(c){var i=SUP.indexOf(c);return i<0?c:PLAIN[i];}).join('');if(plain)badges.push(badge(plain));});return ' ';});
    text=text.replace(/^[\s#=*~|\-–—•]+|[\s#=*~|\-–—•]+$/g,'');
    var t=leadTag(text);if(t&&tags&&tags.has(t))text=text.replace(/^\s*[A-Za-z0-9]{2,6}\s*(?::|\||\s-\s)\s*/,'');
    text=text.replace(/\s*[([](?:19|20)\d{2}[)\]]\s*$/,function(m){year=m.replace(/\D/g,'');return '';});
    var words=text.trim().split(/\s+/),tail=[];while(words.length>1&&QUALITY.test(words[words.length-1].replace(/[[\]()]/g,'')))tail.unshift(badge(words.pop().replace(/[[\]()]/g,'')));if(tail.length){text=words.join(' ');badges=badges.concat(tail);}
    text=text.replace(/\s+/g,' ').trim();return {title:text||raw||'Untitled',year:year,badges:badges.filter(function(b,i){return badges.indexOf(b)===i;})};}
  function groupLabel(group){return cleanName(group).title.replace(/\s*\|\s*/g,' · ');}
  function clock(seconds){seconds=Math.max(0,Math.floor(seconds||0));var h=Math.floor(seconds/3600),m=Math.floor(seconds%3600/60),s=String(seconds%60).padStart(2,'0');return h?h+':'+String(m).padStart(2,'0')+':'+s:m+':'+s;}
  return {httpUrl:httpUrl,hash:hash,parseM3U:parseM3U,xmlTime:xmlTime,parseXMLTV:parseXMLTV,currentProgram:currentProgram,progress:progress,filter:filter,clock:clock,commonTags:commonTags,cleanName:cleanName,groupLabel:groupLabel};
});
