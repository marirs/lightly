/* Lightly design review site: selectors, prototype, screen index, overview, coverage and notes. */

const LAYOUTS = DEVICES.flatMap(d => d.orient.map(o => ({ dev:d, orient:o, key:`${d.id}:${o}` })));
const st = Object.assign({ dev:'iphone17', orient:'portrait', theme:'light', text:'default', tab:'prototype', screen:'launch' },
  Object.fromEntries(new URLSearchParams(location.hash.slice(1))));
const dev = () => DEVICES.find(d => d.id === st.dev);
const save = () => { history.replaceState(null, '', '#' + new URLSearchParams(st).toString()); };
let proto = null;

/* ------------------------------------------------------------------ header */
function header() {
  const sel = document.getElementById('dev');
  const groups = [...new Set(DEVICES.map(d => d.cls))];
  sel.innerHTML = groups.map(g => `<optgroup label="${g}">${DEVICES.filter(d => d.cls === g).map(d => `<option value="${d.id}">${d.name} · ${d.os === 'ios' ? 'iOS' : 'Android'} · ${d.size[0]}×${d.size[1]}</option>`).join('')}</optgroup>`).join('');
  sel.value = st.dev; sel.onchange = () => { st.dev = sel.value; if (!dev().orient.includes(st.orient)) st.orient = dev().orient[0]; refresh(); };
  const segs = { orient:'orient', theme:'theme', text:'text' };
  for (const [key, id] of Object.entries(segs)) document.querySelectorAll(`#${id} button`).forEach(b => {
    b.classList.toggle('on', st[key] === b.dataset.v);
    if (key === 'orient') b.disabled = !dev().orient.includes(b.dataset.v);
    b.onclick = () => { if (b.disabled) return; st[key] = b.dataset.v; refresh(); };
  });
  const tabs = [['prototype', 'Prototype'], ['index', 'Screen index'], ['overview', 'Overview'], ['coverage', 'Coverage'], ['demo', 'Combined edit'], ['notes', 'Review notes']];
  document.getElementById('tabs').innerHTML = tabs.map(([k, l]) => `<button class="${st.tab === k ? 'on' : ''}" data-t="${k}">${l}</button>`).join('');
  document.querySelectorAll('#tabs button').forEach(b => b.onclick = () => { st.tab = b.dataset.t; refresh(); });
}
const SIM = `<div class="simnote"><b>Review note:</b> photo appearance (presets, Auto, blur, background replacement, skin, effects) is a simulation made with CSS. Lightly's real rendering is not shown, and none of the processing here works. Preset names, categories and order come unchanged from <code>presets/develop-design-ui.json</code>.</div>`;

