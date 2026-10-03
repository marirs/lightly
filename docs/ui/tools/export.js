// Exports contact sheets (Overview tab) for every layout × theme, large-text sheets, and the combined-edit strip.
// Usage: NODE_PATH=... node docs/ui/tools/export.js http://127.0.0.1:8765 <outdir>
const { chromium } = require('playwright-core');
const fs = require('fs');
(async () => {
  const [base, out] = process.argv.slice(2); fs.mkdirSync(`${out}/overview`, { recursive:true }); fs.mkdirSync(`${out}/combined`, { recursive:true });
  const b = await chromium.launch(); const p = await b.newPage({ viewport:{ width:1700, height:1100 }, deviceScaleFactor:1 });
  const layouts = await (async () => { await p.goto(`${base}/docs/ui/app/index.html#tab=notes`, { waitUntil:'networkidle' }); await p.waitForFunction(() => window.READY); return p.evaluate(() => LAYOUTS.map(l => [l.dev.id, l.orient])); })();
  const shoot = async (hash, file) => {
    await p.goto(`${base}/docs/ui/app/index.html#${hash}`, { waitUntil:'networkidle' }); await p.waitForFunction(() => window.READY);
    await p.evaluate(() => location.reload()); await p.waitForLoadState('networkidle'); await p.waitForFunction(() => window.READY);
    await p.evaluate(() => document.fonts.ready); await p.waitForTimeout(400);
    await p.screenshot({ path:file, fullPage:true });
  };
  for (const [d, o] of layouts) for (const th of ['light', 'dark']) await shoot(`dev=${d}&orient=${o}&theme=${th}&text=default&tab=overview`, `${out}/overview/${d}-${o}-${th}.png`);
  for (const [d, o] of [['iphone17', 'portrait'], ['pixel9pro', 'portrait'], ['ipadpro13', 'landscape'], ['fold-inner', 'portrait']]) await shoot(`dev=${d}&orient=${o}&theme=light&text=large&tab=overview`, `${out}/overview/${d}-${o}-light-LARGETEXT.png`);
  for (const [d, o] of layouts) await shoot(`dev=${d}&orient=${o}&theme=light&text=default&tab=demo`, `${out}/combined/${d}-${o}.png`);
  console.log('done'); await b.close();
})();
