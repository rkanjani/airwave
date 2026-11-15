(function(root,factory){var api=factory();if(typeof module==='object')module.exports=api;else root.AirwaveSports=api;})(this,function(){
  'use strict';
  // Leagues the Settings toggles offer; soccer and cricket list the home side first, the other sports the visitors. Scores come from ESPN's public scoreboard feed, fetched only while a league is on.
  // ESPN files international cricket under a new series for every tour, so that toggle reads ESPN's all-cricket feed and keeps only Tests, ODIs and T20Is.
  var LEAGUES=[{id:'nfl',name:'NFL',path:'football/nfl'},{id:'nba',name:'NBA',path:'basketball/nba'},{id:'mlb',name:'MLB',path:'baseball/mlb'},{id:'nhl',name:'NHL',path:'hockey/nhl'},{id:'wnba',name:'WNBA',path:'basketball/wnba'},{id:'mls',name:'MLS',path:'soccer/usa.1'},{id:'cfb',name:'College football',path:'football/college-football'},{id:'cbb',name:'College basketball',path:'basketball/mens-college-basketball'},{id:'epl',name:'Premier League',path:'soccer/eng.1'},{id:'ucl',name:'Champions League',path:'soccer/uefa.champions'},{id:'cricket',name:'International cricket',path:'cricket',feed:'https://site.web.api.espn.com/apis/v2/scoreboard/header?sport=cricket',international:true},{id:'ipl',name:'IPL',path:'cricket/8048'},{id:'bbl',name:'Big Bash League',path:'cricket/8044'}];
  function league(id){return LEAGUES.find(function(l){return l.id===id;})||null;}
  function scoreboardUrl(id){var l=league(id);return !l?'':l.feed||'https://site.api.espn.com/apis/site/v2/sports/'+l.path+'/scoreboard';}
  function isCricket(l){return l.path.split('/')[0]==='cricket';}
  function httpsUrl(value){try{var u=new URL(value);return u.protocol==='https:'?u.href:'';}catch(e){return '';}}
  function text(v){return typeof v==='string'?v.trim():'';}
  // A cricket score reads "156/8 (20 ov, target 153)", or "339 & 120/3" in a Test; the tile keeps the runs and wickets.
  function cricketScore(s){s=s.split('(')[0].trim();return /^\d{1,3}(\/\d{1,2})?d?( & \d{1,3}(\/\d{1,2})?d?)?$/.test(s)?s:'';}
  // The all-cricket feed puts team fields on the competitor itself and sends winner as a string. Cricket abbreviations ("SS-W") are cryptic, so its tiles use full names.
  function side(c,cricket){var t=c&&(c.team||c)||{},score=text(c&&c.score);return {name:text(t.displayName)||text(t.name)||'TBD',short:(cricket?'':text(t.shortDisplayName))||text(t.displayName)||text(t.abbreviation)||'TBD',nickname:text(t.name),abbr:text(t.abbreviation),logo:httpsUrl(t.logo||''),score:cricket?cricketScore(score):/^\d{1,3}$/.test(score)?score:'',winner:!!c&&(c.winner===true||c.winner==='true')};}
  function feedEvents(data){if(data&&Array.isArray(data.events))return data.events;var out=[];(data&&Array.isArray(data.sports)?data.sports:[]).forEach(function(s){(s&&Array.isArray(s.leagues)?s.leagues:[]).forEach(function(l){if(l&&Array.isArray(l.events))out=out.concat(l.events);});});return out;}
  // Keeps only what the tiles and channel matching need; malformed events are skipped rather than shown half-empty.
  function parseScoreboard(data,id){
    var l=league(id);if(!l)return [];var cricket=isCricket(l),events=feedEvents(data);
    if(l.international)events=events.filter(function(e){var cls=e&&(e.class||Array.isArray(e.competitions)&&e.competitions[0]&&e.competitions[0].class)||{};return /^[1-9]\d*$/.test(String(cls.internationalClassId));});
    return events.slice(0,100).map(function(e){
      var comp=e&&(Array.isArray(e.competitions)?e.competitions[0]:Array.isArray(e.competitors)&&e),cs=comp&&Array.isArray(comp.competitors)?comp.competitors:[],status=e&&(e.status&&e.status.type||e.fullStatus&&e.fullStatus.type)||{},start=Date.parse(e&&e.date);
      var home=cs.find(function(c){return c&&c.homeAway==='home';}),away=cs.find(function(c){return c&&c.homeAway==='away';});
      if(!e||!e.id||!home||!away||!isFinite(start)||['pre','in','post'].indexOf(status.state)<0)return null;
      // Cricket says "Stumps" or "Lunch" mid-match and gives a one-line result ("Renegades won by 2 wkts"), kept as a note once play starts.
      var detail=text(status.shortDetail)||text(status.detail)||'',note='';
      if(cricket){var d=text(status.description);detail=status.state==='post'&&/^result$/i.test(d)?'Final':d||detail;if(status.state!=='pre')note=(text(e.status&&e.status.summary)||text(e.fullStatus&&e.fullStatus.summary)).slice(0,80);}
      var cls=e.class||comp.class||{},leagueName=l.international&&text(cls.generalClassCard)||l.name;
      var names=[];(comp.broadcasts||[]).forEach(function(b){(b&&Array.isArray(b.names)?b.names:[]).forEach(function(n){n=text(n);if(n&&names.indexOf(n)<0)names.push(n);});});
      return {id:l.id+':'+e.id,league:l.id,leagueName:leagueName,name:text(e.name)||side(away).name+' at '+side(home).name,state:status.state,scheduled:status.name==='STATUS_SCHEDULED'||cricket&&status.state==='pre',detail:detail,note:note,start:start,home:side(home,cricket),away:side(away,cricket),homeFirst:cricket||l.path.indexOf('soccer/')===0,broadcasts:names.slice(0,4)};
    }).filter(Boolean);
  }
  // Live games first, then the next to start, then the most recently finished.
  function sortGames(games){var rank={in:0,pre:1,post:2};return games.slice().sort(function(a,b){return rank[a.state]-rank[b.state]||(a.state==='post'?b.start-a.start:a.start-b.start)||a.name.localeCompare(b.name);});}
  function norm(s){return ' '+String(s||'').normalize('NFKD').replace(/[̀-ͯ]/g,'').toLowerCase().replace(/[^a-z0-9]+/g,' ').trim()+' ';}
  function teamKeys(t){var keys=[];[t.name,t.short,t.nickname].forEach(function(k){k=norm(k);if(k.trim().length>=3&&keys.indexOf(k)<0)keys.push(k);});return keys;}
  function mentions(haystack,keys){return keys.some(function(k){return haystack.indexOf(k)>=0;});}
  // Basketball playlists often carry a stream per team ("NBA: Harbor City Herons"), which names only one side. A channel
  // counts as a team stream when it names the full team, or a shorter team name plus a basketball word in its name or
  // group, so "Sky Sports" never passes for the Chicago Sky. College nicknames ("Wildcats") are shared, so they never count alone.
  var MARKERS={nba:['nba'],wnba:['wnba'],cbb:['cbb','ncaa','ncaab','ncaam','college basketball']};
  function teamStream(league,t,shown,group){
    if(!MARKERS[league])return false;var full=norm(t.name);if(full.trim().length>=3&&shown.indexOf(full)>=0)return true;
    var marked=MARKERS[league].concat('basketball').map(norm).some(function(m){return (shown+group).indexOf(m)>=0;});
    return marked&&mentions(shown,teamKeys(league==='cbb'?{name:t.name,short:t.short}:t));
  }
  // Ranks live channels for a game: a guide programme naming both teams, then a channel named for both teams (event
  // channels), then, for basketball, a stream named for one of the teams, then a channel named for the broadcaster.
  // Streaming-only broadcasters ("ESPN+") never match a channel.
  function matchChannels(game,channels,programs,options){
    options=options||{};programs=programs||{};var now=options.now||Date.now(),display=options.name||function(x){return x.name;},home=teamKeys(game.home),away=teamKeys(game.away),from=game.start-30*60000,until=Math.max(game.start+5*3600000,now);
    var nets=game.broadcasts.filter(function(n){return !/\+\s*$/.test(n);}).map(norm).filter(function(n){return n.trim().length>=2;}),out=[];
    function both(s){var h=norm(s);return mentions(h,home)&&mentions(h,away);}
    channels.forEach(function(x,index){
      if(x.kind!=='live')return;var score=0,shown=norm(display(x));
      (programs[x.epgId]||[]).forEach(function(p){if(p.end>from&&p.start<until&&both(p.title+' '+(p.description||'')))score=Math.max(score,p.start<=now&&p.end>now?110:100);});
      if(score<90&&(both(x.name)||both(display(x))))score=90;
      if(score<70){var names=norm(x.name)+norm(display(x)),group=norm(x.group);if(teamStream(game.league,game.home,names,group)||teamStream(game.league,game.away,names,group))score=70;}
      if(score<60)nets.forEach(function(n){if(shown===n)score=Math.max(score,60);else if(shown.indexOf(n)===0)score=Math.max(score,30);});
      if(score)out.push({item:x,score:score,index:index});
    });
    return out.sort(function(a,b){return b.score-a.score||a.index-b.index;}).slice(0,5).map(function(m){return {item:m.item,score:m.score};});
  }
  return {LEAGUES:LEAGUES,league:league,scoreboardUrl:scoreboardUrl,parseScoreboard:parseScoreboard,sortGames:sortGames,matchChannels:matchChannels};
});
