# HTML-/JavaScript-Vorlagen des interaktiven Dashboards (zeichengleich zum R-Paket)

const _HTML_HEAD =
    "<!DOCTYPE html><html lang=\"de\"><head><meta charset=\"utf-8\">\n" *
    "<title>SimLev Dashboard</title><style>\n" *
    "body{font-family:system-ui,Segoe UI,Arial,sans-serif;margin:18px;background:#fafafa;color:#222}\n" *
    "h1{font-size:20px;margin:0 0 2px}.sub{color:#666;font-size:13px;margin-bottom:14px}\n" *
    ".panel{background:#fff;border:1px solid #e3e3e3;border-radius:8px;margin-bottom:14px;padding:10px 12px 4px}\n" *
    ".ptitle{font-weight:600;font-size:14px;margin-bottom:2px}\n" *
    ".legend span{display:inline-block;margin-right:14px;font-size:12px;cursor:pointer;user-select:none}\n" *
    ".legend .off{opacity:.35;text-decoration:line-through}\n" *
    ".legend i{display:inline-block;width:18px;height:3px;margin-right:5px;vertical-align:middle}\n" *
    "svg{display:block;width:100%;height:260px}\n" *
    ".tip{position:fixed;pointer-events:none;background:rgba(20,20,20,.92);color:#fff;\n" *
    "padding:7px 10px;border-radius:6px;font-size:12px;line-height:1.5;display:none;z-index:9;max-width:340px}\n" *
    ".tip b{color:#9cf}.axis{font-size:10px;fill:#777}\n" *
    "</style></head><body>\n" *
    "<h1>SimLev &ndash; Interaktives Dashboard</h1>\n" *
    "<div class=\"sub\">"

const _HTML_SUB =
    " &middot; Hover f&uuml;r Details, Legende klickbar</div>\n" *
    ""

const _HTML_MID1 =
    "\n" *
    "<div class=\"tip\" id=\"tip\"></div>\n" *
    "<script>\n" *
    "\"use strict\";\n" *
    "var DATES="

