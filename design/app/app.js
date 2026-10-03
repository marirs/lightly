/* Lightly design prototype — renderer and controller.
   One photo, one session: every tool reads and writes the same `session`, so edits accumulate.
   All photo appearance is SIMULATED with CSS (filters, masks, overlays) for design review only. */

let CAT = null;                               // presets/develop-design-ui.json, loaded as-is
const PRESET = new Map();                     // id -> { cat, stop, name }

/* ---------------------------------------------------------------- icons */
const ICON = {
  close:'<path d="M6 6l12 12M18 6L6 18"/>', back:'<path d="M15 5l-7 7 7 7"/>', backA:'<path d="M20 12H5M11 6l-6 6 6 6"/>', chevron:'<path d="M9 5l7 7-7 7"/>',
  undo:'<path d="M9 7H5V3"/><path d="M5.5 7.5A8 8 0 1 1 4 13"/>', redo:'<path d="M15 7h4V3"/><path d="M18.5 7.5A8 8 0 1 0 20 13"/>',
  compare:'<rect x="4.5" y="4.5" width="15" height="15" rx="2.5"/><path d="M12 4.5v15"/><path d="M12 4.5h5a2.5 2.5 0 0 1 2.5 2.5v10a2.5 2.5 0 0 1-2.5 2.5h-5z" fill="currentColor" stroke="none"/>',
  more:'<circle cx="12" cy="5.5" r="1.3" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="12" cy="18.5" r="1.3" fill="currentColor" stroke="none"/>',
  develop:'<path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1"/>',
  background:'<rect x="3.5" y="5" width="17" height="14" rx="2.5"/><circle cx="12" cy="11" r="2.6"/><path d="M7 19c.8-2.6 2.8-4 5-4s4.2 1.4 5 4"/>',
  portrait:'<circle cx="12" cy="8.5" r="3.6"/><path d="M5 20c1.2-3.8 4-5.6 7-5.6s5.8 1.8 7 5.6"/>',
  edit:'<path d="M5 7h9M18 7h1M5 17h1M10 17h9"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/>',
  effects:'<path d="M12 3l1.8 4.6L18.5 9l-4.7 1.6L12 15l-1.8-4.4L5.5 9l4.7-1.4z"/>',
  watermark:'<path d="M4 17c2.5-4 4.5-9 7-9 1.6 0 1 4 2.6 4 1.3 0 1.7-2 3-2 1 0 1.6 1 3.4 2"/><path d="M4 20h16"/>',
  border:'<rect x="3.5" y="3.5" width="17" height="17" rx="1.5"/><rect x="7" y="7" width="10" height="8" rx=".5"/>',
  star:'<path d="M12 4.5l2.2 4.6 5 .7-3.6 3.5.9 5-4.5-2.4-4.5 2.4.9-5L4.8 9.8l5-.7z"/>',
  brush:'<path d="M14.5 4.5l5 5-8 8H6.5v-5z"/><path d="M4 20h7"/>', erase:'<path d="M8 20h12M5.5 14.5l7-7 5 5-5.5 5.5H9z"/>',
  photo:'<rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><circle cx="9" cy="10" r="1.8"/><path d="M4 17l4.5-4.5 4 4 2.5-2.5 5 5"/>',
  camera:'<path d="M4 8.5A2.5 2.5 0 0 1 6.5 6h1.6l1.4-2h5l1.4 2h1.6A2.5 2.5 0 0 1 20 8.5v8A2.5 2.5 0 0 1 17.5 19h-11A2.5 2.5 0 0 1 4 16.5z"/><circle cx="12" cy="12.5" r="3.4"/>',
  share:'<path d="M12 3v12M7.5 7.5 12 3l4.5 4.5"/><path d="M5 12v6.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V12"/>',
  check:'<path d="M5 12.5l4.5 4.5L19 7.5"/>', info:'<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5M12 8v.5"/>', warn:'<path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17v.5"/>',
  rotl:'<path d="M4 4v5h5"/><path d="M4.5 9A8 8 0 1 1 6 16"/>', rotr:'<path d="M20 4v5h-5"/><path d="M19.5 9A8 8 0 1 0 18 16"/>',
  fliph:'<path d="M12 3v18"/><path d="M9 7L4 12l5 5z"/><path d="M15 7l5 5-5 5z"/>', flipv:'<path d="M3 12h18"/><path d="M7 9l5-5 5 5z"/><path d="M7 15l5 5 5-5z"/>',
  grip:'<path d="M8 7h.01M8 12h.01M8 17h.01M16 7h.01M16 12h.01M16 17h.01" stroke-width="3"/>', trash:'<path d="M5 7h14M9 7V5h6v2M7 7l1 13h8l1-13"/>',
  circle:'<circle cx="12" cy="12" r="7"/>', hex:'<path d="M12 4.5l6.5 3.75v7.5L12 19.5l-6.5-3.75v-7.5z"/>', heart:'<path d="M12 19s-7-4.4-7-9.5A3.8 3.8 0 0 1 12 7a3.8 3.8 0 0 1 7 2.5C19 14.6 12 19 12 19z"/>',
  starShape:'<path d="M12 5l2 4.6 5 .4-3.8 3.3 1.2 4.9L12 15.6 7.6 18.2l1.2-4.9L5 10l5-.4z"/>', plus:'<path d="M12 5v14M5 12h14"/>', search:'<circle cx="11" cy="11" r="6"/><path d="M20 20l-4.5-4.5"/>',
  flash:'<path d="M13 3L5 13h6l-1 8 8-10h-6z"/>', sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M5 19l1.5-1.5M17.5 6.5 19 5"/>',
};
const icon = (n, s = 22, extra = '') => `<svg class="icon" style="width:${s}px;height:${s}px" viewBox="0 0 24 24" ${extra}>${ICON[n]}</svg>`;
function mark(size, color) {   // the existing eight-ray Lightly mark (geometry of BrandMark.swift)
  const c = size / 2, r = size / 2, inner = r * .3; let p = '';
  for (let i = 0; i < 8; i++) { const a = i * Math.PI / 4, o = i % 2 ? r * .86 : r; p += `M${c + Math.cos(a) * inner} ${c + Math.sin(a) * inner}L${c + Math.cos(a) * o} ${c + Math.sin(a) * o}`; }
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}"><path d="${p}" stroke="${color}" stroke-width="${Math.max(1.6, size * .035)}" stroke-linecap="round" fill="none"/></svg>`;
}
/* A user's drawn signature (vector stroke) and an imported one (keeps its own ink and texture). */
const SIG_DRAWN = 'M6 38c10-20 16-30 20-28 5 3-9 28-3 30 6 2 10-18 15-17 4 1-1 15 4 15 5 0 7-12 12-12 4 0 2 10 6 10 6 0 10-14 18-14 6 0 3 9 9 9 7 0 12-8 22-10';
const sigSvg = (h, color, imported) => imported
  ? `<svg height="${h}" viewBox="0 0 170 50"><path d="${SIG_DRAWN}" fill="none" stroke="#1D2A6B" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" opacity=".9"/><path d="${SIG_DRAWN}" fill="none" stroke="#1D2A6B" stroke-width="1" transform="translate(1.2 .8)" opacity=".35"/></svg>`
  : `<svg height="${h}" viewBox="0 0 170 50"><path d="${SIG_DRAWN}" fill="none" stroke="${color}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
const LOGO = (h, color) => `<svg height="${h}" viewBox="0 0 64 64"><circle cx="32" cy="32" r="27" fill="none" stroke="${color}" stroke-width="3"/><text x="32" y="40" text-anchor="middle" font-family="Inter, sans-serif" font-weight="700" font-size="22" fill="${color}">AR</text></svg>`;
const FONTS = [['Allura', 'Allura, cursive'], ['Cormorant Garamond', '"Cormorant Garamond", serif'], ['Inter', 'Inter, sans-serif'], ['Caveat', 'Caveat, cursive']];

/* ---------------------------------------------------------------- session */
function newSession(photo = 'lake') {
  return {
    photo, auto:'applied', dirty:false, saved:false,
    dev:{ applied:null, amount:{} },
    favs:[],
    bg:{ mode:'focus', replaced:null, x:50, y:50, scale:100, style:'lens', bokeh:'round', blur:0, depth:40, styleAmt:50, target:null },
    faces:(PHOTOS[photo].faces || []).map(() => ({ skin:{ smooth:0, blemish:0, tone:0, texture:85 }, under:{ bright:0, soften:0 }, eyes:{ bright:0, clarity:0 }, teeth:{ bright:0 }, hair:{ define:0, fly:0, shine:0 } })),
    face:0,
    edit:{ aspect:'original', rot:0, flipH:false, flipV:false, straighten:0, pv:0, ph:0,
           adj:{ exposure:0, contrast:0, highlights:0, shadows:0, temp:0, tint:0, saturation:0, vibrance:0, sharpness:0, clarity:0, noise:0 }, strokes:0 },
    fx:{ leak:{ on:false, style:'warm', intensity:55, x:18, y:14, rot:0 }, grain:{ on:false, style:'film', amount:30, size:40, rough:50 }, vig:{ on:false, amount:35, size:60, soft:60 } },
    wm:{ type:'none', sig:'drawn', text:'A. Rivera', font:'Allura', size:34, opacity:85, colour:'#FFFFFF', place:'photo', pos:8 },
    border:{ type:'none', colour:'#FFFFFF', width:4, spacing:3, mat:'#F4F1EC', sigOnMargin:true },
  };
}
const presetAt = (catId, stop) => { const c = CAT.categories.find(x => x.id === catId); return stop ? c.presets[stop - 1] : null; };
function applyPreset(s, catId, stop) { const p = presetAt(catId, stop); s.dev.applied = p ? { cat:catId, id:p.id, name:p.displayName, stop } : null; }
const PRIVATE_FAVS = () => [presetAt('portrait', 13), presetAt('landscape', 37), presetAt('film', 12), presetAt('golden-hour', 4), presetAt('black-white', 3)].map(p => p.id);

/* ---------------------------------------------------------------- simulated photo appearance */
function lookFilter(catId, id, amount = 1) {
  let h = 0; for (const c of id) h = (h * 31 + c.charCodeAt(0)) >>> 0; const r = k => ((h >>> k) & 255) / 255;
  if (catId === 'black-white') return `grayscale(${amount}) contrast(${1 + (r(8) - .4) * .3 * amount})`;
  return `saturate(${1 + (r(0) - .45) * .55 * amount}) contrast(${1 + (r(8) - .5) * .26 * amount}) brightness(${1 + (r(16) - .5) * .12 * amount}) sepia(${(catId === 'golden-hour' ? .22 : .06) * r(4) * amount}) hue-rotate(${(r(24) - .5) * 12 * amount}deg)`;
}
function photoFilter(s, original) {
  if (original) return 'none';
  const a = s.edit.adj; const f = [];
  if (s.auto === 'applied') f.push('contrast(1.04) saturate(1.06) brightness(1.02)');
  if (s.dev.applied) f.push(lookFilter(s.dev.applied.cat, s.dev.applied.id, (s.dev.amount[s.dev.applied.id] ?? 100) / 100));
  if (a.exposure || a.highlights || a.shadows) f.push(`brightness(${1 + a.exposure / 220 + a.shadows / 600 - a.highlights / 900})`);
  if (a.contrast || a.clarity) f.push(`contrast(${1 + a.contrast / 220 + a.clarity / 500})`);
  if (a.saturation || a.vibrance) f.push(`saturate(${1 + a.saturation / 110 + a.vibrance / 220})`);
  if (a.temp > 0) f.push(`sepia(${a.temp / 320})`); if (a.temp < 0 || a.tint) f.push(`hue-rotate(${-a.temp / 14 + a.tint / 10}deg)`);
  const sk = s.faces[s.face]; if (sk && (sk.skin.smooth || sk.skin.tone)) f.push(`brightness(1.01)`);
  return f.join(' ') || 'none';
}
const ASPECTS = { original:null, free:null, '1:1':1, '4:5':4 / 5, '3:2':3 / 2, '16:9':16 / 9, '9:16':9 / 16 };
/** Border insets as fractions of the image width: [side, top, bottom]. Polaroid keeps a larger bottom margin. */
function borderInsets(b) {
  if (b.type === 'solid') return [b.width / 100, b.width / 100, b.width / 100];
  if (b.type === 'frame') { const t = (b.width + b.spacing) / 100; return [t, t, t]; }
  if (b.type === 'polaroid') return [.055, .055, .24];
  return [0, 0, 0];
}

/** The photograph with every session edit layered on (never cropped to fill: always contain-fit). */
function photoHTML(s, ui = {}) {
  const ph = PHOTOS[s.photo], original = !!ui.compare;
  const crop = !original && ASPECTS[s.edit.aspect] ? ASPECTS[s.edit.aspect] : null;
  let r = crop || ph.ratio; if (!original && s.edit.rot % 180) r = 1 / r;
  const [bs, bt, bb] = original ? [0, 0, 0] : borderInsets(s.border);
  const outer = (1 + 2 * bs) / (1 / r + bt + bb);
  const W = 100 / (1 + 2 * bs);                       // image width as % of outer width
  const imgTop = bt / (1 / r + bt + bb) * 100, imgH = (1 / r) / (1 / r + bt + bb) * 100;
  const filter = photoFilter(s, original);
  const flip = original ? '' : `${s.edit.flipH ? 'scaleX(-1)' : ''} ${s.edit.flipV ? 'scaleY(-1)' : ''} rotate(${s.edit.rot + s.edit.straighten}deg) ${s.edit.straighten ? 'scale(1.12)' : ''}`;
  const sub = ph.subject, b = s.bg;
  // Subject layer: the person, sharp, composited over the background (blurred and/or replaced) — as the real
  // pipeline will do it. The mask is a soft union of head and body ellipses (illustration only).
  const subjectMask = sub ? sub.map(e => `radial-gradient(ellipse ${e.rx * 100}% ${e.ry * 100}% at ${e.cx * 100}% ${e.cy * 100}%, #000 72%, transparent 100%)`).join(',') : '';
  const blur = !original && b.blur && sub ? `filter:blur(${b.blur / 9}px);transform:scale(1.04);` : '';
  let layers = '';
  if (!original && b.replaced && sub) {
    const rv = b.replaced;
    const bgStyle = rv.type === 'image' ? `background-image:url(${rv.value});background-size:${b.scale}%;background-position:${b.x}% ${b.y}%` : `background:${rv.value}`;
    layers = `<div class="layer bg" style="${bgStyle};${blur}"></div><img src="${ph.src}" alt="" style="-webkit-mask-image:${subjectMask};mask-image:${subjectMask}">`;
  } else if (blur) {
    layers = `<img src="${ph.src}" alt="" style="${blur}"><img src="${ph.src}" alt="${ph.name}" style="-webkit-mask-image:${subjectMask};mask-image:${subjectMask}">`;
  } else layers = `<img src="${ph.src}" alt="${ph.name}">`;
  const fx = s.fx; let over = '';
  if (!original && fx.leak.on) over += `<div class="overlay" style="background:radial-gradient(circle at ${fx.leak.x}% ${fx.leak.y}%, rgba(255,150,70,${fx.leak.intensity / 130}), rgba(255,90,60,${fx.leak.intensity / 400}) 30%, transparent 55%);mix-blend-mode:screen;transform:rotate(${fx.leak.rot}deg)"></div>`;
  if (!original && fx.grain.on) over += `<div class="overlay" style="opacity:${fx.grain.amount / 140};mix-blend-mode:overlay;background-image:url(&quot;data:image/svg+xml,${encodeURIComponent(`<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='${(1.4 - fx.grain.size / 100).toFixed(2)}' numOctaves='2'/></filter><rect width='160' height='160' filter='url(#n)'/></svg>`)}&quot;)"></div>`;
  if (!original && fx.vig.on) over += `<div class="overlay" style="background:radial-gradient(ellipse at center, transparent ${fx.vig.size * .6}%, rgba(0,0,0,${fx.vig.amount / 110}) ${Math.min(100, fx.vig.size * .6 + fx.vig.soft * .7)}%)"></div>`;
  const wm = original ? '' : watermarkHTML(s, 'photo');
  const marks = ui.marks || '';
  const bgColour = s.border.type === 'polaroid' ? s.border.colour : s.border.type === 'frame' ? s.border.colour : s.border.colour;
  const frameInner = s.border.type === 'frame' && !original
    ? `<div style="position:absolute;left:${(s.border.width / 100) / (1 + 2 * bs) * 100}%;right:${(s.border.width / 100) / (1 + 2 * bs) * 100}%;top:${(s.border.width / 100) / (1 / r + bt + bb) * 100}%;bottom:${(s.border.width / 100) / (1 / r + bt + bb) * 100}%;background:${s.border.mat}"></div>` : '';
  const outline = !original && s.border.type !== 'none' ? 'box-shadow:0 0 0 1px rgba(0,0,0,.12)' : '';
  return `<div class="pic" data-ratio="${outer}" style="--r:${outer};${outline}">
    <div class="frame" style="background:${bs || bt ? bgColour : 'transparent'}">${frameInner}
      <div class="imgbox" style="left:${(100 - W) / 2}%;width:${W}%;top:${imgTop}%;height:${imgH}%">
        <div style="position:absolute;inset:0;filter:${filter};transform:${flip}">${layers}</div>${over}${wm}${marks}</div>
      ${original ? '' : watermarkHTML(s, 'border')}</div>${original ? '<div class="badge">Original</div>' : ''}</div>`;
}
function watermarkHTML(s, where) {
  const w = s.wm; if (w.type === 'none') return '';
  const onBorder = w.place === 'border' && s.border.type !== 'none';
  if ((where === 'border') !== onBorder) return '';
  const pos = [[6, 6], [50, 6], [94, 6], [6, 50], [50, 50], [94, 50], [6, 94], [50, 94], [94, 94]][w.pos];
  const tx = pos[0] < 30 ? '0' : pos[0] > 70 ? '-100%' : '-50%', ty = pos[1] < 30 ? '0' : pos[1] > 70 ? '-100%' : '-50%';
  const scale = w.size / 34;
  const ink = s.border.type === 'polaroid' && onBorder ? '#222' : w.colour;
  let body = '';
  if (w.type === 'signature') body = sigSvg(26 * scale, ink, w.sig === 'imported');
  if (w.type === 'text') body = `<span style="font-family:${FONTS.find(f => f[0] === w.font)[1]};font-size:${18 * scale}px;color:${ink}">${w.text}</span>`;
  if (w.type === 'logo') body = LOGO(30 * scale, ink);
  if (onBorder) return `<div class="wm" style="left:50%;bottom:${s.border.type === 'polaroid' ? 6 : 1}%;transform:translateX(-50%);text-shadow:none;opacity:${w.opacity / 100}">${body}</div>`;
  return `<div class="wm" style="left:${pos[0]}%;top:${pos[1]}%;transform:translate(${tx},${ty});opacity:${w.opacity / 100}">${body}</div>`;
}

