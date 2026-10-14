# AGENTS.md

## Что это

`pg-s3-backup` — самостоятельный репозиторий (без коммитов, история ещё не начата).
Один Docker-образ, который циклично делает **логический бэкап всех баз PostgreSQL → zstd → S3**,
с проверкой целостности и ретеншном. Подключается к любому стеку только образом + переменными окружения.

Вся логика — в одном скрипте `backup.sh` (POSIX `sh`). Остальное — обвязка для сборки/запуска.

## Файлы

| Файл | Роль |
|---|---|
| `backup.sh` | **Вся логика.** Цикл `while true`: перечислить базы → `pg_dump -Fc -Z0` → внешний `zstd` → `verify` → `s3 cp` → `retain` → `sleep INTERVAL` |
| `Dockerfile` | `postgres:${PG_MAJOR}-alpine` + `aws-cli` + `zstd`; `USER postgres`; ENTRYPOINT — скрипт. `ARG PG_MAJOR=18` |
| `docker-compose.example.yml` | Пример подключения (только `image` + `environment`), сервис в одной сети с БД |
| `stack.env.example` | Шаблон env-файла (`KEY=VALUE`); `cp stack.env.example stack.env` (последний в `.gitignore`) |
| `docker-compose.test.yml` | Локальный стенд: PG 15/16/17/18 (свой seed у каждой) + S3 (adobe/s3mock) + `runner` |
| `test/seed/pgXX/` | Версионные данные с фичами мажора (MERGE, SQL/JSON, JSON_TABLE, uuidv7, ...) |
| `test/checks/pgXX.sql` | Версионная проверка восстановленной БД (RAISE EXCEPTION при расхождении) |
| `test/run-all.sh`, `test/verify.sh`, `test/retention.sh` | Прогон по версиям; проверка «дамп из S3 разворачивается, данные на месте»; проверка удаления старых копий |
| `test/faults.sh` | Негативные проверки: падение `pg_dump` не должно давать загрузку битого дампа |
| `test/reals3.sh` | Проверка РЕАЛЬНОГО S3 из `.env`: доступ, `list`/`delete`, диагностика скачивания, прогон `backup.sh` в отдельный префикс |
| `.github/workflows/build.yml` | CI в 2 этапа: `test` (весь стенд) → `build` (сборка/пуш образа, только при успешных тестах) |
| `Makefile` | Локальные `make build/push/run/logs` (`PG_MAJOR` переопределяем) |
| `README.md` | Полная документация: переменные, проверки, восстановление, нюансы версий/прав |
| `.dockerignore`, `.gitignore` | Исключения (`.idea` — только из git-индекса, см. ниже) |

## Как работает `backup.sh` (кратко)

0. `load_env_file`: читает переменные из `ENV_FILE` (по умолчанию `/etc/pg-backup/env`), **не** переопределяя
   уже заданные в окружении (окружение приоритетнее файла). Поддержка обоих способов — см. «Соглашения».
1. `set -u`, обязательные переменные через `${VAR:?}`; ставит `aws-cli`/`zstd` через `apk`, если их нет.
2. `detect_env()`: читает `server_version_num`, права роли (`rolsuper`/`rolbypassrls`/`rolcreatedb`),
   членство в `pg_read_all_data`.
3. Ждёт `pg_isready`. Если **сервер новее клиента** `pg_dump` — пропускает прогон с FATAL (клиент обязан быть `>=` сервера).
4. `_globals` (роли/привилегии, `pg_dumpall --globals-only --no-role-passwords`) → `S3_PREFIX/_globals/<ts>.sql.zst`.
5. По каждой базе из `pg_database` (кроме `EXCLUDE_DBS`, шаблонов, `datallowconn=false`):
   - предпроверка `CONNECT`; предупреждение о RLS-таблицах без `BYPASSRLS`;
   - `pg_dump -Fc -Z0` (cross-version → `--quote-all-identifiers`) `| zstd -<ZSTD_LEVEL>` в файл;
   - `verify_archive()`: `zstd -t` + `unzstd | pg_restore -l`, при `VERIFY_FULL=1` ещё `pg_restore -f /dev/null`;
   - при `RESTORE_TEST=1` — восстановление в скретч-БД `restore_test_*` и `dropdb` (нужен `CREATEDB`/суперюзер);
   - `aws s3 cp` в `S3_PREFIX/<db>/<UTC>.dump.zst`, при `VERIFY_REMOTE=1` сверка `ContentLength`;
   - `retain()` — оставляет `KEEP` последних объектов префикса, лишние удаляет.
6. Любой сбой помечает прогон `failed=1`; дамп при провале проверок **не** загружается.

## Соглашения и грабли

