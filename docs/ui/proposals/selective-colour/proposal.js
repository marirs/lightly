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
const SEL_DEFAULTS = { picks:[], range:40, strength:100, area:[] };

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
  const picks = sel.picks.map(p => sampleLab(id, p.x, p.y)), aspect = im.w / im.h, limitedToArea = sel.area.some(d => d.mode === 'add');
  for (let p = 0; p < n; p++) {
    let best = 0;
    for (const k of picks) {
      const dL = 0.35 * (im.lab[p * 3] - k[0]), da = im.lab[p * 3 + 1] - k[1], db = im.lab[p * 3 + 2] - k[2];
      const d = Math.sqrt(dL * dL + da * da + db * db);
      best = Math.max(best, Math.min(1, Math.max(0, (tolerance - d) / (0.35 * tolerance))));
    }
    if (limitedToArea && best > 0) best *= areaAt(sel.area, (p % im.w) / im.w, Math.floor(p / im.w) / im.h, aspect);
    out[p] = best;
  }
  return out;
}

// The overlay shows the painted area while refining (the area exists), else what stays in colour.
const ui_selRefineShown = (sel) => sel.area.length > 0;
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
    const shown = ui_selRefineShown(sel) ? areaAt(sel.area, (p % im.w) / im.w, Math.floor(p / im.w) / im.h, im.w / im.h) : keep[p];
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
// Eyedropper glyph in the approved icon style (24 × 24, 1.6 stroke).
ICON.picker = '<path d="M13.5 6.5l4 4"/><path d="M15.2 4.8a2.1 2.1 0 013 3l-2.2 2.2-3-3z"/><path d="M12.5 8L5 15.5V19h3.5L16 11.5"/>';
effectsPanel = function (s, ui, L) {
  if (ui.sub !== 'sel') return approvedEffectsPanel(s, ui, L).replace(/<div class="tabs">([\s\S]*?)<\/div>/, (all, inner) => `<div class="tabs">${inner}${selTab(s, ui)}</div>`);
  const fx = s.fx, sel = fx.sel, tool = selToolOf(s, ui);
  const items = [['leak', 'Light Leaks', fx.leak.on ? 'dotted' : ''], ['grain', 'Grain', fx.grain.on ? 'dotted' : ''], ['vig', 'Vignette', fx.vig.on ? 'dotted' : ''], ['sel', 'Selective Colour', sel.picks.length ? 'dotted' : '']];
  // One panel. Top row: three tools for what a touch on the photo does (pick a colour, paint the area where
  // colours stay, erase from it), then the kept colours as small dots (they scroll), then Clear.
  // Icons and dots are drawn small inside 44 pt touch targets.
  const target = 'width:44px;height:44px;display:grid;place-items:center;flex:0 0 auto;background:none;border:0;padding:0';
  const toolBtn = (k, ic, label) => `<button data-act="selTool:${k}" aria-pressed="${tool === k}" aria-label="${label}" style="${target};color:${tool === k ? 'var(--sel)' : 'var(--ink2)'}">${icon(ic, 21)}</button>`;
  const dots = sel.picks.map((p, i) => `<button data-act="selRemove:${i}" aria-label="Remove colour ${i + 1}" style="${target}"><span style="width:26px;height:26px;border-radius:13px;border:1px solid var(--hair);background:${selImages[s.photo] ? labToCss(sampleLab(s.photo, p.x, p.y)) : '#999'}"></span></button>`).join('');
  let body = `<div style="display:flex;align-items:center;padding:4px 10px 0 10px">${toolBtn('pick', 'picker', 'Pick a colour')}${toolBtn('add', 'brush', 'Paint the area where colours stay')}${toolBtn('erase', 'erase', 'Erase from the area')}<span style="width:1px;height:24px;background:var(--hair);margin:0 6px;flex:0 0 auto"></span>`;
  if (!sel.picks.length) return `${L.roomy ? '<div class="ptitle">Effects</div>' : ''}${tabs(items, 'sel', 'sub')}${body}<span class="note" style="padding:0 6px">Tap a colour in the photo.</span></div>`;
  body += `<div class="chiprow" style="flex:1 1 auto;min-width:0;padding:0;gap:0;align-items:center">${dots}</div><button class="btn quiet small" data-act="selClear">Clear</button></div>`;
  body += sl('Range', sel.range, 'fx.sel.range') + sl('Strength', sel.strength, 'fx.sel.strength');
  if (tool !== 'pick') body += sl('Brush size', selBrushSize(ui), 'ui.selBrush');
  return `${L.roomy ? '<div class="ptitle">Effects</div>' : ''}${tabs(items, 'sel', 'sub')}${body}`;
};
// The tool a touch on the photo uses: the eyedropper until there is a colour, then whichever is chosen.
const selToolOf = (s, ui) => s.fx.sel.picks.length ? (ui.selTool || 'pick') : 'pick';
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
    case 'selTool': this.ui.selTool = arg; return r();
    case 'selRemove': sel.picks.splice(+arg, 1); this.commit(); return r();
    case 'selClear': sel.picks = []; sel.area = []; this.ui.selTool = 'pick'; this.commit(); return r();
  }
  return approvedAct.call(this, a, el);
};
const approvedRender = Prototype.prototype.render;
Prototype.prototype.render = function () {
  approvedRender.call(this);
  const stage = this.host.querySelector('.stage'), sel = this.s.fx.sel, ui = this.ui;
  if (!stage || ui.tool !== 'effects' || ui.sub !== 'sel') return;
  const at = (e) => { const b = stage.querySelector('.imgbox').getBoundingClientRect(); return { x:(e.clientX - b.left) / b.width, y:(e.clientY - b.top) / b.height }; };
  const tool = selToolOf(this.s, ui);
  if (tool === 'pick') stage.onclick = (e) => { const p = at(e); if (p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return; sel.picks.push(p); ui.selOverlay = true; this.commit(); this.render(); setTimeout(() => { ui.selOverlay = false; this.render(); }, 1200); };
  else this.wireSelStroke(stage);
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
    const r = selBrushRadius(ui), mode = selToolOf(this.s, ui) === 'erase' ? 'erase' : 'add';
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
add('fx-selective-empty', 'effects', 'PROPOSAL · Selective Colour · first pick (tap the photo)', 'editor', { photo:'woman', setup:selSetup({}), ui:{ tool:'effects', sub:'sel' } });
add('fx-selective-picked', 'effects', 'PROPOSAL · Selective Colour · one colour kept, Matching colours', 'editor', { photo:'woman', setup:selSetup({ picks:[ARROW] }), ui:{ tool:'effects', sub:'sel' } });
add('fx-selective-overlay', 'effects', 'PROPOSAL · Selective Colour · overlay while Range is dragged', 'editor', { photo:'woman', setup:selSetup({ picks:[ARROW], range:55 }), ui:{ tool:'effects', sub:'sel', selOverlay:true } });
add('fx-selective-multi', 'effects', 'PROPOSAL · Selective Colour · several colours kept', 'editor', { photo:'street', setup:selSetup({ picks:[{ x:0.62, y:0.10 }, { x:0.15, y:0.56 }, { x:0.72, y:0.40 }], range:35 }), ui:{ tool:'effects', sub:'sel' } });
add('fx-selective-area-painting', 'effects', 'PROPOSAL · Selective Colour · brush, while painting (overlay)', 'editor', { photo:'woman', setup:selSetup({ picks:[ARROW], range:55, area:ARROW_AREA }), ui:{ tool:'effects', sub:'sel', selTool:'add', selOverlay:true } });
add('fx-selective-area', 'effects', 'PROPOSAL · Selective Colour · brush, limited to the painted area (result)', 'editor', { photo:'woman', setup:selSetup({ picks:[ARROW], range:55, area:ARROW_AREA }), ui:{ tool:'effects', sub:'sel', selTool:'add' } });
add('fx-selective-area-remove', 'effects', 'PROPOSAL · Selective Colour · eraser', 'editor', { photo:'woman', setup:selSetup({ picks:[ARROW], range:55, area:LIPS_REMOVED }), ui:{ tool:'effects', sub:'sel', selTool:'erase' } });
add('fx-selective-leak', 'effects', 'PROPOSAL · Selective Colour · with a Light Leak (applied after the leak)', 'editor', { photo:'woman', setup:(s) => { selSetup({ picks:[ARROW] })(s); s.fx.leak.on = true; }, ui:{ tool:'effects', sub:'sel' } });

/* The whole approved catalogue stays (the prototype controller starts from Launch); the proposal screens are
   listed under Effects, after the approved Effects screens. */
if (!location.hash) location.hash = 'screen=fx-selective-empty&tab=prototype';

Promise.all(SEL_PHOTOS.map(loadSelPhoto)).then(() => { selCache.clear(); window.SEL_READY = true; if (window.READY) refresh(); });

/* ================================================================ PROPOSAL 2: no On/Off switch on Light Leaks,
   Grain and Vignette (owner, 2026-10-05: "why an on/off button"). Each effect is on while its main slider
   (Light Leaks Intensity, Grain Amount, Vignette Amount) is above 0; dragging it to 0 turns it off. Choosing a
   style while it is at 0 starts it at the approved default. The approved panels are reused; only the switch row
   is removed and `on` is derived from the slider. */
const FX_MAIN = { leak:['intensity', 55], grain:['amount', 30], vig:['amount', 35] };
const deriveFxOn = (s) => { for (const [k, [key]] of Object.entries(FX_MAIN)) s.fx[k].on = s.fx[k][key] > 0; };

const approvedStateFor = stateFor;
stateFor = function (spec) {
  const st = approvedStateFor(spec);
  // A screen that switched an effect on keeps the approved default amount; one that did not starts at 0.
  for (const [k, [key, def]] of Object.entries(FX_MAIN)) { const fx = st.s.fx[k]; fx[key] = fx.on ? (fx[key] || def) : 0; }
  deriveFxOn(st.s); return st;
};
const approvedScreenHTML = screenHTML;
screenHTML = function (spec, s, ...rest) { deriveFxOn(s); return approvedScreenHTML(spec, s, ...rest); };

const selEffectsPanel = effectsPanel;
effectsPanel = function (s, ui, L) {
  return selEffectsPanel(s, ui, L).replace(/<button class="listrow"[^>]*data-act="fxToggle:[a-z]+"[^>]*>[\s\S]*?<\/button>/, '');
};
PANELS.effects = effectsPanel;

const selAct = Prototype.prototype.act;
Prototype.prototype.act = function (a, el) {
  const m = /^set:fx\.(leak|grain)\.style=/.exec(a);
  if (m) { const [key, def] = FX_MAIN[m[1]], fx = this.s.fx[m[1]]; if (!(fx[key] > 0)) fx[key] = def; }
  return selAct.call(this, a, el);
};
add('fx-noswitch-leak-off', 'effects', 'PROPOSAL 2 · Light Leaks without a switch · off (Intensity 0)', 'editor', { photo:'sunset', ui:{ tool:'effects', sub:'leak' } });
add('fx-noswitch-leak-on', 'effects', 'PROPOSAL 2 · Light Leaks without a switch · on', 'editor', { photo:'sunset', setup:s => { s.fx.leak.on = true; }, ui:{ tool:'effects', sub:'leak' } });
