#!/bin/sh
# Проверка retention: заливаем БОЛЬШЕ копий, чем KEEP, и убеждаемся, что в S3 остались
# ровно KEEP самых новых, а старые удалены. Гоняем backup.sh с RUN_ONCE=1 и малым KEEP.
#
# Использование: retention.sh <pgXX> [keep=2] [runs=5]   (runs должно быть > keep)
# Переменные: PGHOST/PGPORT/PGUSER/PGPASSWORD, S3_BUCKET/S3_ENDPOINT, AWS_*.
set -eu

VER="${1:?нужен аргумент версии, напр. pg18}"
KEEP_R="${2:-2}"
RUNS="${3:-5}"
[ "$RUNS" -gt "$KEEP_R" ] || { echo "[retention] runs($RUNS) должен быть > keep($KEEP_R)"; exit 2; }

: "${PGHOST:?нужен PGHOST}"
: "${PGUSER:?нужен PGUSER}"
: "${PGPASSWORD:?нужен PGPASSWORD}"
: "${S3_BUCKET:?нужен S3_BUCKET}"
export PGPASSWORD
export S3_PREFIX="test/retention-$VER"     # отдельный префикс, чтобы не мешать основным бэкапам
PGPORT="${PGPORT:-5432}"
EP=""; [ -n "${S3_ENDPOINT:-}" ] && EP="--endpoint-url $S3_ENDPOINT"
aws configure set default.s3.addressing_style path >/dev/null 2>&1 || true

DB="app"
PREFIX="$S3_PREFIX/$DB/"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
log() { echo "[retention $VER] $*"; }

# все ключи под префиксом, по возрастанию (старые -> новые)
list_keys() {
  aws $EP s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$PREFIX" \
    --query 'sort_by(Contents,&Key)[].Key' --output text 2>/dev/null \
    | tr '\t' '\n' | grep . | grep -v '^None$' || true
}

# чистим префикс от прошлых прогонов, чтобы счёт был детерминированным
del_all() {
  for k in $(list_keys); do
    aws $EP --only-show-errors s3 rm "s3://$S3_BUCKET/$k" >/dev/null 2>&1 || true
  done
}

del_all
log "старт: KEEP=$KEEP_R, прогонов=$RUNS, префикс s3://$S3_BUCKET/$PREFIX"

# заливаем RUNS копий, запоминая ключ каждого прогона
i=1
while [ "$i" -le "$RUNS" ]; do
  sleep 1                                   # гарантируем разный TS (секунда) в ключе
  if ! PGHOST="$PGHOST" S3_PREFIX="$S3_PREFIX" KEEP="$KEEP_R" INTERVAL=1 RUN_ONCE=1 \
       DUMP_GLOBALS=0 RESTORE_TEST=0 VERIFY=1 VERIFY_FULL=0 \
       sh /usr/local/bin/backup.sh >"$TMP/run$i.log" 2>&1; then
    log "ОШИБКА: прогон $i завершился неудачно:"; sed 's/^/    /' "$TMP/run$i.log"; exit 1
  fi
  k="$(list_keys | tail -n 1)"
  [ -n "$k" ] || { log "ОШИБКА: прогон $i не залил объект"; exit 1; }
  echo "$k" >> "$TMP/keys.txt"
  n="$(list_keys | grep -c .)"
  log "прогон $i: залит $k; сейчас в S3 $n объектов (KEEP=$KEEP_R)"
  i=$((i + 1))
done

# сколько уникальных копий реально залито (ключи не должны совпадать)
made="$(sort -u "$TMP/keys.txt" | grep -c .)"
if [ "$made" -ne "$RUNS" ]; then
  log "ОШИБКА: уникальных дампов $made из $RUNS (совпали TS?)"; exit 1
fi

# что осталось
left="$(list_keys | sort)"
count="$(printf '%s\n' "$left" | grep -c .)"
expected="$(tail -n "$KEEP_R" "$TMP/keys.txt" | sort)"
oldest="$(head -n 1 "$TMP/keys.txt")"

log "осталось в S3: $count (ожидалось KEEP=$KEEP_R)"
printf '%s\n' "$left" | sed 's/^/    /'

rc=0
if [ "$count" -ne "$KEEP_R" ]; then log "FAIL: должно остаться ровно $KEEP_R объектов, а есть $count"; rc=1; fi
if [ "$left" != "$expected" ]; then
  log "FAIL: остались не самые новые объекты"
  log "  ожидались:"; printf '%s\n' "$expected" | sed 's/^/    /'
  rc=1
fi
if printf '%s\n' "$left" | grep -qx "$oldest"; then
  log "FAIL: самый старый дамп ($oldest) не удалён"; rc=1
fi

if [ "$rc" = "0" ]; then
  log "OK: залито $RUNS копий, KEEP=$KEEP_R — в S3 остались ровно $KEEP_R новейших, старейшие $((RUNS - KEEP_R)) удалены"
else
  log "ИТОГ: retention ПРОВАЛЕН"
fi
exit "$rc"
