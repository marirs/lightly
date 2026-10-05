/* PROPOSAL, not approved: Effects › Selective Colour (owner request, 2026-10-04).
   Adds one Effects tab and its states to the approved prototype without changing any approved screen:
   the approved app.js / screens.js / review.js are loaded unchanged and only extended here.

   Two different ways of choosing what stays in colour, named differently on purpose:
   - "Matching colours" (default): every pixel whose colour is close to a picked colour stays in colour,
     anywhere in the photo. This is colour matching only; it does not know what an object is.
   - "Painted area": the person paints, with Add and Remove brushes, the region where picked colours may
     stay in colour. Only the painted pixels can stay coloured. The app does not detect the dress or the
     balloon; the painting is what limits it.

   Photo rendering here is an in-browser illustration (canvas, Lab colour distance), like the rest of the
   prototype's CSS simulations; it is not the native renderer. */

const SEL_PHOTOS = ['woman', 'street'];
// No On switch: the effect is active while at least one colour is kept; removing the last colour or Clear
// selection turns it off.
const SEL_DEFAULTS = { picks:[], scope:'match', range:40, strength:100, area:[] };

/* ---------------------------------------------------------------- session: fx.sel */
const approvedNewSession = newSession;
newSession = function (photo) { const s = approvedNewSession(photo); s.fx.sel = JSON.parse(JSON.stringify(SEL_DEFAULTS)); return s; };

const approvedToolUsed = toolUsed;
toolUsed = function (s, t) { return approvedToolUsed(s, t) || (t === 'effects' && !!(s.fx.sel && s.fx.sel.picks.length)); };

/* ---------------------------------------------------------------- pixels (illustration) */
const selImages = {};          // photo id -> { w, h, rgb:Uint8ClampedArray, lab:Float32Array }
const selCache = new Map();    // key -> { photo:dataURL, tint:dataURL }

function srgbToLab(r, g, b) {
  const lin = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  const R = lin(r), G = lin(g), B = lin(b);
  const X = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047, Y = 0.2126 * R + 0.7152 * G + 0.0722 * B, Z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883;
  const f = (t) => t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116;
  return [116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z))];
}

function loadSelPhoto(id) {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, 900 / Math.max(img.width, img.height));
      const w = Math.round(img.width * scale), h = Math.round(img.height * scale);
      const c = document.createElement('canvas'); c.width = w; c.height = h;
      const g = c.getContext('2d'); g.drawImage(img, 0, 0, w, h);
      const rgb = g.getImageData(0, 0, w, h).data, lab = new Float32Array(w * h * 3);
      for (let p = 0; p < w * h; p++) lab.set(srgbToLab(rgb[p * 4], rgb[p * 4 + 1], rgb[p * 4 + 2]), p * 3);
      selImages[id] = { w, h, rgb, lab }; resolve();
    };
    img.src = PHOTOS[id].src;
  });
}

/** Mean Lab colour in a small square around a photo point (x, y in 0..1). */
function sampleLab(id, x, y) {
  const im = selImages[id], cx = Math.round(x * (im.w - 1)), cy = Math.round(y * (im.h - 1)), acc = [0, 0, 0]; let n = 0;
  for (let yy = Math.max(0, cy - 3); yy <= Math.min(im.h - 1, cy + 3); yy++) for (let xx = Math.max(0, cx - 3); xx <= Math.min(im.w - 1, cx + 3); xx++) {
    const p = (yy * im.w + xx) * 3; acc[0] += im.lab[p]; acc[1] += im.lab[p + 1]; acc[2] += im.lab[p + 2]; n++;
  }
  return acc.map(v => v / n);
}
const labToCss = ([L, a, b]) => `lab(${L.toFixed(1)}% ${a.toFixed(1)} ${b.toFixed(1)})`;

/** Painted area in photo coordinates: brush dabs, applied in order (Add sets, Remove clears). */
function areaAt(area, x, y, aspect) {
  let v = 0;
  for (const d of area) { const dx = (x - d.x) * aspect, dy = y - d.y; if (dx * dx + dy * dy <= d.r * d.r) v = d.mode === 'add' ? 1 : 0; }
  return v;
}