/* ---------------------------------------------------------------- shared panel pieces */
const sl = (label, v, path, min = 0, max = 100) => {
  const f = (v - min) / (max - min) * 100, mid = min < 0;
  const fill = mid ? `left:${Math.min(50, f)}%;width:${Math.abs(f - 50)}%` : `width:${f}%`;
  return `<div class="sl"><span class="lbl">${label}</span><div class="trk ${mid ? 'mid' : ''}" data-path="${path}" data-min="${min}" data-max="${max}"><i style="${fill}"></i><b style="left:${f}%"></b></div><span class="v">${v > 0 && mid ? '+' : ''}${Math.round(v)}</span></div>`;
};
const tabs = (items, on, act) => `<div class="tabs">${items.map(([k, l, extra]) => `<button class="${k === on ? 'on' : ''} ${extra || ''}" data-act="${act}:${k}">${l}</button>`).join('')}</div>`;
const seg = (items, on, act) => `<div class="seg">${items.map(([k, l]) => `<button class="${k === on ? 'on' : ''}" data-act="${act}:${k}">${l}</button>`).join('')}</div>`;
const notice = (ic, html, acts = '') => `<div class="notice">${icon(ic, 18)}<div>${html}${acts ? `<div class="acts">${acts}</div>` : ''}</div></div>`;

