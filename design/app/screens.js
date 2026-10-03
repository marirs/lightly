/* Lightly design prototype — every screen and state, and the clickable controller.
   A screen = kind + photo + session setup + UI state. The prototype keeps ONE session across
   navigation, so edits made in any tool stay on the photo when switching tools. */

const S = [];   // screen registry, in journey order
const add = (id, j, t, kind, o = {}) => S.push({ id, j, t, kind, ...o });
const ed = (s) => s;   // readability helper for setups

/* -------- Start and photo choice -------- */
add('launch', 'start', 'Launch', 'launch', { next:'welcome' });
add('welcome', 'start', 'Welcome', 'welcome');
add('welcome-more', 'start', 'Welcome · More (⋮)', 'welcome', { ui:{ overlay:'more' } });
add('picker', 'start', 'Choose a photo · system photo picker', 'picker');
add('picker-cancelled', 'start', 'Picker cancelled · back to Welcome, nothing changed', 'welcome', { ui:{ toastWelcome:true } });
add('camera-permission', 'start', 'Camera · system permission request', 'welcome', { ui:{ overlay:'cameraPerm' } });
add('camera-denied', 'start', 'Camera · permission denied', 'cameraDenied', { rec:true });
add('camera', 'start', 'Camera · system capture', 'camera');
add('camera-review', 'start', 'Camera · retake or use photo', 'cameraReview');
add('load-failed', 'start', 'Photo can’t be opened (unsupported or unavailable)', 'loadFailed', { rec:true });

/* -------- Opening and automatic Develop -------- */
add('loading', 'open', 'Opening the photo (photo stays visible)', 'loading', { photo:'lake' });
add('developing', 'open', 'Automatic Develop in progress', 'developing', { photo:'lake' });
add('developed', 'open', 'Developed · Auto applied', 'editor', { photo:'lake', ui:{ tool:'develop', toast:'Developed' } });
add('develop-failed', 'open', 'Automatic Develop failed · Retry or continue with original', 'editor', { photo:'lake', setup:s => { s.auto = 'failed'; }, ui:{ tool:'develop' }, rec:true });
add('model-unavailable', 'open', 'Automatic correction unavailable · presets still work', 'editor', { photo:'lake', setup:s => { s.auto = 'unavailable'; }, ui:{ tool:'develop' }, rec:true });

/* -------- Develop -------- */
add('dev-preset', 'develop', 'Preset applied (landscape photo, no Portrait tool)', 'editor', { photo:'lake', setup:s => applyPreset(s, 'landscape', 37), ui:{ tool:'develop' } });
add('dev-original', 'develop', 'Auto off · stop zero reads Original', 'editor', { photo:'lake', setup:s => { s.auto = 'off'; }, ui:{ tool:'develop' } });
add('dev-dragging', 'develop', 'Dragging · preview before release, fine control', 'editor', { photo:'lake', setup:s => applyPreset(s, 'landscape', 37), ui:{ tool:'develop', stop:41, fine:true } });
add('dev-browse', 'develop', 'Browsing another category · applied preset unchanged', 'editor', { photo:'lake', setup:s => applyPreset(s, 'landscape', 37), ui:{ tool:'develop', cat:'cinematic', stop:0 } });
add('dev-large', 'develop', 'Largest category: Cinematic, last of 564', 'editor', { photo:'lake', setup:s => applyPreset(s, 'cinematic', 564), ui:{ tool:'develop' } });
add('dev-long-name', 'develop', 'Long preset name', 'editor', { photo:'field', setup:s => applyPreset(s, 'landscape', CAT.categories[1].presets.findIndex(p => p.displayName === 'Landscape 15 - Winter Wonderland') + 1), ui:{ tool:'develop' } });
add('dev-amount', 'develop', 'Amount (secondary control)', 'editor', { photo:'lake', setup:s => { applyPreset(s, 'landscape', 37); s.dev.amount[s.dev.applied.id] = 70; }, ui:{ tool:'develop', amount:true } });
add('dev-starred', 'develop', 'Preset starred as a favourite', 'editor', { photo:'lake', setup:s => { applyPreset(s, 'landscape', 37); s.favs = [s.dev.applied.id]; }, ui:{ tool:'develop' } });
add('dev-favourites', 'develop', 'Favourites shortcut (up to five)', 'editor', { photo:'man', setup:s => { s.favs = PRIVATE_FAVS(); applyPreset(s, 'portrait', 13); }, ui:{ tool:'develop', cat:'favourites' } });
add('dev-fav-full', 'develop', 'Favourites full · sixth star', 'editor', { photo:'lake', setup:s => { s.favs = PRIVATE_FAVS(); applyPreset(s, 'travel', 5); }, ui:{ tool:'develop', favFull:true } });
add('dev-fav-replace', 'develop', 'Replace a favourite', 'editor', { photo:'lake', setup:s => { s.favs = PRIVATE_FAVS(); applyPreset(s, 'travel', 5); }, ui:{ tool:'develop', overlay:'favReplace' } });
add('dev-bw', 'develop', 'Black & White preset', 'editor', { photo:'man', setup:s => applyPreset(s, 'black-white', 8), ui:{ tool:'develop' } });
add('dev-landscape-photo', 'develop', 'Landscape-orientation photograph', 'editor', { photo:'sunset', setup:s => applyPreset(s, 'golden-hour', 12), ui:{ tool:'develop' } });
add('dev-portrait-photo', 'develop', 'Portrait photo · Portrait tool offered', 'editor', { photo:'man', setup:s => applyPreset(s, 'portrait', 13), ui:{ tool:'develop' } });