/** Per-pixel "stays in colour" weight: colour match to the nearest pick, limited to the painted area. */
function keepWeights(id, sel) {
  const im = selImages[id], n = im.w * im.h, out = new Float32Array(n);
  const tolerance = 6 + sel.range * 0.5;                 // Range 0..100 -> ΔE 6..56
  const picks = sel.picks.map(p => sampleLab(id, p.x, p.y)), aspect = im.w / im.h;
  for (let p = 0; p < n; p++) {
    let best = 0;
    for (const k of picks) {
      const dL = 0.35 * (im.lab[p * 3] - k[0]), da = im.lab[p * 3 + 1] - k[1], db = im.lab[p * 3 + 2] - k[2];
      const d = Math.sqrt(dL * dL + da * da + db * db);
      best = Math.max(best, Math.min(1, Math.max(0, (tolerance - d) / (0.35 * tolerance))));
    }
    if (sel.scope === 'area' && best > 0) best *= areaAt(sel.area, (p % im.w) / im.w, Math.floor(p / im.w) / im.h, aspect);
    out[p] = best;
  }
  return out;
}

function renderSel(id, sel) {
  const key = JSON.stringify([id, sel]);
  if (selCache.has(key)) return selCache.get(key);
  const im = selImages[id]; if (!im) return null;
  const keep = keepWeights(id, sel), strength = sel.strength / 100;
  const c = document.createElement('canvas'); c.width = im.w; c.height = im.h;
  const g = c.getContext('2d'), photo = g.createImageData(im.w, im.h), tint = g.createImageData(im.w, im.h);
  for (let p = 0; p < im.w * im.h; p++) {
    const r = im.rgb[p * 4], gr = im.rgb[p * 4 + 1], b = im.rgb[p * 4 + 2], y = 0.2126 * r + 0.7152 * gr + 0.0722 * b;
    const colour = keep[p] + (1 - keep[p]) * (1 - strength);    // Strength 100: everything else black and white
    photo.data[p * 4] = y + (r - y) * colour; photo.data[p * 4 + 1] = y + (gr - y) * colour; photo.data[p * 4 + 2] = y + (b - y) * colour; photo.data[p * 4 + 3] = 255;
    // Temporary overlay mask: in Matching colours, what stays in colour; in Painted area, the painted area
    // itself (as Background › Refine tints the subject), so the person sees where they painted.
    const shown = sel.scope === 'area' ? areaAt(sel.area, (p % im.w) / im.w, Math.floor(p / im.w) / im.h, im.w / im.h) : keep[p];
    tint.data[p * 4 + 3] = Math.round(255 * shown);
  }
  g.putImageData(photo, 0, 0); const photoUrl = c.toDataURL('image/jpeg', 0.9);
  g.clearRect(0, 0, im.w, im.h); g.putImageData(tint, 0, 0); const tintUrl = c.toDataURL('image/png');
  const out = { photo:photoUrl, tint:tintUrl }; selCache.set(key, out); return out;
}

/* ---------------------------------------------------------------- photo and marks */
const approvedPhotoHTML = photoHTML;
photoHTML = function (s, ui = {}) {
  const html = approvedPhotoHTML(s, ui), sel = s.fx.sel;
  if (ui.compare || !sel || !sel.picks.length || !selImages[s.photo]) return html;
  const r = renderSel(s.photo, sel); if (!r) return html;
  // Order (owner recommendation): after Light Leaks, before Grain and Vignette, so a coloured leak does not
  // bring colour back. Illustration only: the leak overlay is desaturated by Strength.
  return html.split(`src="${PHOTOS[s.photo].src}"`).join(`src="${r.photo}"`)
    .replace('mix-blend-mode:screen;', `mix-blend-mode:screen;filter:saturate(${1 - sel.strength / 100});`);
};

const approvedMarksFor = marksFor;
marksFor = function (s, ui) {
  let m = approvedMarksFor(s, ui); const sel = s.fx.sel;
  // Temporary overlay (Background › Refine's blue tint), never saved: shown for a moment after a pick, while
  // Range is dragged and while painting; otherwise the person sees the actual result.
  if (ui.tool === 'effects' && ui.sub === 'sel' && sel.picks.length && ui.selOverlay) {
    const r = renderSel(s.photo, sel);
    if (r) m += `<div class="maskTint" style="-webkit-mask-image:url(${r.tint});mask-image:url(${r.tint});-webkit-mask-size:100% 100%;mask-size:100% 100%"></div>`;
  }
  return m;
};

