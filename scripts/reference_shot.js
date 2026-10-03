// Renders one approved prototype screen for the reference cache (scripts/reference_cache.py).
//
// Identical to docs/ui/tools/shot.js except for one optional argument: a named variant from
// scripts/reference_variants.json, whose `state` fields are assigned onto the screen's session
// after the approved setup runs. With no variant the output must be byte-identical to shot.js;
// scripts/reference_cache.py checks that on every new tool revision before using it.
//
// Usage: NODE_PATH=<playwright-core> node scripts/reference_shot.js <screenId> <deviceId>
//          <portrait|landscape> <light|dark> <default|large> <out.png> <base> [variantName]
const { chromium } = require('playwright-core');
const path = require('path');
const fs = require('fs');
(async () => {
  const [screen, dev, orient, theme, text, out, base = 'http://127.0.0.1:8765', variantName = ''] = process.argv.slice(2);
  let variantState = null;
  if (variantName) {
    const variants = JSON.parse(fs.readFileSync(path.join(__dirname, 'reference_variants.json'), 'utf8'));
    if (!variants[variantName]) throw new Error('unknown variant ' + variantName);
    variantState = variants[variantName].state;
  }
  const b = await chromium.launch();
  const probe = await b.newPage(); await probe.goto(`${base}/docs/ui/app/index.html#tab=notes`, { waitUntil:'networkidle' });
  await probe.waitForFunction(() => window.READY);
  const L = await probe.evaluate(([d, o]) => { const dv = DEVICES.find(x => x.id === d); return { ...layoutFor(dv, o), scale: dv.os === 'ios' ? (/ipad/.test(dv.id) ? 2 : 3) : 2.625 }; }, [dev, orient]);
  await probe.close();
  const p = await b.newPage({ viewport:{ width:L.w + 40, height:L.h + 40 }, deviceScaleFactor:L.scale });
  await p.goto(`${base}/docs/ui/app/index.html#tab=notes`, { waitUntil:'networkidle' }); await p.waitForFunction(() => window.READY);
  await p.evaluate(() => document.fonts.ready);
  await p.evaluate(([screen, dev, orient, theme, text, variantState]) => {
    const spec = S.find(x => x.id === screen); if (!spec) throw new Error('unknown screen ' + screen);
    const d = DEVICES.find(x => x.id === dev), L = layoutFor(d, orient), { s, ui } = stateFor(spec);
    if (variantState) Object.assign(s, variantState);
    document.body.innerHTML = `<div id="shot" class="dv ${theme} ${d.os} ${text === 'large' ? 'large' : ''}" style="width:${L.w}px;height:${L.h}px;margin:0">${screenHTML(spec, s, ui, d, L)}</div>`;
    document.body.style.margin = '0'; buildRulers(document.getElementById('shot'));
  }, [screen, dev, orient, theme, text, variantState]);
  await p.waitForTimeout(300);
  await (await p.$('#shot')).screenshot({ path: out });
  console.log(`${out} ${L.w}x${L.h}@${L.scale}`); await b.close();
})().catch(e => { console.error(e.message); process.exit(1); });