/* -------- Background -------- */
const BGP = 'woman';
add('bg-focus', 'background', 'Focus & Blur · target, Lens style, bokeh', 'editor', { photo:BGP, setup:s => { s.bg.blur = 55; }, ui:{ tool:'background', sub:'focus' } });
add('bg-soft', 'background', 'Focus & Blur · Soft', 'editor', { photo:BGP, setup:s => { s.bg.blur = 55; s.bg.style = 'soft'; }, ui:{ tool:'background', sub:'focus' } });
add('bg-swirl', 'background', 'Focus & Blur · Swirl', 'editor', { photo:BGP, setup:s => { s.bg.blur = 55; s.bg.style = 'swirl'; }, ui:{ tool:'background', sub:'focus' } });
add('bg-motion', 'background', 'Focus & Blur · Motion', 'editor', { photo:BGP, setup:s => { s.bg.blur = 55; s.bg.style = 'motion'; }, ui:{ tool:'background', sub:'focus' } });
add('bg-refine', 'background', 'Refine edges (brush)', 'editor', { photo:BGP, setup:s => { s.bg.blur = 55; }, ui:{ tool:'background', sub:'refine' } });
add('bg-change-image', 'background', 'Change background · image, position, scale', 'editor', { photo:BGP, setup:s => { s.bg.replaced = { type:'image', value:BACKGROUNDS[0] }; s.bg.scale = 120; }, ui:{ tool:'background', sub:'change', bgKind:'image' } });
add('bg-change-colour', 'background', 'Change background · solid colour', 'editor', { photo:BGP, setup:s => { s.bg.replaced = { type:'colour', value:SWATCHES[3] }; }, ui:{ tool:'background', sub:'change', bgKind:'colour' } });
add('bg-change-gradient', 'background', 'Change background · gradient', 'editor', { photo:BGP, setup:s => { s.bg.replaced = { type:'gradient', value:GRADIENTS[0] }; }, ui:{ tool:'background', sub:'change', bgKind:'gradient' } });
add('bg-replaced-blur', 'background', 'After replacement, the same Focus & Blur still works', 'editor', { photo:BGP, setup:s => { s.bg.replaced = { type:'image', value:BACKGROUNDS[0] }; s.bg.scale = 120; s.bg.blur = 60; }, ui:{ tool:'background', sub:'focus' } });
add('bg-separating', 'background', 'Finding the subject · cancellable', 'editor', { photo:BGP, ui:{ tool:'background', sub:'change', op:'separating' }, rec:true });
add('bg-failed', 'background', 'Subject separation failed · edits kept', 'editor', { photo:BGP, setup:s => applyPreset(s, 'portrait', 13), ui:{ tool:'background', sub:'change', op:'failed' }, rec:true });
add('bg-no-subject', 'background', 'No clear subject', 'editor', { photo:'lake', ui:{ tool:'background', sub:'focus' }, rec:true });

