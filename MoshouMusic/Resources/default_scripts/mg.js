// 咪咕音乐源脚本占位 - 实际使用时替换为社区脚本
;(function(){var s='mg';lx.send(EVENT_NAMES.inited,{sources:['mg'],qualities:['128k','320k','flac']});lx.on(EVENT_NAMES.request,function(d,c){if(d.source!==s)return;switch(d.action){case 'musicSearch':c(null,{list:[],total:0});break;default:c({message:'Not implemented'},null)}})})();