/* ---------------------------------------------------------------- panel */
const approvedEffectsPanel = effectsPanel;
effectsPanel = function (s, ui, L) {
  if (ui.sub !== 'sel') return approvedEffectsPanel(s, ui, L).replace(/<div class="tabs">([\s\S]*?)<\/div>/, (all, inner) => `<div class="tabs">${inner}${selTab(s, ui)}</div>`);
  const fx = s.fx, sel = fx.sel;
  const items = [['leak', 'Light Leaks', fx.leak.on ? 'dotted' : ''], ['grain', 'Grain', fx.grain.on ? 'dotted' : ''], ['vig', 'Vignette', fx.vig.on ? 'dotted' : ''], ['sel', 'Selective Colour', sel.picks.length ? 'dotted' : '']];
  let body = '';
  {
    const picking = ui.picking || !sel.picks.length;
    // Kept colours are the approved 44 pt swatches (`.sw`, as in Background and Border); a small × marks that
    // tapping one removes it.
    const chips = sel.picks.map((p, i) => `<button class="sw" data-act="selRemove:${i}" aria-label="Remove colour ${i + 1}" style="background:${selImages[s.photo] ? labToCss(sampleLab(s.photo, p.x, p.y)) : '#999'}"><span style="position:absolute;right:-3px;top:-3px;width:18px;height:18px;border-radius:9px;background:var(--bg);border:1px solid var(--hair);display:grid;place-items:center;color:var(--ink2)">${icon('close', 11)}</span></button>`).join('');
    // "Keep" and Pick are pinned; only the colour chips scroll (`.chiprow`), so adding another colour stays
    // in reach however many there are.
    body += `<div style="display:flex;align-items:center;gap:8px;padding-left:18px"><span style="min-width:76px;color:var(--ink2)">Keep</span><button class="sw ${picking ? 'on' : ''}" data-act="selPicking" aria-pressed="${picking}" aria-label="Pick a colour" style="display:grid;place-items:center;background:var(--bg2);color:var(--ink)">${icon('plus', 20)}</button><div class="chiprow" style="flex:1 1 auto;min-width:0;padding-left:0;align-items:center">${chips}</div></div>`;
    body += `<div class="note">${picking ? 'Tap the photo on a colour to keep it. Everything else turns black and white.' : 'Tap a colour to remove it.'}</div>`;
    body += seg([['match', 'Matching colours'], ['area', 'Painted area']], sel.scope, 'selScope');
    if (sel.scope === 'match') body += `<div class="note">The picked colours stay wherever they appear in the photo.</div>`;
    else body += `<div class="note">Paint where the picked colours stay. Outside the painted area, the photo turns black and white.</div>` + seg([['add', `${icon('brush', 16)}&nbsp;Add`], ['erase', `${icon('erase', 16)}&nbsp;Remove`]], ui.brush || 'add', 'brush') + sl('Brush size', selBrushSize(ui), 'ui.selBrush');
    body += sl('Range', sel.range, 'fx.sel.range') + sl('Strength', sel.strength, 'fx.sel.strength');
    body += `<div style="display:flex;justify-content:flex-end;padding:0 10px"><button class="btn quiet" data-act="selClear" ${sel.picks.length || sel.area.length ? '' : 'disabled'}>Clear selection</button></div>`;
  }
  return `${L.roomy ? '<div class="ptitle">Effects</div>' : ''}${tabs(items, 'sel', 'sub')}${body}`;
};
PANELS.effects = effectsPanel;   // the approved panel map captured the original function
const selTab = (s, ui) => { const sel = s.fx.sel, dotted = sel.picks.length; return `<button class="${dotted ? 'dotted' : ''}" data-act="sub:sel">Selective Colour</button>`; };