/* -------- Portrait (contextual) -------- */
const face = (s, g, k, v) => { s.faces[s.face][g][k] = v; };
add('pt-skin', 'portrait', 'Skin · single face selected automatically', 'editor', { photo:'man', setup:s => { face(s, 'skin', 'smooth', 24); face(s, 'skin', 'blemish', 40); face(s, 'skin', 'tone', 18); }, ui:{ tool:'portrait', sub:'skin' } });
add('pt-under', 'portrait', 'Under-eye', 'editor', { photo:'man', setup:s => { face(s, 'under', 'bright', 20); face(s, 'under', 'soften', 15); }, ui:{ tool:'portrait', sub:'under' } });
add('pt-eyes', 'portrait', 'Eyes', 'editor', { photo:'man', setup:s => { face(s, 'eyes', 'bright', 15); }, ui:{ tool:'portrait', sub:'eyes' } });
add('pt-teeth', 'portrait', 'Teeth', 'editor', { photo:'smile', setup:s => { face(s, 'teeth', 'bright', 20); }, ui:{ tool:'portrait', sub:'teeth' } });
add('pt-hair', 'portrait', 'Hair & Beard', 'editor', { photo:'man', setup:s => { face(s, 'hair', 'define', 30); }, ui:{ tool:'portrait', sub:'hair' } });
add('pt-landscape-photo', 'portrait', 'Portrait on a landscape-orientation photograph', 'editor', { photo:'smile', setup:s => { face(s, 'skin', 'smooth', 20); }, ui:{ tool:'portrait', sub:'skin' } });
add('pt-multi', 'portrait', 'Several faces · choose a face, separate adjustments', 'editor', { photo:'man', missing:'No licensed multi-person photograph is available locally. The face picker is implemented (one chip and ring per face) but only a one-face photo can be shown.', setup:s => { face(s, 'skin', 'smooth', 20); }, ui:{ tool:'portrait', sub:'skin' } });
add('pt-no-usable-face', 'portrait', 'People found, but no usable face', 'editor', { photo:'bar', ui:{ tool:'portrait' }, rec:true });
add('pt-hidden', 'portrait', 'No person · Portrait tool hidden', 'editor', { photo:'field', setup:s => applyPreset(s, 'landscape', 120), ui:{ tool:'develop' } });

/* -------- Edit -------- */
add('ed-crop', 'edit', 'Crop · aspect ratios', 'editor', { photo:'lake', setup:s => { s.edit.aspect = '4:5'; }, ui:{ tool:'edit', sub:'crop' } });
add('ed-rotate', 'edit', 'Rotate and flip', 'editor', { photo:'field', setup:s => { s.edit.flipH = true; }, ui:{ tool:'edit', sub:'rotate' } });
add('ed-straighten', 'edit', 'Straighten', 'editor', { photo:'field', setup:s => { s.edit.straighten = -3; }, ui:{ tool:'edit', sub:'straighten' } });
add('ed-perspective', 'edit', 'Perspective', 'editor', { photo:'street', setup:s => { s.edit.pv = 18; }, ui:{ tool:'edit', sub:'perspective' } });
add('ed-adjust-light', 'edit', 'Adjust · Light (exposure, contrast, highlights, shadows)', 'editor', { photo:'lake', setup:s => { Object.assign(s.edit.adj, { exposure:12, contrast:10, highlights:-20, shadows:25 }); }, ui:{ tool:'edit', sub:'adjust', group:'light' } });
add('ed-adjust-colour', 'edit', 'Adjust · Colour (white balance, saturation)', 'editor', { photo:'lake', setup:s => { Object.assign(s.edit.adj, { temp:15, tint:-4, vibrance:12 }); }, ui:{ tool:'edit', sub:'adjust', group:'colour' } });
add('ed-adjust-detail', 'edit', 'Adjust · Detail', 'editor', { photo:'lake', setup:s => { Object.assign(s.edit.adj, { sharpness:30, clarity:15, noise:20 }); }, ui:{ tool:'edit', sub:'adjust', group:'detail' } });
add('ed-remove', 'edit', 'Remove · brush over unwanted objects', 'editor', { photo:'field', setup:s => { s.edit.strokes = 1; }, ui:{ tool:'edit', sub:'remove' } });
add('ed-removing', 'edit', 'Removing · cancellable', 'editor', { photo:'field', setup:s => { s.edit.strokes = 1; }, ui:{ tool:'edit', sub:'remove', op:'removing' }, rec:true });
add('ed-remove-failed', 'edit', 'Remove failed · edits kept', 'editor', { photo:'field', setup:s => { s.edit.strokes = 1; applyPreset(s, 'landscape', 37); }, ui:{ tool:'edit', sub:'remove', op:'failed' }, rec:true });