/* ---------------------------------------------------------------- tool panels */
function developPanel(s, ui, L) {
  const roomy = L.roomy, cur = ui.cat || (s.dev.applied ? s.dev.applied.cat : 'landscape');
  const favMode = cur === 'favourites';
  const list = favMode ? s.favs.map(id => PRESET.get(id)) : CAT.categories.find(c => c.id === cur).presets.map(p => ({ id:p.id, name:p.displayName }));
  const stop = ui.stop != null ? ui.stop : s.dev.applied ? (favMode ? s.favs.indexOf(s.dev.applied.id) + 1 : s.dev.applied.cat === cur ? s.dev.applied.stop : 0) : 0;
  const p = stop ? list[stop - 1] : null;
  const base = s.auto === 'applied' ? 'Auto' : 'Original';
  const autoCls = s.auto === 'applied' ? 'on' : (s.auto === 'unavailable' || s.auto === 'failed') ? 'na' : '';
  const catItems = [['favourites', `${icon('star', 15)}Favourites<span class="count">${s.favs.length}/5</span>`], ...CAT.categories.map(c => [c.id, `${c.name}<span class="count">${c.presets.length}</span>`, s.dev.applied && s.dev.applied.cat === c.id ? 'dotted' : ''])];
  const cats = roomy ? `<div class="catlist">${catItems.map(([k, l, x]) => `<button class="${k === cur ? 'on' : ''} ${x || ''}" data-act="cat:${k}">${l}</button>`).join('')}</div>` : tabs(catItems, cur, 'cat');
  const isFav = p && s.favs.includes(p.id);
  const ctx = s.dev.applied && p == null && stop === 0 && !(favMode ? s.favs.includes(s.dev.applied.id) : s.dev.applied.cat === cur) ? `Applied: ${s.dev.applied.name}` : '';
  let n = '';
  if (s.auto === 'failed') n = notice('warn', `<b>Automatic correction didn't finish.</b> Your photo is unchanged and presets still work.`, `<button class="btn quiet small" data-act="retryAuto">Retry</button><button class="btn quiet small" data-act="useOriginal">Continue with original</button>`);
  if (s.auto === 'unavailable') n = notice('info', `Automatic correction isn't available on this device. Presets still work.`);
  if (ui.favFull) n = notice('star', `<b>Favourites holds five presets.</b> Remove one in Preferences, or replace one now.`, `<button class="btn quiet small" data-act="overlay:favReplace">Replace…</button><button class="btn quiet small" data-act="dismiss">Not now</button>`);
  const amount = p ? (s.dev.amount[p.id] ?? 100) : 100;
  const lower = ui.amount && p
    ? `<div style="display:flex;align-items:center">${sl('Amount', amount, `dev.amount.${p.id}`)}<button class="btn quiet small" data-act="amountDone">Done</button></div>`
    : `<div class="ruler" data-ruler="${cur}" data-stop="${stop}" data-count="${list.length}"><div class="rtrack"></div><div class="rfade"></div><div class="needle"></div>${ui.fine ? '<div class="fine">Fine</div>' : ''}</div>`;
  return `${roomy ? '<div class="ptitle">Develop</div>' : ''}
    <div class="devhead"><button class="autoT ${autoCls}" data-act="toggleAuto" aria-label="Automatic correction">Auto</button>${roomy ? '' : cats}</div>
    ${roomy ? cats : ''}${n}
    <div class="namerow"><button class="star ${isFav ? 'on' : ''}" data-act="star" aria-label="Favourite" ${p ? '' : 'style="visibility:hidden"'}>${icon('star', 20)}</button>
      <div class="lookname" data-name>${p ? p.name : base}</div><div class="pos" data-pos>${stop} / ${list.length}</div>
      <button class="amount" data-act="amount" ${p ? '' : 'style="visibility:hidden"'}>Amount ${Math.round(amount)}</button></div>
    <div class="context" data-ctx>${ctx}</div>${lower}`;
}

function backgroundPanel(s, ui, L) {
  const b = s.bg, mode = ui.sub || 'focus', ph = PHOTOS[s.photo];
  let h = `${L.roomy ? '<div class="ptitle">Background</div>' : ''}${seg([['focus', 'Focus &amp; Blur'], ['change', 'Change background']], mode === 'refine' ? 'focus' : mode, 'sub')}`;
  if (!ph.subject) return h + notice('info', `<b>No clear subject found.</b> Change background needs a person or object in front. You can still blur by tapping where to focus.`) + sl('Blur', b.blur, 'bg.blur');
  if (ui.op === 'separating') return h + notice('info', 'Finding the subject…', `<button class="btn quiet small" data-act="cancelOp">Cancel</button>`);
  if (ui.op === 'failed') return h + notice('warn', `<b>Couldn't separate the subject.</b> Your other edits are kept.`, `<button class="btn quiet small" data-act="retryOp">Try again</button>`);
  if (mode === 'refine') return h + `<div class="note">Brush over the edge to add to or remove from the subject.</div>` + seg([['add', `${icon('brush', 16)}&nbsp;Add`], ['erase', `${icon('erase', 16)}&nbsp;Remove`]], ui.brush || 'add', 'brush') + sl('Brush size', 40, 'ui.brushSize') + `<div style="display:flex;justify-content:flex-end;padding:0 10px"><button class="btn quiet" data-act="sub:focus">Done</button></div>`;
  if (mode === 'change') {
    const kind = ui.bgKind || (b.replaced ? b.replaced.type : 'image');
    let opts = '';
    if (kind === 'image') opts = `<div class="chiprow">${BACKGROUNDS.map(src => `<button class="thumbopt ${b.replaced && b.replaced.value === src ? 'on' : ''}" style="background-image:url(${src})" data-act="bgImage:${src}" aria-label="Background image"></button>`).join('')}<button class="thumbopt add" data-act="noop" aria-label="Choose a photo">${icon('plus')}</button></div>`;
    if (kind === 'colour') opts = `<div class="chiprow">${SWATCHES.map(c => `<button class="sw ${b.replaced && b.replaced.value === c ? 'on' : ''}" style="background:${c}" data-act="bgColour:${c}" aria-label="Colour ${c}"></button>`).join('')}</div>`;
    if (kind === 'gradient') opts = `<div class="chiprow">${GRADIENTS.map(g => `<button class="sw ${b.replaced && b.replaced.value === g ? 'on' : ''}" style="background:${g};width:52px;border-radius:10px" data-act="bgGradient:${g}" aria-label="Gradient"></button>`).join('')}</div>`;
    return h + tabs([['image', 'Image'], ['colour', 'Colour'], ['gradient', 'Gradient']], kind, 'bgKind') + opts
      + (kind === 'image' && b.replaced ? sl('Scale', b.scale, 'bg.scale', 100, 200) + `<div class="note">Drag the photo to position the background.</div>` : '')
      + (b.replaced ? `<div style="display:flex;padding:0 6px"><button class="btn quiet small" data-act="removeBg">Remove background change</button></div>` : '')
      + (b.replaced ? `<div class="note">Focus &amp; Blur still works on the new background.</div>` : '');
  }
  const style = b.style;
  const extra = style === 'lens' ? `<div class="chiprow" style="align-items:center"><span style="min-width:72px;color:var(--ink2)">Bokeh</span>${[['round', 'circle'], ['hex', 'hex'], ['heart', 'heart'], ['star', 'starShape']].map(([k, ic]) => `<button class="opt ${b.bokeh === k ? 'on' : ''}" data-act="set:bg.bokeh=${k}" aria-label="${k} bokeh">${icon(ic, 18)}</button>`).join('')}</div>`
    : style === 'soft' ? sl('Glow', b.styleAmt, 'bg.styleAmt') : style === 'swirl' ? sl('Swirl', b.styleAmt, 'bg.styleAmt') : sl('Direction', b.styleAmt * 3.6 - 180, 'bg.styleAmt', -180, 180);
  return h + tabs([['lens', 'Lens'], ['soft', 'Soft'], ['swirl', 'Swirl'], ['motion', 'Motion']], style, 'bgStyle') + extra
    + sl('Blur', b.blur, 'bg.blur') + sl('Focus depth', b.depth, 'bg.depth')
    + `<div style="display:flex;align-items:center;padding:0 6px"><button class="btn quiet small" data-act="sub:refine">${icon('brush', 17)}Refine edges</button><span class="note" style="padding:0 8px">Tap the photo to set focus.</span></div>`;
}