/* ---------------------------------------------------------------- interactions */
// Brush size 0..100 -> dab radius 2 %..15 % of the photo's height. A view setting, not an edit (no undo step).
const selBrushSize = (ui) => ui.selBrush ?? 40;
const selBrushRadius = (ui) => 0.02 + selBrushSize(ui) / 100 * 0.13;
const approvedAct = Prototype.prototype.act;
Prototype.prototype.act = function (a, el) {
  const [verb, arg] = a.split(/:(.*)/s), sel = this.s.fx.sel, r = () => this.render();
  switch (verb) {
    case 'selPicking': this.ui.picking = !this.ui.picking; return r();
    case 'selRemove': sel.picks.splice(+arg, 1); this.commit(); return r();
    case 'selScope': sel.scope = arg; this.commit(); return r();
    case 'selClear': sel.picks = []; sel.area = []; this.ui.picking = true; this.commit(); return r();
  }
  return approvedAct.call(this, a, el);
};
const approvedRender = Prototype.prototype.render;
Prototype.prototype.render = function () {
  approvedRender.call(this);
  const stage = this.host.querySelector('.stage'), sel = this.s.fx.sel, ui = this.ui;
  if (!stage || ui.tool !== 'effects' || ui.sub !== 'sel') return;
  const at = (e) => { const b = stage.querySelector('.imgbox').getBoundingClientRect(); return { x:(e.clientX - b.left) / b.width, y:(e.clientY - b.top) / b.height }; };
  const picking = ui.picking || !sel.picks.length;
  if (picking) stage.onclick = (e) => { const p = at(e); if (p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return; sel.picks.push(p); ui.picking = false; ui.selOverlay = true; this.commit(); this.render(); setTimeout(() => { ui.selOverlay = false; this.render(); }, 1200); };
  else if (sel.scope === 'area') this.wireSelStroke(stage);
  this.wireSelBrushSize();
  // Range drag shows the overlay while the finger is down (one undo step on release, as every slider).
  const range = this.host.querySelector('.trk[data-path="fx.sel.range"]');
  if (range) { const down = range.onpointerdown, up = range.onpointerup; range.onpointerdown = (e) => { ui.selOverlay = true; down(e); }; range.onpointerup = (e) => { ui.selOverlay = false; up(e); this.render(); }; }
};

/** Painted area: a dragged stroke at the Brush size. While the finger is down the painted area (blue) and
 *  the stroke are shown; on release the stroke becomes one undo step, then the overlay clears to the result. */
Prototype.prototype.wireSelStroke = function (stage) {
  const sel = this.s.fx.sel, ui = this.ui;
  stage.onpointerdown = (e) => {
    const box = stage.querySelector('.imgbox'), b = box.getBoundingClientRect();
    const r = selBrushRadius(ui), mode = ui.brush === 'erase' ? 'erase' : 'add';
    stage.setPointerCapture(e.pointerId); clearTimeout(this.selTimer);
    const painted = renderSel(this.s.photo, sel);
    if (painted) box.insertAdjacentHTML('beforeend', `<div class="maskTint" style="-webkit-mask-image:url(${painted.tint});mask-image:url(${painted.tint});-webkit-mask-size:100% 100%;mask-size:100% 100%"></div>`);
    const cv = document.createElement('canvas'), dpr = window.devicePixelRatio || 1;
    cv.width = b.width * dpr; cv.height = b.height * dpr;
    cv.style.cssText = `position:absolute;inset:0;width:100%;height:100%;pointer-events:none;opacity:${mode === 'add' ? 0.32 : 0.55}`;
    box.appendChild(cv);
    const g = cv.getContext('2d'); g.fillStyle = mode === 'add' ? 'rgb(47,107,235)' : '#fff';
    const dabs = [];
    const dab = (ev) => {
      const x = (ev.clientX - b.left) / b.width, y = (ev.clientY - b.top) / b.height, last = dabs.at(-1);
      if (last && Math.hypot((x - last.x) * b.width, (y - last.y) * b.height) < r * b.height * 0.35) return;
      dabs.push({ x, y, r, mode }); g.beginPath(); g.arc(x * cv.width, y * cv.height, r * cv.height, 0, 2 * Math.PI); g.fill();
    };
    dab(e);
    stage.onpointermove = dab;
    stage.onpointerup = stage.onpointercancel = () => {
      stage.onpointermove = stage.onpointerup = stage.onpointercancel = null;
      sel.area.push(...dabs); ui.selOverlay = true; this.commit(); this.render();
      this.selTimer = setTimeout(() => { ui.selOverlay = false; this.render(); }, 1200);
    };
  };
};
/** Brush size is a view setting: dragging moves the thumb and value in place, without an undo step. */
Prototype.prototype.wireSelBrushSize = function () {
  const t = this.host.querySelector('.trk[data-path="ui.selBrush"]'); if (!t) return;
  const set = (e) => {
    const r = t.getBoundingClientRect(), v = Math.round(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * 100);
    this.ui.selBrush = v; t.querySelector('i').style.width = v + '%'; t.querySelector('b').style.left = v + '%'; t.parentElement.querySelector('.v').textContent = v;
  };
  t.onpointerdown = (e) => { t.setPointerCapture(e.pointerId); set(e); t.onpointermove = set; };
  t.onpointerup = t.onpointercancel = () => { t.onpointermove = null; };
};

/* ---------------------------------------------------------------- screens (journey: effects) */
const ARROW = { x:0.30, y:0.12 };                                        // red arrow on the wall
// Painted with Add over the arrow; one dab also caught the lips (red, so they stayed in colour) ...
const ARROW_AREA = [{ x:0.30, y:0.12, r:0.17, mode:'add' }, { x:0.30, y:0.36, r:0.17, mode:'add' }, { x:0.24, y:0.62, r:0.17, mode:'add' }, { x:0.20, y:0.78, r:0.13, mode:'add' }, { x:0.31, y:0.52, r:0.08, mode:'add' }];
// ... and Remove takes the lips back out of the painted area.
const LIPS_REMOVED = [...ARROW_AREA, { x:0.335, y:0.545, r:0.06, mode:'erase' }];
const selSetup = (o) => (s) => { Object.assign(s.fx.sel, JSON.parse(JSON.stringify(o))); };
add('fx-selective-empty', 'effects', 'PROPOSAL · Selective Colour · first pick (tap the photo)', 'editor', { photo:'woman', setup:selSetup({}), ui:{ tool:'effects', sub:'sel', picking:true } });
add('fx-selective-picked', 'effects', 'PROPOSAL · Selective Colour · one colour kept, Matching colours', 'editor', { photo:'woman', setup:selSetup({ picks:[ARROW] }), ui:{ tool:'effects', sub:'sel' } });
add('fx-selective-overlay', 'effects', 'PROPOSAL · Selective Colour · overlay while Range is dragged', 'editor', { photo:'woman', setup:selSetup({ picks:[ARROW], range:55 }), ui:{ tool:'effects', sub:'sel', selOverlay:true } });
add('fx-selective-multi', 'effects', 'PROPOSAL · Selective Colour · several colours kept', 'editor', { photo:'street', setup:selSetup({ picks:[{ x:0.62, y:0.10 }, { x:0.15, y:0.56 }, { x:0.72, y:0.40 }], range:35 }), ui:{ tool:'effects', sub:'sel' } });
add('fx-selective-area-painting', 'effects', 'PROPOSAL · Selective Colour · Painted area, while painting (overlay)', 'editor', { photo:'woman', setup:selSetup({ picks:[ARROW], scope:'area', range:55, area:ARROW_AREA }), ui:{ tool:'effects', sub:'sel', brush:'add', selOverlay:true } });
add('fx-selective-area', 'effects', 'PROPOSAL · Selective Colour · Painted area, Add (result)', 'editor', { photo:'woman', setup:selSetup({ picks:[ARROW], scope:'area', range:55, area:ARROW_AREA }), ui:{ tool:'effects', sub:'sel', brush:'add' } });
add('fx-selective-area-remove', 'effects', 'PROPOSAL · Selective Colour · Painted area, Remove (result)', 'editor', { photo:'woman', setup:selSetup({ picks:[ARROW], scope:'area', range:55, area:LIPS_REMOVED }), ui:{ tool:'effects', sub:'sel', brush:'erase' } });
add('fx-selective-leak', 'effects', 'PROPOSAL · Selective Colour · with a Light Leak (applied after the leak)', 'editor', { photo:'woman', setup:(s) => { selSetup({ picks:[ARROW] })(s); s.fx.leak.on = true; }, ui:{ tool:'effects', sub:'sel' } });

/* The whole approved catalogue stays (the prototype controller starts from Launch); the proposal screens are
   listed under Effects, after the approved Effects screens. */
if (!location.hash) location.hash = 'screen=fx-selective-empty&tab=prototype';

Promise.all(SEL_PHOTOS.map(loadSelPhoto)).then(() => { selCache.clear(); window.SEL_READY = true; if (window.READY) refresh(); });