/* ------------------------------------------------------------------ prototype */
function fitScale(L, maxW, maxH) { return Math.min(1, maxW / L.w, maxH / L.h); }
function renderPrototype(main) {
  const d = dev(), L = layoutFor(d, st.orient);
  main.innerHTML = `${SIM}<div class="protoWrap"><div id="ph" style="position:relative"><div class="stagehost" id="host"></div></div><aside class="side" id="side"></aside></div>`;
  const avail = Math.max(420, innerHeight - 170), sc = fitScale(L, Math.max(380, innerWidth - 640), avail);
  const host = document.getElementById('host'); host.style.transform = `scale(${sc})`;
  document.getElementById('ph').style.width = `${L.w * sc + 20}px`; document.getElementById('ph').style.height = `${L.h * sc + 20}px`;
  const requestedScreen = st.screen;
  proto = new Prototype(host, { dev:d, orient:st.orient, theme:st.theme, large:st.text === 'large', onChange:p => { st.screen = p.spec.id; save(); sideInfo(p); } });
  if (requestedScreen && requestedScreen !== 'launch') proto.open(requestedScreen);
}
function sideInfo(p) {
  const d = dev(), L = layoutFor(d, st.orient), spec = p.spec;
  const journeys = [['Start at the beginning', 'launch'], ['Choose a photo', 'picker'], ['Camera', 'camera-permission'], ['Combined edit', 'demo-1'], ['Preferences', 'preferences']];
  document.getElementById('side').innerHTML = `<h2>${spec.t}</h2>
    <div class="meta">${d.name} (${d.os === 'ios' ? 'iOS' : 'Android'}) · ${st.orient} · ${L.w}×${L.h} · layout: ${({ below:'controls below the photo', wide:'centred controls below a large photo', side:'side panel and tool rail', splitV:'one pane each side of the vertical fold', splitH:'photo above, controls below the horizontal fold' })[L.mode]}<br>${d.source}</div>
    ${spec.missing ? `<div class="simnote" style="background:#FDECEC;border-color:#F3B4B4;color:#8A1C1C"><b>Not fully shown:</b> ${spec.missing}</div>` : ''}
    <div><b>Try it:</b> every control on the device is live. Tools switch without reopening the photo, and edits accumulate. Undo and Redo step through the session's history. Hold Compare to see the original. Close (or Android Back) with edits opens the leave dialog.</div>
    <h2 style="margin-top:16px">Jump to</h2><ol>${journeys.map(([l, id]) => `<li><button class="lk" data-open="${id}">${l}</button></li>`).join('')}</ol>
    <div class="meta">The Screen index lists every screen and state.</div>`;
  document.querySelectorAll('[data-open]').forEach(b => b.onclick = () => { st.screen = b.dataset.open; proto.open(b.dataset.open); });
}

/* ------------------------------------------------------------------ index */
function renderIndex(main) {
  const d = dev();
  main.innerHTML = `${SIM}<p>${S.length} screens and states. Each one opens in the prototype on the selected device (${d.name}, ${st.orient}, ${st.theme}). <span class="tagr">recovery</span> marks recovery states. <span class="tagm">gap</span> marks something that cannot be fully shown yet.</p>
    <div class="idx">${Object.entries(J).map(([k, title]) => {
      const list = k === 'recovery' ? S.filter(x => x.rec) : S.filter(x => x.j === k);
      return `<section><h3>${title}</h3><ul>${list.map(x => `<li><button class="lk" data-open="${x.id}" ${applies(x, d) ? '' : 'disabled style="color:#aaa"'}>${x.t}</button>${x.rec && k !== 'recovery' ? '<span class="tagr">recovery</span>' : ''}${x.missing ? '<span class="tagm">gap</span>' : ''}${applies(x, d) ? '' : ' <span class="na">(iOS only)</span>'}</li>`).join('')}</ul></section>`; }).join('')}</div>`;
  main.querySelectorAll('[data-open]').forEach(b => b.onclick = () => { st.screen = b.dataset.open; st.tab = 'prototype'; refresh(); });
}

/* ------------------------------------------------------------------ static frame (overview, demo, checks) */
function staticFrame(spec, d, orient, theme, large, maxW, maxH, extraState) {
  const L = layoutFor(d, orient), { s, ui } = extraState || stateFor(spec);
  const sc = Math.min(maxW / L.w, maxH / L.h);
  const wrap = document.createElement('div'); wrap.className = 'ovitem';
  wrap.innerHTML = `<div class="ovframe" style="width:${L.w * sc}px;height:${L.h * sc}px"><div class="dv ${theme} ${d.os} ${large ? 'large' : ''}" style="width:${L.w}px;height:${L.h}px;transform:scale(${sc})">${screenHTML(spec, s, ui, d, L)}</div></div><div class="cap">${spec.t}</div>`;
  return wrap;
}
function finishFrames(root) { root.querySelectorAll('.dv').forEach(dv => { fitPhotos(dv); buildRulers(dv); }); }