function portraitPanel(s, ui, L) {
  const ph = PHOTOS[s.photo];
  if (!ph.faces.length) return `${L.roomy ? '<div class="ptitle">Portrait</div>' : ''}` + notice('info', `<b>No face can be edited in this photo.</b> Faces are too small, turned away or too dark. Portrait controls need a clear face.`);
  const faceStrip = ph.faces.length > 1 ? `<div class="chiprow" style="align-items:center">${ph.faces.map((f, i) => `<button class="opt ${i === s.face ? 'on' : ''}" data-act="face:${i}">Face ${i + 1}${countChanges(s.faces[i]) ? ` · ${countChanges(s.faces[i])}` : ''}</button>`).join('')}<span class="note">Each face keeps its own settings.</span></div>` : '';
  const sub = ui.sub || 'skin', f = s.faces[s.face], k = `faces.${s.face}`;
  let body = '';
  if (sub === 'skin') body = sl('Smoothing', f.skin.smooth, `${k}.skin.smooth`) + sl('Blemishes', f.skin.blemish, `${k}.skin.blemish`) + sl('Even tone', f.skin.tone, `${k}.skin.tone`) + sl('Keep texture', f.skin.texture, `${k}.skin.texture`)
    + `<div class="note">Blemish reduction is temporary marks only. Pores, freckles, moles and skin tone colour stay.</div>`;
  if (sub === 'under') body = sl('Brighten', f.under.bright, `${k}.under.bright`) + sl('Soften lines', f.under.soften, `${k}.under.soften`);
  if (sub === 'eyes') body = sl('Brighten', f.eyes.bright, `${k}.eyes.bright`) + sl('Clarity', f.eyes.clarity, `${k}.eyes.clarity`) + `<div class="note">Eye colour and shape are never changed.</div>`;
  if (sub === 'teeth') body = sl('Brighten', f.teeth.bright, `${k}.teeth.bright`) + `<div class="note">Stays within a natural range. There is no automatic whitening.</div>`;
  if (sub === 'hair') body = sl('Definition', f.hair.define, `${k}.hair.define`) + sl('Flyaways', f.hair.fly, `${k}.hair.fly`) + sl('Shine', f.hair.shine, `${k}.hair.shine`);
  return `${L.roomy ? '<div class="ptitle">Portrait</div>' : ''}${faceStrip}${tabs([['skin', 'Skin'], ['under', 'Under-eye'], ['eyes', 'Eyes'], ['teeth', 'Teeth'], ['hair', 'Hair &amp; Beard']], sub, 'sub')}${body}`;
}
const countChanges = (f) => Object.entries(f).reduce((n, [g, o]) => n + Object.entries(o).filter(([k, v]) => k === 'texture' ? v !== 85 : v).length, 0);

function editPanel(s, ui, L) {
  const sub = ui.sub || 'crop', e = s.edit;
  let body = '';
  if (sub === 'crop') body = `<div class="chiprow">${Object.keys(ASPECTS).map(a => `<button class="opt ${e.aspect === a ? 'on' : ''}" data-act="set:edit.aspect=${a}">${a === 'original' ? 'Original' : a === 'free' ? 'Free' : a}</button>`).join('')}</div><div class="note">Drag the corners to crop. Pinch to zoom.</div>`;
  if (sub === 'rotate') body = `<div class="chiprow">${[['rotl', 'Rotate left', 'rot=-90'], ['rotr', 'Rotate right', 'rot=90'], ['fliph', 'Flip horizontal', 'flipH'], ['flipv', 'Flip vertical', 'flipV']].map(([ic, l, a]) => `<button class="opt" data-act="geom:${a}">${icon(ic, 18)}${l}</button>`).join('')}</div>`;
  if (sub === 'straighten') body = sl('Angle', e.straighten, 'edit.straighten', -45, 45) + `<div class="note">The photo is zoomed slightly so no empty corners show.</div>`;
  if (sub === 'perspective') body = sl('Vertical', e.pv, 'edit.pv', -100, 100) + sl('Horizontal', e.ph, 'edit.ph', -100, 100);
  if (sub === 'adjust') {
    const g = ui.group || 'light', a = e.adj;
    body = tabs([['light', 'Light'], ['colour', 'Colour'], ['detail', 'Detail']], g, 'group')
      + (g === 'light' ? sl('Exposure', a.exposure, 'edit.adj.exposure', -100, 100) + sl('Contrast', a.contrast, 'edit.adj.contrast', -100, 100) + sl('Highlights', a.highlights, 'edit.adj.highlights', -100, 100) + sl('Shadows', a.shadows, 'edit.adj.shadows', -100, 100)
       : g === 'colour' ? sl('Temperature', a.temp, 'edit.adj.temp', -100, 100) + sl('Tint', a.tint, 'edit.adj.tint', -100, 100) + sl('Saturation', a.saturation, 'edit.adj.saturation', -100, 100) + sl('Vibrance', a.vibrance, 'edit.adj.vibrance', -100, 100)
       : sl('Sharpness', a.sharpness, 'edit.adj.sharpness') + sl('Clarity', a.clarity, 'edit.adj.clarity', -100, 100) + sl('Noise reduction', a.noise, 'edit.adj.noise'));
  }
  if (sub === 'remove') {
    if (ui.op === 'removing') body = notice('info', 'Removing…', `<button class="btn quiet small" data-act="cancelOp">Cancel</button>`);
    else if (ui.op === 'failed') body = notice('warn', `<b>Couldn't remove that area.</b> Try a smaller stroke. Your other edits are kept.`, `<button class="btn quiet small" data-act="retryOp">Try again</button>`);
    else body = sl('Brush size', 35, 'ui.brushSize') + `<div style="display:flex;align-items:center;padding:0 6px"><button class="btn quiet small" data-act="undoStroke" ${e.strokes ? '' : 'disabled style="opacity:.4"'}>Undo stroke</button><span class="note">Brush over anything you want removed.</span></div>`;
  }
  return `${L.roomy ? '<div class="ptitle">Edit</div>' : ''}${tabs([['crop', 'Crop'], ['rotate', 'Rotate'], ['straighten', 'Straighten'], ['perspective', 'Perspective'], ['adjust', 'Adjust'], ['remove', 'Remove']], sub, 'sub')}${body}`;
}

function effectsPanel(s, ui, L) {
  const sub = ui.sub || 'leak', fx = s.fx;
  const items = [['leak', 'Light Leaks', fx.leak.on ? 'dotted' : ''], ['grain', 'Grain', fx.grain.on ? 'dotted' : ''], ['vig', 'Vignette', fx.vig.on ? 'dotted' : '']];
  let body = '';
  const onRow = (k, on) => `<button class="listrow" style="border:0;min-height:44px;width:100%" data-act="fxToggle:${k}" aria-pressed="${on}"><span>${on ? 'On' : 'Off'}</span><span class="toggle ${on ? 'on' : ''}" style="margin-left:auto"></span></button>`;
  if (sub === 'leak') body = onRow('leak', fx.leak.on) + `<div class="chiprow">${[['warm', 'Warm edge'], ['amber', 'Amber flare'], ['rose', 'Rose'], ['prism', 'Prism']].map(([k, l]) => `<button class="opt ${fx.leak.style === k ? 'on' : ''}" data-act="set:fx.leak.style=${k}">${l}</button>`).join('')}</div>` + sl('Intensity', fx.leak.intensity, 'fx.leak.intensity') + sl('Rotation', fx.leak.rot, 'fx.leak.rot', -180, 180) + `<div class="note">Drag on the photo to move the leak.</div>`;
  if (sub === 'grain') body = onRow('grain', fx.grain.on) + `<div class="chiprow">${[['fine', 'Fine'], ['film', 'Film'], ['coarse', 'Coarse']].map(([k, l]) => `<button class="opt ${fx.grain.style === k ? 'on' : ''}" data-act="set:fx.grain.style=${k}">${l}</button>`).join('')}</div>` + sl('Amount', fx.grain.amount, 'fx.grain.amount') + sl('Size', fx.grain.size, 'fx.grain.size') + sl('Roughness', fx.grain.rough, 'fx.grain.rough');
  if (sub === 'vig') body = onRow('vig', fx.vig.on) + sl('Amount', fx.vig.amount, 'fx.vig.amount') + sl('Size', fx.vig.size, 'fx.vig.size') + sl('Softness', fx.vig.soft, 'fx.vig.soft');
  const presetFx = s.dev.applied && presetHasEffect(s.dev.applied.id);
  const conflict = presetFx && ((sub === 'grain' && fx.grain.on) || (sub === 'vig' && fx.vig.on)) ? notice('info', `The applied preset already includes its own ${sub === 'grain' ? 'grain' : 'vignette'}. This one is added to it, not replaced.`) : '';
  return `${L.roomy ? '<div class="ptitle">Effects</div>' : ''}${tabs(items, sub, 'sub')}${conflict}${body}`;
}
/* Which presets carry their own grain/vignette is not in the UI catalogue; the review marks this as an open question. */
const presetHasEffect = (id) => id.charCodeAt(id.length - 1) % 3 === 0;

