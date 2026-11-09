# PLAN — чекліст по етапах

## Етап 1
- [x] FEATURES.md — повний перелік функцій з джерелами — docs/FEATURES.md — check_features (§2)
- [x] DECISIONS.md — неоднозначності «Питання → Рішення → Чому» — docs/DECISIONS.md (§2, §0)
- [x] Копії макетів і опису — docs/design/{landing.jpg,catalog.jpg,structure.txt,mockups.md} — cmp з inputs (§0)
- [x] git init і перший коміт — git log (§8)

## Етап 2
- [x] Монорепо npm workspaces apps/api, apps/web, e2e — package.json — npm run typecheck (§3)
- [x] api: Fastify + buildApp + /api/health з тестом — apps/api/src — vitest (§3, §6)
- [x] web: React 18 + Vite + Router + Tailwind-токени, тест каркаса — apps/web/src — vitest (§3, §5)
- [x] Docker: db/api/web, multi-stage, non-root, healthcheck — docker-compose.yml — docker compose config (§6)
- [x] docker-compose.test.yml + Dockerfile.test, Makefile up/down/logs/test/coverage/reset-db — make test (§6)
- [x] ESLint + Prettier + tsc strict — npm run lint (§3)

## Етап 3
- [ ] Схема Prisma: ігри, жанри, платформи, видавці, ціни в копійках, знижки, спецпропозиції, рейтинг, salesCount, системні вимоги, медіаоцінки, відгуки — apps/api/prisma/schema.prisma (§4.7, §4)
- [ ] Схема: сесії, кошик і позиції, промокоди, замовлення з рядками-знімками, підписки, баланс кешбеку — schema.prisma (§4.5, §4.6, §4.1)
- [ ] Міграції Prisma і застосування при старті api — apps/api/prisma/migrations — prisma migrate deploy (§6)
- [ ] Детермінований сід ≥ 40 ігор, покриття всіх жанрів, платформ, діапазонів цін і знижок, спецпропозицій; промокоди CYBER10/FRIDAY200/EXPIRED5 — apps/api/prisma/seed.ts — make reset-db (§4.7, §4.5)
- [ ] Генератор обкладинок і скріншотів (SVG/PNG у стилі макета) — scripts/ — запуск генератора (§4.7)
- [ ] «Найновіша» гра для golden path записана в DECISIONS — docs/DECISIONS.md (§1)
- [ ] Тести сіду й схеми в make test — make test (§7)

## Етап 4
- [ ] Ціноутворення: знижки, промокоди, кешбек, економія — unit-тести спершу (§4.5, §7)
- [ ] GET /api/games, /api/games/facets, /api/games/:slug з фільтрами, сортуванням, фасетами (§4.3, §4.4)
- [ ] Кошик, підписка, замовлення, чек — ендпоінти з інтеграційними тестами на Postgres (§4.5, §4.6, §7)
- [ ] Rate-limit, Zod, маскування логів (§5, §4.6)

## Етап 5
- [ ] Лендінг за макетом з компонентними тестами (§4.2, §7)
- [ ] Каталог з фільтрами, сортуванням, URL-станом, Quick View (§4.3, §7)
- [ ] Сторінка гри, кошик, checkout, чек, news/support/account (§4.4–§4.6, §4.1)

## Етап 6
- [ ] Playwright у Docker: 10 обов'язкових E2E-сценаріїв (§7)
- [ ] axe на всіх сторінках (§7)
- [ ] Скриншоти 1440/375 у docs/screenshots/, scripts/check-traceability (§7, §2)

## Етап 7
- [ ] Поліровка під макети на 1440 (§5)
- [ ] Адаптивність 375/768 (§5)
- [ ] Продуктивність: WebP/AVIF, lazy, Lighthouse ≥ 80 (§5)

## Етап 8
- [ ] docker compose down -v && up --build -d && make test з нуля (§8)
- [ ] Покриття 100% api і web (§7)
- [ ] Golden path вручну через Playwright (§1, §8)

## Етап 9
- [ ] README.md: запуск, тести, промокоди, «найновіша» гра (§9)
- [ ] docs/REPORT.md за §10 (§10)
- [ ] Відомі обмеження чесно (§10)