function renderOverview(main) {
  const d = dev(), L = layoutFor(d, st.orient);
  main.innerHTML = `${SIM}<p>Every screen for <b>${d.name}</b> (${st.orient}, ${st.theme}${st.text === 'large' ? ', large text' : ''}), grouped by journey. Click a frame to open it in the prototype.</p><div class="ov" id="ov"></div>`;
  const ov = document.getElementById('ov'), maxW = L.w > L.h ? 420 : 240, maxH = 420;
  for (const [k, title] of Object.entries(J)) {
    if (k === 'recovery') continue;
    const list = S.filter(x => x.j === k && applies(x, d)); if (!list.length) continue;
    const h = document.createElement('h3'); h.textContent = title; ov.appendChild(h);
    const g = document.createElement('div'); g.className = 'ovgrid'; ov.appendChild(g);
    list.forEach(spec => { const f = staticFrame(spec, d, st.orient, st.theme, st.text === 'large', maxW, maxH); f.onclick = () => { st.screen = spec.id; st.tab = 'prototype'; refresh(); }; g.appendChild(f); });
  }
  finishFrames(ov);
}

function renderDemo(main) {
  const d = dev(), L = layoutFor(d, st.orient);
  main.innerHTML = `${SIM}<p>One session on one photo: Develop preset, then background replacement, then focus and blur on the new background, then a Portrait adjustment, an effect, a signature and a Polaroid border, then the new JPEG. Each step keeps every earlier edit. The dots on the tool icons show which tools hold edits. To click through the same flow live, open it in the Prototype (Combined edit).</p><div class="demo" id="demo"></div>`;
  const box = document.getElementById('demo');
  S.filter(x => x.j === 'demo').forEach(spec => box.appendChild(staticFrame(spec, d, st.orient, st.theme, st.text === 'large', L.w > L.h ? 460 : 260, 460)));
  finishFrames(box);
}