function watermarkPanel(s, ui, L) {
  const w = s.wm, type = ui.sub || w.type;
  let body = '';
  const placement = s.border.type !== 'none' ? seg([['photo', 'On photo'], ['border', 'On border']], w.place, 'wmPlace') : `<div class="note">Add a border to place the watermark on it.</div>`;
  const POS = ['Top left', 'Top', 'Top right', 'Left', 'Centre', 'Right', 'Bottom left', 'Bottom', 'Bottom right'];
  // Position: one row (cycles through nine anchors) plus dragging on the photo; no tiny grid targets.
  const posgrid = w.place === 'border' && s.border.type !== 'none' ? '' : `<button class="listrow" style="width:100%;border:0;min-height:44px" data-act="set:wm.pos=${(w.pos + 1) % 9}"><span>Position</span><span class="end">${POS[w.pos]} ${icon('chevron', 16)}</span></button><div class="note" style="padding-top:0">Or drag the watermark on the photo.</div>`;
  const colours = `<div class="chiprow" style="align-items:center"><span style="min-width:84px;color:var(--ink2)">Colour</span>${['#FFFFFF', '#111111', '#C9A27E', '#8A8A8F'].map(c => `<button class="sw ${w.colour === c ? 'on' : ''}" style="background:${c}" data-act="set:wm.colour=${c}" aria-label="Colour"></button>`).join('')}</div>`;
  if (type === 'none') body = `<div class="note">No watermark. Choose Signature, Text or Logo to add one.</div>`;
  if (type === 'signature') body = `<div class="chiprow"><button class="opt ${w.sig === 'drawn' ? 'on' : ''}" data-act="set:wm.sig=drawn" style="min-width:120px">${sigSvg(26, 'currentColor')}</button><button class="opt ${w.sig === 'imported' ? 'on' : ''}" data-act="set:wm.sig=imported" style="min-width:120px">${sigSvg(26, '', true)}</button><button class="opt" data-act="overlay:sigDraw">${icon('plus', 18)}Draw</button><button class="opt" data-act="overlay:sigImport">${icon('photo', 18)}Import</button></div>
      <div class="note">Saved signatures keep their own look. ${w.sig === 'drawn' ? 'You can change the ink colour of a drawn signature.' : 'An imported signature keeps its own ink.'}</div>${placement}${posgrid}${sl('Size', w.size, 'wm.size', 10, 80)}${sl('Opacity', w.opacity, 'wm.opacity')}${w.sig === 'drawn' ? colours : ''}`;
  if (type === 'text') body = `<div class="listrow" style="border:0"><span style="color:var(--ink2)">Text</span><span class="end" style="color:var(--ink)">${w.text}</span></div>
      <div class="chiprow">${FONTS.map(([n, css]) => `<button class="fontopt ${w.font === n ? 'on' : ''}" data-act="set:wm.font=${n}"><span style="font-family:${css};font-size:20px">${w.text}</span><small>${n}</small></button>`).join('')}</div>${placement}${posgrid}${sl('Size', w.size, 'wm.size', 10, 80)}${sl('Opacity', w.opacity, 'wm.opacity')}${colours}`;
  if (type === 'logo') body = `<div class="chiprow" style="align-items:center"><span class="opt on">${LOGO(26, 'currentColor')}</span><button class="opt" data-act="noop">${icon('photo', 18)}Replace logo</button></div>${placement}${posgrid}${sl('Size', w.size, 'wm.size', 10, 80)}${sl('Opacity', w.opacity, 'wm.opacity')}`;
  return `${L.roomy ? '<div class="ptitle">Watermark</div>' : ''}${tabs([['none', 'None'], ['signature', 'Signature'], ['text', 'Text'], ['logo', 'Logo']], type, 'wmType')}${body}`;
}

function borderPanel(s, ui, L) {
  const b = s.border, type = ui.sub || b.type;
  const swatches = (path, cur, list) => `<div class="chiprow">${list.map(c => `<button class="sw ${cur === c ? 'on' : ''}" style="background:${c}" data-act="set:${path}=${c}" aria-label="Colour"></button>`).join('')}</div>`;
  let body = '';
  if (type === 'none') body = `<div class="note">No border. Your preferred border in Preferences is ${'None'}; it is never added automatically.</div>`;
  if (type === 'solid') body = swatches('border.colour', b.colour, ['#FFFFFF', '#F4F1EC', '#111111', '#3C4A55', '#C9A27E']) + sl('Width', b.width, 'border.width', 1, 15);
  if (type === 'frame') body = `<div class="note" style="padding-bottom:0">Frame</div>` + swatches('border.colour', b.colour, ['#111111', '#5A4636', '#C9C2B8', '#FFFFFF']) + sl('Frame width', b.width, 'border.width', 1, 10) + `<div class="note" style="padding-bottom:0">Mat</div>` + swatches('border.mat', b.mat, ['#F4F1EC', '#FFFFFF', '#1F2328']) + sl('Spacing', b.spacing, 'border.spacing', 0, 12);
  if (type === 'polaroid') body = swatches('border.colour', b.colour, ['#FFFFFF', '#F4F1EC', '#111111']) + `<div class="note">A wider bottom margin, as on an instant print.</div>
    <button class="listrow" style="border:0;width:100%" data-act="polaroidSig"><span>Signature on the margin</span><span class="toggle ${s.wm.place === 'border' && s.wm.type !== 'none' ? 'on' : ''}" style="margin-left:auto"></span></button>`;
  return `${L.roomy ? '<div class="ptitle">Border</div>' : ''}${tabs([['none', 'None'], ['solid', 'Solid'], ['frame', 'Photo Frame'], ['polaroid', 'Polaroid']], type, 'borderType')}${body}`;
}
const PANELS = { develop:developPanel, background:backgroundPanel, portrait:portraitPanel, edit:editPanel, effects:effectsPanel, watermark:watermarkPanel, border:borderPanel };
const TOOL_NAMES = { develop:'Develop', background:'Background', portrait:'Portrait', edit:'Edit', effects:'Effects', watermark:'Watermark', border:'Border' };

/* Portrait is contextual: offered only when the photo has a person. */
const toolsFor = (s) => Object.keys(TOOL_NAMES).filter(t => t !== 'portrait' || PHOTOS[s.photo].faces.length || PHOTOS[s.photo].people);
function toolUsed(s, t) {
  if (t === 'develop') return !!s.dev.applied; if (t === 'background') return !!(s.bg.replaced || s.bg.blur);
  if (t === 'portrait') return s.faces.some(f => countChanges(f)); if (t === 'edit') return s.edit.aspect !== 'original' || s.edit.rot || s.edit.flipH || s.edit.straighten || Object.values(s.edit.adj).some(Boolean) || s.edit.strokes;
  if (t === 'effects') return s.fx.leak.on || s.fx.grain.on || s.fx.vig.on; if (t === 'watermark') return s.wm.type !== 'none'; return s.border.type !== 'none';
}

/* ---------------------------------------------------------------- photo marks per tool */
function marksFor(s, ui) {
  const ph = PHOTOS[s.photo]; let m = '';
  if (ui.tool === 'portrait' && ph.faces.length) m += ph.faces.map((f, i) => `<button class="faceRing ${i === s.face ? '' : 'dim'}" data-act="face:${i}" style="left:${f.x * 100}%;top:${f.y * 100}%;width:${f.w * 100}%;height:${f.h * 100}%" aria-label="Face ${i + 1}">${ph.faces.length > 1 ? `<span class="tag">Face ${i + 1}</span>` : ''}</button>`).join('');
  if (ui.tool === 'portrait' && !ph.faces.length && ph.people) m += `<div class="faceRing dim" style="left:30%;top:58%;width:9%;height:6%"></div><div class="faceRing dim" style="left:56%;top:57%;width:8%;height:6%"></div>`;
  if (ui.tool === 'background' && (ui.sub || 'focus') === 'focus' && ph.subject) { const t = s.bg.target || ph.target || { x:ph.subject[0].cx, y:ph.subject[0].cy }; m += `<div class="target" style="left:${t.x * 100}%;top:${t.y * 100}%"></div>`; }
  if (ui.tool === 'background' && ui.sub === 'refine') { const mk = ph.subject.map(e => `radial-gradient(ellipse ${e.rx * 100}% ${e.ry * 100}% at ${e.cx * 100}% ${e.cy * 100}%, #000 72%, transparent 76%)`).join(','); m += `<div class="maskTint" style="-webkit-mask-image:${mk};mask-image:${mk}"></div>`; }
  if (ui.tool === 'edit' && (ui.sub || 'crop') === 'crop') m += `<div class="cropframe"><i style="left:-3px;top:-3px;border-right:0;border-bottom:0"></i><i style="right:-3px;top:-3px;border-left:0;border-bottom:0"></i><i style="left:-3px;bottom:-3px;border-right:0;border-top:0"></i><i style="right:-3px;bottom:-3px;border-left:0;border-top:0"></i><div class="grid3"></div></div>`;
  if (ui.tool === 'edit' && (ui.sub === 'straighten' || ui.sub === 'perspective')) m += `<div class="grid3"></div>`;
  if (ui.tool === 'edit' && ui.sub === 'remove' && s.edit.strokes) m += `<div class="stroke" style="left:62%;top:30%;width:16%;height:5%;transform:rotate(-12deg)"></div>`;
  if (ui.op === 'separating' || ui.op === 'removing') m += `<div class="progress"><div class="spinner"></div>${ui.op === 'separating' ? 'Finding the subject…' : 'Removing…'}<br><button class="btn" data-act="cancelOp">Cancel</button></div>`;
  return m;
}

/* ---------------------------------------------------------------- chrome */
function statusBar(dev, L, dark) {
  if (dev.os === 'android') return `<div class="sys" style="height:${dev.safe.top}px"><span>9:41</span><div class="punch"></div><span>${sysIcons()}</span></div>`;
  if (/ipad/.test(dev.id)) return `<div class="sys" style="height:${dev.safe.top}px;font-size:13px"><span>9:41&nbsp;&nbsp;Fri 2 Oct</span><span>${sysIcons()}</span></div>`;
  return `<div class="sys phone" style="height:${dev.safe.top}px"><span>9:41</span><div class="island"></div><span>${sysIcons()}</span></div>`;
}
const sysIcons = () => `<svg width="17" height="11" viewBox="0 0 18 12" fill="currentColor" style="vertical-align:-1px"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/><rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0" width="3" height="12" rx="1"/></svg>&nbsp;<svg width="25" height="12" viewBox="0 0 26 12" style="vertical-align:-1px"><rect x=".5" y=".5" width="22" height="11" rx="3.5" stroke="currentColor" fill="none" opacity=".4"/><rect x="2" y="2" width="17" height="8" rx="2" fill="currentColor"/></svg>`;
const closeIcon = (dev) => dev.os === 'android' ? icon('backA') : icon('close');

