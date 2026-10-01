// Regression tests for Codex M1 findings 5 and 6 (prototype behaviour).
// Run: NODE_PATH=<dir with playwright> CHROME=<headless chrome path> node codex_findings.test.js
const { chromium } = require('playwright');
const assert = require('assert');
const path = require('path');

(async () => {
  const browser = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME } : {});
  const page = await browser.newPage({ viewport: { width: 400, height: 900 } });
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.goto('file://' + path.resolve(__dirname, '../index.html'));
  await page.evaluate(() => proto.ready);
  const state = () => page.evaluate(() => proto.get());
  const tab = id => page.click('#tab-' + id);
  const stopLabel = i => page.click(`#stopLabels span:nth-child(${i + 1})`);
  await page.evaluate(() => proto.set({ layout: 'phone', state: 'auto' }));

  // Finding 5: Film -> browse Warm -> choose Auto => Look removed.
  await tab('film'); await stopLabel(2); await tab('warm');
  let s = await state();
  assert.deepStrictEqual(s.look, { cat: 'film', stop: 2 }, 'browsing Warm keeps the Film look');
  await stopLabel(0);
  s = await state();
  assert.strictEqual(s.look, null, 'explicitly choosing Auto in another category removes the Look');
  // keyboard variant: Home at Auto in a non-owning category
  await tab('film'); await stopLabel(3); await tab('cool');
  await page.focus('#stepper'); await page.keyboard.press('Home');
  assert.strictEqual((await state()).look, null, 'Home (explicit Auto) removes the Look via keyboard');

  // Finding 6: one drag with a long pause mid-way = exactly one undo step.
  await tab('film');
  const before = (await state()).undo;
  const box = await page.locator('#track').boundingBox();
  const xAt = i => box.x + box.width * i / 4;  // film has 5 stops
  await page.mouse.move(xAt(1), box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(xAt(2), box.y + box.height / 2, { steps: 4 });
  await page.waitForTimeout(900);                 // pause while still pressed (old timer committed here)
  await page.mouse.move(xAt(3), box.y + box.height / 2, { steps: 4 });
  await page.mouse.up();
  s = await state();
  assert.strictEqual(s.undo - before, 1, `drag created ${s.undo - before} undo steps`);
  assert.deepStrictEqual(s.look, { cat: 'film', stop: 3 });

  // Keyboard: each arrow step is its own committed step.
  const k0 = (await state()).undo;
  await page.focus('#stepper'); await page.keyboard.press('ArrowLeft'); await page.keyboard.press('ArrowLeft');
  assert.strictEqual((await state()).undo - k0, 2, 'two key steps = two undo steps');

  assert.deepStrictEqual(errors, [], 'no page errors');
  console.log('PASS codex findings 5 & 6');
  await browser.close();
})().catch(e => { console.error('FAIL', e.message); process.exit(1); });