/* -------- Effects -------- */
add('fx-leak', 'effects', 'Light Leaks · style, intensity, position, rotation', 'editor', { photo:'sunset', setup:s => { s.fx.leak.on = true; }, ui:{ tool:'effects', sub:'leak' } });
add('fx-grain', 'effects', 'Grain · style, amount, size, roughness', 'editor', { photo:'lake', setup:s => { s.fx.grain.on = true; s.fx.grain.amount = 45; }, ui:{ tool:'effects', sub:'grain' } });
add('fx-vignette', 'effects', 'Vignette · amount, size, softness', 'editor', { photo:'lake', setup:s => { s.fx.vig.on = true; }, ui:{ tool:'effects', sub:'vig' } });
add('fx-combined', 'effects', 'Combined effects', 'editor', { photo:'sunset', setup:s => { s.fx.leak.on = true; s.fx.grain.on = true; s.fx.vig.on = true; }, ui:{ tool:'effects', sub:'vig' } });
add('fx-preset-conflict', 'effects', 'Preset already contains grain · shown, not doubled silently', 'editor', { photo:'lake', setup:s => { applyPreset(s, 'film', [...Array(253).keys()].map(i => i + 1).find(n => presetHasEffect(presetAt('film', n).id))); s.fx.grain.on = true; }, ui:{ tool:'effects', sub:'grain' } });

/* -------- Watermark -------- */
add('wm-none', 'watermark', 'Watermark · None', 'editor', { photo:'sunset', ui:{ tool:'watermark', sub:'none' } });
add('wm-signature', 'watermark', 'Signature · saved, drawn and imported', 'editor', { photo:'sunset', setup:s => { s.wm.type = 'signature'; }, ui:{ tool:'watermark', sub:'signature' } });
add('wm-sig-draw', 'watermark', 'Draw and save a signature', 'editor', { photo:'sunset', setup:s => { s.wm.type = 'signature'; }, ui:{ tool:'watermark', sub:'signature', overlay:'sigDraw' } });
add('wm-sig-import', 'watermark', 'Import a signature (keeps its own appearance)', 'editor', { photo:'sunset', setup:s => { s.wm.type = 'signature'; }, ui:{ tool:'watermark', sub:'signature', overlay:'sigImport' } });
add('wm-text', 'watermark', 'Text · Allura, Cormorant Garamond, Inter, Caveat', 'editor', { photo:'sunset', setup:s => { s.wm.type = 'text'; s.wm.font = 'Cormorant Garamond'; }, ui:{ tool:'watermark', sub:'text' } });
add('wm-logo', 'watermark', 'Logo · position, size, opacity', 'editor', { photo:'lake', setup:s => { s.wm.type = 'logo'; s.wm.pos = 2; }, ui:{ tool:'watermark', sub:'logo' } });
add('wm-on-border', 'watermark', 'Watermark placed on the border', 'editor', { photo:'lake', setup:s => { s.wm.type = 'text'; s.wm.font = 'Caveat'; s.border.type = 'solid'; s.border.width = 8; s.wm.place = 'border'; }, ui:{ tool:'watermark', sub:'text' } });

/* -------- Border -------- */
add('bd-none', 'border', 'Border · None (preferred border is None)', 'editor', { photo:'lake', ui:{ tool:'border', sub:'none' } });
add('bd-solid', 'border', 'Solid · colour, width', 'editor', { photo:'lake', setup:s => { s.border.type = 'solid'; s.border.width = 5; }, ui:{ tool:'border', sub:'solid' } });
add('bd-frame', 'border', 'Photo Frame · frame, mat, spacing', 'editor', { photo:'sunset', setup:s => { s.border.type = 'frame'; s.border.colour = '#111111'; s.border.width = 3; s.border.spacing = 5; }, ui:{ tool:'border', sub:'frame' } });
add('bd-polaroid', 'border', 'Polaroid · larger bottom margin, signature on margin', 'editor', { photo:'man', setup:s => { s.border.type = 'polaroid'; s.wm.type = 'signature'; s.wm.place = 'border'; }, ui:{ tool:'border', sub:'polaroid' } });

