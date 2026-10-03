// Renders one approved prototype screen at a device's logical size and pixel density, for side-by-side
// comparison with native screenshots.
// Usage: NODE_PATH=<playwright-core> node design/tools/shot.js <screenId> <deviceId> <portrait|landscape> <light|dark> <default|large> <out.png> [base]
// Device ids and sizes: design/app/data.js (DEVICES). Requires the local review server (python3 -m http.server 8765 --directory <repo>).
const { chromium } = require('playwright-core');
(async () => {
  const [screen, dev, orient, theme, text, out, base = 'http://127.0.0.1:8765'] = process.argv.slice(2);
  const b = await chromium.launch();
  const probe = await b.newPage(); await probe.goto(`${base}/design/app/index.html#tab=notes`, { waitUntil:'networkidle' });
  await probe.waitForFunction(() => window.READY);
  const L = await probe.evaluate(([d, o]) => { const dv = DEVICES.find(x => x.id === d); return { ...layoutFor(dv, o), scale: dv.os === 'ios' ? (/ipad/.test(dv.id) ? 2 : 3) : 2.625 }; }, [dev, orient]);
  await probe.close();
  const p = await b.newPage({ viewport:{ width:L.w + 40, height:L.h + 40 }, deviceScaleFactor:L.scale });
  await p.goto(`${base}/design/app/index.html#tab=notes`, { waitUntil:'networkidle' }); await p.waitForFunction(() => window.READY);
  await p.evaluate(() => document.fonts.ready);
  await p.evaluate(([screen, dev, orient, theme, text]) => {
    const spec = S.find(x => x.id === screen); if (!spec) throw new Error('unknown screen ' + screen);
    const d = DEVICES.find(x => x.id === dev), L = layoutFor(d, orient), { s, ui } = stateFor(spec);
    document.body.innerHTML = `<div id="shot" class="dv ${theme} ${d.os} ${text === 'large' ? 'large' : ''}" style="width:${L.w}px;height:${L.h}px;margin:0">${screenHTML(spec, s, ui, d, L)}</div>`;
    document.body.style.margin = '0'; buildRulers(document.getElementById('shot'));
  }, [screen, dev, orient, theme, text]);
  await p.waitForTimeout(300);
  await (await p.$('#shot')).screenshot({ path: out });
  console.log(`${out} ${L.w}x${L.h}@${L.scale}`); await b.close();
})().catch(e => { console.error(e.message); process.exit(1); });
