document.querySelector('.bar h1').textContent='Processing · full-screen overlay';
document.title='Processing · proposal';
// Keep tool contents in place during work, rather than replacing them with notices.
const normalBackgroundPanel=PANELS.background;
PANELS.background=s=>normalBackgroundPanel({...s,bg:{...s.bg,op:undefined}});
const processingCases=[
 ['opening','1 · Opening a photo',{type:'loading',s:{photo:'lake',auto:'off'}}],
 ['auto','2 · Auto enhancement',{type:'developing',s:{photo:'lake',auto:'off'}}],
 ['subject','3 · Finding the subject',ED('background','woman',{auto:'off',photoProgress:'Processing',bg:{mode:'change',op:'working'}})],
 ['depth','4 · Calculating background blur',ED('background','woman',{auto:'off',photoProgress:'Processing',bg:{mode:'focus',blur:35,op:'working'}})],
 ['erase','5 · Eraser',specFor('busy')],
 ['save','6 · Saving a copy',ED('develop','lake',{...EDITED,photoProgress:'Processing'})]
];
// Opening and Auto retain the existing loading-stage geometry; only the progress UI changes.
// Reference screen types are loading/developing (handled explicitly here to avoid ambiguous dispatch).
const originalScreen=screen;
// One scrim covers the entire app, with no separate fading of controls or photo-level spinner.
progressCard=()=>'';
screen=(spec,d)=>{
 const body=spec.type==='loading'||spec.type==='developing'?loadingScreen(spec.s,d,spec.type):originalScreen(spec,d);
 return `<div inert style="position:absolute;inset:0">${body}</div><div role="status" aria-label="Processing" style="position:absolute;inset:0;z-index:100;background:rgba(0,0,0,.48);display:grid;place-items:center;pointer-events:auto"><span style="box-sizing:border-box;width:34px;height:34px;border-radius:50%;border:3px solid rgba(255,255,255,.28);border-top-color:#fff;animation:l2spin .8s linear infinite"></span></div>`;
};
J.splice(0,J.length,...processingCases.map(([id,label,spec])=>[label,[[id,'The whole app is dimmed. One centred spinner; no message or Cancel button.',spec]]]));
const selectedCase=processingCases.find(([id])=>id===captureState);
if(selectedCase){state.zoom=1;J.splice(0,J.length,['',[[selectedCase[0],'',selectedCase[2]]]]);const css=document.createElement('style');css.textContent='.bar,h2.j,figcaption{display:none!important}main{padding:0!important}.row{margin:0!important;gap:28px!important;flex-wrap:nowrap!important}figure{gap:0!important}';document.head.append(css);}
