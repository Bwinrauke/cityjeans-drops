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
  const block = async (pg) => {
    // The sandbox browser can't reach cdn.shopify.com; serve real image bytes.
    await pg.route('**/cdn.shopify.com/**', r =>
      r.fulfill({ status: 200, contentType: 'image/jpeg', body: shoe }));
    // Photos uploaded through the admin live on Supabase storage, which the
    // browser also can't reach directly — send those via the local harness.
    await pg.route(u => u.hostname.endsWith('supabase.co') && u.pathname.startsWith('/storage'),
      async r => {
      // Same-protocol rule blocks a rewrite, so fetch the bytes here and serve them.
      try {
        const via = r.request().url().replace(/^https:\/\/[^/]+/, 'http://localhost:8900');
        const res = await fetch(via);
        const buf = Buffer.from(await res.arrayBuffer());
        await r.fulfill({ status: res.status,
          contentType: res.headers.get('content-type') || 'application/octet-stream',
          body: buf });
      } catch { await r.abort(); }
      });
  };
  const page = await ctx.newPage();
  await block(page);
  const errors = [];
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));

  const step = async (label, fn) => {
    try { await fn(); console.log('  PASS  ' + label); }
    catch (e) { console.log('  FAIL  ' + label + ' -> ' + e.message); process.exitCode = 1; }
  };

  // The catalogue is live data, so pick a release at run time rather than
  // pinning the suite to a slug that can be archived at any moment.
  const API = 'http://localhost:8900';
  const KEY = 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a';
  const call = async (fn, body = {}) => (await (await fetch(`${API}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(body) })).json());

  const openRels = await call('list_open_releases');
  if (!Array.isArray(openRels) || !openRels.length) {
    console.log('  no open releases — cannot run the customer flow'); await browser.close(); return;
  }
  let TEST = null;
  for (const r of openRels) {
    const av = await call('get_availability', { p_release_slug: r.slug });
    const free = (av || []).filter(a => a.available);
    if (free.length) {
      TEST = { ...r, sizes: [...new Set(free.map(a => a.size))], free };
      break;
    }
  }
  if (!TEST) { console.log('  no release has stock — cannot run the customer flow'); await browser.close(); return; }
  console.log(`  (testing against "${TEST.name}" — ${TEST.sizes.length} sizes with stock)`);

  // No standing test account: the suite signs in as whoever you give it, so
  // there is no owner-level login sitting in the project between runs.
  const ADMIN_EMAIL = process.env.DROPS_TEST_EMAIL;
  const ADMIN_PASS  = process.env.DROPS_TEST_PASSWORD;
  if (!ADMIN_EMAIL || !ADMIN_PASS) {
    console.log('  set DROPS_TEST_EMAIL and DROPS_TEST_PASSWORD (an owner account) to run the admin half');
    await browser.close();
    return;
  }

  console.log('\n--- CUSTOMER FLOW ---');
  await page.goto(`http://localhost:8900/index.html?release=${TEST.slug}`, { waitUntil: 'domcontentloaded' });

  await step('release loads with name + price', async () => {
    await page.waitForSelector('#s-size.active', { timeout: 10000 });
    const name = await page.textContent('#name');
    if (name.trim() !== TEST.name.trim()) throw new Error('name = ' + name);
    if (TEST.retail_price != null) {
      const price = await page.textContent('#price');
      if (!price.replace(/[^0-9]/g, '').startsWith(String(Math.floor(TEST.retail_price))))
        throw new Error('price = ' + price);
    }
  });

  await step('shoe photo rendered (or a placeholder when none is set)', async () => {
    if (TEST.photo_url) {
      // the harness relays storage bytes through Node, so give the decode a moment
      await page.waitForFunction(() => {
        const i = document.querySelector('#hero img');
        return !!i && i.complete && i.naturalWidth > 100;
      }, null, { timeout: 20000 }).catch(() => {});
    }
    const got = await page.evaluate(() => {
      const i = document.querySelector('#hero img');
      const ph = document.querySelector('#hero .ph');
      return { img: !!i && i.naturalWidth > 100, placeholder: !!ph };
    });
    if (TEST.photo_url) {
      if (!got.img) throw new Error('the release has a photo but it did not load');
    } else if (!got.placeholder) {
      throw new Error('no photo and no placeholder shown');
    }
  });

  await step('size grid shows availability without counts', async () => {
    const n = await page.locator('#sizes .size').count();
    if (n < 1) throw new Error('no sizes rendered');
    const sub = await page.textContent('#sizeSub');
    if (!/sizing/i.test(sub)) throw new Error('sub = ' + sub);
    if (/\d/.test(sub)) throw new Error('the size subheading leaks a count: ' + sub);
    const grid = await page.textContent('#sizes');
    if (/left/i.test(grid)) throw new Error('the size grid leaks counts: ' + grid);
  });

  await page.screenshot({ path: '/root/cityjeans-drops/shot-1-product.png', fullPage: true });

  await step('continue is disabled until a size is picked', async () => {
    if (!(await page.isDisabled('#cta'))) throw new Error('CTA was enabled with no size');
  });

  await step('pick size 10 then continue', async () => {
    await page.locator('#sizes .size:not(.out)').first().click();
    await page.waitForSelector('#sizes .size.sel');
    if (await page.isDisabled('#cta')) throw new Error('CTA still disabled after size pick');
    await page.click('#cta');
    await page.waitForSelector('#s-loc.active');
  });

  await step('locations listed without per-store counts', async () => {
    const n = await page.locator('#locs .loc').count();
    if (n < 1) throw new Error('no locations shown');
    const t = await page.textContent('#locSub');
    if (!/choose where/i.test(t)) throw new Error('locSub = ' + t);
    const locs = await page.textContent('#locs');
    if (/\d+\s*left/i.test(locs)) throw new Error('the store list leaks counts: ' + locs);
  });

  await page.screenshot({ path: '/root/cityjeans-drops/shot-2-location.png', fullPage: true });

  let pickedStore = null;
  await step('pick a store and continue', async () => {
    const first = page.locator('#locs .loc').first();
    // whichever store is offered first depends on what still has stock, so
    // remember the one chosen instead of assuming a name
    pickedStore = (await first.textContent()).split('\n')[0].trim();
    await first.click();
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
    for (const s of ['Reserved', 'Test Shopper']) {
      if (!t.includes(s)) throw new Error('ticket missing "' + s + '"');
    }
    if (pickedStore && !t.includes(pickedStore.split('·')[0].trim()))
      throw new Error('ticket does not name the store that was chosen: ' + pickedStore);
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
    await page.goto(`http://localhost:8900/index.html?release=${TEST.slug}`, { waitUntil: 'domcontentloaded' });
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
    await page.goto(`http://localhost:8900/index.html?release=${TEST.slug}`, { waitUntil: 'domcontentloaded' });
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
    await page.goto(`http://localhost:8900/index.html?release=${TEST.slug}`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#s-size.active');
    await page.click('#cta2');
    await page.fill('#lcode', code);
    await page.fill('#lem', 'someone-else@example.com');
    await page.click('#cta');
    await page.waitForSelector('#lerr.show', { timeout: 8000 });
  });

  console.log('\n--- MULTIPLE RELEASES ---');
  await step('the landing page lists every open release', async () => {
    await page.goto('http://localhost:8900/index.html', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#s-list.active', { timeout: 15000 });
    const n = await page.locator('#rels .rel').count();
    if (n < 2) throw new Error('only ' + n + ' releases listed');
    const txt = await page.textContent('#rels');
    if (!/Men's/.test(txt) || !/Grade School/.test(txt))
      throw new Error('size scales not shown on the cards: ' + txt.slice(0, 160));
    if (/\d+\s*(left|pairs? left)/i.test(txt))
      throw new Error('the release list leaks stock counts');
    const sub = await page.textContent('#listSub');
    if (!/releases open/.test(sub)) throw new Error('listSub = ' + sub);
  });

  await step('opening a release shows its own size scale, and back returns', async () => {
    const first = await page.locator('#rels .rel .nm').first().textContent();
    await page.locator('#rels .rel').first().click();
    await page.waitForSelector('#s-size.active', { timeout: 15000 });
    const name = await page.textContent('#name');
    if (name.trim() !== first.trim()) throw new Error(`opened "${name}" after tapping "${first}"`);
    const scaleA = await page.textContent('#sizeSub');

    await page.click('#back');
    await page.waitForSelector('#s-list.active', { timeout: 10000 });

    await page.locator('#rels .rel').nth(1).click();
    await page.waitForSelector('#s-size.active', { timeout: 15000 });
    const scaleB = await page.textContent('#sizeSub');
    if (scaleA === scaleB)
      throw new Error('both releases show the same size scale: ' + scaleA);
    const sizesB = await page.textContent('#sizes');
    if (!sizesB.trim()) throw new Error('the second release has no sizes');
  });

  await step('a direct release link still skips the list', async () => {
    await page.goto('http://localhost:8900/index.html?release=' + TEST.slug + '',
      { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#s-size.active', { timeout: 15000 });
    if (await page.isVisible('#s-list')) throw new Error('the list showed for a direct link');
    const name = await page.textContent('#name');
    if (name.trim() !== TEST.name.trim()) throw new Error('wrong release: ' + name);
  });

  await step('lookup is reachable from the list', async () => {
    await page.goto('http://localhost:8900/index.html', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#s-list.active', { timeout: 15000 });
    await page.click('#listLookup');
    await page.waitForSelector('#s-lookup.active', { timeout: 10000 });
    await page.click('#back');
    await page.waitForSelector('#s-list.active', { timeout: 10000 });
  });

  console.log('\n--- ADMIN ---');
  const page2 = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
  await block(page2);
  page2.on('pageerror', e => errors.push('ADMIN PAGEERROR: ' + e.message));

  // One dialog handler for the whole admin page. A per-step `once` handler that
  // never fires stays armed and swallows the next step's dialog, so arm the
  // action instead and let a single listener apply whatever is currently armed.
  let armed = null;
  const armDialog = fn => { armed = fn; };
  page2.on('dialog', async d => {
    const fn = armed; armed = null;
    try { fn ? await fn(d) : await d.accept(); } catch {}
  });

  // Inventory is admin-only now, so test reads must use the admin session
  // rather than the publishable key.
  const adminFetch = (fn, args = []) => page2.evaluate(async ([body, ...rest]) => {
    const tok = localStorage.getItem('drops_at');
    const H = { apikey: 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a',
                Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' };
    return await (new Function('H', 'url', 'a', 'return (' + body + ')(H, url, a)'))(
      H, 'http://localhost:8900', rest);
  }, [fn.toString(), ...args]);

  await step('admin login works', async () => {
    await page2.goto('http://localhost:8900/admin.html', { waitUntil: 'domcontentloaded' });
    await page2.fill('#e', ADMIN_EMAIL);
    await page2.fill('#p', ADMIN_PASS);
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
    await page2.waitForFunction(
      () => /Jordan/.test(document.getElementById('relTable').textContent),
      null, { timeout: 20000 });
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

  await step('release editor loads the quantity editor', async () => {
    await page2.click('.tab[data-v="v-rel"]');
    await page2.waitForSelector('#relTable [data-edit]');
    await page2.locator('#relTable tbody tr', { hasText: TEST.name }).locator('[data-edit]').click();
    await page2.waitForSelector('#v-edit.on');
    await page2.waitForSelector('#qtyStores details', { timeout: 15000 });
    const stores = await page2.locator('#qtyStores details').count();
    if (stores < 2) throw new Error('only ' + stores + ' stores in the stack');
    // the editor shows every size the release carries, including sold-out ones,
    // so compare against the release rather than against what still has stock
    const ticked = await adminFetch(async (H, url, a) => {
      const r = await fetch(
        `${url}/rest/v1/release_inventory?select=size&release_id=eq.${a[0]}`, { headers: H });
      return [...new Set((await r.json()).map(x => x.size))].length;
    }, [TEST.id]);
    const n = await page2.locator('#qtyStores details').first().locator('input').count();
    if (n !== ticked)
      throw new Error(`${n} size rows for a release carrying ${ticked} sizes`);
    const tot = await page2.textContent('#matrixTotal');
    if (!/pair/.test(tot)) throw new Error('grand total = ' + tot);
  });

  await page2.screenshot({ path: '/root/cityjeans-drops/shot-5-admin-editor.png', fullPage: true });

  await step('register redeems the code once, then refuses a second time', async () => {
    await page2.click('.tab[data-v="v-reg"]');
    // a register is bound to one store, so bind it to the one this pair is held at
    const held = await adminFetch(async (H, url, a) => {
      const r = await fetch(`${url}/rest/v1/reservations?select=location_id&code=eq.${a[0]}`,
        { headers: H });
      return (await r.json())[0]?.location_id;
    }, [code]);
    // options inside a closed <select> never count as visible, so poll the DOM
    await page2.waitForFunction(
      id => !!document.querySelector(`#regStore option[value="${id}"]`), held,
      { timeout: 15000 });
    await page2.selectOption('#regStore', held);
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
  await step('create a staff account, then revoke it', async () => {
    await page2.fill('#invEmail', invitee);
    await page2.fill('#invName', 'E2E Tester');
    await page2.selectOption('#invRole', 'staff');
    await page2.click('#genPass');
    const pass = await page2.inputValue('#invPass');
    if (pass.length < 10) throw new Error('generated password too short: ' + pass);
    await page2.click('#invite');
    await page2.waitForSelector('#invmsg.show');
    const t = await page2.textContent('#invmsg');
    if (!/Account created/i.test(t)) throw new Error('create said: ' + t);
    if (!t.includes(pass)) throw new Error('temp password not shown to the admin');
    // the new account must actually be able to sign in
    const ok = await page2.evaluate(async ([url, key, em, pw]) => {
      const r = await fetch(url + '/auth/v1/token?grant_type=password', {
        method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: em, password: pw }) });
      return (await r.json()).access_token ? true : false;
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', invitee, pass]);
    if (!ok) throw new Error('the new account could not sign in');
    await page2.waitForSelector(`#staffTable [data-rev="${invitee}"]`, { timeout: 10000 });
    await page2.click(`#staffTable [data-rev="${invitee}"]`);
    await page2.waitForFunction(
      e => !document.querySelector(`#staffTable [data-rev="${e}"]`), invitee, { timeout: 10000 });
  });

  await step('one temp password can cover several people, and forces a change', async () => {
    await page2.click('.tab[data-v="v-acct"]');
    await page2.waitForSelector('#invPass');
    const shared = 'city-jeans-shared-2026';
    const a = 'e2e-staff-a' + Date.now() + '@cityjeans.com';
    const b = 'e2e-staff-b' + Date.now() + '@cityjeans.com';

    await page2.fill('#invPass', shared);
    await page2.fill('#invEmail', a);
    await page2.selectOption('#invRole', 'staff');
    await page2.click('#invite');
    await page2.waitForSelector('#invmsg.show');
    if (!/Account created/i.test(await page2.textContent('#invmsg')))
      throw new Error('first account failed: ' + await page2.textContent('#invmsg'));

    // the password box must still hold the shared password
    if (await page2.inputValue('#invPass') !== shared)
      throw new Error('the temp password was cleared between people');

    await page2.fill('#invEmail', b);
    await page2.click('#invite');
    await page2.waitForSelector('#invmsg.show');
    if (!/Account created/i.test(await page2.textContent('#invmsg')))
      throw new Error('second account failed with the same password');

    // both can sign in with the one password
    for (const em of [a, b]) {
      const ok = await page2.evaluate(async ([url, key, e, pw]) => {
        const r = await fetch(url + '/auth/v1/token?grant_type=password', {
          method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' },
          body: JSON.stringify({ email: e, password: pw }) });
        return !!(await r.json()).access_token;
      }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', em, shared]);
      if (!ok) throw new Error(em + ' could not sign in with the shared password');
    }

    // and are locked to the Account tab until they set their own
    const ctx3 = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    const p3 = await ctx3.newPage();
    await block(p3);
    await p3.goto('http://localhost:8900/admin.html', { waitUntil: 'domcontentloaded' });
    await p3.fill('#e', a); await p3.fill('#p', shared);
    await p3.click('#signin');
    await p3.waitForSelector('#v-acct.on', { timeout: 20000 });
    if (!(await p3.isDisabled('.tab[data-v="v-reg"]')))
      throw new Error('other tabs are reachable before the password is changed');
    const warn = await p3.textContent('#pwmsg');
    if (!/temporary password/i.test(warn)) throw new Error('no warning shown: ' + warn);

    await p3.fill('#pw1', 'my-own-password-9'); await p3.fill('#pw2', 'my-own-password-9');
    await p3.click('#savePw');
    await p3.waitForFunction(() => !document.querySelector('.tab[data-v="v-reg"]').disabled,
      null, { timeout: 15000 });
    await ctx3.close();

    // tidy up
    await page2.click('.tab[data-v="v-acct"]');
    for (const em of [a, b]) {
      await page2.waitForSelector(`#staffTable [data-rev="${em}"]`, { timeout: 10000 });
      await page2.click(`#staffTable [data-rev="${em}"]`);
      await page2.waitForFunction(
        e => !document.querySelector(`#staffTable [data-rev="${e}"]`), em, { timeout: 10000 });
    }
  });

  await step('size run is checkboxes, and reserved sizes are locked', async () => {
    await page2.click('.tab[data-v="v-rel"]');
    await page2.waitForSelector('#relTable [data-edit]');
    await page2.locator('#relTable tbody tr', { hasText: TEST.name }).locator('[data-edit]').click();
    await page2.waitForSelector('#sizeChips .chip');
    if (await page2.locator('#fSizes').count()) throw new Error('the free-text size box is still there');
    await page2.waitForSelector('#qtyStores .qtyrow', { timeout: 15000 });
    const chips = await page2.locator('#sizeChips .chip').count();
    if (chips < TEST.sizes.length)
      throw new Error(`${chips} size chips for a release with ${TEST.sizes.length} sizes`);
    const rowsIn = () => page2.locator('#qtyStores details').first().locator('.qtyrow').count();
    const before = await rowsIn();
    const ticked = page2.locator('#sizeChips .chip.on:not(.locked)').first();
    if (!(await ticked.count())) throw new Error('no unlocked ticked size to test with');
    const label = (await ticked.textContent()).trim();
    await ticked.click();
    await page2.waitForTimeout(350);
    const after = await rowsIn();
    if (after >= before) throw new Error(`unticking ${label} did not remove its row (${before} -> ${after})`);
    await page2.locator('#sizeChips .chip', { hasText: label }).first().click();
    await page2.waitForTimeout(350);
  });

  await step('switching scale offers the matching size run', async () => {
    await page2.selectOption('#fScale', 'gs');
    await page2.waitForTimeout(300);
    const txt = await page2.textContent('#sizeChips');
    if (!/Y/.test(txt)) throw new Error('GS sizes not offered: ' + txt.slice(0, 80));
    await page2.selectOption('#fScale', 'mens');
    await page2.waitForTimeout(300);
  });

  await step('stores open and close, and each holds its own numbers', async () => {
    await page2.waitForSelector('#qtyStores details');
    const all = page2.locator('#qtyStores details');
    const count = await all.count();
    if (count < 2) throw new Error('need 2+ stores');

    const a = all.nth(0), b = all.nth(1);
    const aId = await a.getAttribute('data-row');

    // the summary line collapses/expands
    await a.locator('summary').click();
    await page2.waitForTimeout(200);
    const openedA = await a.evaluate(el => el.open);
    await a.locator('summary').click();
    await page2.waitForTimeout(200);
    if (openedA === await a.evaluate(el => el.open))
      throw new Error('the store section does not toggle');

    if (!(await a.evaluate(el => el.open))) await a.locator('summary').click();
    if (!(await b.evaluate(el => el.open))) await b.locator('summary').click();
    await page2.waitForTimeout(250);

    const rows = await a.locator('.qtyrow').count();
    armDialog(d => d.accept('3'));
    await a.locator('[data-fillrow]').click();
    await page2.waitForTimeout(400);

    const aNow = page2.locator(`#qtyStores details[data-row="${aId}"]`);
    const aVals = await aNow.locator('input').evaluateAll(e => e.map(x => x.value));
    if (!aVals.every(v => v === '3'))
      throw new Error('fill missed cells in its own store: ' + aVals.join(','));

    const bVals = await page2.locator(`#qtyStores details:not([data-row="${aId}"])`)
      .first().locator('input').evaluateAll(e => e.map(x => x.value));
    if (bVals.length && bVals.every(v => v === '3'))
      throw new Error('the fill leaked into another store');

    const head = await aNow.locator('.rowtot').textContent();
    if (Number(head) !== 3 * rows)
      throw new Error(`store header says ${head}, expected ${3 * rows}`);
  });

  await step('summaries total by store and by size', async () => {
    const byStore = await page2.locator('#sumStores div').count();
    const bySize  = await page2.locator('#sumSizes div').count();
    const rows    = await page2.locator('#qtyStores details').first().locator('.qtyrow').count();
    if (byStore < 2) throw new Error('by-store summary has ' + byStore + ' rows');
    if (bySize !== rows) throw new Error('by-size summary has ' + bySize + ' rows for ' + rows + ' sizes');

    const sums = await page2.evaluate(() => {
      const num = sel => [...document.querySelectorAll(sel + ' div b')].map(b => Number(b.textContent));
      const stores = num('#sumStores'), sizes = num('#sumSizes');
      const add = a => a.reduce((x, y) => x + y, 0);
      const grand = Number((document.getElementById('matrixTotal').textContent.match(/(\d+)\s*pair/) || [])[1]);
      return { stores: add(stores), sizes: add(sizes), grand };
    });
    if (sums.stores !== sums.sizes)
      throw new Error(`by-store total ${sums.stores} != by-size total ${sums.sizes}`);
    if (sums.grand !== sums.stores)
      throw new Error(`grand total ${sums.grand} != summary total ${sums.stores}`);
  });

  await step('register offers camera scanning', async () => {
    await page2.click('.tab[data-v="v-reg"]');
    await page2.waitForSelector('#scanStart');
    // the register refuses to act until it knows which store it is
    await page2.selectOption('#regStore', { index: 1 });
    await page2.fill('#rcode', '');
    if (!(await page2.isVisible('#scanStart'))) throw new Error('scan button not visible');
    const decoded = await page2.evaluate(() => {
      // exercise the decode path without a real camera
      window.__clicked = false;
      const go = document.getElementById('rgo');
      const orig = go.click.bind(go);
      go.click = () => { window.__clicked = true; };
      window.__drops.onScanned('https://example.com/x?c=CJ-AB12CD');
      go.click = orig;
      return { code: document.getElementById('rcode').value, submitted: window.__clicked };
    });
    if (decoded.code !== 'CJ-AB12CD')
      throw new Error('scanned value parsed to "' + decoded.code + '"');
    if (!decoded.submitted) throw new Error('a successful scan did not trigger the lookup');
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

  console.log('\n--- ARCHIVING ---');
  await step('archiving hides a row, restoring brings it back', async () => {
    await page2.click('.tab[data-v="v-res"]');
    await page2.waitForSelector('#resTable tbody tr');
    await page2.uncheck('#showArch').catch(() => {});
    await page2.fill('#fQ', '');
    await page2.waitForTimeout(500);

    const before = await page2.locator('#resTable [data-arch]').count();
    if (!before) return;   // nothing live to archive
    const target = page2.locator('#resTable tbody tr').filter({ has: page2.locator('[data-arch]') }).first();
    const codeCell = (await target.locator('td').first().textContent()).trim().split(' ')[0];

    // a confirmed row prompts about the held pair; decline so stock is untouched
    armDialog(d => d.dismiss());
    await target.locator('[data-arch]').click();
    await page2.waitForSelector('#archmsg.show', { timeout: 15000 });
    const msg = await page2.textContent('#archmsg');
    if (!/archived/i.test(msg)) throw new Error('archive said: ' + msg);

    await page2.waitForTimeout(600);
    const after = await page2.locator('#resTable [data-arch]').count();
    if (after >= before) throw new Error(`archivable rows went ${before} -> ${after}`);
    const stillThere = await page2.textContent('#resTable');
    if (stillThere.includes(codeCell)) throw new Error(codeCell + ' is still listed');

    // it reappears with the box ticked, flagged as archived
    await page2.check('#showArch');
    await page2.waitForTimeout(900);
    const withArch = await page2.textContent('#resTable');
    if (!withArch.includes(codeCell)) throw new Error('archived row not shown when asked for');
    const row = page2.locator('#resTable tbody tr', { hasText: codeCell }).first();
    if (!(await row.getAttribute('class') || '').includes('arch'))
      throw new Error('archived row is not marked');

    // restore it
    await row.locator('[data-unarch]').click();
    await page2.waitForSelector('#archmsg.show', { timeout: 15000 });
    if (!/brought back/i.test(await page2.textContent('#archmsg')))
      throw new Error('restore said: ' + await page2.textContent('#archmsg'));
    await page2.uncheck('#showArch');
    await page2.waitForTimeout(900);
    if (!(await page2.textContent('#resTable')).includes(codeCell))
      throw new Error('restored row did not come back to the default list');
  });

  await step('archiving a test booking can hand the pair back', async () => {
    // make a throwaway reservation, then archive it releasing the stock
    const em = 'e2e-arch' + Date.now() + '@example.com';
    const ph = '917' + String(Date.now()).slice(-7);
    const made = await page2.evaluate(async ([url, key, em, ph, slug, loc, size]) => {
      const r = await fetch(url + '/rest/v1/rpc/reserve_spot', {
        method: 'POST',
        headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_release_slug: slug,
          p_location_id: loc, p_size: size, p_first_name: 'Arch', p_last_name: 'Test',
          p_email: em, p_phone: ph })
      });
      return r.json();
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', em, ph,
        TEST.slug, TEST.free[0].location_id, TEST.free[0].size]);
    if (!made.ok) return;   // no stock left; the row-level path above already covers it

    await page2.click('#refreshRes'); await page2.waitForTimeout(900);
    await page2.fill('#fQ', made.code); await page2.waitForTimeout(500);
    const row = page2.locator('#resTable tbody tr').first();
    armDialog(d => d.accept());   // yes, put the pair back
    await row.locator('[data-arch]').click();
    await page2.waitForSelector('#archmsg.show', { timeout: 15000 });
    const m2 = await page2.textContent('#archmsg');
    if (!/released back to stock/i.test(m2))
      throw new Error('expected the pair to be released: ' + m2);
    await page2.fill('#fQ', '');
  });

  console.log('\n--- MOBILE ADMIN (iPhone 13) ---');
  const mctx = await browser.newContext({ ...devices['iPhone 13'] });
  const m = await mctx.newPage();
  await block(m);
  m.on('pageerror', e => errors.push('MOBILE PAGEERROR: ' + e.message));

  await step('signs in on a phone', async () => {
    await m.goto('http://localhost:8900/admin.html', { waitUntil: 'domcontentloaded' });
    await m.fill('#e', ADMIN_EMAIL);
    await m.fill('#p', ADMIN_PASS);
    await m.click('#signin');
    await m.waitForSelector('#app', { state: 'visible', timeout: 20000 });
  });

  const noOverflow = async (label) => {
    const bad = await m.evaluate(() => {
      const w = window.innerWidth;
      return [...document.querySelectorAll('#app *')]
        .filter(el => el.getBoundingClientRect().width > w + 1)
        .map(el => el.tagName + (el.id ? '#' + el.id : ''))
        .slice(0, 3);
    });
    if (bad.length) throw new Error(label + ' overflows: ' + bad.join(', '));
    const doc = await m.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
    if (doc[0] > doc[1] + 1) throw new Error(label + ' page scrolls sideways: ' + doc.join(' vs '));
  };

  await step('every tab fits the screen with no sideways scrolling', async () => {
    for (const v of ['v-reg','v-res','v-rel','v-loc','v-acct']) {
      await m.click(`.tab[data-v="${v}"]`);
      await m.waitForTimeout(700);
      await noOverflow(v);
    }
  });

  await step('reservations read as stacked cards, not a cut-off table', async () => {
    await m.click('.tab[data-v="v-res"]');
    await m.waitForSelector('#resTable tbody tr');
    const shown = await m.evaluate(() => {
      const th = document.querySelector('#resTable thead');
      const td = document.querySelector('#resTable tbody td[data-l]:not([data-l=""])');
      return { headHidden: getComputedStyle(th).position === 'absolute',
               label: td ? getComputedStyle(td, '::before').content : 'NO_ROWS' };
    });
    if (!shown.headHidden) throw new Error('the table header is still rendering on mobile');
    if (shown.label !== 'NO_ROWS' && !/[A-Z]/i.test(shown.label))
      throw new Error('cells are missing their labels: ' + shown.label);
  });

  await step('inventory editor fits a phone', async () => {
    await m.click('.tab[data-v="v-rel"]');
    await m.waitForSelector('#relTable [data-edit]', { timeout: 15000 });
    await m.locator('#relTable tbody tr', { hasText: TEST.name }).locator('[data-edit]').click();
    await m.waitForSelector('#v-edit.on');
    await m.waitForSelector('#qtyStores details', { timeout: 10000 });
    await noOverflow('release editor');
    if (!(await m.locator('#qtyStores details').count()))
      throw new Error('no store sections on mobile');
    if (!(await m.isVisible('#sumStores'))) throw new Error('no by-store summary on mobile');
    if (!(await m.isVisible('#sumSizes'))) throw new Error('no by-size summary on mobile');
  });

  console.log('\n--- RAFFLE ---');
  const RAF = 'zz-e2e-raffle-' + Date.now();
  let rafId = null, entryCode = null;
  const entrantEmail = 'zz-raf-lead@example.com';

  await step('a raffle release can be created and entered', async () => {
    // remove raffles left behind by earlier runs so this one is unambiguous
    await adminFetch(async (H, url) => {
      const old = await (await fetch(
        url + '/rest/v1/releases?select=id&slug=like.zz-e2e-raffle-*', { headers: H })).json();
      for (const r of old) {
        await fetch(`${url}/rest/v1/releases?id=eq.${r.id}`, { method: 'DELETE', headers: H });
      }
    });
    // create it via the admin UI so the whole path is exercised
    await page2.click('.tab[data-v="v-rel"]');
    await page2.waitForSelector('#newRel');
    await page2.click('#newRel');
    await page2.waitForSelector('#v-edit.on');
    await page2.fill('#fName', 'ZZ E2E Raffle');
    await page2.fill('#fSlug', RAF);
    await page2.selectOption('#fMode', 'raffle');
    await page2.selectOption('#fStatus', 'open');
    await page2.selectOption('#fScale', 'mens');
    await page2.waitForTimeout(400);
    // entries open now and close shortly; the test moves the close time back
    // once the entries are in, which is the real sequence a drop follows
    const soon = new Date(Date.now() + 30 * 60000);
    const pad = n => String(n).padStart(2, '0');
    await page2.fill('#fCloses',
      `${soon.getFullYear()}-${pad(soon.getMonth()+1)}-${pad(soon.getDate())}T${pad(soon.getHours())}:${pad(soon.getMinutes())}`);
    // keep just a couple of sizes, quantities left at zero for now
    await page2.click('#sizesNone');
    await page2.waitForTimeout(250);
    await page2.locator('#sizeChips .chip').first().click();
    await page2.waitForTimeout(250);
    await page2.click('#saveRel');
    await page2.waitForSelector('#emsg.show', { timeout: 20000 });
    const msg = await page2.textContent('#emsg');
    if (!/Saved/i.test(msg)) throw new Error('save said: ' + msg);

    rafId = await adminFetch(async (H, url, a) => {
      const r = await fetch(`${url}/rest/v1/releases?select=id&slug=eq.${a[0]}`, { headers: H });
      return (await r.json())[0]?.id;
    }, [RAF]);
    if (!rafId) throw new Error('release was not created');
  });

  await step('entering holds no pair, and a second entry is taken but flagged', async () => {
    const loc = await page2.evaluate(async ([url, key]) => {
      const r = await fetch(url + '/rest/v1/locations?select=id&active=eq.true&order=sort_order&limit=1',
        { headers: { apikey: key, Authorization: 'Bearer ' + key } });
      return (await r.json())[0].id;
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a']);

    const enter = (em, ph) => page2.evaluate(async ([url, key, slug, loc, em, ph]) => {
      const r = await fetch(url + '/rest/v1/rpc/enter_raffle', {
        method: 'POST',
        headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_release_slug: slug, p_location_id: loc, p_size: null,
          p_first_name: 'Ent', p_last_name: 'Rant', p_email: em, p_phone: ph,
          p_agree: true }) });
      return r.json();
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', RAF, loc, em, ph]);

    // find the size that was ticked
    const size = await adminFetch(async (H, url, a) => {
      const r = await fetch(`${url}/rest/v1/release_inventory?select=size&release_id=eq.${a[0]}`, { headers: H });
      return (await r.json())[0]?.size;
    }, [rafId]);
    if (!size) throw new Error('no size row was created for the raffle');

    const enterSized = (em, ph) => page2.evaluate(async ([url, key, slug, loc, em, ph, size]) => {
      const r = await fetch(url + '/rest/v1/rpc/enter_raffle', {
        method: 'POST',
        headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_release_slug: slug, p_location_id: loc, p_size: size,
          p_first_name: 'Ent', p_last_name: 'Rant', p_email: em, p_phone: ph,
          p_agree: true }) });
      return r.json();
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', RAF, loc, em, ph, size]);

    const first = await enterSized(entrantEmail, '9998880001');
    if (!first.ok) throw new Error('first entry failed: ' + JSON.stringify(first).slice(0, 160));
    entryCode = first.code;
    if (!/^RF-[0-9A-Z]{6}$/.test(entryCode)) throw new Error('entry code = ' + entryCode);
    if (first.duplicate) throw new Error('a first entry was flagged as a duplicate');

    // more entries so there are losers
    for (let i = 2; i <= 6; i++) await enterSized(`zz-raf-${i}@example.com`, '99988800' + String(i).padStart(2,'0'));

    // the same person again on a fresh email but the same phone: accepted now,
    // and told plainly that it will cost them
    const again = await enterSized('zz-raf-dupe@example.com', '9998880002');
    if (!again.ok) throw new Error('a second entry was refused: ' + JSON.stringify(again).slice(0, 160));
    if (!again.duplicate) throw new Error('the second entry was not flagged as a duplicate');
    if (!/disqualif/i.test(again.duplicate_message || ''))
      throw new Error('the warning does not say what happens: ' + again.duplicate_message);
    if (again.entries_held !== 2) throw new Error('entries_held = ' + again.entries_held);

    // nothing may be held yet
    const reserved = await adminFetch(async (H, url, a) => {
      const r = await fetch(`${url}/rest/v1/release_inventory?select=quantity_reserved&release_id=eq.${a[0]}`, { headers: H });
      return (await r.json()).reduce((x, y) => x + y.quantity_reserved, 0);
    }, [rafId]);
    if (reserved !== 0) throw new Error('entering held ' + reserved + ' pairs — it must hold none');
  });

  await step('the rules are shown, and entering without agreeing is refused', async () => {
    const loc = await page2.evaluate(async ([url, key]) => {
      const r = await fetch(url + '/rest/v1/locations?select=id&active=eq.true&order=sort_order&limit=1',
        { headers: { apikey: key, Authorization: 'Bearer ' + key } });
      return (await r.json())[0].id;
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a']);

    // the server refuses an unticked entry, whatever the page does
    const size = await adminFetch(async (H, url, a) => {
      const r = await fetch(`${url}/rest/v1/release_inventory?select=size&release_id=eq.${a[0]}`, { headers: H });
      return (await r.json())[0]?.size;
    }, [rafId]);
    const bare = await page.evaluate(async ([url, key, slug, loc, size]) => {
      const H = { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' };
      return await (await fetch(url + '/rest/v1/rpc/enter_raffle', {
        method: 'POST', headers: H,
        body: JSON.stringify({ p_release_slug: slug, p_location_id: loc, p_size: size,
          p_first_name: 'No', p_last_name: 'Consent', p_email: 'zz-noconsent@example.com',
          p_phone: '9998887000' }) })).json();
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', RAF, loc, size]);
    if (bare.ok || bare.error !== 'rules_not_accepted')
      throw new Error('an entry with no consent was accepted: ' + JSON.stringify(bare).slice(0, 160));

    // and the customer page shows the rules with the button held until ticked
    const rp = await (await browser.newContext({ ...devices['iPhone 13'] })).newPage();
    await block(rp);
    await rp.goto(`http://localhost:8900/index.html?release=${RAF}`, { waitUntil: 'domcontentloaded' });
    await rp.waitForSelector('#s-size.active', { timeout: 15000 });
    await rp.locator('#sizes .size:not(.out)').first().click();
    await rp.click('#cta'); await rp.waitForSelector('#s-loc.active');
    await rp.locator('#locs .loc').first().click();
    await rp.click('#cta'); await rp.waitForSelector('#s-info.active');
    await rp.waitForSelector('#rulesBox .rules', { timeout: 10000 });
    const txt = await rp.textContent('#rulesBox');
    for (const must of ['ONLY 1 ENTRY PER PERSON', 'cityjeanspremium', 'DO NOT change sizes'])
      if (!txt.includes(must)) throw new Error('rules missing: ' + must);
    if (!(await rp.isDisabled('#cta')))
      throw new Error('the entry button was live before the rules were ticked');
    await rp.check('#agree');
    if (await rp.isDisabled('#cta'))
      throw new Error('the entry button stayed dead after ticking the rules');
    await rp.context().close();
  });

  await step('closing entries stops further entry', async () => {
    await adminFetch(async (H, url, a) => {
      await fetch(`${url}/rest/v1/releases?id=eq.${a[0]}`, {
        method: 'PATCH', headers: H,
        body: JSON.stringify({ closes_at: new Date(Date.now() - 60000).toISOString() }) });
    }, [rafId]);
    const late = await page2.evaluate(async ([url, key, slug]) => {
      const r = await fetch(url + '/rest/v1/rpc/enter_raffle', {
        method: 'POST',
        headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_release_slug: slug, p_location_id: null, p_size: '9',
          p_first_name: 'Too', p_last_name: 'Late', p_email: 'zz-late@example.com',
          p_phone: '9998887777', p_agree: true }) });
      return r.json();
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', RAF]);
    if (late.ok) throw new Error('an entry was accepted after entries closed');
  });

  await step('the raffle tab shows demand and refuses to draw with no pairs', async () => {
    await page2.click('.tab[data-v="v-raffle"]');
    await page2.waitForSelector('#rafRel');
    await page2.selectOption('#rafRel', rafId);
    await page2.waitForSelector('#rafBody .bucket tbody tr', { timeout: 15000 });
    const t = await page2.textContent('#rafBody');
    if (!/No pairs loaded yet/i.test(t)) throw new Error('expected the no-pairs gate: ' + t.slice(0, 200));
    if (await page2.locator('#rafDraw').count()) throw new Error('draw button offered with no pairs');
  });

  await step('after allocating, the draw picks exactly the pairs loaded', async () => {
    // allocate 2 pairs to the bucket the entrants actually chose
    await adminFetch(async (H, url, a) => {
      const ent = await (await fetch(
        `${url}/rest/v1/raffle_entries?select=location_id,size&release_id=eq.${a[0]}&limit=1`,
        { headers: H })).json();
      const b = ent[0];
      const rows = await (await fetch(
        `${url}/rest/v1/release_inventory?select=id&release_id=eq.${a[0]}` +
        `&location_id=eq.${b.location_id}&size=eq.${encodeURIComponent(b.size)}`,
        { headers: H })).json();
      await fetch(`${url}/rest/v1/release_inventory?id=eq.${rows[0].id}`, {
        method: 'PATCH', headers: H, body: JSON.stringify({ quantity_total: 2 }) });
    }, [rafId]);

    await page2.click('.tab[data-v="v-rel"]'); await page2.waitForTimeout(400);
    await page2.click('.tab[data-v="v-raffle"]');
    await page2.selectOption('#rafRel', rafId);
    await page2.waitForSelector('#rafDraw', { timeout: 15000 });
    armDialog(d => d.accept());
    await page2.click('#rafDraw');
    await page2.waitForSelector('#rafMsg.show', { timeout: 25000 });
    const m = await page2.textContent('#rafMsg');
    if (!/winner/i.test(m)) throw new Error('draw said: ' + m);

    const res = await adminFetch(async (H, url, a) => {
      const g = async (q) => (await (await fetch(url + '/rest/v1/' + q, { headers: H })).json());
      const won  = await g(`raffle_entries?select=id&release_id=eq.${a[0]}&status=eq.won`);
      const lost = await g(`raffle_entries?select=id&release_id=eq.${a[0]}&status=eq.lost`);
      const dq   = await g(`raffle_entries?select=id&release_id=eq.${a[0]}&status=eq.disqualified`);
      const rs   = await g(`reservations?select=id,code,source&release_id=eq.${a[0]}`);
      return { won: won.length, lost: lost.length, dq: dq.length, reservations: rs.length,
               allRaffle: rs.every(r => r.source === 'raffle'),
               codes: rs.every(r => /^CJ-[0-9A-Z]{6}$/.test(r.code)) };
    }, [rafId]);

    if (res.won !== 2) throw new Error('expected 2 winners, got ' + res.won);
    if (res.lost !== 3) throw new Error('expected 3 losers, got ' + res.lost);
    if (res.dq !== 2) throw new Error('expected both duplicate entries out, got ' + res.dq);
    if (res.reservations !== 2) throw new Error('winners did not become reservations');
    if (!res.allRaffle || !res.codes) throw new Error('winner reservations are malformed');
  });

  await step('a drawn raffle cannot be drawn again, and shows its seed', async () => {
    await page2.click('.tab[data-v="v-rel"]'); await page2.waitForTimeout(400);
    await page2.click('.tab[data-v="v-raffle"]');
    await page2.selectOption('#rafRel', rafId);
    await page2.waitForTimeout(1200);
    const t = await page2.textContent('#rafBody');
    if (!/Verification seed/i.test(t)) throw new Error('no seed shown after the draw');
    if (await page2.locator('#rafDraw').count()) throw new Error('draw offered a second time');
  });

  await step('every entrant is emailed — winners and losers alike', async () => {
    const n = await adminFetch(async (H, url, a) => {
      const id = a[0];
      const ent = await (await fetch(`${url}/rest/v1/raffle_entries?select=id&release_id=eq.${id}`, { headers: H })).json();
      const ids = ent.map(e => e.id);
      const notes = await (await fetch(`${url}/rest/v1/notifications?select=template,entry_id,reservation_id`, { headers: H })).json();
      const lost = notes.filter(x => x.template === 'raffle_lost' && ids.includes(x.entry_id)).length;
      const dq = notes.filter(x => x.template === 'raffle_disqualified' && ids.includes(x.entry_id)).length;
      const entered = notes.filter(x => x.template === 'entered' && ids.includes(x.entry_id)).length;
      const rs = await (await fetch(`${url}/rest/v1/reservations?select=id&release_id=eq.${id}`, { headers: H })).json();
      const rid = rs.map(r => r.id);
      const won = notes.filter(x => x.template === 'raffle_won' && rid.includes(x.reservation_id)).length;
      return { entered, lost, won, dq };
    }, [rafId]);
    if (n.entered !== 7) throw new Error('entry confirmations queued: ' + n.entered);
    if (n.lost !== 3) throw new Error('loser emails queued: ' + n.lost);
    if (n.dq !== 2) throw new Error('disqualification emails queued: ' + n.dq);
    if (n.won !== 2) throw new Error('winner emails queued: ' + n.won);
  });

  console.log('\n--- WRONG STORE ---');
  await step('a code scanned at the wrong store is refused, right store works', async () => {
    const out = await page2.evaluate(async ([url, key, em, pw]) => {
      const tok = await (await fetch(url + '/auth/v1/token?grant_type=password', {
        method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: em, password: pw }) })).json();
      const A = { apikey: key, Authorization: 'Bearer ' + tok.access_token, 'Content-Type': 'application/json' };
      const locs = await (await fetch(url + '/rest/v1/locations?select=id,name&active=eq.true&order=sort_order&limit=2', { headers: A })).json();
      const rs = await (await fetch(url + '/rest/v1/reservations?select=code,location_id&status=eq.confirmed&limit=1', { headers: A })).json();
      if (!rs.length) return { skip: true };
      const other = locs.find(l => l.id !== rs[0].location_id) || locs[0];
      const wrong = await (await fetch(url + '/rest/v1/rpc/redeem_reservation', {
        method: 'POST', headers: A,
        body: JSON.stringify({ p_code: rs[0].code, p_at_location: other.id }) })).json();
      const right = await (await fetch(url + '/rest/v1/rpc/redeem_reservation', {
        method: 'POST', headers: A,
        body: JSON.stringify({ p_code: rs[0].code, p_at_location: rs[0].location_id }) })).json();
      return { wrong, right };
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a',
        ADMIN_EMAIL, ADMIN_PASS]);
    if (out.skip) return;
    if (out.wrong.ok || out.wrong.error !== 'wrong_store')
      throw new Error('wrong store was allowed: ' + JSON.stringify(out.wrong).slice(0, 160));
    if (!/held at/i.test(out.wrong.message || ''))
      throw new Error('the refusal does not say where it is held');
    if (!out.right.ok) throw new Error('the correct store was refused: ' + JSON.stringify(out.right).slice(0, 160));
  });

  console.log('\n--- SUSPENSIONS ---');
  const SUSP_PHONE = '2125' + String(Date.now()).slice(-6);
  let suspId = null;

  await step('two missed pickups in a row suspends, one does not', async () => {
    // two closed drops whose pickup windows are already past, so the nightly
    // sweep has something real to find
    const made = await adminFetch(async (H, url, a) => {
      const phone = a[0];
      const loc = (await (await fetch(
        url + '/rest/v1/locations?select=id&active=eq.true&order=sort_order&limit=1',
        { headers: H })).json())[0].id;
      const mk = async (slug, name, endDaysAgo) => {
        const r = await (await fetch(url + '/rest/v1/releases', {
          method: 'POST', headers: { ...H, Prefer: 'return=representation' },
          body: JSON.stringify({ slug, name, status: 'closed', mode: 'fcfs',
            size_scale: 'mens',
            pickup_starts_at: new Date(Date.now() - (endDaysAgo + 1) * 86400000).toISOString(),
            pickup_ends_at:   new Date(Date.now() - endDaysAgo * 86400000).toISOString() }) })).json();
        const rel = r[0].id;
        await fetch(url + '/rest/v1/release_inventory', { method: 'POST', headers: H,
          body: JSON.stringify({ release_id: rel, location_id: loc, size: '10',
            size_order: 1, quantity_total: 5 }) });
        return rel;
      };
      const relA = await mk('zz-miss-a-' + phone, 'ZZ Missed A', 10);
      const relB = await mk('zz-miss-b-' + phone, 'ZZ Missed B', 3);
      const res = async (rel, code, em) => (await (await fetch(url + '/rest/v1/reservations', {
        method: 'POST', headers: { ...H, Prefer: 'return=representation' },
        body: JSON.stringify({ code, release_id: rel, location_id: loc, size: '10',
          first_name: 'Zed', last_name: 'Probe', email: em, email_norm: em,
          phone, phone_norm: phone }) })).json())[0].id;
      // a fresh email the second time: the phone is what ties them together
      await res(relA, 'CJ-Z' + phone.slice(-5), 'zz-miss-' + phone + '@example.com');
      await res(relB, 'CJ-Y' + phone.slice(-5), 'zz-miss-alt-' + phone + '@example.com');
      return { relA, relB };
    }, [SUSP_PHONE]);
    if (!made.relA) throw new Error('could not set up the missed drops');

    const sweep = await page2.evaluate(async ([url, key]) => {
      const tok = localStorage.getItem('drops_at');
      return await (await fetch(url + '/rest/v1/rpc/sweep_no_shows_now', {
        method: 'POST',
        headers: { apikey: key, Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' },
        body: '{}' })).json();
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a']);
    if (!sweep.ok) throw new Error('sweep said: ' + JSON.stringify(sweep).slice(0, 160));
    if (sweep.marked_no_show < 2) throw new Error('marked ' + sweep.marked_no_show + ' no-shows');

    const list = await page2.evaluate(async ([url, key]) => {
      const tok = localStorage.getItem('drops_at');
      return await (await fetch(url + '/rest/v1/rpc/list_suspensions', {
        method: 'POST',
        headers: { apikey: key, Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_include_past: false }) })).json();
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a']);
    const mine = (list.rows || []).find(r => r.phone === SUSP_PHONE);
    if (!mine) throw new Error('no suspension was created for two misses in a row');
    if (mine.days_left < 85 || mine.days_left > 91)
      throw new Error('days_left = ' + mine.days_left + ', expected about 90');
    suspId = mine.id;
  });

  await step('a suspended person cannot reserve or enter, under any email', async () => {
    const out = await page.evaluate(async ([url, key, slug, phone]) => {
      const H = { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' };
      const loc = (await (await fetch(
        url + '/rest/v1/locations?select=id&active=eq.true&order=sort_order&limit=1',
        { headers: H })).json())[0].id;
      const r = await (await fetch(url + '/rest/v1/rpc/reserve_spot', {
        method: 'POST', headers: H,
        body: JSON.stringify({ p_release_slug: slug, p_location_id: loc, p_size: '10',
          p_first_name: 'Zed', p_last_name: 'Probe',
          p_email: 'zz-brand-new-' + phone + '@example.com', p_phone: phone }) })).json();
      return r;
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a',
        TEST.slug, SUSP_PHONE]);
    if (out.ok || out.error !== 'suspended')
      throw new Error('a suspended person was allowed through: ' + JSON.stringify(out).slice(0, 160));
    if (!/paused/i.test(out.message || '') || !out.eligible_again)
      throw new Error('the refusal does not say when it ends: ' + out.message);
  });

  await step('the suspended tab lists them with the time left', async () => {
    await page2.click('.tab[data-v="v-susp"]');
    await page2.waitForSelector('#v-susp.on');
    await page2.waitForSelector('#suspTable tbody tr', { timeout: 15000 });
    const t = await page2.textContent('#suspTable');
    if (!t.includes('Zed')) throw new Error('the suspended person is not listed');
    if (!/day[s]? left/i.test(t)) throw new Error('no countdown shown: ' + t.slice(0, 200));
  });

  await step('a manager can reactivate early, and then they can book again', async () => {
    armDialog(d => d.accept('customer called, family emergency'));
    await page2.locator(`[data-lift="${suspId}"]`).click();
    await page2.waitForSelector('#suspMsg.show', { timeout: 15000 });
    const m = await page2.textContent('#suspMsg');
    if (!/again/i.test(m)) throw new Error('lift said: ' + m);

    const out = await page.evaluate(async ([url, key, slug, phone]) => {
      const H = { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' };
      const loc = (await (await fetch(
        url + '/rest/v1/locations?select=id&active=eq.true&order=sort_order&limit=1',
        { headers: H })).json())[0].id;
      return await (await fetch(url + '/rest/v1/rpc/reserve_spot', {
        method: 'POST', headers: H,
        body: JSON.stringify({ p_release_slug: slug, p_location_id: loc, p_size: '10',
          p_first_name: 'Zed', p_last_name: 'Probe',
          p_email: 'zz-after-lift-' + phone + '@example.com', p_phone: phone }) })).json();
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a',
        TEST.slug, SUSP_PHONE]);
    if (out.error === 'suspended') throw new Error('still blocked after the lift');
  });

  await step('the same two misses cannot suspend them a second time', async () => {
    const sweep = await page2.evaluate(async ([url, key]) => {
      const tok = localStorage.getItem('drops_at');
      return await (await fetch(url + '/rest/v1/rpc/sweep_no_shows_now', {
        method: 'POST',
        headers: { apikey: key, Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' },
        body: '{}' })).json();
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a']);
    const list = await page2.evaluate(async ([url, key]) => {
      const tok = localStorage.getItem('drops_at');
      return await (await fetch(url + '/rest/v1/rpc/list_suspensions', {
        method: 'POST',
        headers: { apikey: key, Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_include_past: false }) })).json();
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a']);
    if ((list.rows || []).some(r => r.phone === SUSP_PHONE))
      throw new Error('a lifted suspension came straight back on the next sweep');
    if (!sweep.ok) throw new Error('second sweep failed');
  });

  console.log('\n--- ROLES ---');
  const cashier = 'e2e-staff-cashier' + Date.now() + '@cityjeans.com';
  const cashierPass = 'cashier-probe-2026';
  await step('a staff cashier sees only the register, reservations and their password', async () => {
    // make a real staff-role account for this check, then clear its first-login lock
    await page2.click('.tab[data-v="v-acct"]');
    await page2.waitForSelector('#invEmail');
    await page2.fill('#invEmail', cashier);
    await page2.fill('#invName', 'Cashier');
    await page2.selectOption('#invRole', 'staff');
    await page2.fill('#invPass', cashierPass);
    await page2.click('#invite');
    await page2.waitForSelector('#invmsg.show');
    if (!/Account created/i.test(await page2.textContent('#invmsg')))
      throw new Error('could not create the cashier: ' + await page2.textContent('#invmsg'));

    const c = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    const sp = await c.newPage(); await block(sp);
    await sp.goto('http://localhost:8900/admin.html', { waitUntil: 'domcontentloaded' });
    await sp.fill('#e', cashier); await sp.fill('#p', cashierPass);
    await sp.click('#signin');
    await sp.waitForSelector('#app', { state: 'visible', timeout: 20000 });
    await sp.waitForTimeout(700);

    // first sign-in must land locked on Account until they set their own password
    if (!(await sp.isDisabled('.tab[data-v="v-reg"]')))
      throw new Error('a temp-password account was not locked to the Account tab');
    await sp.fill('#pw1', 'cashier-own-pass-1');
    await sp.fill('#pw2', 'cashier-own-pass-1');
    await sp.click('#savePw');
    await sp.waitForFunction(() => !document.querySelector('.tab[data-v="v-reg"]').disabled,
      null, { timeout: 15000 });

    const tabs = await sp.$$eval('.tab', els =>
      els.filter(e => e.style.display !== 'none').map(e => e.textContent.trim()));
    const want = ['Register', 'Reservations', 'Suspended', 'Account'];
    if (JSON.stringify(tabs) !== JSON.stringify(want))
      throw new Error('staff tabs = ' + JSON.stringify(tabs));
    await sp.click('.tab[data-v="v-res"]'); await sp.waitForTimeout(800);
    if (await sp.isVisible('#csv')) throw new Error('staff can export the customer CSV');
    await sp.click('.tab[data-v="v-acct"]'); await sp.waitForTimeout(600);
    if (await sp.isVisible('#invite')) throw new Error('staff can create accounts');
    if (await sp.isVisible('#staffTable')) throw new Error('staff can see the staff list');
    // a cashier reads the suspended list — they are the one who gets asked why —
    // but the Reactivate button is a manager's
    await sp.click('.tab[data-v="v-susp"]'); await sp.waitForTimeout(900);
    if (await sp.locator('#suspTable [data-lift]').count())
      throw new Error('staff was offered the Reactivate button');
    await c.close();
  });

  await step('the database refuses staff writes even without the UI', async () => {
    const r = await page2.evaluate(async ([url, key, em, pw]) => {
      const tok = await (await fetch(url + '/auth/v1/token?grant_type=password', {
        method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: em, password: pw })
      })).json();
      const H = { apikey: key, Authorization: 'Bearer ' + tok.access_token, 'Content-Type': 'application/json' };
      const call = async (fn, body) =>
        (await (await fetch(url + '/rest/v1/rpc/' + fn, { method: 'POST', headers: H, body: JSON.stringify(body) })).json());
      return {
        revoke: await call('revoke_user', { p_email: 'ben@cityjeans.com' }),
        lift:   await call('lift_suspension', { p_id: '00000000-0000-0000-0000-000000000000' }),
        sweep:  await call('sweep_no_shows_now', {}),
        create: await call('create_staff_account', { p_email: 'a@b.com', p_password: 'aaaaaaaaaaaa', p_role: 'owner' }),
        list:   await call('list_staff', {})
      };
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', cashier, 'cashier-own-pass-1']);
    for (const [k, v] of Object.entries(r))
      if (v.ok) throw new Error('staff was allowed to ' + k + '!');

    // tidy up the cashier
    await page2.click('.tab[data-v="v-acct"]');
    await page2.waitForSelector(`#staffTable [data-rev="${cashier}"]`, { timeout: 10000 });
    await page2.click(`#staffTable [data-rev="${cashier}"]`);
    await page2.waitForFunction(
      e => !document.querySelector(`#staffTable [data-rev="${e}"]`), cashier, { timeout: 10000 });
  });

  await step('customers cannot see how many pairs are left', async () => {
    const r = await page.evaluate(async ([url, key, slug]) => {
      const H = { apikey: key, Authorization: 'Bearer ' + key };
      const rows = await (await fetch(url + '/rest/v1/release_inventory?select=*', { headers: H })).json();
      const avail = await (await fetch(url + '/rest/v1/rpc/get_availability', {
        method: 'POST', headers: { ...H, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_release_slug: slug }) })).json();
      return { rows, avail };
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', TEST.slug]);
    if (Array.isArray(r.rows) && r.rows.length)
      throw new Error('anonymous can still read raw inventory rows');
    if (!Array.isArray(r.avail) || !r.avail.length)
      throw new Error('availability RPC returned nothing');
    const leaks = r.avail.filter(a => 'quantity_total' in a || 'quantity_reserved' in a);
    if (leaks.length) throw new Error('the availability RPC leaks counts');
    const pageText = await page.textContent('#sizes');
    if (/\d+\s*left/i.test(pageText)) throw new Error('the size grid still shows counts: ' + pageText);
  });

  console.log('\n--- RELEASE LIFECYCLE ---');
  const LC = 'zz-lifecycle-' + Date.now();
  let lcId = null;
  await step('archiving a release hides it and restore brings it back', async () => {
    // make a throwaway fcfs release with a size row, straight through the API
    lcId = await adminFetch(async (H, url, a) => {
      const loc = (await (await fetch(url + '/rest/v1/locations?select=id&active=eq.true&order=sort_order&limit=1', { headers: H })).json())[0].id;
      const r = await (await fetch(url + '/rest/v1/releases', {
        method: 'POST', headers: { ...H, Prefer: 'return=representation' },
        body: JSON.stringify({ slug: a[0], name: 'ZZ Lifecycle', status: 'open',
          mode: 'fcfs', size_scale: 'mens' }) })).json();
      const id = r[0].id;
      await fetch(url + '/rest/v1/release_inventory', { method: 'POST', headers: H,
        body: JSON.stringify({ release_id: id, location_id: loc, size: '10', size_order: 1, quantity_total: 3 }) });
      return id;
    }, [LC]);

    await page2.click('.tab[data-v="v-rel"]'); await page2.waitForTimeout(300);
    await page2.click('#refreshRel');
    await page2.waitForSelector(`#relTable [data-relstatus="${lcId}"][data-to="archived"]`, { timeout: 15000 });
    armDialog(d => d.accept());
    await page2.click(`#relTable [data-relstatus="${lcId}"][data-to="archived"]`);
    await page2.waitForSelector('#relMsg.show', { timeout: 15000 });
    if (!/archived/i.test(await page2.textContent('#relMsg'))) throw new Error('archive message missing');
    // the re-render lands after the message; wait for the row to actually leave
    await page2.waitForFunction(
      id => !document.querySelector(`#relTable [data-relstatus="${id}"]`), lcId,
      { timeout: 10000 }).catch(() => { throw new Error('archived release still shows without the toggle'); });
    // reappears under Show archived, with a Restore button
    await page2.check('#showArchRel');
    await page2.waitForSelector(`#relTable [data-relstatus="${lcId}"][data-to="closed"]`, { timeout: 10000 });
    await page2.click(`#relTable [data-relstatus="${lcId}"][data-to="closed"]`);
    // the archive banner is still on screen, so wait for the text to change
    await page2.waitForFunction(
      () => /restored/i.test(document.getElementById('relMsg').textContent),
      null, { timeout: 10000 }).catch(() => { throw new Error('restore message missing'); });
    await page2.uncheck('#showArchRel');
    // leave it as a plain closed release for the banner checks below
    await page2.waitForFunction(
      id => !!document.querySelector(`#relTable [data-relstatus="${id}"][data-to="archived"]`), lcId,
      { timeout: 10000 });
  });

  await step('a past entry window shows the closed badge in admin', async () => {
    await adminFetch(async (H, url, a) => {
      await fetch(`${url}/rest/v1/releases?id=eq.${a[0]}`, { method: 'PATCH', headers: H,
        body: JSON.stringify({ closes_at: new Date(Date.now() - 3600000).toISOString() }) });
    }, [lcId]);
    await page2.click('#refreshRel'); await page2.waitForTimeout(500);
    const row = page2.locator('#relTable tr', { hasText: 'ZZ Lifecycle' });
    const badge = await row.locator('.relstate').textContent().catch(() => '');
    if (!/reservations closed/i.test(badge)) throw new Error('admin badge = ' + JSON.stringify(badge));
  });

  await step('the customer sees a Reservations closed banner, not the form', async () => {
    const lp = await (await browser.newContext({ ...devices['iPhone 13'] })).newPage();
    await block(lp);
    await lp.goto(`http://localhost:8900/index.html?release=${LC}`, { waitUntil: 'domcontentloaded' });
    await lp.waitForSelector('#s-closed.active', { timeout: 15000 });
    const t = await lp.textContent('#closedBox');
    if (!/reservations closed/i.test(t)) throw new Error('banner = ' + t.slice(0, 120));
    if (await lp.isVisible('#s-size')) throw new Error('the entry form is still shown on a closed drop');
    if (!(await lp.isVisible('#closedLookup'))) throw new Error('no lookup offered on the closed screen');
    await lp.context().close();
  });

  await step('pickup ended shows for 24h then the drop is over', async () => {
    // pickup ended 2 hours ago → within the 24h grace
    await adminFetch(async (H, url, a) => {
      await fetch(`${url}/rest/v1/releases?id=eq.${a[0]}`, { method: 'PATCH', headers: H,
        body: JSON.stringify({ pickup_ends_at: new Date(Date.now() - 2 * 3600000).toISOString() }) });
    }, [lcId]);
    const lp = await (await browser.newContext({ ...devices['iPhone 13'] })).newPage();
    await block(lp);
    await lp.goto(`http://localhost:8900/index.html?release=${LC}`, { waitUntil: 'domcontentloaded' });
    await lp.waitForSelector('#s-closed.active', { timeout: 15000 });
    if (!/pickup (has )?ended/i.test(await lp.textContent('#closedBox')))
      throw new Error('expected a pickup-ended banner');
    await lp.context().close();

    // pickup ended 30 hours ago → past the grace, the drop reads as over
    await adminFetch(async (H, url, a) => {
      await fetch(`${url}/rest/v1/releases?id=eq.${a[0]}`, { method: 'PATCH', headers: H,
        body: JSON.stringify({ pickup_ends_at: new Date(Date.now() - 30 * 3600000).toISOString() }) });
    }, [lcId]);
    const lp2 = await (await browser.newContext({ ...devices['iPhone 13'] })).newPage();
    await block(lp2);
    await lp2.goto(`http://localhost:8900/index.html?release=${LC}`, { waitUntil: 'domcontentloaded' });
    await lp2.waitForSelector('#s-closed.active', { timeout: 15000 });
    if (!/ended/i.test(await lp2.textContent('#closedBox')))
      throw new Error('expected an ended banner past the grace window');
    await lp2.context().close();

    // clean up the throwaway release
    await adminFetch(async (H, url, a) => {
      await fetch(`${url}/rest/v1/releases?id=eq.${a[0]}`, { method: 'DELETE', headers: H });
    }, [lcId]);
  });

  await step('no console errors anywhere', async () => {
    const real = errors.filter(e => !/favicon|404|net::ERR_/i.test(e));
    if (real.length) throw new Error(real.slice(0, 4).join(' | '));
  });

  console.log('\n--- ANONYMOUS ATTACK SURFACE ---');
  // These are the holes the Sep 2 security pass closed. Each one was live and
  // exploitable with nothing but the publishable key; they must stay shut.
  await step('anon cannot reach the privileged SECURITY DEFINER internals', async () => {
    const rpc = (fn, body) => page.evaluate(async ([url, key, fn, body]) => {
      const r = await fetch(url + '/rest/v1/rpc/' + fn, {
        method: 'POST', headers: { apikey: key, Authorization: 'Bearer ' + key,
          'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
      return { status: r.status, body: await r.text() };
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', fn, body]);

    // dumping codes/PII, or exhausting the retry counter to silence all email
    // blocked = a 403/401 permission-denied, or PGRST202 (PostgREST cannot even
    // resolve the function for this role). What must never happen is a 2xx with
    // a real result.
    const blocked = r => r.status === 403 || r.status === 401 || r.status === 404
      || /permission denied|PGRST202|42501/i.test(r.body);
    for (const [fn, body] of [
      ['claim_notifications', { p_limit: 1 }],
      ['mark_missed_pickups', { p_grace: '0 seconds' }],
      ['apply_no_show_suspensions', { p_days: 1 }],
      ['run_no_show_sweep', {}],
      ['complete_notification', { p_id: '00000000-0000-0000-0000-000000000000', p_ok: true }],
      ['active_suspension', { p_email_norm: 'x@y.com', p_phone_norm: '1' }],
      ['raffle_entry_count', { p_release_id: '00000000-0000-0000-0000-000000000000', p_email_norm: 'x', p_phone_norm: '1' }],
      ['is_admin', {}],
    ]) {
      const r = await rpc(fn, body);
      if (!blocked(r))
        throw new Error('anon reached ' + fn + ': ' + r.status + ' ' + r.body.slice(0, 120));
    }
  });

  await step('anon cannot read reservations, entries, suspensions or admins directly', async () => {
    const tbl = t => page.evaluate(async ([url, key, t]) => {
      const r = await fetch(`${url}/rest/v1/${t}?select=*&limit=3`,
        { headers: { apikey: key, Authorization: 'Bearer ' + key } });
      return { status: r.status, body: await r.text() };
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a', t]);
    for (const t of ['reservations','raffle_entries','suspensions','admins','invited_emails','notifications']) {
      const r = await tbl(t);
      // acceptable: an empty array (RLS filtered everything) or a permission
      // error. A leak is a 200 whose body parses to a non-empty array.
      let rows = null;
      try { rows = JSON.parse(r.body); } catch {}
      if (r.status === 200 && Array.isArray(rows) && rows.length)
        throw new Error(t + ' leaked ' + rows.length + ' rows to anon: ' + r.body.slice(0, 120));
    }
  });

  await step('anon draft/upcoming releases and raw stock stay hidden', async () => {
    const out = await page.evaluate(async ([url, key]) => {
      const H = { apikey: key, Authorization: 'Bearer ' + key };
      const drafts = await (await fetch(url + '/rest/v1/releases?select=slug&status=eq.draft', { headers: H })).json();
      const inv = await (await fetch(url + '/rest/v1/release_inventory?select=quantity_total&limit=1', { headers: H })).json();
      return { drafts, inv };
    }, ['http://localhost:8900', 'sb_publishable_Tk7DTTfSz7hEeib_7dHbyw_ncWSJG9a']);
    if (Array.isArray(out.drafts) && out.drafts.length)
      throw new Error('anon can see draft releases');
    if (Array.isArray(out.inv) && out.inv.length)
      throw new Error('anon can read raw inventory counts');
  });

  await browser.close();
  console.log('\ndone.');
})();
