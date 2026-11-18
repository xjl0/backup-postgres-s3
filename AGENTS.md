# AGENTS.md

## Что это

`pg-s3-backup` — самостоятельный репозиторий (без коммитов, история ещё не начата).
Один Docker-образ, который циклично делает **логический бэкап всех баз PostgreSQL → pg_dump `-Fd` (zstd по файлу на таблицу) → S3 папкой**,
с проверкой целостности и ретеншном. Подключается к любому стеку только образом + переменными окружения.

Вся логика — в одном скрипте `backup.sh` (POSIX `sh`). Остальное — обвязка для сборки/запуска.

## Файлы

| Файл | Роль |
|---|---|
| `backup.sh` | **Вся логика.** Цикл `while true`: перечислить базы → `pg_dump -Fd -j -Z zstd:N` → `verify` → `rclone copy` папки (multipart) → `MANIFEST.sha256` → `retain` → `sleep INTERVAL` |
| `Dockerfile` | `postgres:${PG_MAJOR}-alpine` + `rclone` + `zstd` + `curl`; `USER postgres`; ENTRYPOINT — скрипт. `ARG PG_MAJOR=18` |
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
1. `set -u`, обязательные переменные через `${VAR:?}`; ставит `rclone`/`zstd` через `apk` (с повторами), если их нет; клиент pg_dump < 16 → FATAL (нет `-Z zstd`).
2. `detect_env()`: читает `server_version_num`, права роли (`rolsuper`/`rolbypassrls`/`rolcreatedb`),
   членство в `pg_read_all_data`.
3. Ждёт `pg_isready`. Если **сервер новее клиента** `pg_dump` — пропускает прогон с FATAL (клиент обязан быть `>=` сервера).
4. `_globals` (роли/привилегии, `pg_dumpall --globals-only --no-role-passwords`) → `S3_PREFIX/_globals/<ts>.sql.zst`.
5. По каждой базе из `pg_database` (кроме `EXCLUDE_DBS`, шаблонов, `datallowconn=false`):
   - предпроверка `CONNECT`; предупреждение о RLS-таблицах без `BYPASSRLS`;
   - `pg_dump -Fd -j DUMP_JOBS -Z zstd:ZSTD_LEVEL` (cross-version → `--quote-all-identifiers`) в папку
     `WORKDIR/<db>/<UTC>/`: `toc.dat` + самостоятельный `<oid>.dat.zst` на таблицу;
   - `verify_archive()`: `pg_restore -l` + `zstd -t` каждого файла, при `VERIFY_FULL=1` ещё `pg_restore -f /dev/null`;
   - при `RESTORE_TEST=1` — восстановление папки в скретч-БД `restore_test_*` и `dropdb` (нужен `CREATEDB`/суперюзер);
   - `MANIFEST.sha256` локально → `rclone copy` папки (без манифеста) в `S3_PREFIX/<db>/<UTC>/` →
     манифест последним (только при rc=0 загрузки);
     при провале — `rclone purge` неполной папки;
   - `retain()` — копии = папки с манифестом (+ одиночные файлы прежнего формата); оставляет `KEEP`
     новейших, остальные удаляет (`purge`/`deletefile`); папки без манифеста (кроме текущего TS) удаляет.
6. Любой сбой помечает прогон `failed=1`; дамп при провале проверок **не** загружается.

## Соглашения и грабли

- Язык комментариев/логов/доков — **русский**; сообщения скрипта в stdout → `docker logs`.
- **S3 — только через `rclone`**, минимум сущностей: `rclone lsf` (список), `rclone copy`/`copyto`
  (загрузка/скачивание), `rclone purge`/`deletefile` (retention). Потоки загрузки — всегда 4, остальное по
  умолчанию rclone. Подключение — из переменных окружения (`S3_ENDPOINT`/`S3_REGION`/ключи), файла
  конфигурации нет. Бакет уже существует — скрипт его НЕ создаёт.
- **Данные из S3 по умолчанию НЕ выкачиваются**: `VERIFY_FULL=1` (локально) + код возврата rclone
  (Content-MD5 частей + размер). Полное скачивание — только `VERIFY_DOWNLOAD=1`.