function topbar(s, ui, dev, part = 'all') {
  const canUndo = (ui.histPos ?? 0) > 0, canRedo = ui.histPos != null && ui.histLen != null && ui.histPos < ui.histLen - 1;
  const left = `<button class="ib" data-act="close" aria-label="${dev.os === 'android' ? 'Back' : 'Close'}">${closeIcon(dev)}</button>
    <button class="ib" data-act="undo" aria-label="Undo" ${canUndo || ui.demoUndo ? '' : 'disabled'}>${icon('undo')}</button>
    <button class="ib" data-act="redo" aria-label="Redo" ${canRedo ? '' : 'disabled'}>${icon('redo')}</button>
    <button class="ib ${ui.compare ? 'on' : ''}" data-act="compare" aria-label="Hold to compare with the original">${icon('compare')}</button>`;
  const right = `<button class="save" data-act="save">Save copy</button><button class="ib" data-act="overlay:more" aria-label="More">${icon('more')}</button>`;
  if (part === 'left') return left; if (part === 'right') return right;
  return `<div class="topbar">${left}<div class="grow"></div>${right}</div>`;
}
function toolNav(s, ui, kind) {
  const items = toolsFor(s).map(t => `<button class="tool ${t === ui.tool ? 'on' : ''} ${toolUsed(s, t) ? 'used' : ''}" data-act="tool:${t}">${icon(t)}<span>${TOOL_NAMES[t]}</span></button>`).join('');
  return kind === 'rail' ? `<nav class="rail" aria-label="Tools">${items}</nav>` : `<nav class="dock ${kind}" aria-label="Tools">${items}</nav>`;
}

/* ---------------------------------------------------------------- editor in every layout */
function editorHTML(s, ui, dev, L) {
  const tool = ui.tool || 'develop';
  const P = { roomy:false };
  const stage = (extra = '') => `<div class="stage" ${extra}>${photoHTML(s, { compare:ui.compare, marks:ui.compare ? '' : marksFor(s, ui) })}${ui.toast ? `<div class="toast">${ui.toast}</div>` : ''}</div>`;
  const panel = (roomy, style = '') => `<div class="panelbody ${roomy ? '' : ''} ${L.mode === 'wide' ? 'wrapped' : ''}" style="${style}">${PANELS[tool](s, ui, { roomy, wide:L.mode === 'wide' })}</div>`;
  const inset = `<div class="inset" style="height:${dev.safe.bottom}px"></div>`;
  // The panel never takes more than its share of the height: it scrolls, so the photo stays dominant.
  if (L.mode === 'below') return `${statusBar(dev, L)}${topbar(s, ui, dev)}${stage()}<div class="panel">${panel(false, `max-height:${Math.round(L.h * .34)}px`)}${toolNav(s, ui, 'scrolls')}${inset}</div>`;
  if (L.mode === 'wide') return `${statusBar(dev, L)}${topbar(s, ui, dev)}${stage()}<div class="panel">${panel(false, `width:${L.content}px;max-width:100%;margin:0 auto;padding-top:4px;max-height:${Math.round(L.h * .3)}px`)}${toolNav(s, ui, 'fits')}${inset}</div>`;
  if (L.mode === 'side') return `${statusBar(dev, L)}${topbar(s, ui, dev)}<div class="row grow">${stage()}<div class="panel sidepanel" style="width:${L.panel}px">${panel(true)}</div>${toolNav(s, ui, 'rail')}</div>${inset}`;
  if (L.mode === 'splitV') { const half = L.w / 2;
    return `${statusBar(dev, L)}<div class="topbar" style="padding:0"><div class="row" style="width:${half}px;padding-left:6px">${topbar(s, ui, dev, 'left')}</div><div class="grow"></div>${topbar(s, ui, dev, 'right')}</div>
      <div class="row grow"><div class="col" style="flex:0 0 ${half}px">${stage()}</div><div class="panel" style="flex:1;min-width:0">${panel(true)}</div>${toolNav(s, ui, 'rail')}</div>${inset}<div class="hinge v" style="left:${half - 1}px"></div>`; }
  // splitH: the photo fills the upper pane, controls the lower pane; nothing sits on the fold.
  const half = L.h / 2;
  // The whole upper half above the fold is photo; actions, controls and tools share the lower half.
  return `<div class="col" style="flex:0 0 ${half}px">${statusBar(dev, L)}${stage()}</div>
    <div class="col grow" style="padding-top:4px">${topbar(s, ui, dev)}<div class="panel grow" style="min-height:0">${panel(false, `width:${L.content}px;max-width:100%;margin:0 auto;flex:1 1 auto`)}${toolNav(s, ui, 'fits')}</div>${inset}</div><div class="hinge h" style="top:${half - 1}px"></div>`;
}

/* ---------------------------------------------------------------- non-editor screens */
function welcomeHTML(dev, L) {
  if (L.mode === 'splitV' || L.mode === 'splitH') {   // brand in one pane, actions in the other: nothing on the fold
    const v = L.mode === 'splitV';
    return `${statusBar(dev, L)}<div class="topbar"><div class="grow"></div><button class="ib" data-act="overlay:more" aria-label="More">${icon('more')}</button></div>
      <div class="foldsplit ${v ? '' : 'h'}"><div class="center"><div class="welcome" style="flex:0;gap:14px">${mark(56, 'currentColor')}<div class="word">Lightly</div><div class="tag">See it as you remember it.</div></div></div>
        <div class="center"><div class="welcome" style="flex:0;width:100%"><div class="actions" style="margin:0 auto"><button class="btn primary" data-act="go:picker">${icon('photo', 20)}Choose a photo</button><button class="btn line" data-act="go:camera-permission">${icon('camera', 20)}Camera</button></div><div class="priv">Your photos stay on your device by default.</div><button class="btn quiet privacy-link" data-act="welcomePrivacy">Privacy Policy</button></div></div></div>
      <div class="inset" style="height:${dev.safe.bottom}px"></div><div class="hinge ${v ? 'v' : 'h'}" style="${v ? `left:${L.w / 2 - 1}px` : `top:${L.h / 2 - 1}px`}"></div>`;
  }
  return `${statusBar(dev, L)}<div class="topbar"><div class="grow"></div><button class="ib" data-act="overlay:more" aria-label="More">${icon('more')}</button></div>
    <div class="welcome"><div class="brand">${mark(56, 'currentColor')}<div class="word">Lightly</div><div class="tag">See it as you remember it.</div></div>
      <div class="actions"><button class="btn primary" data-act="go:picker">${icon('photo', 20)}Choose a photo</button><button class="btn line" data-act="go:camera-permission">${icon('camera', 20)}Camera</button></div>
      <div class="priv">Your photos stay on your device by default.</div><button class="btn quiet privacy-link" data-act="welcomePrivacy">Privacy Policy</button><div style="height:${Math.max(28, L.h * .06)}px"></div></div>
    <div class="inset" style="height:${dev.safe.bottom}px"></div>`;
}
function launchHTML(dev, L) { return `${statusBar(dev, L)}<div class="grow center">${mark(64, 'currentColor')}</div>`; }
function pickerHTML(dev, L) {
  const cols = L.w > 700 ? 5 : 3;
  const grid = `<div class="pgrid" style="grid-template-columns:repeat(${cols},1fr)">${PICKER_ORDER.map(k => `<button style="background-image:url(${PHOTOS[k].thumb})" data-act="pick:${k}" aria-label="${PHOTOS[k].name}"></button>`).join('')}</div>`;
  if (dev.os === 'ios') {
    const body = `<div class="grab"></div><div class="sheethead" style="font-size:17px"><button class="btn quiet" style="padding:0 8px" data-act="go:welcome">Cancel</button><div class="grow">Photos</div><span style="width:70px"></span></div>
      <div class="seg" style="margin:4px 16px 8px"><button class="on">Photos</button><button>Collections</button></div>
      <div style="margin:0 16px 8px;height:36px;border-radius:10px;background:var(--bg2);display:flex;align-items:center;gap:6px;padding:0 10px;color:var(--ink3)">${icon('search', 18)}Search</div>${grid}`;
    return welcomeHTML(dev, L) + `<div class="scrim ${L.w > 700 ? 'middle' : ''}" data-system="1"><div class="sheet ${L.w > 700 ? 'form' : ''}" style="${L.w > 700 ? 'height:80%' : 'height:92%'}">${body}</div></div>`;
  }
  const body = `<div class="grab"></div><div class="sheethead"><button class="ib" data-act="go:welcome" aria-label="Cancel">${icon('close')}</button><div class="grow" style="text-align:left">Select a photo</div></div>
    <div class="seg" style="margin:4px 16px 10px;border-radius:20px"><button class="on" style="border-radius:18px">Photos</button><button style="border-radius:18px">Albums</button></div>${grid}`;
  return welcomeHTML(dev, L) + `<div class="scrim" data-system="1"><div class="sheet" style="height:${L.w > 700 ? '75%' : '90%'};${L.w > 700 ? 'width:720px;' : ''}border-radius:28px 28px 0 0">${body}</div></div>`;
}
function cameraHTML(dev, L, review) {
  const photo = PHOTOS.smile;
  const ios = dev.os === 'ios';
  const top = review ? '' : `<div style="height:${dev.safe.top + 8}px;display:flex;align-items:flex-end;justify-content:space-between;padding:0 18px 6px">${icon('flash')}<span style="font-size:13px;letter-spacing:.06em">${ios ? 'PHOTO' : ''}</span>${icon('close')}</div>`;
  const view = `<div style="flex:1;background:url(${photo.src}) center/cover"></div>`;
  const bottom = review
    ? (ios ? `<div style="height:110px;display:flex;align-items:center;justify-content:space-between;padding:0 28px"><button class="btn" style="color:#fff" data-act="go:camera">Retake</button><button class="btn" style="color:#fff" data-act="pickCamera">Use Photo</button></div>`
           : `<div style="height:110px;display:flex;align-items:center;justify-content:space-around"><button class="ib" style="color:#fff" data-act="go:camera" aria-label="Retake">${icon('close', 30)}</button><button class="ib" style="color:#fff" data-act="pickCamera" aria-label="Use photo">${icon('check', 32)}</button></div>`)
    : `<div style="height:150px;display:flex;align-items:center;justify-content:center;gap:60px"><button class="ib" style="color:#fff" data-act="go:welcome" aria-label="Cancel">${ios ? '<span style="font-size:17px">Cancel</span>' : icon('close')}</button><button class="shutter" data-act="go:camera-review" aria-label="Take photo"></button><span style="width:44px"></span></div>`;
  return `<div class="camera" data-system="1">${top}${view}${bottom}</div>`;
}
function systemDialog(dev, title, body, buttons, pane = '', system = false) {   // platform alert conventions
  const attrs = `class="scrim middle ${pane}" ${system ? 'data-system="1"' : ''}`;
  if (dev.os === 'ios') return `<div ${attrs}><div class="dialog"><h3>${title}</h3><p>${body}</p><div class="acts">${buttons.map(([l, a, cls]) => `<button class="${cls || ''}" data-act="${a}">${l}</button>`).join('')}</div></div></div>`;
  return `<div ${attrs}><div class="dialog md"><h3>${title}</h3><p>${body}</p><div class="acts">${buttons.map(([l, a, cls]) => `<button class="${cls || ''}" style="color:var(--sel)" data-act="${a}">${l}</button>`).join('')}</div></div></div>`;
}
function loadingHTML(s, dev, L, phase) {
  const label = phase === 'loading' ? 'Opening photo…' : 'Developing…<br><span style="opacity:.75;font-size:13px">Applying thoughtful enhancements.</span>';
  const fold = L.mode === 'splitV' ? `style="margin-right:${L.w / 2}px"` : L.mode === 'splitH' ? `style="flex:0 0 ${L.h / 2 - dev.safe.top - 48}px"` : '';
  return `${statusBar(dev, L)}<div class="topbar"><button class="ib" data-act="go:welcome" aria-label="Cancel">${closeIcon(dev)}</button></div>
    <div class="stage" ${fold}>${photoHTML({ ...s, auto:'off' }, { marks:`<div class="progress"><div class="spinner"></div>${label}<div class="bar"><i style="width:${phase === 'loading' ? 30 : 70}%"></i></div></div>` })}</div>
    <div style="height:${L.mode === 'side' || L.mode === 'splitV' ? 20 : L.mode === 'splitH' ? L.h / 2 - dev.safe.bottom : 120}px"></div><div class="inset" style="height:${dev.safe.bottom}px"></div>`;
}
function messageScreen(dev, L, title, body, actions) {
  const head = `${icon('photo', 44)}<h2 style="font-size:calc(20px * var(--ts));margin:16px 0 8px;font-weight:600">${title}</h2><p style="color:var(--ink2);margin:0">${body}</p>`;
  const acts = `<div style="display:grid;gap:8px;width:min(380px,100%)">${actions}</div>`;
  const back = `${statusBar(dev, L)}<div class="topbar"><button class="ib" data-act="go:welcome" aria-label="Back">${closeIcon(dev)}</button></div>`;
  if (L.mode === 'splitV' || L.mode === 'splitH') {   // message in one pane, actions in the other
    const v = L.mode === 'splitV';
    return `${back}<div class="foldsplit ${v ? '' : 'h'}"><div class="center" style="padding:24px;text-align:center"><div style="max-width:360px">${head}</div></div><div class="center" style="padding:24px">${acts}</div></div>
      <div class="inset" style="height:${dev.safe.bottom}px"></div><div class="hinge ${v ? 'v' : 'h'}" style="${v ? `left:${L.w / 2 - 1}px` : `top:${L.h / 2 - 1}px`}"></div>`;
  }
  return `${back}<div class="grow center" style="padding:24px;text-align:center"><div style="max-width:380px;display:grid;justify-items:center;gap:20px"><div>${head}</div>${acts}</div></div><div class="inset" style="height:${dev.safe.bottom}px"></div>`;
}

