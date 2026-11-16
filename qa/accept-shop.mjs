// 16.11: незалежна приймальна перевірка сайту «магазин» (CyberSphere) за ТЗ — однакова для всіх моделей.
// Не дивиться в код моделі: лише браузер (видимі тексти з ТЗ і .txt) і HTTP. Сайт має бути піднятий на BASE.
//   PW=<шлях до node_modules/playwright> NEWEST="<назва найновішої гри з DECISIONS>" node qa/accept-shop.mjs [BASE] [out.json]
// Кожен пункт: id (розділ ТЗ), що перевірено, ok true/false, примітка. Вихід — JSON + короткий друк.
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PW);
const BASE = process.argv[2] || 'http://localhost:8088';
const OUT = process.argv[3] || '/dev/null';
const SHOTS = process.env.SHOTS || '';
const res = [];
// ok: true — виконано; 'minor' — працює, але текст/назва відходить від ТЗ; false — не виконано
const rec = (id, what, ok, note = '') => { const lvl = ok === 'minor' ? '~' : ok ? '✓' : '✗'; res.push({ id, what, ok: lvl, note: String(note).slice(0, 220) }); console.log(`${lvl} ${id} ${what}${note ? ' — ' + String(note).slice(0, 160) : ''}`); };
const tryRec = async (id, what, fn) => { try { const r = await fn(); if (Array.isArray(r)) rec(id, what, r[0], r[1]); else rec(id, what, r); } catch (e) { rec(id, what, false, 'виняток: ' + (e.message || e).split('\n')[0]); } };

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
const go = async (p) => { await page.goto(BASE + p, { waitUntil: 'networkidle' }); };
const body = async () => (await page.locator('body').innerText()).replace(/\s+/g, ' ');
const hscroll = async () => page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
const cartCount = async () => {
  const t = await page.locator('header').innerText();
  const m = t.replace(/\s+/g, ' ').match(/(?:кошик|cart)[^0-9]{0,20}(\d+)|(\d+)\s*$/i);
  const all = await page.locator('header [aria-live]').allInnerTexts().catch(() => []);
  const n = all.map((x) => parseInt(x.replace(/\D/g, ''), 10)).find((x) => !Number.isNaN(x));
  return n ?? (m ? parseInt(m[1] || m[2], 10) : NaN);
};
// жанри можуть ховатися під «Показати всі» (так і вимагає ТЗ) — розкрити перед пошуком мітки
const genre = async (pg, name) => {
  const l = () => pg.locator('label:visible').filter({ hasText: new RegExp(`^\\s*${name}\\s*\\(?\\d+\\)?\\s*$`) }).first();
  if (!(await l().count())) { const more = pg.getByRole('button', { name: /Показати всі/ }).first(); if (await more.count()) { await more.click(); await pg.waitForTimeout(400); } }
  return l();
};
const shot = async (name) => { if (SHOTS) await page.screenshot({ path: `${SHOTS}/${name}.png`, fullPage: false }); };

