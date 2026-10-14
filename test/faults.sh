#!/bin/sh
# Негативные проверки (fault injection): если pg_dump НЕ смог сделать дамп, backup.sh ОБЯЗАН
# вернуть ненулевой код и НЕ загружать объект в S3. Ловит классическую ошибку с маскировкой
# статуса в конвейере `pg_dump | zstd` (в POSIX sh статус конвейера — это статус zstd, поэтому
# оборванный дамп с валидным оглавлением может пройти verify и уехать в S3 как «успешный»).
#
# Использование: faults.sh [pgXX=pg18]
# Переменные: PGHOST/PGPORT/PGUSER/PGPASSWORD, S3_BUCKET/S3_PREFIX (rclone).
set -u

VER="${1:-pg18}"
: "${PGUSER:?нужен PGUSER}"
: "${PGPASSWORD:?нужен PGPASSWORD}"
: "${S3_BUCKET:?нужен S3_BUCKET}"
export PGPASSWORD
PGPORT="${PGPORT:-5432}"
. /s3env.sh

DB="app"
PREFIX="test/faults-$VER"
REF=/tmp/ref.dump
FAKEBIN=/tmp/fakebin
FAILED=0
log() { echo "[faults $VER] $*"; }

psqlD() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$1" -At -c "$2"; }
count_prefix() { s3_list "$PREFIX/" | grep -c . || true; }
clean_prefix() { for k in $(s3_list "$PREFIX/"); do s3_del "$PREFIX/$k"; done; }

# --- эталонный (валидный) дамп: нужен, чтобы имитировать «оборвалось на середине» ---
createdb -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" faults_ref 2>/dev/null || true
psqlD faults_ref "create table t as select g, repeat(md5(g::text),50) v from generate_series(1,20000) g" >/dev/null
pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -Fc -d faults_ref > "$REF"
log "эталонный дамп: $(wc -c <"$REF") B"

# --- подставной pg_dump: падает, отдав (или не отдав) оглавление и часть данных ---
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/pg_dump" <<'EOS'
#!/bin/sh
case "$*" in *--version*) echo "pg_dump (PostgreSQL) 18.6"; exit 0 ;; esac
case "${FAKE_MODE:-mid}" in
  mid)       head -c $(( $(wc -c < /tmp/ref.dump) * 55 / 100 )) /tmp/ref.dump ;;
  immediate) : ;;    # падает, не отдав ничего
esac
echo "pg_dump: error: simulated connection failure" >&2
exit 1
EOS
chmod +x "$FAKEBIN/pg_dump"

# --- прогон одного сценария ---
run_case() {
  mode="$1"
  clean_prefix
  log "сценарий '$mode': запускаю backup.sh (VERIFY=1, VERIFY_FULL=0 — дефолт)"
  FAKE_MODE="$mode" PATH="$FAKEBIN:$PATH" \
    PGHOST="$PGHOST" PGUSER="$PGUSER" ADMIN_DB="${ADMIN_DB:-postgres}" \
    S3_PREFIX="$PREFIX" RUN_ONCE=1 INTERVAL=1 DUMP_GLOBALS=0 \
    VERIFY=1 VERIFY_FULL=0 RESTORE_TEST=0 KEEP=1 \
    sh /usr/local/bin/backup.sh >/tmp/faults-$mode.log 2>&1
  rc=$?
  n="$(count_prefix)"
  if [ "$rc" != "0" ] && [ "$n" = "0" ]; then
    log "  OK: exit=$rc, объектов в S3: $n (битый дамп не загружен)"
  else
    log "  FAIL: exit=$rc, объектов в S3: $n (ожидалось exit!=0 и 0 объектов)"
    sed 's/^/    /' /tmp/faults-$mode.log | tail -25
    FAILED=1
  fi
}

run_case mid
run_case immediate

dropdb -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --if-exists faults_ref >/dev/null 2>&1 || true
rm -rf "$FAKEBIN" "$REF"

if [ "$FAILED" = "0" ]; then
  log "OK: при падении pg_dump объект в S3 не загружается, код возврата ненулевой"
else
  log "ИТОГ: проверки fault injection ПРОВАЛЕНЫ"
fi
exit "$FAILED"
