# PROGRESS

## Етап 0
Зроблено: docs/PLAN.md — чекліст по етапах 1–9 з посиланнями на ТЗ.

## Етап 1
Зроблено: docs/FEATURES.md (85 функцій F-001…F-085), docs/DECISIONS.md (10 рішень), копії макетів і опису в docs/design/.
Не зроблено: колонка «Тести» заповнюється з етапу 4.

## Етап 2
Зроблено: монорепо (apps/api — Fastify, apps/web — React+Vite+Tailwind, e2e — Playwright), Docker (db/api/web, multi-stage, non-root, healthcheck), docker-compose.test.yml з окремою БД, Makefile, ESLint+Prettier+tsc strict.
Перевірка: `make test` у Docker — lint, typecheck, vitest api (1 тест) і web (3 тести) — код 0.
Не зроблено: схема БД без моделей (етап 3), тому `prisma generate` у Dockerfile-ах додається на етапі 3.
