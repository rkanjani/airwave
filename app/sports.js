(function(root,factory){var api=factory();if(typeof module==='object')module.exports=api;else root.AirwaveSports=api;})(this,function(){
  'use strict';
  // Leagues the Settings toggles offer; soccer lists the home side first, the other sports the visitors. Scores come from ESPN's public scoreboard feed, fetched only while a league is on.
  var LEAGUES=[{id:'nfl',name:'NFL',path:'football/nfl'},{id:'nba',name:'NBA',path:'basketball/nba'},{id:'mlb',name:'MLB',path:'baseball/mlb'},{id:'nhl',name:'NHL',path:'hockey/nhl'},{id:'wnba',name:'WNBA',path:'basketball/wnba'},{id:'mls',name:'MLS',path:'soccer/usa.1'},{id:'cfb',name:'College football',path:'football/college-football'},{id:'cbb',name:'College basketball',path:'basketball/mens-college-basketball'},{id:'epl',name:'Premier League',path:'soccer/eng.1'},{id:'ucl',name:'Champions League',path:'soccer/uefa.champions'}];
  function league(id){return LEAGUES.find(function(l){return l.id===id;})||null;}
  function scoreboardUrl(id){var l=league(id);return l?'https://site.api.espn.com/apis/site/v2/sports/'+l.path+'/scoreboard':'';}
  function httpsUrl(value){try{var u=new URL(value);return u.protocol==='https:'?u.href:'';}catch(e){return '';}}
  function text(v){return typeof v==='string'?v.trim():'';}
  function side(c){var t=c&&c.team||{},score=text(c&&c.score);return {name:text(t.displayName)||text(t.name)||'TBD',short:text(t.shortDisplayName)||text(t.displayName)||text(t.abbreviation)||'TBD',nickname:text(t.name),abbr:text(t.abbreviation),logo:httpsUrl(t.logo||''),score:/^\d{1,3}$/.test(score)?score:'',winner:c&&c.winner===true};}
  // Keeps only what the tiles and channel matching need; malformed events are skipped rather than shown half-empty.
  function parseScoreboard(data,id){
    var l=league(id),events=data&&Array.isArray(data.events)?data.events:[];if(!l)return [];
    return events.slice(0,100).map(function(e){
      var comp=e&&Array.isArray(e.competitions)&&e.competitions[0],cs=comp&&Array.isArray(comp.competitors)?comp.competitors:[],status=e&&e.status&&e.status.type||{},start=Date.parse(e&&e.date);
      var home=cs.find(function(c){return c&&c.homeAway==='home';}),away=cs.find(function(c){return c&&c.homeAway==='away';});
      if(!e||!e.id||!home||!away||!isFinite(start)||['pre','in','post'].indexOf(status.state)<0)return null;
      var names=[];(comp.broadcasts||[]).forEach(function(b){(b&&Array.isArray(b.names)?b.names:[]).forEach(function(n){n=text(n);if(n&&names.indexOf(n)<0)names.push(n);});});
      return {id:l.id+':'+e.id,league:l.id,leagueName:l.name,name:text(e.name)||side(away).name+' at '+side(home).name,state:status.state,scheduled:status.name==='STATUS_SCHEDULED',detail:text(status.shortDetail)||text(status.detail)||'',start:start,home:side(home),away:side(away),homeFirst:l.path.indexOf('soccer/')===0,broadcasts:names.slice(0,4)};
    }).filter(Boolean);
  }
  // Live games first, then the next to start, then the most recently finished.
  function sortGames(games){var rank={in:0,pre:1,post:2};return games.slice().sort(function(a,b){return rank[a.state]-rank[b.state]||(a.state==='post'?b.start-a.start:a.start-b.start)||a.name.localeCompare(b.name);});}
  function norm(s){return ' '+String(s||'').normalize('NFKD').replace(/[̀-ͯ]/g,'').toLowerCase().replace(/[^a-z0-9]+/g,' ').trim()+' ';}
  function teamKeys(t){var keys=[];[t.name,t.short,t.nickname].forEach(function(k){k=norm(k);if(k.trim().length>=3&&keys.indexOf(k)<0)keys.push(k);});return keys;}
  function mentions(haystack,keys){return keys.some(function(k){return haystack.indexOf(k)>=0;});}
  // Ranks live channels for a game: a guide programme naming both teams, then a channel named for both teams (event
  // channels), then a channel named for the broadcaster. Streaming-only broadcasters ("ESPN+") never match a channel.
  function matchChannels(game,channels,programs,options){
    options=options||{};programs=programs||{};var now=options.now||Date.now(),display=options.name||function(x){return x.name;},home=teamKeys(game.home),away=teamKeys(game.away),from=game.start-30*60000,until=Math.max(game.start+5*3600000,now);
    var nets=game.broadcasts.filter(function(n){return !/\+\s*$/.test(n);}).map(norm).filter(function(n){return n.trim().length>=2;}),out=[];
    function both(s){var h=norm(s);return mentions(h,home)&&mentions(h,away);}
    channels.forEach(function(x,index){
      if(x.kind!=='live')return;var score=0,shown=norm(display(x));
      (programs[x.epgId]||[]).forEach(function(p){if(p.end>from&&p.start<until&&both(p.title+' '+(p.description||'')))score=Math.max(score,p.start<=now&&p.end>now?110:100);});
      if(score<90&&(both(x.name)||both(display(x))))score=90;
      if(score<60)nets.forEach(function(n){if(shown===n)score=Math.max(score,60);else if(shown.indexOf(n)===0)score=Math.max(score,30);});
      if(score)out.push({item:x,score:score,index:index});
    });
    return out.sort(function(a,b){return b.score-a.score||a.index-b.index;}).slice(0,5).map(function(m){return {item:m.item,score:m.score};});
  }
  return {LEAGUES:LEAGUES,league:league,scoreboardUrl:scoreboardUrl,parseScoreboard:parseScoreboard,sortGames:sortGames,matchChannels:matchChannels};
});
