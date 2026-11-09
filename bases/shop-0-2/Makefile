.PHONY: up down logs test coverage reset-db

up:
	docker compose up --build -d

down:
	docker compose down

logs:
	docker compose logs -f

# Усі тести в Docker (§6): lint, typecheck, unit; код виходу 0 лише якщо пройшло все
test:
	docker compose -p cybersphere-test -f docker-compose.test.yml build tests
	docker compose -p cybersphere-test -f docker-compose.test.yml run --rm -T tests; rc=$$?; docker compose -p cybersphere-test -f docker-compose.test.yml down -v --remove-orphans >/dev/null 2>&1; exit $$rc

coverage:
	docker compose -p cybersphere-test -f docker-compose.test.yml build tests
	docker compose -p cybersphere-test -f docker-compose.test.yml run --rm -T -v $(CURDIR)/coverage:/repo/coverage tests sh -c "npm run coverage --workspace=apps/api -- --coverage.reportsDirectory=/repo/coverage/api && npm run coverage --workspace=apps/web -- --coverage.reportsDirectory=/repo/coverage/web"; rc=$$?; docker compose -p cybersphere-test -f docker-compose.test.yml down -v >/dev/null 2>&1; exit $$rc

reset-db:
	docker compose exec api npx prisma migrate reset --force