/* ------------------------------------------------------------------ automated checks */
const SCROLLERS = '.tabs, .chiprow, .dock, .rtrack, .pgrid, .sharegrid, .page .scroll, .catlist, .panelbody';
function checkFrame(dv, spec, s, d, L) {
  const issues = [], R = dv.getBoundingClientRect(), sc = R.width / L.w;
  const overlay = dv.querySelector('.scrim');
  const scope = overlay || dv;
  const visible = el => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; };
  const inScroller = el => !!el.closest(SCROLLERS);
  // 1. Controls cut off by their panel, outside the screen, or too small.
  scope.querySelectorAll('[data-act]').forEach(el => {
    if (!visible(el)) return;
    const r = el.getBoundingClientRect(), w = r.width / sc, h = r.height / sc;
    if (!inScroller(el)) {
      if (r.left < R.left - 1 || r.right > R.right + 1 || r.top < R.top - 1 || r.bottom > R.bottom + 1) issues.push(['offscreen', label(el)]);
      const clip = el.closest('.panelbody, .sheet, .page .scroll');
      if (clip) { const c = clip.getBoundingClientRect(); if (r.bottom > c.bottom + 1 || r.top < c.top - 1) issues.push(['cut off', label(el)]); }
    }
    if ((w < 43.5 || h < 43.5) && !el.classList.contains('faceRing')) issues.push(['small target', `${label(el)} ${Math.round(w)}×${Math.round(h)}`]);
  });
  // 2. Text clipped (overflowing a fixed box outside a scroller).
  scope.querySelectorAll('button, span, div, h2, h3, p').forEach(el => {
    if (!visible(el) || inScroller(el) || !el.childNodes.length || ![...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim())) return;
    if (el.scrollWidth > el.clientWidth + 1 && getComputedStyle(el).overflow !== 'visible') issues.push(['clipped text', el.textContent.trim().slice(0, 40)]);
    const r = el.getBoundingClientRect(); if (r.right > R.right + 1 || r.left < R.left - 1) issues.push(['text outside screen', el.textContent.trim().slice(0, 40)]);
  });
  // 3. Contrast of text against its own surface (photo-backed text is skipped: it sits on scrims or badges).
  scope.querySelectorAll('button, span, div, h2, h3, p, label').forEach(el => {
    if (!visible(el) || ![...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()) || el.closest('.stage, .camera, .progress, .toast, .badge, .wm, .faceRing, .fontopt')) return;
    const cs = getComputedStyle(el), fg = rgb(cs.color), bg = surface(el); if (!fg || !bg) return;
    const ratio = contrast(fg, bg), size = parseFloat(cs.fontSize), bold = +cs.fontWeight >= 600;
    const need = (size >= 24 || (size >= 18.6 && bold)) ? 3 : 4.5;
    if (ratio < need && !el.closest('[disabled]')) issues.push(['contrast', `${el.textContent.trim().slice(0, 30)} ${ratio.toFixed(2)}:1`]);
  });
  // 4. Photo is dominant in the editor (shown whole, never cropped to fill).
  // The photo area (stage) keeps most of the screen; the photo inside is contain-fitted, so a wide photo on a tall
  // screen is correctly smaller. The photo must fill the stage in one dimension (shown whole, as large as it fits).
  let share = null;
  const stage = dv.querySelector('.stage'), pic = stage && stage.querySelector('.pic');
  if (pic && spec.kind === 'editor') {
    const a = stage.getBoundingClientRect(), p = pic.getBoundingClientRect(); share = (a.width * a.height) / (R.width * R.height);
    const min = L.mode === 'splitV' || L.mode === 'splitH' ? .3 : L.mode === 'side' ? .55 : dv.classList.contains('large') ? .36 : .4;
    if (share < min) issues.push(['small photo area', `${Math.round(share * 100)}% of the screen`]);
    if (Math.abs(p.width - a.width) > 2 && Math.abs(p.height - a.height) > 2) issues.push(['photo not fitted', '']);
    if (p.width > a.width + 2 || p.height > a.height + 2) issues.push(['photo cropped', `${Math.round(p.width)}×${Math.round(p.height)} in ${Math.round(a.width)}×${Math.round(a.height)}`]);
    // The image itself must fill the photo box, not render at its natural size inside it.
    const imgs = pic.querySelectorAll('.imgbox img'), img = imgs[imgs.length - 1], box = pic.querySelector('.imgbox');   // the sharp layer (a blurred background is scaled slightly on purpose)
    /* Straighten zooms the photo on purpose so no empty corners show. */
    if (img && box && !s.edit.straighten && !s.edit.rot) { const i = img.getBoundingClientRect(), bx = box.getBoundingClientRect(); if (Math.abs(i.width - bx.width) > 2 || Math.abs(i.height - bx.height) > 2) issues.push(['image not fitted to its box', '']); }
  }
  // 4b. On the unfolded foldable the photo area itself never crosses the fold.
  if (d.hinge && stage) { const a = stage.getBoundingClientRect(), x0 = (a.left - R.left) / sc, x1 = (a.right - R.left) / sc, y0 = (a.top - R.top) / sc, y1 = (a.bottom - R.top) / sc;
    if ((L.mode === 'splitV' && x0 < L.w / 2 - 1 && x1 > L.w / 2 + 1) || (L.mode === 'splitH' && y0 < L.h / 2 - 1 && y1 > L.h / 2 + 1)) issues.push(['photo on hinge', '']); }
  // 5. Portrait is contextual.
  if (spec.kind === 'editor') {
    const ph = PHOTOS[s.photo], has = !!dv.querySelector('[data-act="tool:portrait"]'), should = ph.faces.length > 0 || !!ph.people;
    if (has !== should) issues.push(['portrait tool', should ? 'missing for a photo with people' : 'shown for a photo without people']);
  }
  // 6. A way back from every screen except Launch and Welcome.
  if (!['launch', 'welcome'].includes(spec.kind) && !(spec.kind === 'welcome')) {
    const back = dv.querySelector('[data-act^="close"], [data-act="go:welcome"], [data-act^="page:"], [data-act="dismiss"], [data-act="closeMore"], [data-act^="go:camera"], [data-act="overlay:saved"], [data-act="discard"]');
    if (!back && spec.kind !== 'camera' && spec.kind !== 'launch') issues.push(['no way back', '']);
  }
  // 7. Hinge and system gesture areas are clear of controls.
  scope.querySelectorAll('[data-act]').forEach(el => {
    if (!visible(el) || inScroller(el)) return; const r = el.getBoundingClientRect();
    const y0 = (r.top - R.top) / sc, y1 = (r.bottom - R.top) / sc, x0 = (r.left - R.left) / sc, x1 = (r.right - R.left) / sc;
    if (d.hinge && !el.closest('[data-system]')) { if (L.mode === 'splitV' && x0 < L.w / 2 && x1 > L.w / 2) issues.push(['on hinge', label(el)]); if (L.mode === 'splitH' && y0 < L.h / 2 && y1 > L.h / 2) issues.push(['on hinge', label(el)]); }
    if (!overlay && spec.kind !== 'camera' && spec.kind !== 'cameraReview' && y1 > L.h - d.safe.bottom + 1) issues.push(['gesture area', label(el)]);
  });
  return { issues: dedupe(issues), share };
}
const label = el => (el.getAttribute('aria-label') || el.textContent || el.dataset.act).trim().replace(/\s+/g, ' ').slice(0, 28);
const dedupe = a => { const m = new Map(); a.forEach(([t, d]) => m.set(t + '|' + d, [t, d])); return [...m.values()]; };
function rgb(c) { const m = c.match(/rgba?\(([^)]+)\)/); if (!m) return null; const p = m[1].split(',').map(Number); return p.length > 3 && p[3] === 0 ? null : p.slice(0, 3); }
/** Effective surface colour: composite every translucent background up the tree (a 10% tint is not opaque). */
function surface(el) {
  const stack = [];
  for (let e = el; e; e = e.parentElement) { const m = getComputedStyle(e).backgroundColor.match(/rgba?\(([^)]+)\)/); if (!m) continue; const p = m[1].split(',').map(Number); const a = p.length > 3 ? p[3] : 1; if (a > 0) stack.push([p[0], p[1], p[2], a]); if (a >= 1) break; }
  let c = [255, 255, 255]; for (const [r, g, b, a] of stack.reverse()) c = [r * a + c[0] * (1 - a), g * a + c[1] * (1 - a), b * a + c[2] * (1 - a)]; return c;
}
function lum([r, g, b]) { const f = v => { v /= 255; return v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; }; return .2126 * f(r) + .7152 * f(g) + .0722 * f(b); }
function contrast(a, b) { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + .05) / (y + .05); }

