#!/bin/sh
# Проверка уведомлений: NOTIFY_CMD должен получать статус ok/fail, а NOTIFY_ON управлять тем,
# когда уведомлять (failure — только ошибки, always — каждый прогон).
# Негативный сценарий делаем через подставной pg_dump (как в test/faults.sh).
#
# Использование: notify.sh [pgXX=pg18]
set -u

VER="${1:-pg18}"
: "${PGUSER:?нужен PGUSER}"
: "${PGPASSWORD:?нужен PGPASSWORD}"
: "${S3_BUCKET:?нужен S3_BUCKET}"
export PGPASSWORD
PGPORT="${PGPORT:-5432}"
EP=""; [ -n "${S3_ENDPOINT:-}" ] && EP="--endpoint-url $S3_ENDPOINT"
aws configure set default.s3.addressing_style path >/dev/null 2>&1 || true

PREFIX="test/notify-$VER"
OUT=/tmp/notify.out
REF=/tmp/notify-ref.dump
FAKEBIN=/tmp/notify-fakebin
FAILED=0
log() { echo "[notify $VER] $*"; }
psqlD() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$1" -At -c "$2"; }

# общие параметры прогона (без уведомлений — их задаём точечно)
base_env() {
  PGHOST="$PGHOST" PGUSER="$PGUSER" ADMIN_DB="${ADMIN_DB:-postgres}" \
  S3_PREFIX="$PREFIX" RUN_ONCE=1 INTERVAL=1 DUMP_GLOBALS=0 \
  VERIFY=1 VERIFY_FULL=1 RESTORE_TEST=0 KEEP=1
}

# --- готовим подставной «падающий» pg_dump ---
createdb -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" notify_ref 2>/dev/null || true
psqlD notify_ref "create table t as select g, repeat(md5(g::text),50) v from generate_series(1,5000) g" >/dev/null
pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -Fc -d notify_ref > "$REF"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/pg_dump" <<'EOS'
#!/bin/sh
case "$*" in *--version*) echo "pg_dump (PostgreSQL) 18.6"; exit 0 ;; esac
head -c $(( $(wc -c < /tmp/notify-ref.dump) * 55 / 100 )) /tmp/notify-ref.dump
echo "pg_dump: error: simulated failure" >&2
exit 1
EOS
chmod +x "$FAKEBIN/pg_dump"

# --- кейс: успешный прогон, NOTIFY_ON=always -> должно прийти "ok" ---
: > "$OUT"
env $(base_env) NOTIFY_ON=always NOTIFY_CMD="echo \"\$STATUS\" >> $OUT" \
  sh /usr/local/bin/backup.sh >/dev/null 2>&1
if grep -qx ok "$OUT"; then log "OK: успех -> уведомление 'ok' отправлено"; else log "FAIL: нет 'ok' в $OUT"; FAILED=1; fi

# --- кейс: успешный прогон, NOTIFY_ON=failure -> уведомлений быть не должно ---
: > "$OUT"
env $(base_env) NOTIFY_ON=failure NOTIFY_CMD="echo \"\$STATUS\" >> $OUT" \
  sh /usr/local/bin/backup.sh >/dev/null 2>&1
if [ -s "$OUT" ]; then log "FAIL: при NOTIFY_ON=failure успех не должен уведомлять, а пришло: $(cat "$OUT")"; FAILED=1
else log "OK: успех при NOTIFY_ON=failure -> уведомлений нет (не спамим)"; fi

# --- кейс: падение pg_dump, NOTIFY_ON=failure -> должно прийти "fail" ---
: > "$OUT"
env $(base_env) NOTIFY_ON=failure NOTIFY_CMD="echo \"\$STATUS\" >> $OUT" PATH="$FAKEBIN:$PATH" \
  sh /usr/local/bin/backup.sh >/dev/null 2>&1
if grep -qx fail "$OUT"; then log "OK: ошибка -> уведомление 'fail' отправлено"; else log "FAIL: нет 'fail' в $OUT"; FAILED=1; fi

# --- кейс: NOTIFY_URL (webhook). Слушаем локально busybox nc, если он есть ---
if command -v nc >/dev/null 2>&1; then
  : > /tmp/notify.req
  (nc -l -p 8099 > /tmp/notify.req 2>/dev/null) &
  NCPID=$!
  sleep 1
  env $(base_env) NOTIFY_ON=always NOTIFY_URL="http://127.0.0.1:8099/" \
    sh /usr/local/bin/backup.sh >/dev/null 2>&1
  sleep 1
  kill "$NCPID" 2>/dev/null || true
  if grep -q '"text"' /tmp/notify.req 2>/dev/null; then
    log "OK: webhook получил POST с телом {\"text\": ...}"
  else
    log "WARN: не удалось проверить NOTIFY_URL локальным nc (пропускаю)"
  fi
else
  log "WARN: nc нет — проверку NOTIFY_URL пропускаю"
fi

dropdb -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --if-exists notify_ref >/dev/null 2>&1 || true
rm -rf "$FAKEBIN" "$REF" "$OUT"

if [ "$FAILED" = "0" ]; then log "OK: уведомления работают (ok/fail, NOTIFY_ON, NOTIFY_URL)"; fi
exit "$FAILED"