- Надёжность загрузки — два уровня: **наши 3 попытки** (`rclone copy` заново, пауза 10 с) и
  **внутренние повторы rclone** (`--retries 5`, `--low-level-retries 25`, `--timeout 15m`).
  Плюс сторожевой таймаут попытки (минимум 15 мин, для крупных дампов ~размер/300 КБ/с).
  `--s3-disable-http2` добавляется только на 3-й (последней) попытке — через `RCLONE_EXTRA`
  (у части S3-совместимых HTTP/2 подвешивает загрузку).
- Переменные берутся из окружения **и** из `ENV_FILE` (`KEY=VALUE`, по умолчанию `/etc/pg-backup/env`);
  заданные в окружении имеют приоритет. Новую переменную документируй в `README.md`.
- Правки — в `backup.sh`; помни, что это POSIX `sh`, а не bash.
- Сжатие — **встроенный zstd pg_dump** (`-Fd -Z zstd:N`), по файлу на таблицу: каждый файл самостоятелен,
  `pg_restore` читает папку напрямую. Сжатие однопоточное (pg_dump не поддерживает `workers`), поэтому
  дефолт `ZSTD_LEVEL=3` (замер на 6,7 ГБ: 3 → 17 с, 9 → 72 с, 15 → 586 с при разнице размера ≤5%).
- `MANIFEST.sha256` загружается **последним** и служит маркером полной копии — не меняй порядок.
- **Загрузка — единым способом: multipart для всех файлов** (`--s3-upload-cutoff 0 --multi-thread-streams 0`),
  лимит 5 ТБ на файл. НЕ добавляй `rclone check` по MD5: у Servercore ETag multipart-объекта без «-N»,
  rclone принимает его за MD5 и сверка ложно падает. И не переходи на один PUT — это лимит 5 ГБ на файл.
- Код возврата `pg_dump` теперь прямой (конвейера нет); у `pg_dumpall | zstd` (globals) он по-прежнему
  пишется в отдельный файл. Падение pg_dump → нет загрузки — покрыто `test/faults.sh`, не сломай.
- Проверки уровня `VERIFY` (`pg_restore -l` + `zstd -t`) НЕ ловят обрыв на границе zstd-фрейма:
  надёжно ловит `VERIFY_FULL=1` (`pg_restore -f /dev/null`) и код возврата pg_dump.
- Кросс-версионные `SET <guc>`-ошибки при restore считаются безобидными (см. `nonbenign`).
- Меняя поведение/переменные — синхронизируй таблицу в `README.md` и комментарии в `docker-compose.example.yml`.
- Репозиторий ещё без коммитов; `.idea` вычищена из индекса и добавлена в `.gitignore`.
- Стенд: инфраструктура поднимается detached, а прогон идёт через `docker compose run --no-deps`.
  Лог — в контейнере `pg-s3-backup-test` (`make test-logs`), он НЕ удаляется (`--name` вместо `--rm`).
  Бакет для стенда создаёт `test/run-all.sh` (s3mock сам бакеты не создаёт) — в проде бакет внешний.

## Команды

```bash
make build IMAGE=xjl00/backup-postgres-s3 [PG_MAJOR=16]      # сборка (по умолчанию Docker Hub)
make push  IMAGE=xjl00/backup-postgres-s3                    # сборка + push в Docker Hub
make push-all                                                # сборка + push в Docker Hub и ghcr.io
make run                                                      # локальный запуск из stack.env
# стенд (PG 15/16/17/18 + S3, локально): бэкап + проверка восстановления данных
make test                                                     # поднять стенд и прогнать
make test-verify VER=pg15 DB=app                              # перепроверить восстановление
make test-retention VER=pg18 KEEP_CHECK=2 KEEP_RUNS=5         # перепроверить retention
make test-faults VER=pg18                                     # негативные проверки (падение pg_dump)
make test-real-s3                                             # проверка РЕАЛЬНОГО S3 из .env
make test-ls                                                  # что лежит в S3-стенде
make test-down                                                # сбросить стенд (down -v)
```

Все test-* зависят от `runner-image` (образ runner печёт `backup.sh` при сборке): без этого легко
протестировать устаревший скрипт.

Инфраструктура стенда поднимается detached (прерывание не роняет БД, повторный `make test` — секунды).
Тестов как таковых нет; проверка скрипта — стенд выше, либо запуск образа против БД и анализ логов
(`--- конфигурация ---`, `verify: OK`, `upload OK`, `restore-test OK`, `retention`, `failed=`).