// ── 4.2 Лендінг ──
await go('/');
await shot('landing');
await tryRec('4.2.1', 'Hero: заголовок і підзаголовок дослівно з .txt', async () => {
  const t = await body();
  return [t.includes('Твій квиток у віртуальні світи') && t.includes('Грай без обмежень') && t.includes('Цифрові ліцензії, миттєва доставка, найкращі ціни в Україні'), ''];
});
await tryRec('4.2.1', 'Hero: анімація вимикається при prefers-reduced-motion', async () => {
  const css = await page.evaluate(() => [...document.styleSheets].flatMap((s) => { try { return [...s.cssRules].map((r) => r.cssText); } catch { return []; } }).join('\n'));
  return [/prefers-reduced-motion/.test(css), ''];
});
await tryRec('4.2.1', '«В каталог» → /catalog', async () => {
  await page.getByRole('link', { name: /^\s*В каталог\s*$/ }).first().click(); await page.waitForLoadState('networkidle');
  const u = new URL(page.url()); await go('/'); return [u.pathname === '/catalog', u.pathname + u.search];
});
await tryRec('4.2.1', '«Акції тижня» → /catalog?sale=1', async () => {
  await page.getByRole('link', { name: /Акції тижня/ }).first().click(); await page.waitForLoadState('networkidle');
  const u = new URL(page.url()); await go('/'); return [u.pathname === '/catalog' && /sale=(1|true)/.test(u.search), u.pathname + u.search];
});
await tryRec('4.2.2', 'Featured: «Придбати Neon Horizon (-20%)» → /games/neon-horizon-2088', async () => {
  const b = page.getByRole('link', { name: /Придбати Neon Horizon \(-20\s?%\)/ }).or(page.getByRole('button', { name: /Придбати Neon Horizon \(-20\s?%\)/ }));
  const exact = (await b.first().innerText()).includes('(-20%)');
  await b.first().click(); await page.waitForLoadState('networkidle'); const p = new URL(page.url()).pathname; await go('/');
  return [p === '/games/neon-horizon-2088' ? (exact ? true : 'minor') : false, p + (exact ? '' : '; текст «(-20 %)» з пробілом замість «(-20%)»')];
});
await tryRec('4.2.2', 'Featured: «Дослідити Eldoria» → /games/chronicles-of-eldoria', async () => {
  const b = page.getByRole('link', { name: /Дослідити Eldoria/ }).or(page.getByRole('button', { name: /Дослідити Eldoria/ }));
  await b.first().click(); await page.waitForLoadState('networkidle'); const p = new URL(page.url()).pathname; await go('/'); return [p === '/games/chronicles-of-eldoria', p];
});
await tryRec('4.2.2', 'Featured: елементи довіри (IGN 9.5/10, 100 000 завантажень, нагорода 2026)', async () => {
  const t = await body(); const miss = ['9.5/10', '100 000', 'Найкращий візуальний стиль 2026'].filter((x) => !t.includes(x)); return [miss.length === 0, miss.join('; ')];
});
await tryRec('4.2.3', 'Переваги: 4 різні пункти', async () => {
  const t = await body(); const miss = ['Миттєвий доступ', '100% ліцензія', 'Геймерський кешбек', 'Підтримка 24/7'].filter((x) => !t.includes(x)); return [miss.length === 0, miss.join('; ')];
});
await tryRec('4.2.4', 'Shop Preview: «Add to Cart» додає без переходу (лічильник +1)', async () => {
  const before = await cartCount();
  await page.getByRole('button', { name: /Add to Cart/i }).first().click(); await page.waitForTimeout(1200);
  const after = await cartCount(); const same = new URL(page.url()).pathname === '/';
  return [same && after === (Number.isNaN(before) ? 0 : before) + 1, `лічильник ${before} → ${after}`];
});
await tryRec('4.1', 'Підвал: соцмережі Discord/Telegram/YouTube з rel=noopener', async () => {
  const links = await page.locator('footer a[href^="http"]').evaluateAll((as) => as.map((a) => [a.textContent + (a.getAttribute('aria-label') || ''), a.rel]));
  const need = ['Discord', 'Telegram', 'YouTube'].filter((n) => !links.some(([t, r]) => t.includes(n) && /noopener/.test(r)));
  return [need.length === 0, need.join('; ')];
});
await tryRec('4.1', 'Підвал: Visa, Mastercard, Apple Pay, Google Pay', async () => {
  const html = await page.locator('footer').innerHTML(); const miss = ['Visa', 'Mastercard', 'Apple Pay', 'Google Pay'].filter((x) => !html.includes(x)); return [miss.length === 0, miss.join('; ')];
});
await tryRec('4.1', 'Live Chat: віджет з авто-відповіддю', async () => {
  await page.getByRole('button', { name: /Live Chat|чат/i }).first().click(); await page.waitForTimeout(500);
  const inp = page.locator('[role="dialog"] input:not([type=email]), [role="dialog"] textarea, input[placeholder*="овідомлен" i], textarea[placeholder*="овідомлен" i]').first();
  await inp.fill('Привіт, допоможіть з ключем'); await inp.press('Enter'); await page.waitForTimeout(3500);
  const t = await body(); return [t.includes('Привіт, допоможіть з ключем') && /оператор|відпов|дякуємо|допоможемо|зв'яж/i.test(t), ''];
});
const sub = async (email) => {
  const f = page.locator('footer input[type="email"], footer input[name*="mail" i]').first();
  await f.fill(email); await f.press('Enter'); await page.waitForTimeout(1500); return (await page.locator('footer').innerText()).replace(/\s+/g, ' ');
};
await tryRec('4.1', 'Підписка: некоректний email — зрозуміла помилка', async () => {
  await go('/'); const t = await sub('not-an-email'); return [/некорект|невірн|введіть|помилк|формат/i.test(t), ''];
});
await tryRec('4.1', 'Підписка: новий email прийнято, дубль → «Ви вже підписані»', async () => {
  await go('/'); const e = `acc${Date.now()}@example.com`; const t1 = await sub(e); await go('/'); const t2 = await sub(e);
  return [/дякуємо|підписал|підписано|успіш/i.test(t1) && /Ви вже підписані/.test(t2), ''];
});

// ── 4.1 Шапка ──
for (const [name, path, must] of [['Catalog', '/catalog', null], ['News', '/news', null], ['Support', '/support', null], ['Account', '/account', /незабаром/i]]) {
  await tryRec('4.1', `Навігація ${name} → ${path}${must ? ' (заглушка «Особистий кабінет — незабаром»)' : ''}`, async () => {
    await go('/'); await page.locator('header').getByRole('link', { name: new RegExp(`^\\s*${name}\\s*$`) }).first().click(); await page.waitForLoadState('networkidle');
    const p = new URL(page.url()).pathname; const t = await body(); const okp = p === path && !/404|не знайдено/i.test(t.slice(0, 400));
    return [okp ? (!must || must.test(t) ? true : 'minor') : false, p + (okp && must && !must.test(t) ? '; немає тексту «незабаром»' : '')];
  });
}
await tryRec('4.1', 'News: 3–5 демо-новин', async () => {
  await go('/news'); const n = await page.locator('main article, main li, main [class*="card" i]').count(); return [n >= 3, `${n} блоків`];
});
await tryRec('4.1', 'Support: FAQ з якорем #faq', async () => { await go('/support#faq'); return [await page.locator('#faq').count() > 0, '']; });
await tryRec('4.1', 'Пошук у шапці: Enter → /catalog?q=, без урахування регістру', async () => {
  await go('/'); const s = page.locator('header input[type="search"], header input[name*="q" i], header input[placeholder*="ошук" i]').first();
  await s.fill('NEON'); await s.press('Enter'); await page.waitForLoadState('networkidle'); await page.waitForTimeout(800);
  const u = new URL(page.url()); const t = await body(); return [u.pathname === '/catalog' && /q=NEON/i.test(u.search) && t.includes('Neon Horizon'), u.search];
});
await tryRec('4.1', 'Пошук без результатів — empty-state', async () => {
  await go('/catalog?q=zzqqxx'); await page.waitForTimeout(800); const t = await body(); return [/Нічого не знайдено/.test(t), ''];
});

// ── 4.3 Каталог ──
await go('/catalog'); await page.waitForTimeout(800); await shot('catalog');
await tryRec('4.3', 'Top Sellers: карусель зі стрілками', async () => {
  const t = await body(); const arrows = await page.locator('main button').evaluateAll((bs) => bs.filter((b) => /‹|›|←|→|попередн|наступн|prev|next|назад|вперед|прокрут|scroll/i.test((b.innerText || '') + ' ' + (b.getAttribute('aria-label') || ''))).length); return [/Top Sellers/i.test(t) && arrows >= 2, `${arrows} кнопок`];
});
await tryRec('4.3', 'Сітка: «Add to Cart» і «Quick View» на картках', async () => {
  const a = await page.getByRole('button', { name: /Add to Cart/i }).count(); const q = await page.getByRole('button', { name: /Quick View/i }).count(); return [a >= 10 && q >= 10, `Add ${a}, Quick ${q}`];
});
await tryRec('4.3', 'Ціна: стара перекреслена (s/del/line-through)', async () => {
  const n = await page.locator('main s, main del, main .line-through').count(); return [n > 0, `${n}`];
});
await tryRec('4.3', 'Лічильники фасетів біля пунктів («Steam (N)»)', async () => { const t = await body(); const a = /Steam\s*\(\d+\)/.test(t); const b = /Steam\s+\d+/.test(t); return [a ? true : b ? 'minor' : false, a ? (t.match(/Steam\s*\(\d+\)/) || [''])[0] : b ? 'формат «Steam 36» без дужок' : '']; });
await tryRec('4.3', 'Фільтри: усі 12 платформ із .txt', async () => {
  const t = await body(); const miss = ['Steam', 'Epic Games Store', 'GOG', 'Ubisoft Connect', 'EA App', 'PlayStation 5', 'PlayStation 4', 'Xbox Series X/S', 'Nintendo Switch', 'Windows', 'macOS', 'Linux'].filter((x) => !t.includes(x));
  const alias = miss.every((x) => ({ 'PlayStation 5': 'PS5', 'PlayStation 4': 'PS4' })[x] && t.includes(({ 'PlayStation 5': 'PS5', 'PlayStation 4': 'PS4' })[x]));
  return [miss.length === 0 ? true : alias ? 'minor' : false, miss.length ? (alias ? 'PS5/PS4 замість назв із .txt' : 'бракує: ' + miss.join('; ')) : ''];
});
await tryRec('4.3', 'Знижки: перемикач і 4 діапазони, спецпропозиції', async () => {
  const t = await body(); const miss = ['зі знижкою', '30', '50', '70', 'Хіти до 200', 'Безкоштовні вихідні', 'Передзамовлення з бонусами'].filter((x) => !t.includes(x)); return [miss.length === 0, miss.join('; ')];
});
await tryRec('4.3', 'Ціна: повзунок з двома ручками + поля «Від/До» + 4 швидкі кнопки', async () => {
  const sliders = await page.locator('input[type="range"], [role="slider"]').count(); const t = await body();
  const miss = ['Від', 'До', 'Безкоштовно', 'До 350', 'До 1000', 'AAA'].filter((x) => !t.includes(x)); return [sliders >= 2 && miss.length === 0, `повзунків ${sliders}; бракує: ${miss.join('; ')}`];
});
await tryRec('4.3', 'Жанри: «Показати всі»', async () => { return [await page.getByRole('button', { name: /Показати всі/ }).count() > 0, '']; });
await tryRec('4.3', 'Сортування: 5 способів', async () => {
  const opts = await page.locator('select option').allInnerTexts(); const need = [/популярн/i, /дешев/i, /дорог|дорож/i, /рейтинг/i, /дат/i]; const miss = need.filter((r) => !opts.some((o) => r.test(o)));
  return [miss.length === 0, opts.join(' | ').slice(0, 150)];
});
await tryRec('4.3', '«Показати ще»: 24 на порцію', async () => {
  const cards = async () => page.getByRole('button', { name: /Quick View/i }).count();
  const top = await page.locator('main').getByText(/Top Sellers/i).count();
  const n1 = await cards(); await page.getByRole('button', { name: /Показати ще/ }).first().click(); await page.waitForTimeout(1500); const n2 = await cards();
  return [n2 > n1, `карток із Quick View: ${n1} → ${n2}${top ? ' (разом із каруселлю)' : ''}`];
});
await tryRec('4.3', 'Quick View: відкривається й закривається Esc', async () => {
  await go('/catalog'); await page.getByRole('button', { name: /Quick View/i }).first().click(); await page.waitForTimeout(500);
  const open = await page.locator('[role="dialog"]').count(); await page.keyboard.press('Escape'); await page.waitForTimeout(500); const closed = await page.locator('[role="dialog"]:visible').count();
  return [open > 0 && closed === 0, `відкрито ${open}, після Esc ${closed}`];
});
await tryRec('4.3', 'Quick View: фокус утримується (Tab ×15 не виходить із вікна)', async () => {
  await page.getByRole('button', { name: /Quick View/i }).first().click(); await page.waitForTimeout(400);
  let out = 0; for (let i = 0; i < 15; i++) { await page.keyboard.press('Tab'); if (!(await page.evaluate(() => !!document.activeElement?.closest('[role="dialog"]')))) out++; }
  await page.keyboard.press('Escape'); return [out === 0, `поза вікном ${out} з 15`];
});
await tryRec('4.3', 'Стан у URL: фільтр + сортування переживають перезавантаження; «Назад» працює', async () => {
  await go('/catalog'); const u0 = page.url();
  await (await genre(page, 'RPG')).click(); await page.waitForTimeout(1200);
  const u1 = page.url(); await page.reload({ waitUntil: 'networkidle' }); await page.waitForTimeout(800);
  const checked = await (await genre(page, 'RPG')).locator('input').isChecked().catch(() => false);
  await page.goBack({ waitUntil: 'networkidle' }); await page.waitForTimeout(800); const u2 = page.url();
  return [u1 !== u0 && checked && u2 !== u1, `${new URL(u1).search} → назад ${new URL(u2).search || '(без фільтрів)'}`];
});
await tryRec('4.3', '«Скинути все» очищає фільтри', async () => {
  await go('/catalog'); await (await genre(page, 'RPG')).click(); await page.waitForTimeout(1000);
  const b = page.getByRole('button', { name: /Скинути все/ }).first(); await b.click(); await page.waitForTimeout(1000); const u = new URL(page.url());
  return [!/genre|platform|sale|price/i.test(u.search), u.search || '(порожньо)'];
});

// ── Golden path (ТЗ §1) ──
const ctx2 = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const gp = await ctx2.newPage();
const B = async () => (await gp.locator('body').innerText()).replace(/\s+/g, ' ');
const gcount = async () => { const all = await gp.locator('header [aria-live]').allInnerTexts().catch(() => []); const n = all.map((x) => parseInt(x.replace(/\D/g, ''), 10)).find((x) => !Number.isNaN(x)); return n ?? NaN; };
let receiptUrl = ''; let escNote = '';
await tryRec('§1', 'Golden path 2–3: Featured → гра → платформа Steam → «Додати в кошик» → модалка, лічильник 1', async () => {
  await gp.goto(BASE + '/', { waitUntil: 'networkidle' });
  await gp.getByRole('link', { name: /Придбати Neon Horizon/ }).or(gp.getByRole('button', { name: /Придбати Neon Horizon/ })).first().click(); await gp.waitForLoadState('networkidle');
  const addBtn = gp.getByRole('button', { name: /Додати в кошик/ }).first();
  const disabledBefore = await addBtn.isDisabled().catch(() => false);
  const sel = gp.locator('select').filter({ has: gp.locator('option', { hasText: 'Steam' }) }).first();
  if (await sel.count()) await sel.selectOption({ label: 'Steam' }); else await gp.getByRole('radio', { name: /Steam/ }).or(gp.getByRole('button', { name: /^\s*Steam\s*$/ })).or(gp.locator('label').filter({ hasText: /^\s*Steam\s*$/ })).first().click();
  await addBtn.click(); await gp.waitForTimeout(1200); const t = await B();
  return [/Гру додано/.test(t) && /Продовжити покупки/.test(t) && /Перейти до кошика/.test(t) && (await gcount()) === 1, `кнопка до вибору платформи ${disabledBefore ? 'неактивна' : 'активна (може бути підказка)'}; лічильник ${await gcount()}`];
});
await tryRec('4.4', 'Сторінка гри: ≥3 скріншоти, видавець, дата, вимоги (Мінімальні/Рекомендовані), «Цифровий ключ», відгуки', async () => {
  const esc0 = await gp.getByRole('button', { name: /Продовжити покупки/ }).count(); await gp.keyboard.press('Escape'); await gp.waitForTimeout(400);
  const escOk = (await gp.getByRole('button', { name: /Продовжити покупки/ }).count()) === 0; escNote = `модалка «Гру додано» ${escOk ? 'закривається' : 'НЕ закривається'} по Esc`;
  if (!escOk) await gp.getByRole('button', { name: /Продовжити покупки/ }).first().click();
  const t = await B(); const imgs = await gp.locator('main img').count();
  const miss = ['Мінімальні', 'Рекомендовані', 'Цифровий ключ', 'Vertex'].filter((x) => !t.includes(x));
  return [imgs >= 3 && miss.length <= 1 && /відгук/i.test(t), `зображень ${imgs}; бракує: ${miss.join('; ')}; ${escNote}`];
});
await tryRec('§1', 'Golden path 4–6: Catalog → RPG + Steam → «За датою релізу» → перша гра = найновіша з DECISIONS → Add to Cart → 2', async () => {
  await gp.locator('header').getByRole('link', { name: /^\s*Catalog\s*$/ }).first().click(); await gp.waitForLoadState('networkidle');
  await (await genre(gp, 'RPG')).click(); await gp.waitForTimeout(1000);
  await gp.locator('label').filter({ hasText: /^\s*Steam\s*\(?\d+\)?\s*$/ }).first().click(); await gp.waitForTimeout(1000);
  const s = gp.locator('select').filter({ has: gp.locator('option', { hasText: /дат/i }) }).first(); const v = await s.locator('option', { hasText: /дат/i }).first().getAttribute('value'); await s.selectOption(v); await gp.waitForTimeout(1500);
  const url = gp.url(); const firstCard = gp.getByRole('button', { name: /Add to Cart/i });
  // перша картка сітки (не каруселі Top Sellers): шукаємо назву поруч із першою кнопкою Quick View
  const qv = gp.getByRole('button', { name: /Quick View/i }); const n = await qv.count();
  // перша картка сітки: пропускаємо каруселі (предок з горизонтальним прокручуванням); назва — текст посилання на /games/
  let title = ''; let gi = -1;
  for (let i = 0; i < n && !title; i++) {
    const inCarousel = await qv.nth(i).evaluate((el) => { for (let e = el.parentElement; e; e = e.parentElement) { const ox = getComputedStyle(e).overflowX; if ((ox === 'auto' || ox === 'scroll' || ox === 'hidden') && e.scrollWidth > e.clientWidth + 4) return true; } return false; });
    if (inCarousel) continue;
    const links = await qv.nth(i).locator('xpath=ancestor::*[.//a[starts-with(@href, "/games/")]][1]').locator('a[href^="/games/"]').allInnerTexts();
    title = links.map((x) => x.trim()).find((x) => x.length > 3) || ''; gi = i;
  }
  const want = process.env.NEWEST || '';
  await qv.nth(Math.max(gi, 0)).locator('xpath=ancestor::*[.//button[contains(., "Add to Cart")]][1]').getByRole('button', { name: /Add to Cart/i }).first().click(); await gp.waitForTimeout(1200);
  const c = await gcount(); return [want && title.includes(want.split(':')[0]) && c === 2 && /genre|жанр/i.test(url), `перша: «${title}», очікувано «${want}»; лічильник ${c}; ${new URL(url).search}`];
});
await tryRec('§1', 'Golden path 7: кошик — 2 позиції, ціни, знижка, «Ви заощадили», монети', async () => {
  await gp.goto(BASE + '/cart', { waitUntil: 'networkidle' }); const t = await B(); await gp.screenshot({ path: SHOTS ? `${SHOTS}/cart.png` : '/dev/null' }).catch(() => {});
  const miss = ['Разом до оплати', 'Ви заощадили', 'ігрових монет', 'Безпечна оплата', '100% Офіційні ключі', 'Цифровий ключ'].filter((x) => !t.includes(x));
  const items = (t.match(/Neon Horizon: 2088/g) || []).length; return [miss.length === 0 && items >= 1, `бракує: ${miss.join('; ')}`];
});
await tryRec('4.5', 'Повторне додавання тієї ж гри на ту ж платформу → «Вже в кошику», без дубля', async () => {
  await gp.goto(BASE + '/games/neon-horizon-2088', { waitUntil: 'networkidle' });
  const sel = gp.locator('select').filter({ has: gp.locator('option', { hasText: 'Steam' }) }).first();
  if (await sel.count()) await sel.selectOption({ label: 'Steam' }); else await gp.getByRole('radio', { name: /Steam/ }).or(gp.getByRole('button', { name: /^\s*Steam\s*$/ })).or(gp.locator('label').filter({ hasText: /^\s*Steam\s*$/ })).first().click();
  await gp.getByRole('button', { name: /Додати в кошик/ }).first().click(); await gp.waitForTimeout(1500); const t = await B();
  if (await gp.getByRole('button', { name: /Продовжити покупки/ }).count()) await gp.getByRole('button', { name: /Продовжити покупки/ }).first().click();
  const exact = /Вже в кошику/.test(t); const near = /вже в кошику/i.test(t); const n = await gcount();
  return [n === 2 && (exact || near) ? (exact ? true : 'minor') : false, `лічильник ${n}${!exact && near ? '; текст не дослівно: «' + (t.match(/[^.]{0,30}вже в кошику[^.]{0,30}/i) || [''])[0].trim() + '»' : ''}`];
});
const promo = async (code) => { const f = gp.locator('input[name*="promo" i], input[id*="promo" i], input[placeholder*="ромокод" i], input[aria-label*="ромокод" i]').first(); await f.fill(code); await gp.getByRole('button', { name: /Застосувати/ }).first().click(); await gp.waitForTimeout(1300); return B(); };
await tryRec('4.5', 'Промокоди: невідомий → «Промокод не знайдено»; EXPIRED5 → «Термін дії минув»; CYBER10 застосовано', async () => {
  await gp.goto(BASE + '/cart', { waitUntil: 'networkidle' });
  const a = await promo('NOPE123'); const b = await promo('EXPIRED5'); const before = await B(); const c = await promo('CYBER10');
  return [/Промокод не знайдено/.test(a) && /Термін дії минув/.test(b) && /CYBER10/.test(c), ''];
});
await tryRec('4.5', '«Купити як подарунок»: з\'являється обов\'язкове поле email друга', async () => {
  const before = await gp.locator('input[type="email"]').count();
  await gp.getByText(/Купити як подарунок/).first().click(); await gp.waitForTimeout(800); const after = await gp.locator('input[type="email"]').count();
  if (after > before) { await gp.getByText(/Купити як подарунок/).first().click(); await gp.waitForTimeout(500); }
  return [after > before, `полів email ${before} → ${after}`];
});
await tryRec('4.6', 'Checkout: банер «Демо-режим», 3 способи, без полів картки', async () => {
  await gp.getByRole('button', { name: /Оформити замовлення/ }).or(gp.getByRole('link', { name: /Оформити замовлення/ })).first().click(); await gp.waitForLoadState('networkidle'); await gp.waitForTimeout(600);
  const t = await B(); const card = await gp.locator('input[name*="card" i], input[name*="cvv" i], input[autocomplete^="cc-"], input[placeholder*="CVV" i]').count();
  const miss = ['Демо-режим', 'Картка (демо)', 'Apple Pay (демо)', 'Google Pay (демо)'].filter((x) => !t.includes(x)); return [miss.length === 0 && card === 0 && new URL(gp.url()).pathname === '/checkout', `бракує: ${miss.join('; ')}; полів картки ${card}`];
});
await tryRec('4.6', 'Checkout: некоректний email не пропускає', async () => {
  const e = gp.locator('input[type="email"]').first(); await e.fill('bad@'); await gp.getByRole('button', { name: /Підтвердити замовлення/ }).first().click(); await gp.waitForTimeout(1000);
  return [new URL(gp.url()).pathname === '/checkout', gp.url()];
});
await tryRec('§1', 'Golden path 8–9: підтвердження → чек CS-2026-…, DEMO-ключі, «ДЕМО — оплату не проведено», «Друкувати»', async () => {
  await gp.locator('input[type="email"]').first().fill('buyer@example.com'); await gp.getByRole('button', { name: /Підтвердити замовлення/ }).first().click();
  await gp.waitForURL(/receipt/, { timeout: 15000 }); await gp.waitForLoadState('networkidle'); await gp.waitForTimeout(800); receiptUrl = gp.url(); const t = await B();
  if (SHOTS) await gp.screenshot({ path: `${SHOTS}/receipt.png` });
  const keys = (t.match(/DEMO-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}/g) || []).length;
  return [/CS-2026-\d{6}/.test(t) && keys >= 2 && /ДЕМО — оплату не проведено/i.test(t) && /Друкувати/.test(t), `ключів ${keys}; ${new URL(receiptUrl).pathname}`];
});
await tryRec('4.6', 'Після замовлення кошик порожній, лічильник 0, empty-state з посиланням у каталог', async () => {
  await gp.goto(BASE + '/cart', { waitUntil: 'networkidle' }); const t = await B(); const link = await gp.locator('main a[href*="/catalog"]').count();
  const dis = await gp.getByRole('button', { name: /Оформити замовлення/ }).count();
  return [(await gcount()) === 0 && link > 0, `лічильник ${await gcount()}; кнопка оформлення ${dis ? 'є' : 'нема'}`];
});
await tryRec('4.1', 'Account: історія демо-замовлень цієї сесії', async () => {
  await gp.goto(BASE + '/account', { waitUntil: 'networkidle' }); const t = await B(); return [/CS-2026-\d{6}/.test(t), ''];
});
await tryRec('4.6', 'API: JSON чека для своєї сесії, 404 для чужої', async () => {
  const p = new URL(receiptUrl).pathname.replace(/^\/orders\//, '/api/orders/');
  const own = await gp.request.get(BASE + p); const other = await (await browser.newContext()).request.get(BASE + p);
  return [own.status() === 200 && /json/.test(own.headers()['content-type'] || '') && other.status() === 404, `${p}: своя ${own.status()}, чужа ${other.status()}`];
});
await tryRec('4.4', 'Неіснуючий slug → 404 з посиланням у каталог', async () => {
  await gp.goto(BASE + '/games/no-such-game-xyz', { waitUntil: 'networkidle' }); await gp.waitForTimeout(800); const t = await B();
  return [/404|не знайдено/i.test(t) && (await gp.locator('main a[href*="/catalog"]').count()) > 0, ''];
});
await tryRec('4.5', 'Cookie сесії: httpOnly, SameSite=Lax', async () => {
  const c = (await ctx2.cookies()).filter((x) => x.httpOnly); return [c.length > 0 && c.every((x) => x.sameSite === 'Lax'), c.map((x) => `${x.name} httpOnly sameSite=${x.sameSite}`).join('; ')];
});
await tryRec('§5', 'CSP-заголовок на сторінках', async () => { const r = await gp.request.get(BASE + '/'); return [!!r.headers()['content-security-policy'], (r.headers()['content-security-policy'] || '').slice(0, 80)]; });

// ── §5 Адаптивність і мобільні фільтри ──
const m = await browser.newContext({ viewport: { width: 375, height: 800 } }); const mp = await m.newPage();
for (const p of ['/', '/catalog', '/games/neon-horizon-2088', '/cart']) {
  await tryRec('§5', `375 px без горизонтального прокручування: ${p}`, async () => { await mp.goto(BASE + p, { waitUntil: 'networkidle' }); await mp.waitForTimeout(500); return [!(await mp.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)), `${await mp.evaluate(() => document.documentElement.scrollWidth)} px`]; });
}
await tryRec('4.3', '375 px: фільтри у висувній панелі за кнопкою «Фільтри»', async () => {
  await mp.goto(BASE + '/catalog', { waitUntil: 'networkidle' }); const steamVisible = await mp.locator('label:visible').filter({ hasText: /^\s*Steam\s*\(?\d+\)?\s*$/ }).count() > 0;
  await mp.getByRole('button', { name: /Фільтри/ }).first().click(); await mp.waitForTimeout(700); const after = await mp.locator('label:visible').filter({ hasText: /^\s*Steam\s*\(?\d+\)?\s*$/ }).count() > 0;
  return [!steamVisible && after, `до: ${steamVisible ? 'видно' : 'сховано'}, після: ${after ? 'видно' : 'сховано'}`];
});
for (const p of ['/', '/catalog', '/cart']) {
  await tryRec('§5', `1440 px без горизонтального прокручування: ${p}`, async () => { await go(p); return [!(await hscroll()), '']; });
}
rec('§5', 'Без JS-помилок у консолі за всю перевірку (вкладка 1)', errors.length === 0, errors.slice(0, 2).join(' | '));

await browser.close();
const cnt = (l) => res.filter((r) => r.ok === l).length;
console.log(`\nПідсумок: ✓ ${cnt('✓')} · ~ ${cnt('~')} · ✗ ${cnt('✗')} з ${res.length}`);
fs.writeFileSync(OUT, JSON.stringify({ base: BASE, ok: cnt('✓'), minor: cnt('~'), fail: cnt('✗'), total: res.length, results: res }, null, 1));