const _HTML_SCRIPT =
    ";\n" *
    "var N=DATES.length, tip=document.getElementById(\"tip\"), PANELS=[];\n" *
    "function fmt(v,u){return v==null?\"&ndash;\":(Math.abs(v)>=1000?v.toLocaleString(\"de-DE\",{maximumFractionDigits:0}):v.toLocaleString(\"de-DE\",{maximumFractionDigits:2}))+u}\n" *
    "function makePanel(id,title,series,unit,fillFirst){\n" *
    " var host=document.getElementById(id); if(!host)return;\n" *
    " host.innerHTML='<div class=\"ptitle\">'+title+'</div><div class=\"legend\"></div>';\n" *
    " var leg=host.querySelector(\".legend\");\n" *
    " var svg=document.createElementNS(\"http://www.w3.org/2000/svg\",\"svg\");\n" *
    " host.appendChild(svg);\n" *
    " var P={id:id,series:series,unit:unit,fillFirst:fillFirst,svg:svg,on:series.map(function(){return true})};\n" *
    " series.forEach(function(s,i){\n" *
    "   var el=document.createElement(\"span\");\n" *
    "   el.innerHTML='<i style=\"background:'+s.col+'\"></i>'+s.name;\n" *
    "   el.onclick=function(){P.on[i]=!P.on[i];el.classList.toggle(\"off\");draw(P)};\n" *
    "   leg.appendChild(el);\n" *
    " });\n" *
    " PANELS.push(P); draw(P);\n" *
    " svg.addEventListener(\"mousemove\",function(e){hover(e,P)});\n" *
    " svg.addEventListener(\"mouseleave\",function(){tip.style.display=\"none\";\n" *
    "   PANELS.forEach(function(q){var c=q.svg.querySelector(\".xh\");if(c)c.setAttribute(\"opacity\",0)})});\n" *
    "}\n" *
    "function extent(P){var lo=Infinity,hi=-Infinity;\n" *
    " P.series.forEach(function(s,i){if(!P.on[i])return;\n" *
    "  for(var k=0;k<N;k++){var v=s.v[k];if(v==null)continue;if(v<lo)lo=v;if(v>hi)hi=v}});\n" *
    " if(lo===Infinity){lo=0;hi=1} if(lo===hi){hi=lo+1} return [lo,hi];}\n" *
    "function draw(P){\n" *
    " var W=P.svg.clientWidth||900,H=260,L=62,R=12,T=10,B=24;\n" *
    " P.geo={W:W,H:H,L:L,R:R,T:T,B:B};\n" *
    " var ex=extent(P),lo=ex[0],hi=ex[1],pad=(hi-lo)*0.05;lo-=pad;hi+=pad;\n" *
    " P.lo=lo;P.hi=hi;\n" *
    " function X(k){return L+(W-L-R)*k/(N-1)} function Y(v){return T+(H-T-B)*(1-(v-lo)/(hi-lo))}\n" *
    " P.X=X;P.Y=Y;\n" *
    " var g='<line class=\"xh\" x1=\"0\" x2=\"0\" y1=\"'+T+'\" y2=\"'+(H-B)+'\" stroke=\"#999\" stroke-dasharray=\"3,3\" opacity=\"0\"/>';\n" *
    " for(var t=0;t<=4;t++){var v=lo+(hi-lo)*t/4,y=Y(v);\n" *
    "   g+='<line x1=\"'+L+'\" x2=\"'+(W-R)+'\" y1=\"'+y+'\" y2=\"'+y+'\" stroke=\"#eee\"/>'+\n" *
    "      '<text class=\"axis\" x=\"'+(L-6)+'\" y=\"'+(y+3)+'\" text-anchor=\"end\">'+fmt(v,\"\")+'</text>'}\n" *
    " for(var q=0;q<=5;q++){var k=Math.round((N-1)*q/5);\n" *
    "   g+='<text class=\"axis\" x=\"'+X(k)+'\" y=\"'+(H-8)+'\" text-anchor=\"middle\">'+DATES[k].slice(0,7)+'</text>'}\n" *
    " P.series.forEach(function(s,i){if(!P.on[i])return;\n" *
    "  var dstr=\"\",first=true;\n" *
    "  for(var k=0;k<N;k++){var v=s.v[k];if(v==null){first=true;continue}\n" *
    "    dstr+=(first?\"M\":\"L\")+X(k).toFixed(1)+\" \"+Y(v).toFixed(1);first=false}\n" *
    "  if(P.fillFirst&&i===0){\n" *
    "    var area=dstr+\"L\"+X(N-1).toFixed(1)+\" \"+Y(Math.min(0,P.hi)).toFixed(1)+\n" *
    "             \"L\"+X(0).toFixed(1)+\" \"+Y(Math.min(0,P.hi)).toFixed(1)+\"Z\";\n" *
    "    g+='<path d=\"'+area+'\" fill=\"'+s.col+'\" opacity=\"0.18\"/>'}\n" *
    "  g+='<path d=\"'+dstr+'\" fill=\"none\" stroke=\"'+s.col+'\" stroke-width=\"'+s.w+'\"'+\n" *
    "     (s.dash?' stroke-dasharray=\"5,4\"':\"\")+'/>'});\n" *
    " P.svg.setAttribute(\"viewBox\",\"0 0 \"+W+\" \"+H);\n" *
    " P.svg.innerHTML=g;\n" *
    "}\n" *
    "function hover(e,src){\n" *
    " var r=src.svg.getBoundingClientRect(),g=src.geo;\n" *
    " var frac=(e.clientX-r.left-g.L)/(r.width-g.L-g.R);\n" *
    " var k=Math.max(0,Math.min(N-1,Math.round(frac*(N-1))));\n" *
    " PANELS.forEach(function(P){\n" *
    "   var gg=P.geo,x=P.X(k),c=P.svg.querySelector(\".xh\");\n" *
    "   if(c){c.setAttribute(\"x1\",x);c.setAttribute(\"x2\",x);c.setAttribute(\"opacity\",1)}});\n" *
    " var h=\"<b>\"+DATES[k]+\"</b>\"+(FILLED[k]?\" (aufgef&uuml;llt)\":\"\");\n" *
    " PANELS.forEach(function(P){\n" *
    "   P.series.forEach(function(s,i){if(!P.on[i])return;\n" *
    "     h+='<br><i style=\"display:inline-block;width:10px;height:10px;border-radius:2px;background:'+\n" *
    "        s.col+';margin-right:5px\"></i>'+s.name+\": <b>\"+fmt(s.v[k],P.unit)+\"</b>\"})});\n" *
    " tip.innerHTML=h;tip.style.display=\"block\";\n" *
    " tip.style.left=Math.min(e.clientX+16,window.innerWidth-360)+\"px\";\n" *
    " tip.style.top=(e.clientY+14)+\"px\";\n" *
    "}\n" *
    ""

const _HTML_TAIL =
    "\n" *
    "window.addEventListener(\"resize\",function(){PANELS.forEach(draw)});\n" *
    "</script></body></html>"