/* -------- Compare, save, leaving -------- */
const edited = s => { applyPreset(s, 'landscape', 37); s.fx.vig.on = true; s.dirty = true; };
add('compare', 'save', 'Compare · hold to see the original', 'editor', { photo:'lake', setup:edited, ui:{ tool:'develop', compare:true } });
add('leave-unsaved', 'save', 'Leaving with unsaved changes', 'editor', { photo:'lake', setup:edited, ui:{ tool:'develop', overlay:'leave' }, rec:true });
add('save-permission', 'save', 'First save · system Photos permission (iOS)', 'editor', { photo:'lake', setup:edited, os:'ios', ui:{ tool:'develop', overlay:'savePerm' } });
add('save-permission-denied', 'save', 'Photos permission denied · edits kept (iOS)', 'editor', { photo:'lake', setup:edited, os:'ios', ui:{ tool:'develop', overlay:'saveDenied' }, rec:true });
add('saving', 'save', 'Saving a new JPEG', 'editor', { photo:'lake', setup:edited, ui:{ tool:'develop', overlay:'saving' } });
add('saved', 'save', 'Saved · share, keep editing, another photo', 'editor', { photo:'lake', setup:s => { edited(s); s.dirty = false; s.saved = true; }, ui:{ tool:'develop', overlay:'saved' } });
add('share', 'save', 'Share the saved copy (system share)', 'editor', { photo:'lake', setup:s => { edited(s); s.saved = true; }, ui:{ tool:'develop', overlay:'share' } });
add('another-photo', 'save', 'Choose another photo after saving', 'picker');
add('storage-full', 'save', 'Storage full · edits kept', 'editor', { photo:'lake', setup:edited, ui:{ tool:'develop', overlay:'storage' }, rec:true });
add('export-failed', 'save', 'Export failed · edits kept', 'editor', { photo:'lake', setup:edited, ui:{ tool:'develop', overlay:'exportFail' }, rec:true });

/* -------- More -------- */
add('more', 'more', 'More (from the editor)', 'editor', { photo:'lake', setup:edited, ui:{ tool:'develop', overlay:'page', page:'more' } });
add('preferences', 'more', 'Preferences', 'page', { setup:s => { s.favs = PRIVATE_FAVS(); }, ui:{ page:'preferences' } });
add('pref-favourites', 'more', 'Manage favourites · reorder up to five', 'page', { setup:s => { s.favs = PRIVATE_FAVS(); }, ui:{ page:'favourites' } });
add('pref-signature', 'more', 'Saved signature', 'page', { ui:{ page:'signature' } });
add('pref-border', 'more', 'Preferred border · None by default', 'page', { ui:{ page:'prefborder' } });
add('legal', 'more', 'Legal', 'page', { ui:{ page:'legal' } });
add('privacy', 'more', 'Privacy Policy (draft placeholder)', 'page', { ui:{ page:'privacy' } });
add('terms', 'more', 'Terms of Use (draft placeholder)', 'page', { ui:{ page:'terms' } });
add('about', 'more', 'About · version and build', 'page', { ui:{ page:'about' } });
add('support', 'more', 'Support', 'page', { ui:{ page:'support' } });

/* -------- Combined edit, one session -------- */
const DEMO = [
  ['Develop preset', s => applyPreset(s, 'portrait', 13), { tool:'develop' }],
  ['Background replaced', s => { s.bg.replaced = { type:'image', value:BACKGROUNDS[0] }; s.bg.scale = 120; }, { tool:'background', sub:'change', bgKind:'image' }],
  ['Focus and blur on the new background', s => { s.bg.blur = 55; }, { tool:'background', sub:'focus' }],
  ['Portrait adjustment', s => { face(s, 'skin', 'smooth', 22); face(s, 'skin', 'blemish', 35); face(s, 'under', 'bright', 15); }, { tool:'portrait', sub:'skin' }],
  ['Effect', s => { s.fx.vig.on = true; s.fx.grain.on = true; s.fx.grain.amount = 25; }, { tool:'effects', sub:'vig' }],
  ['Signature', s => { s.wm.type = 'signature'; s.wm.size = 30; }, { tool:'watermark', sub:'signature' }],
  ['Polaroid border, signature on the margin', s => { s.border.type = 'polaroid'; s.wm.place = 'border'; }, { tool:'border', sub:'polaroid' }],
  ['Saving the new JPEG', () => {}, { tool:'border', sub:'polaroid', overlay:'saving' }],
  ['Saved · original unchanged', s => { s.saved = true; }, { tool:'border', sub:'polaroid', overlay:'saved' }],
];
DEMO.forEach(([t], i) => add(`demo-${i + 1}`, 'demo', `${i + 1}. ${t}`, 'editor', { photo:'woman', setup:s => DEMO.slice(0, i + 1).forEach(([, f]) => f(s)), ui:{ ...DEMO[i][2] } }));