- Язык комментариев/логов/доков — **русский**; сообщения скрипта в stdout → `docker logs`.
- **Данные из S3 по умолчанию НЕ выкачиваются** (egress платный): «не сломан ли дамп» — локально
  (`VERIFY_FULL=1`), «доехал ли» — по метаданным (`VERIFY_REMOTE`: размер + ETag/MD5/ChecksumSHA256).
  Полное скачивание — только `VERIFY_DOWNLOAD=1` (опционально).
- **`S3_CHECKSUM_ALGORITHM` по умолчанию `SHA256`** (сквозная сумма на загрузке) с автоматическим
  повтором без суммы, если провайдер её не принимает. Это осознанный компромисс: на корректных S3
  даёт проверку байтов на приёмке, на «кривых» — деградирует до размера/ETag, а не ломает прогон.
- **`aws configure set ... when_required`** в `backup.sh`/`verify.sh` обязателен: aws-cli ≥ 2.23 сам
  навешивает CRC64 на загрузке, у части S3-совместимых хранилищ multipart-сумма некорректна, и тогда
  `aws s3 cp` не может скачать объект (сломается восстановление). Не убирай эти строки.
- Уведомления: `NOTIFY_URL`/`NOTIFY_CMD`/`HEALTHCHECK_URL` (код `ok|fail` через `notify()`); покрыто
  `test/notify.sh`.
- Переменные берутся из окружения **и** из `ENV_FILE` (`KEY=VALUE`, по умолчанию `/etc/pg-backup/env`);
  заданные в окружении имеют приоритет. Новую переменную документируй в `README.md`.
- Правки — в `backup.sh`; помни, что это POSIX `sh`, а не bash.
- Сжатие — **внешним `zstd` по всему архиву**, а не `-Z zstd` внутри `pg_dump` (встроенное жмёт по сегментам и хуже).
- `--only-show-errors` есть только у `s3 cp/rm`, **нельзя** у `s3api` (aws-cli v2).
- `--endpoint-url` подставляется только если задан `S3_ENDPOINT`; для части S3-совместимых нужен path-style (уже выставляется).
- `pg_restore` не читает `.zst` напрямую — всегда `unzstd -c file | pg_restore`.
- **Статус конвейера в POSIX `sh` — это статус последней команды** (`pg_dump | zstd` → статус `zstd`),
  поэтому код возврата `pg_dump`/`pg_dumpall` пишется в отдельный файл (иначе оборванный дамп уедет
  в S3 как «успешный»). Это покрыто `test/faults.sh` — не сломай.
- Проверки уровня `VERIFY` (`zstd -t` + `pg_restore -l`) НЕ ловят обрыв внутри данных: оглавление
  валидно. Ловит только `VERIFY_FULL=1` (`pg_restore -f /dev/null`).
- Кросс-версионные `SET <guc>`-ошибки при restore считаются безобидными (см. `nonbenign`).
- Меняя поведение/переменные — синхронизируй таблицу в `README.md` и комментарии в `docker-compose.example.yml`.
- Репозиторий ещё без коммитов; `.idea` вычищена из индекса и добавлена в `.gitignore`.
- Стенд: инфраструктура поднимается detached, а сам прогон идёт через `docker compose run --no-deps`
  (не ждать одноразовый `s3-init` — иначе `run` может зависнуть без вывода). Лог — в контейнере
  `pg-s3-backup-test` (`make test-logs`), потому что контейнер НЕ удаляется (`--name` вместо `--rm`).

## Команды

```bash
make build IMAGE=ghcr.io/<OWNER>/pg-s3-backup [PG_MAJOR=16]   # сборка
make push  IMAGE=ghcr.io/<OWNER>/pg-s3-backup                 # сборка + push
make run                                                      # локальный запуск из stack.env
# стенд (PG 15/16/17/18 + S3, локально): бэкап + проверка восстановления данных
make test                                                     # поднять стенд и прогнать
make test-verify VER=pg15 DB=app                              # перепроверить восстановление
make test-retention VER=pg18 KEEP_CHECK=2 KEEP_RUNS=5         # перепроверить retention
make test-faults VER=pg18                                     # негативные проверки (падение pg_dump)
make test-notify VER=pg18                                     # проверка уведомлений
make test-real-s3                                             # проверка РЕАЛЬНОГО S3 из .env
make test-ls                                                  # что лежит в S3-стенде
make test-down                                                # сбросить стенд (down -v)
```

Все test-* зависят от `runner-image` (образ runner печёт `backup.sh` при сборке): без этого легко
протестировать устаревший скрипт.

Инфраструктура стенда поднимается detached (прерывание не роняет БД, повторный `make test` — секунды).
Тестов как таковых нет; проверка скрипта — стенд выше, либо запуск образа против БД и анализ логов
(`--- конфигурация ---`, `verify: OK`, `upload OK`, `restore-test OK`, `retention`, `failed=`).