/** Every screen × every layout × theme × text size. Used by the Coverage tab and by the export script. */
async function runAllChecks(progress) {
  const out = {}, holder = document.createElement('div'); holder.style.cssText = 'position:absolute;left:-20000px;top:0'; document.body.appendChild(holder);
  for (const lay of LAYOUTS) for (const theme of ['light', 'dark']) for (const text of ['default', 'large']) {
    const key = `${lay.key}|${theme}|${text}`; out[key] = {};
    for (const spec of S) {
      if (!applies(spec, lay.dev)) { out[key][spec.id] = { na:true }; continue; }
      const L = layoutFor(lay.dev, lay.orient), { s, ui } = stateFor(spec);
      holder.innerHTML = `<div class="dv ${theme} ${lay.dev.os} ${text === 'large' ? 'large' : ''}" style="width:${L.w}px;height:${L.h}px">${screenHTML(spec, s, ui, lay.dev, L)}</div>`;
      const dv = holder.firstElementChild; fitPhotos(dv); buildRulers(dv);
      out[key][spec.id] = checkFrame(dv, spec, s, lay.dev, L);
    }
    progress && progress(key); await new Promise(r => setTimeout(r));
  }
  holder.remove(); return out;
}
/** Session preservation: switching tools never changes another tool's edits. */
function sessionSelfTest() {
  const host = document.createElement('div'); host.style.cssText = 'position:absolute;left:-20000px'; document.body.appendChild(host);
  const p = new Prototype(host, { dev:DEVICES[0], orient:'portrait', theme:'light', large:false });
  const results = [], snap = () => JSON.stringify({ dev:p.s.dev.applied, bg:p.s.bg, faces:p.s.faces, fx:p.s.fx, wm:p.s.wm, border:p.s.border });
  p.open('dev-preset'); p.s.photo = 'woman'; p.s.faces = newSession('woman').faces; const steps = [
    ['Develop preset applied', () => applyPreset(p.s, 'portrait', 13)],
    ['Background replaced', () => { p.act('tool:background'); p.s.bg.replaced = { type:'image', value:BACKGROUNDS[0] }; p.commit(); }],
    ['Focus and blur', () => { p.act('sub:focus'); p.s.bg.blur = 55; p.commit(); }],
    ['Portrait skin', () => { p.act('tool:portrait'); p.s.faces[0].skin.smooth = 20; p.commit(); }],
    ['Vignette', () => { p.act('tool:effects'); p.act('fxToggle:vig'); }],
    ['Signature', () => { p.act('tool:watermark'); p.act('wmType:signature'); }],
    ['Polaroid', () => { p.act('tool:border'); p.act('borderType:polaroid'); }],
    ['Category browsing does not change the preset', () => { const a = p.s.dev.applied.id; p.act('tool:develop'); p.act('cat:cinematic'); if (p.s.dev.applied.id !== a) throw new Error('preset changed'); }],
    ['Undo returns one step', () => { const before = p.pos; p.act('undo'); if (p.pos !== before - 1) throw new Error('undo'); p.act('redo'); }],
  ];
  let prev = snap();
  for (const [name, f] of steps) {
    try { const was = JSON.parse(prev); f(); const now = JSON.parse(snap());
      const lost = Object.keys(was).filter(k => k !== 'dev' && JSON.stringify(was[k]) !== JSON.stringify(now[k]) && !name.toLowerCase().includes(k === 'bg' ? 'background' : k === 'faces' ? 'portrait' : k === 'fx' ? 'vignette' : k === 'wm' ? 'signature' : k === 'border' ? 'polaroid' : '~') && !(k === 'bg' && name.startsWith('Focus')) && !(k === 'wm' && name === 'Polaroid'));
      results.push([name, lost.length ? `changed: ${lost.join(', ')}` : 'kept']); prev = JSON.stringify(now);
    } catch (e) { results.push([name, 'FAILED: ' + e.message]); }
  }
  host.remove(); return results;
}

