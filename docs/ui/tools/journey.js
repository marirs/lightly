// Clicks through the prototype like a reviewer: Launch → Welcome → picker → open → Develop (drag the ruler) →
// Background replace → Focus & Blur → Portrait → Effects → Watermark → Border → Save → Saved → Keep editing,
// then close with unsaved edits. Fails loudly if a step does not lead where it should.
const { chromium } = require('playwright-core');
(async () => {
  const [base, dev = 'iphone17', orient = 'portrait'] = process.argv.slice(2);
  const b = await chromium.launch(); const p = await b.newPage({ viewport:{ width:1700, height:1200 } });
  const errors = []; p.on('pageerror', e => errors.push(e.message));
  await p.goto(`${base}/docs/ui/app/index.html#dev=${dev}&orient=${orient}&tab=prototype&screen=launch`, { waitUntil:'networkidle' });
  await p.waitForFunction(() => window.READY);
  const log = [], step = async (name, fn, expect) => { await fn(); await p.waitForTimeout(250); const got = await p.evaluate(() => ({ screen:proto.spec.id, tool:proto.ui.tool, overlay:proto.ui.overlay, applied:proto.s.dev.applied && proto.s.dev.applied.name, bg:!!proto.s.bg.replaced, blur:proto.s.bg.blur, skin:proto.s.faces[0] && proto.s.faces[0].skin.smooth, vig:proto.s.fx.vig.on, wm:proto.s.wm.type, border:proto.s.border.type, saved:proto.s.saved, hist:proto.hist.length }));
    const ok = expect(got); log.push(`${ok ? 'ok ' : 'FAIL'} ${name} → ${JSON.stringify(got)}`); if (!ok) throw new Error(name); };
  const click = sel => p.click(`#host ${sel}`, { force:true });
  try {
    await step('Launch shows, then Welcome', () => p.waitForTimeout(1300), g => g.screen === 'welcome');
    await step('Choose a photo opens the picker', () => click('[data-act="go:picker"]'), g => g.screen === 'picker');
    await step('Pick the portrait by a wall', () => click('[data-act="pick:woman"]'), g => g.screen === 'loading');
    await step('Opening, then automatic Develop, then editor', () => p.waitForTimeout(2900), g => g.screen === 'developed' && g.tool === 'develop');
    await step('Drag the ruler to a preset (preview, then commit)', async () => { await p.$eval('#host .rtrack', e => e.scrollLeft = 13 * 12); await p.waitForTimeout(450); }, g => !!g.applied && g.hist === 2);
    await step('Browse another category: applied preset unchanged', () => click('[data-act="cat:film"]'), g => !!g.applied);
    await step('Background tool', () => click('[data-act="tool:background"]'), g => g.tool === 'background');
    await step('Change background', () => click('[data-act="sub:change"]'), g => true);
    await step('Pick a background image (finding subject, then replaced)', async () => { await click('[data-act^="bgImage:"]'); await p.waitForTimeout(1100); }, g => g.bg && !!g.applied);
    await step('Back to Focus & Blur on the new background', () => click('[data-act="sub:focus"]'), g => g.bg);
    await step('Drag Blur', async () => { const t = await p.$('#host .trk[data-path="bg.blur"]'); const r = await t.boundingBox(); await p.mouse.click(r.x + r.width * .6, r.y + 1); }, g => g.blur > 30 && g.bg);
    await step('Portrait tool, Skin smoothing', async () => { await click('[data-act="tool:portrait"]'); const t = await p.$('#host .trk[data-path="faces.0.skin.smooth"]'); const r = await t.boundingBox(); await p.mouse.click(r.x + r.width * .25, r.y + 1); }, g => g.skin > 10 && g.bg && g.blur > 30 && !!g.applied);
    await step('Effects: Vignette on', async () => { await click('[data-act="tool:effects"]'); await click('[data-act="sub:vig"]'); await click('[data-act="fxToggle:vig"]'); }, g => g.vig && g.skin > 10);
    await step('Watermark: Signature', async () => { await click('[data-act="tool:watermark"]'); await click('[data-act="wmType:signature"]'); }, g => g.wm === 'signature' && g.vig);
    await step('Border: Polaroid, signature on the margin', async () => { await click('[data-act="tool:border"]'); await click('[data-act="borderType:polaroid"]'); await click('[data-act="polaroidSig"]'); }, g => g.border === 'polaroid' && g.wm === 'signature' && g.bg && !!g.applied);
    await step('Undo, then Redo', async () => { await click('[data-act="undo"]'); await click('[data-act="redo"]'); }, g => g.border === 'polaroid');
    await step('Save copy (permission on iOS first save)', async () => { await click('[data-act="save"]'); if (await p.$('#host [data-act="go:saving"]')) await click('[data-act="go:saving"]'); await p.waitForTimeout(1500); }, g => g.overlay === 'saved' && g.saved);
    await step('Keep editing: all edits still there', () => click('[data-act="dismiss"]'), g => !g.overlay && g.border === 'polaroid' && g.bg && g.skin > 10);
    await step('Another edit, then close: leave dialog', async () => { await click('[data-act="tool:effects"]'); await click('[data-act="sub:grain"]'); await click('[data-act="fxToggle:grain"]'); await click('[data-act="close"]'); }, g => g.overlay === 'leave');
    await step('Keep editing from the leave dialog', () => click('[data-act="dismiss"]'), g => !g.overlay);
  } catch (e) { log.push('STOPPED: ' + e.message); }
  console.log(`${dev} ${orient}\n` + log.join('\n') + (errors.length ? '\nerrors: ' + errors.join(' | ') : ''));
  await b.close();
})();
