// Loaded into a separate copy of the reference document. The approved source is never edited.
document.querySelector('.bar h1').textContent = 'Eraser · proposal';
document.title = 'Eraser proposal';
iconSection = () => '';
state.device = 'iphone'; state.themes = ['t-dark', 't-light']; state.zoom = 0.4;
const action = (html, name, disabled = false) => html.replace('<button ', `<button data-action="${name}" ${disabled ? 'disabled' : ''} `);
const pair = (a,b) => `<div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">${a}${b}</div>`;
PANELS.edit = s => {
 const step = s.ed.step, busy = step === 'busy';
 const marked = ['selection','failed','busy'].includes(step), done = step === 'done';
 const tab = tabs([['crop','Crop'],['rotate','Rotate'],['straighten','Straighten'],['perspective','Perspective'],['adjust','Adjust'],['remove','Eraser']], 'remove');
 const title = `<div style="display:flex;align-items:center;justify-content:space-between;min-height:36px"><b style="font-size:17px">Eraser</b></div>`;
 let body;
 body = col(step === 'failed' ? 8 : 14,
   (step === 'failed' ? notice('warn',"<span>Couldn't erase. Try again or brush a smaller area.</span>") : note(done ? 'Done. Brush over anything else you want removed.' : 'Brush over what you want removed.')) +
   slider('Brush size',35) +
   pair(action(lineBtn('Undo','undo'),'empty',!marked&&!done),action(lineBtn('Clear'),'empty',!marked)) +
   action(primary(step === 'failed' ? 'Try again' : 'Erase','erase'),'busy',!marked) +
   note('Use two fingers to zoom and move.'));
 return col(6,tab + title + (busy ? `<div style="pointer-events:none">${body}</div>` : body));
};
const states = [
 ['empty','01 · Brush','Brush over what you want gone.'],
 ['selection','02 · Erase','Undo the last brush stroke, Clear all brush marks, or tap Erase.'],
 ['busy','03 · Processing','A spinner over the photo; no processing message or Cancel button.'],
 ['done','04 · Done','The removal is applied immediately. Undo brings it back; brush again to remove something else. Photo is illustrative, not an actual AI result.'],
 ['failed','05 · Try again','Your photo and brush marks are kept if processing fails.']
];
const specFor = step => ED('edit','field',{auto:'off',photoProgress:step==='busy'?'Processing':undefined,canUndo:['selection','failed','done'].includes(step),ed:{sub:'remove',step,strokes:['selection','busy','failed'].includes(step),touched:step==='done',op:undefined}});
J.splice(0,J.length,...states.map(([key,title,desc])=>[title,[[`eraser-${key}`,desc,specFor(key)]]]));
const captureState = new URLSearchParams(parent.location.search).get('capture');
if (states.some(([key]) => key === captureState)) {
 state.zoom = 1;
 J.splice(0,J.length,['',[[`eraser-${captureState}`,'',specFor(captureState)]]]);
 const captureStyle=document.createElement('style');
 captureStyle.textContent='.bar,h2.j,figcaption{display:none!important}main{padding:0!important}.row{margin:0!important;gap:28px!important;flex-wrap:nowrap!important}figure{gap:0!important}';
 document.head.append(captureStyle);
}
// Allow panel scrolling without changing its reference height or moving the photo.
const proposalStyle=document.createElement('style');
proposalStyle.textContent='[data-panel]{overflow-y:auto!important;mask-image:none!important;-webkit-mask-image:none!important}.scr button[data-action]{cursor:pointer}.scr button:disabled{cursor:default;opacity:.4}';
document.head.append(proposalStyle);
// The state-changing buttons are navigable for review; painting/inference are not simulated.
document.addEventListener('click', e=>{
 const button=e.target.closest('[data-action]');if(!button||button.disabled)return;
 const next=button.dataset.action;if(next==='compare')return;
 const figure=button.closest('figure');const theme=figure.classList.contains('t-light')?'t-light':figure.querySelector('.t-light')?'t-light':'t-dark';
 const target=document.getElementById(`eraser-${next}-${theme}`);target?.scrollIntoView({behavior:'smooth',block:'center'});
});

progressCard = () => `<div role="status" aria-label="Processing" style="position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:48px;height:48px;border-radius:50%;background:rgba(14,15,17,.65);display:grid;place-items:center;z-index:3"><span style="width:24px;height:24px;border-radius:50%;border:2.5px solid rgba(255,255,255,.25);border-top-color:#fff;animation:l2spin .8s linear infinite"></span></div>`;
const spinStyle=document.createElement('style');spinStyle.textContent='@keyframes l2spin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){[role=status] span{animation:none!important}}';document.head.append(spinStyle);