function renderCoverage(main) {
  main.innerHTML = `${SIM}<p>Each required screen is checked on every supported layout, in light and dark and at default and large text: ${LAYOUTS.length} layouts × ${S.length} screens × 4. The checks cover:</p>
    <ul>
      <li>controls cut off by their panel or off screen;</li>
      <li>touch targets under 44 pt;</li>
      <li>clipped text;</li>
      <li>text contrast (4.5:1, or 3:1 for large text);</li>
      <li>the photo staying dominant;</li>
      <li>Portrait shown only when the photo has people;</li>
      <li>a way back from every screen;</li>
      <li>no controls on the hinge or in system gesture areas.</li>
    </ul>
    <p><button class="lk" id="run">Run all checks in this browser</button> <span id="prog"></span>. Results saved by the export script load automatically when present.</p><div id="selftest"></div><div id="cov"></div>`;
  const draw = (res) => {
    const cols = LAYOUTS.map(l => l.key);
    const cell = (sid, lk) => {
      const keys = ['light|default', 'dark|default', 'light|large', 'dark|large'].map(v => `${lk}|${v}`), rs = keys.map(k => res[k] && res[k][sid]).filter(Boolean);
      if (!rs.length) return '<td class="na">–</td>'; if (rs.every(r => r.na)) return '<td class="na">n/a</td>';
      const iss = rs.flatMap(r => r.issues || []); return iss.length ? `<td class="bad" title="${iss.map(i => i.join(': ')).join('\n').replace(/"/g, '')}">${iss.length}</td>` : '<td class="ok">✓</td>';
    };
    document.getElementById('cov').innerHTML = `<table class="cov"><thead><tr><th>Screen</th>${LAYOUTS.map(l => `<th>${l.dev.name.replace('Pixel 9 Pro Fold · ', 'Fold ')}<br>${l.orient}</th>`).join('')}</tr></thead><tbody>
      ${S.map(sp => `<tr><td>${sp.t}${sp.missing ? ' <span class="tagm">gap</span>' : ''}</td>${cols.map(c => cell(sp.id, c)).join('')}</tr>`).join('')}</tbody></table>
      <p class="na">✓ means no issues in any of the four theme and text combinations. A number counts the issues; hover to see them. n/a means the screen does not apply on that platform (iOS-only system permission).</p>`;
  };
  fetch('coverage.json').then(r => r.ok ? r.json() : null).then(j => j && draw(j.results)).catch(() => {});
  document.getElementById('run').onclick = async () => { const res = await runAllChecks(k => document.getElementById('prog').textContent = `checking ${k}…`); document.getElementById('prog').textContent = 'done'; draw(res); };
  const t = sessionSelfTest();
  document.getElementById('selftest').innerHTML = `<h3 style="font-size:14px;margin:10px 0 4px">One-session check (switching tools keeps every other edit)</h3><ul>${t.map(([n, r]) => `<li>${n}: <span class="${r === 'kept' ? 'ok' : 'bad'}">${r}</span></li>`).join('')}</ul>`;
}

