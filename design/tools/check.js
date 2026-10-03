// Runs every screen × layout × theme × text-size check in the review site and writes design/app/coverage.json.
// Usage: NODE_PATH=<playwright-core node_modules> node design/tools/check.js http://127.0.0.1:8765
const { chromium } = require('playwright-core');
const fs = require('fs'), path = require('path');
(async () => {
  const base = process.argv[2] || 'http://127.0.0.1:8765';
  const b = await chromium.launch(); const p = await b.newPage({ viewport:{ width:1600, height:1000 } });
  const errors = []; p.on('pageerror', e => errors.push(e.message)); p.on('console', m => m.type() === 'error' && errors.push(m.text()));
  await p.goto(`${base}/design/app/index.html#tab=notes`, { waitUntil:'networkidle' });
  await p.waitForFunction(() => window.READY === true);
  await p.evaluate(() => document.fonts.ready);
  const results = await p.evaluate(async () => await runAllChecks());
  const selftest = await p.evaluate(() => sessionSelfTest());
  const out = { generated:new Date().toISOString(), results, selftest, errors };
  fs.writeFileSync(path.join(__dirname, '../app/coverage.json'), JSON.stringify(out));
  // Summary by issue type
  const byType = {}; let total = 0, frames = 0;
  for (const [k, screens] of Object.entries(results)) for (const [sid, r] of Object.entries(screens)) { if (r.na) continue; frames++; for (const [t, d] of r.issues) { total++; (byType[t] ||= new Map()).set(`${sid} :: ${d}`, ((byType[t].get(`${sid} :: ${d}`)) || 0) + 1); } }
  console.log(`frames checked: ${frames}, issues: ${total}, page errors: ${errors.length}`);
  for (const [t, m] of Object.entries(byType)) { console.log(`\n== ${t}: ${[...m.values()].reduce((a, b) => a + b, 0)}`); [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 14).forEach(([k, n]) => console.log(`  ${n}× ${k}`)); }
  console.log('\nselftest:', JSON.stringify(selftest));
  if (errors.length) console.log('errors:', errors.slice(0, 5));
  await b.close();
})();