/** Session and UI for a screen opened directly (from the index, overview or checks). */
function stateFor(spec) {
  const s = newSession(spec.photo || 'lake');
  if (spec.setup) spec.setup(s);
  return { s, ui:{ tool:'develop', ...(spec.ui || {}) } };
}
const applies = (spec, dev) => !spec.os || spec.os === dev.os;

/* ======================================================================== prototype controller */
class Prototype {
  constructor(host, opts) { this.host = host; this.opts = opts; this.open('launch'); }
  set(opts) { Object.assign(this.opts, opts); this.render(); }
  open(id, keep) {
    const spec = S.find(x => x.id === id); this.spec = spec;
    if (!keep || !this.s) { const st = stateFor(spec); this.s = st.s; this.ui = st.ui; this.hist = [JSON.stringify(this.s)]; this.pos = 0; }
    else { this.ui = { tool:this.ui.tool || 'develop', ...(spec.ui || {}) }; }
    clearTimeout(this.timer);
    if (spec.kind === 'launch') this.timer = setTimeout(() => this.open('welcome'), 1100);
    if (spec.kind === 'loading') this.timer = setTimeout(() => this.open('developing', true), 1100);
    if (spec.kind === 'developing') this.timer = setTimeout(() => { this.spec = S.find(x => x.id === 'developed'); this.ui = { tool:'develop', toast:'Developed' }; this.render(); setTimeout(() => { this.ui.toast = null; this.render(); }, 1600); }, 1500);
    if (spec.id === 'saving' && keep) this.timer = setTimeout(() => { this.s.saved = true; this.s.dirty = false; this.ui.overlay = 'saved'; this.render(); }, 1300);
    this.render(); this.opts.onChange && this.opts.onChange(this);
  }
  commit() { this.s.dirty = true; this.hist = this.hist.slice(0, this.pos + 1); this.hist.push(JSON.stringify(this.s)); this.pos = this.hist.length - 1; }
  render() {
    const { dev, orient, theme, large } = this.opts, L = layoutFor(dev, orient);
    this.ui.histPos = this.pos; this.ui.histLen = this.hist.length;
    const spec = this.spec.kind === 'page' || this.spec.kind === 'editor' || !this.spec.kind ? this.spec : this.spec;
    this.host.innerHTML = `<div class="dv ${theme} ${dev.os} ${large ? 'large' : ''}" style="width:${L.w}px;height:${L.h}px">${screenHTML(spec, this.s, this.ui, dev, L)}</div>`;
    const root = this.host.firstElementChild;
    fitPhotos(root); buildRulers(root, (rl, tr, n) => this.wireRuler(rl, tr, n));
    root.querySelectorAll('[data-act]').forEach(el => el.addEventListener('click', e => { e.stopPropagation(); this.act(el.dataset.act, el); }));
    root.querySelectorAll('.trk[data-path]').forEach(t => this.wireSlider(t));
    const cmp = root.querySelector('[data-act="compare"]');
    if (cmp) { cmp.onpointerdown = () => { this.ui.compare = true; this.render(); }; cmp.onpointerup = cmp.onpointerleave = () => { if (this.ui.compare) { this.ui.compare = false; this.render(); } }; }
    const stage = root.querySelector('.stage');
    if (stage && this.ui.tool === 'background' && (this.ui.sub || 'focus') === 'focus') stage.onclick = (e) => { const pic = stage.querySelector('.imgbox').getBoundingClientRect(); this.s.bg.target = { x:(e.clientX - pic.left) / pic.width, y:(e.clientY - pic.top) / pic.height }; this.commit(); this.render(); };
    if (stage && this.ui.tool === 'edit' && this.ui.sub === 'remove') stage.onclick = () => { this.s.edit.strokes++; this.commit(); this.ui.op = 'removing'; this.render(); setTimeout(() => { this.ui.op = null; this.render(); }, 1200); };
  }
  wireRuler(rl, tr, n) {
    const cur = rl.dataset.ruler; let settle, programmatic = true;
    setTimeout(() => programmatic = false, 150);
    tr.addEventListener('scroll', () => {
      if (programmatic) return;
      const stop = Math.max(0, Math.min(n, Math.round(tr.scrollLeft / 12)));
      this.ui.stop = stop; this.updateDevLabels(rl, cur, stop);           // preview while dragging
      clearTimeout(settle); settle = setTimeout(() => {                    // commit on release, one undo step
        this.ui.stop = null;
        const id = cur === 'favourites' ? this.s.favs[stop - 1] : stop ? presetAt(cur, stop).id : null;
        const before = this.s.dev.applied && this.s.dev.applied.id;
        if (id !== before && (stop || before)) { if (id) { const p = PRESET.get(id); applyPreset(this.s, p.cat, p.stop); } else this.s.dev.applied = null; this.commit(); }
        this.render();
      }, 220);
    });
  }
  updateDevLabels(rl, cur, stop) {
    const root = rl.closest('.dv'), list = cur === 'favourites' ? this.s.favs.map(id => PRESET.get(id)) : CAT.categories.find(c => c.id === cur).presets.map(p => ({ id:p.id, name:p.displayName, cat:cur }));
    const p = stop ? list[stop - 1] : null;
    root.querySelector('[data-name]').textContent = p ? p.name : (this.s.auto === 'applied' ? 'Auto' : 'Original');
    root.querySelector('[data-pos]').textContent = `${stop} / ${list.length}`;
    const preview = { ...this.s, dev:{ ...this.s.dev, applied:p ? { cat:p.cat || cur, id:p.id, name:p.name, stop } : null } };
    root.querySelector('.imgbox > div').style.filter = photoFilter(preview, false);
  }
  wireSlider(t) {
    const set = (e) => {
      const r = t.getBoundingClientRect(), min = +t.dataset.min, max = +t.dataset.max;
      const v = Math.round(min + Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * (max - min));
      setPath(this, t.dataset.path, v); this.render();
    };
    t.onpointerdown = (e) => { t.setPointerCapture(e.pointerId); set(e); const tt = this.host.querySelector(`.trk[data-path="${t.dataset.path}"]`); };
    t.onpointerup = () => this.commit();
  }
  act(a, el) {
    const [verb, arg] = a.split(/:(.*)/s); const s = this.s, ui = this.ui;
    const r = () => this.render();
    switch (verb) {
      case 'go': return this.open(arg, true);
      case 'pick': { this.s = newSession(arg); this.hist = [JSON.stringify(this.s)]; this.pos = 0; this.ui = { tool:'develop' }; return this.open('loading', true); }
      case 'pickCamera': { this.s = newSession('smile'); this.hist = [JSON.stringify(this.s)]; this.pos = 0; this.ui = { tool:'develop' }; return this.open('loading', true); }
      case 'tool': ui.tool = arg; ui.sub = null; ui.op = null; ui.cat = null; ui.amount = false; return r();
      case 'sub': ui.sub = arg; ui.op = null; return r();
      case 'cat': ui.cat = arg; ui.stop = null; return r();          // browsing never changes the applied preset
      case 'group': ui.group = arg; return r();
      case 'bgKind': ui.bgKind = arg; return r();
      case 'bgStyle': s.bg.style = arg; this.commit(); return r();
      case 'brush': ui.brush = arg; return r();
      case 'bgImage': ui.op = 'separating'; r(); return setTimeout(() => { s.bg.replaced = { type:'image', value:arg }; ui.op = null; this.commit(); r(); }, 900);
      case 'bgColour': s.bg.replaced = { type:'colour', value:arg }; this.commit(); return r();
      case 'bgGradient': s.bg.replaced = { type:'gradient', value:arg }; this.commit(); return r();
      case 'removeBg': s.bg.replaced = null; this.commit(); return r();
      case 'face': s.face = +arg; return r();
      case 'set': { const [path, v] = arg.split('='); setPath(this, path, isNaN(+v) || v === '' ? v : +v); this.commit(); return r(); }
      case 'geom': if (arg === 'flipH') s.edit.flipH = !s.edit.flipH; else if (arg === 'flipV') s.edit.flipV = !s.edit.flipV; else s.edit.rot = (s.edit.rot + +arg.split('=')[1] + 360) % 360; this.commit(); return r();
      case 'undoStroke': s.edit.strokes = Math.max(0, s.edit.strokes - 1); this.commit(); return r();
      case 'fxToggle': s.fx[arg].on = !s.fx[arg].on; this.commit(); return r();
      case 'wmType': ui.sub = arg; s.wm.type = arg; this.commit(); return r();
      case 'wmPlace': s.wm.place = arg; this.commit(); return r();
      case 'borderType': ui.sub = arg; s.border.type = arg; if (arg === 'polaroid') s.border.colour = '#FFFFFF'; this.commit(); return r();
      case 'polaroidSig': if (s.wm.type === 'none') s.wm.type = 'signature'; s.wm.place = s.wm.place === 'border' ? 'photo' : 'border'; this.commit(); return r();
      case 'toggleAuto': if (s.auto === 'applied' || s.auto === 'off') { s.auto = s.auto === 'applied' ? 'off' : 'applied'; this.commit(); } return r();
      case 'retryAuto': ui.overlay = null; return this.open('developing', true);
      case 'useOriginal': s.auto = 'off'; this.commit(); return r();
      case 'star': {
        const id = s.dev.applied && s.dev.applied.id; if (!id) return;
        if (s.favs.includes(id)) s.favs = s.favs.filter(x => x !== id); else if (s.favs.length >= 5) ui.favFull = true; else s.favs.push(id);
        return r(); }
      case 'replaceFav': s.favs = s.favs.map(x => x === arg ? s.dev.applied.id : x); ui.overlay = null; ui.favFull = false; return r();
      case 'unfav': s.favs = s.favs.filter(x => x !== arg); return r();
      case 'amount': ui.amount = true; return r();
      case 'amountDone': ui.amount = false; return r();
      case 'undo': if (this.pos > 0) { this.pos--; this.s = JSON.parse(this.hist[this.pos]); } return r();
      case 'redo': if (this.pos < this.hist.length - 1) { this.pos++; this.s = JSON.parse(this.hist[this.pos]); } return r();
      case 'compare': return;                                            // press-and-hold handled on pointer events
      case 'save': ui.overlay = (this.opts.dev.os === 'ios' && !this.savedOnce) ? 'savePerm' : 'saving'; this.savedOnce = true; r(); if (ui.overlay === 'saving') this.timer = setTimeout(() => { s.saved = true; s.dirty = false; ui.overlay = 'saved'; r(); }, 1300); return;
      case 'close': ui.overlay = s.dirty ? 'leave' : null; if (!s.dirty) return this.open('welcome'); return r();
      case 'discard': return this.open('welcome');
      case 'overlay': ui.overlay = arg === 'more' ? 'page' : arg; if (arg === 'more') ui.page = 'more'; return r();
      case 'page': ui.privacyFromWelcome = false; if (this.spec.kind === 'page' && this.opts.dev && layoutFor(this.opts.dev, this.opts.orient).w <= 700) { ui.page = arg; return r(); } ui.overlay = 'page'; ui.page = arg; return r();
      case 'closeMore': if (this.spec.kind === 'page') return this.open('welcome'); ui.overlay = null; return r();
      case 'appearance': ui.appearance = arg; return r();
      case 'toggleLocation': ui.location = !ui.location; return r();
      case 'toggleMetadata': ui.metadata = !(ui.metadata !== false); return r();
      case 'welcomePrivacy': ui.privacyFromWelcome = true; ui.overlay = 'page'; ui.page = 'privacy'; return r();
      case 'closeWelcomePrivacy': ui.privacyFromWelcome = false; ui.overlay = null; return r();
      case 'saveSig': s.wm.sig = 'drawn'; ui.overlay = null; ui.toast = 'Signature saved for reuse'; r(); return setTimeout(() => { ui.toast = null; r(); }, 1400);
      case 'saveSigImported': s.wm.sig = 'imported'; ui.overlay = null; this.commit(); return r();
      case 'cancelOp': ui.op = null; ui.toast = 'Cancelled · nothing changed'; r(); return setTimeout(() => { ui.toast = null; r(); }, 1400);
      case 'retryOp': ui.op = null; return r();
      case 'dismiss': if (ui.overlay === 'saving') { clearTimeout(this.timer); ui.toast = 'Save cancelled · nothing was written'; } ui.overlay = null; ui.favFull = false; r(); return setTimeout(() => { ui.toast = null; r(); }, 1400);
      case 'noop': return;
    }
  }
}
function setPath(p, path, v) {
  if (path.startsWith('ui.')) return;
  const keys = path.split('.'); let o = p.s; for (const k of keys.slice(0, -1)) o = o[k] ?? (o[k] = {}); o[keys.at(-1)] = v;
}