function renderNotes(main) {
  main.innerHTML = `<div class="notes"><h2 style="margin-top:0">Review notes</h2>${SIM}
  <h3>Device coverage (verified logical sizes)</h3><ul>${DEVICES.map(d => `<li><b>${d.cls}:</b> ${d.name} (${d.os === 'ios' ? 'iOS' : 'Android'}), ${d.size[0]}×${d.size[1]}, ${d.orient.join(' and ')}. Source: ${d.source}.</li>`).join('')}
    <li>Phones and folded foldables are portrait only, so there is no phone-landscape design. Desktop is deferred.</li>
    <li><b>13-inch Android tablet:</b> not shown. No verified 13-inch Android device profile is installed. The iPad Pro 13" layout uses the same layout rules.</li></ul>
  <h3>Draft content</h3><ul>
    <li>The Privacy Policy and Terms of Use pages show draft placeholders. No policy text has been written.</li>
    <li>Version and build ("1.0 (1)") are placeholders. Support shows a "Contact support" action whose destination is not decided.</li>
    <li>"Include location in saved copies" defaults to Off in this design. Please confirm the default.</li></ul>
  <h3>Open questions</h3><ul>
    <li><b>Effects and presets:</b> some presets contain their own grain or vignette. Which ones is not in the UI catalogue, so the prototype uses a stand-in rule to show the notice. Grain and vignette from Effects are added on top and the editor says so. Whether Effects should instead replace a preset's own grain or vignette is undecided.</li>
    <li><b>Multiple faces:</b> no licensed photograph with several people is available locally. The face picker is designed (one chip and ring per face, separate settings per face), but it can only be shown on a one-face photo. A licensed group photo is needed to show it properly.</li>
    <li><b>Category order:</b> the nine categories follow the supplied list. Favourites appears first as a shortcut.</li></ul>
  <h3>What the prototype simulates</h3><ul><li>Automatic Develop, preset looks, blur, subject separation, background replacement, skin adjustments, object removal, effects and saving are all CSS illustrations with timers. None of this processing is functional.</li>
    <li>The native photo picker, camera, share sheet and permission dialogs are drawn to each platform's conventions. They are representations, not the real system UI.</li></ul></div>`;
}

/* ------------------------------------------------------------------ boot */
function refresh() { save(); header(); const main = document.getElementById('main'); ({ prototype:renderPrototype, index:renderIndex, overview:renderOverview, coverage:renderCoverage, demo:renderDemo, notes:renderNotes })[st.tab](main); }
fetch('/presets/develop-design-ui.json').then(r => r.json()).then(d => {
  CAT = d;
  d.categories.forEach(c => c.presets.forEach(p => PRESET.set(p.id, { id:p.id, name:p.displayName, cat:c.id, stop:p.stop })));
  window.READY = true; refresh();
});
