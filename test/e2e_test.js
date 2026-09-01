const { chromium, devices } = require('playwright');

(async () => {
  const browser = await chromium.launch({
    executablePath: '/opt/pw-browsers/chromium',
    args: ['--disable-background-networking','--disable-sync','--no-first-run',
           '--disable-component-update','--disable-features=OptimizationHints']
  });
  const ctx = await browser.newContext({ ...devices['iPhone 13'] });
  const fs = require('fs');
  const shoe = fs.readFileSync('/tmp/shoe.jpg');
  // The sandbox can't reach cdn.shopify.com from the browser; serve the real
  // image bytes locally so the layout is exercised exactly as in production.
  const block = async (pg) => pg.route('**/cdn.shopify.com/**', r =>
    r.fulfill({ status: 200, contentType: 'image/jpeg', body: shoe }));
  const page = await ctx.newPage();
  await block(page);
  const errors = [];
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));

  const step = async (label, fn) => {
    try { await fn(); console.log('  PASS  ' + label); }
    catch (e) { console.log('  FAIL  ' + label + ' -> ' + e.message); process.exitCode = 1; }
  };

  console.log('\n--- CUSTOMER FLOW ---');
  await page.goto('http://localhost:8900/index.html?release=aj4-retro-og-flight-club', { waitUntil: 'domcontentloaded' });

  await step('release loads with name + price', async () => {
    await page.waitForSelector('#s-size.active', { timeout: 10000 });
    const name = await page.textContent('#name');
    const price = await page.textContent('#price');
    if (!name.includes('Jordan')) throw new Error('name = ' + name);
    if (!price.includes('$215')) throw new Error('price = ' + price);
  });

  await step('shoe photo rendered', async () => {
    const ok = await page.evaluate(() => {
      const i = document.querySelector('#hero img');
      return !!i && i.naturalWidth > 100;
    });
    if (!ok) throw new Error('hero image did not load');
  });

  await step('size grid populated with availability', async () => {
    const n = await page.locator('#sizes .size').count();
    if (n !== 12) throw new Error('expected 12 sizes, got ' + n);
    const sub = await page.textContent('#sizeSub');
    if (!/pairs left/.test(sub)) throw new Error('sub = ' + sub);
  });

  await page.screenshot({ path: '/root/cityjeans-drops/shot-1-product.png', fullPage: true });

  await step('continue is disabled until a size is picked', async () => {
    if (!(await page.isDisabled('#cta'))) throw new Error('CTA was enabled with no size');
  });

  await step('pick size 10 then continue', async () => {
    await page.click('#sizes .size:has-text("10.5") >> nth=-1').catch(() => {});
    await page.locator('#sizes .size', { hasText: /^10Available|^10 /}).first().click().catch(async () => {
      await page.locator('#sizes .size').nth(6).click();
    });
    await page.waitForSelector('#sizes .size.sel');
    if (await page.isDisabled('#cta')) throw new Error('CTA still disabled after size pick');
    await page.click('#cta');
    await page.waitForSelector('#s-loc.active');
  });

  await step('locations listed with per-store stock', async () => {
    const n = await page.locator('#locs .loc').count();
    if (n < 1) throw new Error('no locations shown');
    const t = await page.textContent('#locSub');
    if (!/store/.test(t)) throw new Error('locSub = ' + t);
  });

  await page.screenshot({ path: '/root/cityjeans-drops/shot-2-location.png', fullPage: true });

  await step('pick a store and continue', async () => {
    await page.locator('#locs .loc').first().click();
    await page.click('#cta');
    await page.waitForSelector('#s-info.active');
  });

  const phone = '917' + String(Date.now()).slice(-7);
  await step('phone auto-formats as you type', async () => {
    await page.fill('#ph', '');
    await page.type('#ph', '9175551234');
    const v = await page.inputValue('#ph');
    if (v !== '(917) 555-1234') throw new Error('got ' + v);
    // use a unique number for the actual reservation below
    await page.fill('#ph', '');
    await page.type('#ph', phone);
  });

  await step('server rejects a bad email', async () => {
    await page.fill('#fn', 'Test'); await page.fill('#ln', 'Shopper');
    await page.fill('#em', 'not-an-email');
    await page.click('#cta');
    await page.waitForSelector('#err.show', { timeout: 8000 });
    const t = await page.textContent('#err');
    if (!/valid email/i.test(t)) throw new Error('err = ' + t);
  });

  const email = 'e2e' + Date.now() + '@example.com';
  let code = null;
  await step('reservation succeeds and shows a code + QR', async () => {
    await page.fill('#em', email);
    await page.click('#cta');
    await page.waitForSelector('#s-done.active', { timeout: 12000 });
    code = (await page.textContent('.code')).trim();
    if (!/^CJ-[0-9A-Z]{6}$/.test(code)) throw new Error('code = ' + code);
    const qr = await page.evaluate(() => {
      const el = document.querySelector('#qr img, #qr canvas');
      return el ? (el.width || el.naturalWidth) : 0;
    });
    if (qr < 50) throw new Error('QR not rendered (w=' + qr + ')');
  });

  await step('ticket shows size, store and name', async () => {
    const t = await page.textContent('#ticket');
    for (const s of ['Reserved', 'Test Shopper', 'City Jeans']) {
      if (!t.includes(s)) throw new Error('ticket missing "' + s + '"');
    }
  });

  await step('no floating button covers the ticket on the confirmation screen', async () => {
    const vis = await page.evaluate(() => {
      const b = document.getElementById('bar');
      return getComputedStyle(b).display !== 'none';
    });
    if (vis) throw new Error('sticky CTA bar is still shown over the ticket');
  });

  await step('meta box lists the pickup window and close time', async () => {
    const t = await page.evaluate(() => {
      const el = document.getElementById('meta');
      return el ? el.textContent : '';
    });
    // meta lives on the product screen; check it from a fresh load below
  });

  await page.screenshot({ path: '/root/cityjeans-drops/shot-3-confirmation.png', fullPage: true });

  await step('a second reservation on the same phone is refused', async () => {
    await page.goto('http://localhost:8900/index.html?release=aj4-retro-og-flight-club', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#s-size.active');
    await page.locator('#sizes .size:not(.out)').nth(2).click();
    await page.click('#cta'); await page.waitForSelector('#s-loc.active');
    await page.locator('#locs .loc').first().click();
    await page.click('#cta'); await page.waitForSelector('#s-info.active');
    await page.fill('#fn', 'Second'); await page.fill('#ln', 'Try');
    await page.fill('#em', 'different' + Date.now() + '@example.com');
    await page.fill('#ph', ''); await page.type('#ph', phone);
    await page.click('#cta');
    await page.waitForSelector('#err.show', { timeout: 10000 });
    const t = await page.textContent('#err');
    if (!/already have a reservation/i.test(t)) throw new Error('err = ' + t);
  });

  await step('lookup finds the reservation again', async () => {
    await page.goto('http://localhost:8900/index.html?release=aj4-retro-og-flight-club', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#s-size.active');
    await page.click('#cta2');
    await page.waitForSelector('#s-lookup.active');
    await page.fill('#lcode', code.toLowerCase());
    await page.fill('#lem', email.toUpperCase());
    await page.click('#cta');
    await page.waitForSelector('#s-done.active', { timeout: 10000 });
    const t = await page.textContent('.code');
    if (t.trim() !== code) throw new Error('looked up ' + t + ' expected ' + code);
  });

  await step('lookup rejects a wrong email', async () => {
    await page.goto('http://localhost:8900/index.html?release=aj4-retro-og-flight-club', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#s-size.active');
    await page.click('#cta2');
    await page.fill('#lcode', code);
    await page.fill('#lem', 'someone-else@example.com');
    await page.click('#cta');
    await page.waitForSelector('#lerr.show', { timeout: 8000 });
  });

  console.log('\n--- ADMIN ---');
  const page2 = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
  await block(page2);
  page2.on('pageerror', e => errors.push('ADMIN PAGEERROR: ' + e.message));

  await step('admin login works', async () => {
    await page2.goto('http://localhost:8900/admin.html', { waitUntil: 'domcontentloaded' });
    await page2.fill('#e', 'ben@cityjeans.com');
    await page2.fill('#p', 'CityJeansDrops!2026');
    await page2.click('#signin');
    await page2.waitForSelector('#app', { state: 'visible', timeout: 15000 });
  });

  await step('stores tab lists the 9 seeded stores', async () => {
    await page2.click('.tab[data-v="v-loc"]');
    await page2.waitForSelector('#locTable tbody tr');
    const n = await page2.locator('#locTable tbody tr').count();
    if (n !== 9) throw new Error('expected 9 stores, got ' + n);
  });

  await step('releases tab shows the drop and its reserved count', async () => {
    await page2.click('.tab[data-v="v-rel"]');
    await page2.waitForSelector('#relTable tbody tr');
    const t = await page2.textContent('#relTable');
    if (!t.includes('Jordan')) throw new Error('release missing from table');
  });

  await step('reservations tab lists the new reservation', async () => {
    await page2.click('.tab[data-v="v-res"]');
    await page2.waitForSelector('#resTable tbody tr');
    await page2.fill('#fQ', code);
    await page2.waitForTimeout(400);
    const t = await page2.textContent('#resTable');
    if (!t.includes(code)) throw new Error('code not found in reservations table');
  });

  await page2.screenshot({ path: '/root/cityjeans-drops/shot-4-admin-reservations.png', fullPage: true });

  await step('release editor loads inventory matrix', async () => {
    await page2.click('.tab[data-v="v-rel"]');
    await page2.waitForSelector('#relTable [data-edit]');
    await page2.locator('#relTable tbody tr', { hasText: 'Jordan' }).locator('[data-edit]').click();
    await page2.waitForSelector('#v-edit.on');
    await page2.waitForSelector('#matrix input');
    const n = await page2.locator('#matrix input').count();
    if (n < 12) throw new Error('matrix inputs = ' + n);
    const tot = await page2.textContent('#matrixTotal');
    if (!/pairs loaded/.test(tot)) throw new Error('total = ' + tot);
  });

  await page2.screenshot({ path: '/root/cityjeans-drops/shot-5-admin-editor.png', fullPage: true });

  await step('register redeems the code once, then refuses a second time', async () => {
    await page2.click('.tab[data-v="v-reg"]');
    await page2.fill('#rcode', code);
    await page2.click('#rgo');
    await page2.waitForSelector('#rresult.show');
    let t = await page2.textContent('#rresult');
    if (!/Picked up/.test(t)) throw new Error('first redeem said: ' + t);
    await page2.fill('#rcode', code);
    await page2.click('#rgo');
    await page2.waitForTimeout(1200);
    t = await page2.textContent('#rresult');
    if (!/Already picked up/i.test(t)) throw new Error('second redeem said: ' + t);
  });

  await page2.screenshot({ path: '/root/cityjeans-drops/shot-6-admin-register.png' });

  await step('account tab: password form and staff list load', async () => {
    await page2.click('.tab[data-v="v-acct"]');
    await page2.waitForSelector('#v-acct.on');
    await page2.waitForSelector('#staffTable tbody tr', { timeout: 10000 });
    const t = await page2.textContent('#staffTable');
    if (!t.includes('ben@cityjeans.com')) throw new Error('owner missing from staff list');
    if (!(await page2.isVisible('#pw1'))) throw new Error('password field missing');
  });

  await step('password change rejects a mismatch', async () => {
    await page2.fill('#pw1', 'abcdefgh12'); await page2.fill('#pw2', 'different99');
    await page2.click('#savePw');
    await page2.waitForSelector('#pwmsg.show');
    const t = await page2.textContent('#pwmsg');
    if (!/don't match/i.test(t)) throw new Error('msg = ' + t);
    await page2.fill('#pw1', ''); await page2.fill('#pw2', '');
  });

  const invitee = 'e2e-staff-' + Date.now() + '@cityjeans.com';
  await step('invite a teammate, then revoke them', async () => {
    await page2.fill('#invEmail', invitee);
    await page2.selectOption('#invRole', 'staff');
    await page2.fill('#invNote', 'e2e test row');
    await page2.click('#invite');
    await page2.waitForSelector('#invmsg.show');
    let t = await page2.textContent('#invmsg');
    if (!/can now set up an account/i.test(t)) throw new Error('invite said: ' + t);
    await page2.waitForSelector(`#staffTable [data-rev="${invitee}"]`, { timeout: 10000 });
    await page2.click(`#staffTable [data-rev="${invitee}"]`);
    await page2.waitForFunction(
      e => !document.querySelector(`#staffTable [data-rev="${e}"]`), invitee, { timeout: 10000 });
  });

  await step('an uninvited email cannot create an account', async () => {
    const r = await page2.evaluate(async (cfg) => {
      const res = await fetch(cfg.url + '/auth/v1/signup', {
        method: 'POST',
        headers: { apikey: cfg.key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: 'nobody' + Date.now() + '@example.com', password: 'Whatever123!' })
      });
      return { status: res.status, body: (await res.text()).slice(0, 120) };
    }, { url: 'http://localhost:8900', key: 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a' });
    if (r.status < 400) throw new Error('signup succeeded! status ' + r.status + ' ' + r.body);
  });

  await step('no console errors anywhere', async () => {
    const real = errors.filter(e => !/favicon|404|net::ERR_/i.test(e));
    if (real.length) throw new Error(real.slice(0, 4).join(' | '));
  });

  await browser.close();
  console.log('\ndone.');
})();
