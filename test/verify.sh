#!/bin/sh
# Проверка, что бэкап со стенда не только валиден, но и РАЗВОРАЧИВАЕТСЯ с сохранением данных:
#   1) берём последний дамп базы из S3 (стенд), проверяем zstd/pg_restore -l;
#   2) восстанавливаем его в одноразовую БД на сервере ТОЙ ЖЕ версии;
#   3) сверяем число строк по каждой таблице «источник vs восстановленная»;
#   4) прогоняем версионную проверку /checks/<ver>.sql (фичи конкретного мажора).
#
# Использование: verify.sh <pg15|pg16|pg17|pg18> [db=app]
# Переменные: PGHOST/PGPORT/PGUSER/PGPASSWORD, S3_BUCKET/S3_PREFIX (rclone).
set -eu

VER="${1:?нужен аргумент версии, напр. pg18}"
DB="${2:-app}"
EXPECT_MAJOR="${VER#pg}"

: "${PGHOST:?нужен PGHOST}"
: "${PGUSER:?нужен PGUSER}"
: "${PGPASSWORD:?нужен PGPASSWORD}"
: "${S3_BUCKET:?нужен S3_BUCKET}"
export PGPASSWORD
PGPORT="${PGPORT:-5432}"
S3_PREFIX="${S3_PREFIX:-backup}"
. /s3env.sh

SCRATCH="verify_${VER}_$(date -u +%s)_$$"
TMP="$(mktemp -d)"
FAILED=0
log() { echo "[verify $VER] $*"; }
fail() { log "FAIL: $*"; FAILED=1; }

psqlD() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$1" -At -c "$2"; }

cleanup() {
  dropdb -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --if-exists "$SCRATCH" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# 1) последний объект под префиксом базы
rel="$(s3_list "$S3_PREFIX/$DB/" | tail -n 1)"
key=""
[ -n "$rel" ] && key="$S3_PREFIX/$DB/$rel"
if [ -z "$key" ]; then
  log "ОШИБКА: нет объектов s3://$S3_BUCKET/$S3_PREFIX/$DB/"; exit 1
fi
log "последний дамп: $key (скачиваю — это глубокий тест, трафик считаем допустимым)"

mkdir -p "$TMP/dl"
rclone $RCLONE_OPTS copy "$(s3path "$key")" "$TMP/dl" >/dev/null 2>&1 || { log "ОШИБКА: не скачать $key"; exit 1; }
dl="$(ls "$TMP/dl" | head -1)"
mv "$TMP/dl/$dl" "$TMP/db.dump.zst"
log "скачано $(wc -c <"$TMP/db.dump.zst") B"
zstd -t "$TMP/db.dump.zst" >/dev/null 2>&1 || { log "ОШИБКА: zstd -t FAILED"; exit 1; }
unzstd -c "$TMP/db.dump.zst" | pg_restore -l >/dev/null 2>&1 || { log "ОШИБКА: pg_restore -l FAILED"; exit 1; }
log "архив валиден (zstd -t + pg_restore -l)"

# 2) восстановление в одноразовую БД
log "восстанавливаю в $SCRATCH на $(psqlD postgres 'select version()' | cut -d, -f1)"
createdb -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" "$SCRATCH"
# кросс-версионные SET несуществующих GUC — безобидны, провалом не считаем
unzstd -c "$TMP/db.dump.zst" \
  | pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$SCRATCH" --no-owner --no-privileges \
      2>"$TMP/restore.err" || true
nonbenign="$(grep 'pg_restore: error' "$TMP/restore.err" 2>/dev/null \
              | grep -vc 'unrecognized configuration parameter' || true)"
if [ "${nonbenign:-0}" != "0" ]; then
  log "ОШИБКА: pg_restore вернул ошибки:"; sed 's/^/    /' "$TMP/restore.err"; exit 1
fi

# 3) сверка числа строк по каждой таблице
tables="$(psqlD "$DB" "select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1")"
if [ -z "$tables" ]; then log "ОШИБКА: в источнике нет таблиц"; FAILED=1; fi
for t in $tables; do
  src="$(psqlD "$DB"      "select count(*) from public.\"$t\"")"
  dst="$(psqlD "$SCRATCH" "select count(*) from public.\"$t\"")"
  if [ "$src" = "$dst" ]; then
    log "  строка-в-строку $t: $dst (источник $src)"
  else
    fail "таблица $t: источник=$src, восстановлено=$dst"
  fi
done

# 4) версионные фичи и маркер версии
vmaj="$(psqlD "$SCRATCH" "select major from version_probe limit 1")"
vfeat="$(psqlD "$SCRATCH" "select feature from version_probe limit 1")"
if [ "$vmaj" = "$EXPECT_MAJOR" ]; then
  log "  version_probe: major=$vmaj, фичи='$vfeat'"
else
  fail "version_probe.major=$vmaj, ожидалось $EXPECT_MAJOR"
fi
if [ -f "/checks/$VER.sql" ]; then
  log "версионная проверка /checks/$VER.sql"
  if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$SCRATCH" -v ON_ERROR_STOP=1 -At \
       -f "/checks/$VER.sql" >"$TMP/check.out" 2>"$TMP/check.err"; then
    log "  $(tail -n 1 "$TMP/check.out")"
  else
    fail "версионная проверка $VER не прошла:"; sed 's/^/    /' "$TMP/check.err"
  fi
else
  fail "нет файла проверки /checks/$VER.sql"
fi

if [ "$FAILED" = "0" ]; then log "OK: $key восстановлен, данные и фичи PG$EXPECT_MAJOR на месте"; fi
exit "$FAILED"
