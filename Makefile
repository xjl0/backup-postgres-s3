# Локальная сборка/пуш образа (альтернатива CI).
IMAGE    ?= ghcr.io/xjl0/backup-postgres-s3
TAG      ?= latest
PG_MAJOR ?= 18        # клиент pg_dump: должен быть >= сервера (18 снимает 15..18)
TEST_COMPOSE ?= docker-compose.test.yml
TEST_IMAGE ?= pg-s3-backup-test-runner
TEST_NET   ?= pg-s3-backup-test_testnet
REAL_ENV   ?= ./.env          # где лежат креды реального S3 (endpoint/bucket/AWS_*)
REAL_PREFIX ?= test/reals3check   # отдельный префикс: retention не тронет ваши бэкапы
REAL_KEEP  ?= 3
VER      ?= pg18      # версия стенда для test-verify / test-retention
DB       ?= app
KEEP_CHECK ?= 2       # retention: сколько копий оставлять
KEEP_RUNS  ?= 5       # retention: сколько копий залить

.PHONY: build push run logs runner-image test test-up test-logs test-ls test-verify test-retention test-faults test-notify test-real-s3 test-down

build:
	docker build --build-arg PG_MAJOR=$(PG_MAJOR) -t $(IMAGE):$(TAG) .
push: build
	docker push $(IMAGE):$(TAG)
run:
	docker run --rm --env-file ./stack.env $(IMAGE):$(TAG)
logs:
	@echo "swarm:  docker service logs -f <stack>_pg-backup"
	@echo "compose: docker compose logs -f pg-backup"

# --- тестовый стенд (PG 15/16/17/18 + S3, локально) ---
# Инфраструктура поднимается detached: прерывание прогона НЕ роняет БД, а повторный
# запуск идёт быстро (данные стенда сохраняются). Полный сброс — make test-down.
# Образ runner собирается явно, а сам прогон идёт через `run --no-deps` — чтобы не ждать
# одноразовую зависимость s3-init (иначе `run` может «молча» зависнуть на ожидании).
# Для каждой версии: бэкап -> восстановление -> сверка данных -> retention. Код возврата = были ли ошибки.
INFRA = pg15 pg16 pg17 pg18 s3 s3-init
NAME  = pg-s3-backup-test

# ВАЖНО: backup.sh «запекается» в образ runner при сборке — все цели ниже зависят от
# runner-image, иначе можно тестировать устаревший скрипт.
runner-image:
	docker compose -f $(TEST_COMPOSE) build runner

test: runner-image
	docker compose -f $(TEST_COMPOSE) up -d $(INFRA)
	@echo ">>> запускаю runner (лог идёт ниже; Ctrl-C остановит только его, БД останутся)"
	@docker rm -f $(NAME) >/dev/null 2>&1 || true
	@rc=0; docker compose -f $(TEST_COMPOSE) run -T --name $(NAME) --no-deps runner || rc=$$?; \
	 echo "runner: код возврата $$rc; полный лог: make test-logs"; exit $$rc
test-up: runner-image           # только поднять стенд (без прогона)
	docker compose -f $(TEST_COMPOSE) up -d $(INFRA)
test-logs:                     # лог последнего прогона (контейнер сохраняется)
	@docker logs -f $(NAME) 2>/dev/null || \
	 echo "нет контейнера $(NAME): сначала запустите make test"
test-ls:                       # что лежит в S3-стенде
	docker compose -f $(TEST_COMPOSE) run -T --rm --no-deps --entrypoint /bin/sh runner -c \
	  'aws --endpoint-url "$$S3_ENDPOINT" s3 ls --recursive "s3://$$S3_BUCKET/"'
test-verify: runner-image      # отдельная проверка восстановления (VER=pg15 ... DB=app)
	docker compose -f $(TEST_COMPOSE) run -T --rm --no-deps -e PGHOST=$(VER) \
	  -e S3_PREFIX=test/$(VER) --entrypoint /bin/sh runner /verify.sh $(VER) $(DB)
test-retention: runner-image   # отдельная проверка retention (VER=pg18 KEEP_CHECK=2 KEEP_RUNS=5)
	docker compose -f $(TEST_COMPOSE) run -T --rm --no-deps -e PGHOST=$(VER) \
	  -e KEEP_CHECK=$(KEEP_CHECK) -e KEEP_RUNS=$(KEEP_RUNS) \
	  --entrypoint /bin/sh runner /retention.sh $(VER) $(KEEP_CHECK) $(KEEP_RUNS)
test-faults: runner-image      # негативные проверки: падение pg_dump -> нет загрузки в S3
	docker compose -f $(TEST_COMPOSE) run -T --rm --no-deps -e PGHOST=$(VER) \
	  --entrypoint /bin/sh runner /faults.sh $(VER)
test-notify: runner-image      # проверка уведомлений (NOTIFY_CMD/NOTIFY_ON/NOTIFY_URL)
	docker compose -f $(TEST_COMPOSE) run -T --rm --no-deps -e PGHOST=$(VER) \
	  --entrypoint /bin/sh runner /notify.sh $(VER)
test-real-s3: runner-image     # ПРОВЕРКА РЕАЛЬНОГО S3 из $(REAL_ENV) (префикс $(REAL_PREFIX))
	docker compose -f $(TEST_COMPOSE) up -d $(INFRA)
	@echo ">>> реальный S3: endpoint/bucket/креды из $(REAL_ENV); префикс $(REAL_PREFIX) (секреты не печатаю)"
	docker run --rm --network $(TEST_NET) --env-file $(REAL_ENV) \
	  -e PGHOST=pg18 -e PGPORT=5432 -e PGUSER=postgres -e PGPASSWORD=postgres -e ADMIN_DB=postgres \
	  -e S3_PREFIX=$(REAL_PREFIX) -e RUN_ONCE=1 -e INTERVAL=1 -e KEEP=$(REAL_KEEP) \
	  -e DUMP_GLOBALS=1 -e VERIFY=1 -e VERIFY_FULL=1 -e VERIFY_REMOTE=1 -e VERIFY_DOWNLOAD=0 -e RESTORE_TEST=0 \
	  -v $(CURDIR)/test/reals3.sh:/reals3.sh:ro \
	  --entrypoint /bin/sh $(TEST_IMAGE) /reals3.sh
test-down:                     # остановить и удалить данные стенда
	docker compose -f $(TEST_COMPOSE) down -v