/* More, preferences, legal, about: full pages on phones; form sheets on larger screens. */
function morePage(page, s, ui) {
  const row = (label, sub, act, end = icon('chevron', 18)) => `<button class="listrow" style="width:100%" data-act="${act}"><div><div>${label}</div>${sub ? `<div class="sub">${sub}</div>` : ''}</div><span class="end">${end}</span></button>`;
  const pages = {
    more:{ t:'More', b:row('Preferences', '', 'page:preferences') + row('Legal', '', 'page:legal') + row('About', '', 'page:about') },
    preferences:{ t:'Preferences', back:'more', b:`<div class="group">Appearance</div>${seg([['system', 'System'], ['light', 'Light'], ['dark', 'Dark']], ui.appearance || 'system', 'appearance')}
      <div class="group">Shortcuts</div>${row('Favourite presets', `${s.favs.length} of 5 · shortcuts, never applied automatically`, 'page:favourites')}${row('Saved signature', 'Reused only when you choose it', 'page:signature')}
      <div class="group">Saving</div>${row('Preferred border', 'None', 'page:prefborder', `None ${icon('chevron', 18)}`)}<button class="listrow export-pref" role="switch" aria-checked="${ui.metadata !== false}" aria-label="Keep photo metadata" data-act="toggleMetadata"><div><div>Keep photo metadata</div><div class="sub">Camera, lens, aperture, shutter speed, ISO and date taken. Location is separate.</div></div><span aria-hidden="true" class="toggle ${ui.metadata !== false ? 'on' : ''}" style="margin-left:auto"></span></button><button class="listrow export-pref" role="switch" aria-checked="${!!ui.location}" aria-label="Include location" data-act="toggleLocation"><div><div>Include location</div><div class="sub">GPS coordinates in saved copies. Off by default.</div></div><span aria-hidden="true" class="toggle ${ui.location ? 'on' : ''}" style="margin-left:auto"></span></button>` },
    favourites:{ t:'Favourite presets', back:'preferences', b:`<div class="note">Up to five. Drag to reorder. Favourites are shortcuts in Develop; they are never applied automatically.</div>${s.favs.map(id => { const p = PRESET.get(id); return `<div class="listrow"><span class="handle">${icon('grip', 18)}</span><div><div>${p.name}</div><div class="sub">${CAT.categories.find(c => c.id === p.cat).name}</div></div><button class="ib" style="margin-left:auto" data-act="unfav:${id}" aria-label="Remove">${icon('trash', 18)}</button></div>`; }).join('')}${s.favs.length < 5 ? `<div class="note">${5 - s.favs.length} free. Star a preset in Develop to add it.</div>` : ''}` },
    signature:{ t:'Saved signature', back:'preferences', b:`<div style="padding:24px 18px;display:grid;place-items:center;border-bottom:1px solid var(--hair)">${sigSvg(54, 'var(--ink)')}</div>${row('Draw a new signature', '', 'overlay:sigDraw')}${row('Import from a photo', '', 'overlay:sigImport')}<button class="listrow" style="width:100%;color:var(--danger)" data-act="noop">Delete saved signature</button><div class="note">A saved signature is added only when you choose it in Watermark.</div>` },
    prefborder:{ t:'Preferred border', back:'preferences', b:`${['None', 'Solid', 'Photo Frame', 'Polaroid'].map((n, i) => `<div class="listrow"><span>${n}</span>${i === 0 ? `<span class="end" style="color:var(--sel)">${icon('check', 20)}</span>` : ''}</div>`).join('')}<div class="note">Opens first in Border. It is never added to a photo automatically.</div>` },
    legal:{ t:'Legal', back:'more', b:row('Privacy Policy', '', 'page:privacy') + row('Terms of Use', '', 'page:terms') },
    privacy:{ t:'Privacy Policy', back:'legal', b:`<div class="drafttext" style="padding-top:8px"><div class="group">Privacy Policy</div>${'<i></i>'.repeat(5)}<i style="width:60%"></i><div class="group">Photos</div>${'<i></i>'.repeat(4)}<i style="width:40%"></i></div>` },
    terms:{ t:'Terms of Use', back:'legal', b:`<div class="drafttext" style="padding-top:8px"><div class="group">Terms of Use</div>${'<i></i>'.repeat(6)}<i style="width:55%"></i><div class="group">Your content</div>${'<i></i>'.repeat(3)}<i style="width:45%"></i></div>` },
    about:{ t:'About', back:'more', b:`<div style="display:grid;place-items:center;gap:8px;padding:28px 0 18px">${mark(44, 'currentColor')}<div style="font-weight:600;font-size:calc(19px * var(--ts))">Lightly</div><div class="sub" style="color:var(--ink3)">Version 1.0 (1)</div></div>${row('Support', '', 'page:support')}` },
    support:{ t:'Support', back:'about', b:`<div class="note" style="padding-top:14px">Questions or a problem with a photo? Contact us and include your version number.</div><div style="padding:8px 18px"><button class="btn primary" data-act="noop">Contact support</button></div><div class="listrow"><span>Version</span><span class="end">1.0 (1)</span></div>` },
  };
  const p = pages[page];
  return `<div class="page"><div class="head">${p.back ? `<button class="ib" data-act="${page === 'privacy' && ui.privacyFromWelcome ? 'closeWelcomePrivacy' : 'page:' + p.back}" aria-label="Back">${icon('back')}</button>` : `<button class="ib" data-act="closeMore" aria-label="Close">${icon('close')}</button>`}<h2>${p.t}</h2></div><div class="scroll">${p.b}</div></div>`;
}

/* ---------------------------------------------------------------- overlays on top of a base screen */
function overlayHTML(name, s, ui, dev, L) {
  const pane = L.mode === 'splitV' ? 'paneR' : L.mode === 'splitH' ? 'paneB' : '';
  const big = L.w > 700 && !pane;
  const sheet = (inner, h = 'auto') => `<div class="scrim ${big ? 'middle' : ''} ${pane}"><div class="sheet ${big ? 'form' : ''}" style="height:${pane ? 'auto' : h};${pane ? 'max-height:100%' : ''}">${big ? '' : '<div class="grab"></div>'}${inner}</div></div>`;
  const dlg = (t, b, btns) => systemDialog(dev, t, b, btns, pane);
  switch (name) {
    case 'more': case 'page': return sheet(morePage(ui.page || 'more', s, ui), big ? '70%' : '92%');
    case 'leave': return dlg( 'Leave without saving?', 'Your original photo is unchanged. Edits that are not saved as a copy will be lost.', [['Save copy', 'save', 'b'], ['Discard edits', 'discard', 'd'], ['Keep editing', 'dismiss']]);
    case 'savePerm': return systemDialog(dev, '“Lightly” Would Like to Add to your Photos', 'Lightly saves your exported photos to your library. It never reads your library — choosing a photo uses Apple\'s own picker.', [['Don’t Allow', 'go:save-permission-denied'], ['Allow', 'go:saving', 'b']], '', true);
    case 'saveDenied': return dlg( 'Can’t save to Photos', 'Allow Lightly to add photos in Settings. Your edits are kept.', [['Open Settings', 'dismiss', 'b'], ['Not now', 'dismiss']]);
    case 'storage': return dlg( 'Not enough storage', 'Free up some space and try again. Your edits are kept.', [['Try again', 'go:saving', 'b'], ['OK', 'dismiss']]);
    case 'exportFail': return dlg( 'Couldn’t save the copy', 'Something went wrong while saving. Your edits are kept and the original is unchanged.', [['Try again', 'go:saving', 'b'], ['Keep editing', 'dismiss']]);
    case 'saving': return `<div class="scrim middle ${pane}" style="background:var(--scrim)"><div class="progress" style="position:static;transform:none"><div class="spinner"></div>Saving a copy…<div class="bar"><i></i></div><button class="btn" data-act="dismiss">Cancel</button></div></div>`;
    case 'saved': return sheet(`<div style="text-align:center;padding:8px 18px 0"><div style="display:flex;justify-content:center;color:var(--sel);margin-bottom:8px">${icon('check', 30)}</div><div style="font-weight:600;font-size:calc(18px * var(--ts))">Saved as a new photo</div><div style="color:var(--ink2);margin:4px 0 14px">The original is unchanged.</div></div>
        <div style="display:grid;gap:8px;padding:0 18px"><button class="btn primary" data-act="overlay:share">${icon('share', 20)}Share</button><button class="btn line" data-act="dismiss">Keep editing</button><button class="btn quiet" data-act="go:picker">Choose another photo</button></div>`);
    case 'share': return `<div class="scrim" data-system="1"><div class="sheet" style="${L.w > 700 ? 'width:560px;' : ''}"><div class="grab"></div>` + (`<div class="sheethead"><div style="display:flex;gap:10px;align-items:center"><span style="width:40px;height:40px;border-radius:8px;background:url(${PHOTOS[s.photo].thumb}) center/cover"></span><div style="font-size:15px">Lightly copy<div style="font-size:12.5px;color:var(--ink3);font-weight:400">JPEG</div></div></div><div class="grow"></div><button class="ib" data-act="overlay:saved" aria-label="Close">${icon('close')}</button></div>
        <div class="sharegrid">${['Messages', 'Mail', 'Files', 'Notes', 'More'].map(n => `<div><i></i>${n}</div>`).join('')}</div><div class="listrow" style="border-top:1px solid var(--hair)">Copy</div><div class="listrow">Save to Files</div>`) + `</div></div>`;
    case 'sigDraw': return sheet(`<div class="sheethead"><button class="btn quiet" data-act="dismiss">Cancel</button><div class="grow">Draw signature</div><button class="btn quiet" data-act="saveSig">Save</button></div>
        <div class="sigpad"><div class="line"></div><div style="position:absolute;left:24px;bottom:34px">${sigSvg(70, 'var(--ink)')}</div></div><div style="display:flex;padding:0 10px"><button class="btn quiet" data-act="noop">Clear</button><div class="grow"></div><span class="note">Saved for reuse. It keeps its own look.</span></div>`);
    case 'sigImport': return sheet(`<div class="sheethead"><button class="btn quiet" data-act="dismiss">Cancel</button><div class="grow">Import signature</div><button class="btn quiet" data-act="saveSigImported">Use</button></div>
        <div style="margin:10px 18px;height:170px;border-radius:12px;background:#F7F4EE;display:grid;place-items:center;position:relative">${sigSvg(70, '', true)}<div style="position:absolute;inset:14px;border:1.5px dashed var(--sel);border-radius:8px"></div></div><div class="note">The paper is removed. The ink keeps its original colour and texture.</div>`);
    case 'favReplace': return sheet(`<div class="sheethead"><button class="btn quiet" data-act="dismiss">Cancel</button><div class="grow">Replace a favourite</div><span style="width:70px"></span></div>${s.favs.map(id => `<button class="listrow" style="width:100%" data-act="replaceFav:${id}"><div>${PRESET.get(id).name}<div class="sub">${CAT.categories.find(c => c.id === PRESET.get(id).cat).name}</div></div><span class="end" style="color:var(--sel)">Replace</span></button>`).join('')}`);
    case 'cameraPerm': return dev.os === 'ios'
      ? systemDialog(dev, '“Lightly” Would Like to Access the Camera', 'Lightly uses the camera only when you choose to take a new photo. Nothing is captured until you tap the shutter.', [['Don’t Allow', 'go:camera-denied'], ['Allow', 'go:camera', 'b']], '', true)
      : systemDialog(dev, 'Allow Lightly to take pictures and record video?', '', [['While using the app', 'go:camera'], ['Only this time', 'go:camera'], ['Don’t allow', 'go:camera-denied']], '', true);
    default: return '';
  }
}

/* ---------------------------------------------------------------- full screen */
function screenHTML(spec, s, ui, dev, L) {
  let base = '';
  switch (spec.kind) {
    case 'launch': base = launchHTML(dev, L); break;
    case 'welcome': base = welcomeHTML(dev, L); break;
    case 'picker': base = pickerHTML(dev, L); break;
    case 'camera': base = cameraHTML(dev, L, false); break;
    case 'cameraReview': base = cameraHTML(dev, L, true); break;
    case 'loading': base = loadingHTML(s, dev, L, 'loading'); break;
    case 'developing': base = loadingHTML(s, dev, L, 'developing'); break;
    case 'cameraDenied': base = messageScreen(dev, L, 'Camera access is off', 'To take a photo in Lightly, allow camera access in Settings. You can still choose a photo from your library.', `<button class="btn primary" data-act="noop">Open Settings</button><button class="btn line" data-act="go:picker">Choose a photo instead</button>`); break;
    case 'loadFailed': base = messageScreen(dev, L, 'This photo can’t be opened', 'It may be in a format Lightly doesn’t support, or it couldn’t be downloaded. Your library is unchanged.', `<button class="btn primary" data-act="go:picker">Choose another photo</button><button class="btn line" data-act="go:loading">Try again</button>`); break;
    case 'page': base = (L.w > 700 ? welcomeHTML(dev, L) : `${statusBar(dev, L)}${morePage(ui.page, s, ui)}<div class="inset" style="height:${dev.safe.bottom}px"></div>`); break;
    default: base = editorHTML(s, ui, dev, L);
  }
  if (spec.kind === 'page' && L.w > 700) base += overlayHTML('page', s, ui, dev, L);
  if (ui.overlay) base += overlayHTML(ui.overlay, s, ui, dev, L);
  const home = dev.os === 'ios' || dev.os === 'android' ? '<div class="homebar"></div>' : '';
  return base + home;
}

/* Fit every photo inside its stage without cropping. */
function fitPhotos() { /* sizing is pure CSS now (see .pic); kept so callers stay simple */ }

/* Ruler: one tick per preset stop. Static renders park it; the prototype wires preview/commit. */
function buildRulers(root, live) {
  root.querySelectorAll('.ruler').forEach(rl => {
    const tr = rl.querySelector('.rtrack'), n = +rl.dataset.count, stop = +rl.dataset.stop;
    const half = tr.clientWidth / 2 - 6;
    tr.innerHTML = `<div style="flex:0 0 ${half}px"></div>` + Array.from({ length:n + 1 }, (_, i) => `<div class="tk ${i === 0 ? 'b' : i % 10 === 0 ? 'm' : ''}">${i % 50 === 0 && i ? `<span>${i}</span>` : ''}</div>`).join('') + `<div style="flex:0 0 ${half}px"></div>`;
    tr.scrollLeft = stop * 12;
    if (live) live(rl, tr, n);
  });
  root.querySelectorAll('.devhead .tabs, .tabs').forEach(t => { const on = t.querySelector('.on'); if (on && t.scrollWidth > t.clientWidth && !t.closest('.wrapped')) t.scrollLeft = Math.max(0, on.offsetLeft - 120); });
}
