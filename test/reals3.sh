#!/bin/sh
# Проверка РЕАЛЬНОГО S3 (endpoint/бакет/креды берутся из окружения, обычно из .env).
# Ничего не удаляет вне своего префикса; секреты не печатает.
#
# Что проверяем:
#   1) доступность бакета;
#   2) поведение провайдера с контрольными суммами aws-cli (главная проверка — СКАЧИВАНИЕ):
#      A) загрузка «как у наивного пользователя» (дефолтные настройки) -> скачивание дефолтом;
#      B) загрузка «как у нас» (path-style + when_required)          -> скачивание дефолтом;
#      C) наша загрузка -> наше скачивание;
#      D) опционально: загрузка с явной SHA256 -> скачивание (у несовершенных провайдеров падает);
#   3) прогон backup.sh против локального PostgreSQL в отдельный префикс + проверка объекта
#      без скачивания (размер/сумма) — как в проде;
#   4) list/delete (основа retention).
set -u

: "${S3_BUCKET:?нужен S3_BUCKET}"
: "${AWS_ACCESS_KEY_ID:?нужны креды AWS_ACCESS_KEY_ID}"
EP=""; [ -n "${S3_ENDPOINT:-}" ] && EP="--endpoint-url $S3_ENDPOINT"
S3_PREFIX="${S3_PREFIX:-test/reals3check}"
FAILED=0
log() { echo "[reals3] $*"; }
ok()   { echo "  OK   | $*"; }
bad()  { echo "  FAIL | $*"; FAILED=1; }

# защита: не работать в «боевом» префиксе, чтобы retention не удалил чужие бэкапы
case "$S3_PREFIX" in
  ''|test|backup|prod|production)
    log "ОТКАЗ: небезопасный S3_PREFIX='$S3_PREFIX' (нужен отдельный, напр. test/reals3check)"; exit 2 ;;
esac

log "endpoint=${S3_ENDPOINT:-<AWS>} bucket=$S3_BUCKET prefix=$S3_PREFIX region=${AWS_DEFAULT_REGION:-<default>}"

# --- 1) доступность ---
if aws $EP s3api list-objects-v2 --bucket "$S3_BUCKET" --max-keys 1 >/dev/null 2>&1; then
  ok "бакет доступен (list-objects-v2)"
else
  bad "бакет недоступен / нет прав (проверьте креды, endpoint, регион)"; log "дальше смысла нет"; exit 1
fi

PROBE="$S3_PREFIX/_probe"
printf 'pg-s3-backup probe %s\n' "$(date -u +%Y%m%dT%H%M%SZ)" > /tmp/probe.txt
head -c 12000000 /dev/urandom > /tmp/probe-big.bin   # > порога multipart (8 МБ)
CH="--checksum-algorithm SHA256"

# A) наивная загрузка (дефолтный конфиг aws-cli) -> наивное скачивание
HOME=/tmp/hc aws $EP s3 cp /tmp/probe-big.bin "s3://$S3_BUCKET/$PROBE/naive.bin" >/dev/null 2>&1
HOME=/tmp/hc aws $EP s3 cp "s3://$S3_BUCKET/$PROBE/naive.bin" /tmp/naive.out >/dev/null 2>&1 \
  && ok "дефолтная загрузка -> дефолтное скачивание (это то, что делает ваш restore)" \
  || bad "дефолтная загрузка -> скачивание ПАДАЕТ (проблема CRC64 у aws-cli >= 2.23!)"

# B) наша загрузка (path-style + when_required) -> наивное скачивание
aws configure set default.s3.addressing_style path
aws configure set default.request_checksum_calculation when_required
aws configure set default.response_checksum_validation when_required
aws $EP s3 cp /tmp/probe-big.bin "s3://$S3_BUCKET/$PROBE/ours.bin" >/dev/null 2>&1
HOME=/tmp/hc aws $EP s3 cp "s3://$S3_BUCKET/$PROBE/ours.bin" /tmp/ours.out >/dev/null 2>&1 \
  && ok "наша загрузка -> дефолтное скачивание (наши бэкапы восстановимы)" \
  || bad "наша загрузка -> дефолтное скачивание ПАДАЕТ (нужно чинить!)"

# C) наша загрузка -> наше скачивание
aws $EP s3 cp "s3://$S3_BUCKET/$PROBE/ours.bin" /tmp/ours2.out >/dev/null 2>&1 \
  && ok "наша загрузка -> наше скачивание" || bad "наша загрузка -> наше скачивание ПАДАЕТ"

# D) явная SHA256: у части провайдеров multipart-сумма некорректна и скачивание ломается
if aws $EP --only-show-errors s3 cp /tmp/probe-big.bin "s3://$S3_BUCKET/$PROBE/sha.bin" $CH >/dev/null 2>&1; then
  log "  INFO | провайдер принимает --checksum-algorithm SHA256"
  # решающая проверка: скачает ли объект с суммой ОБЫЧНЫЙ пользователь (дефолтные настройки)
  if HOME=/tmp/hc aws $EP s3 cp "s3://$S3_BUCKET/$PROBE/sha.bin" /tmp/sha-naive.out >/dev/null 2>&1; then
    ok "SHA256-объект скачивается и с ДЕФОЛТНЫМИ настройками -> включать сквозную сумму безопасно"
  elif aws $EP s3 cp "s3://$S3_BUCKET/$PROBE/sha.bin" /tmp/sha-ours.out >/dev/null 2>&1; then
    log "  INFO | SHA256-объект скачивается только с when_required -> включать можно, но восстанавливать нужно с этой настройкой"
  else
    bad "SHA256-объект НЕ скачивается вообще -> НЕ включайте S3_CHECKSUM_ALGORITHM"
  fi
else
  log "  INFO | провайдер не принимает --checksum-algorithm SHA256 (оставляйте S3_CHECKSUM_ALGORITHM пустой)"
fi

# --- 2) метаданные объекта (как их видит наш verify_remote_object) ---
log "метаданные $PROBE/ours.bin:"
aws $EP s3api head-object --bucket "$S3_BUCKET" --key "$PROBE/ours.bin" --output json 2>/dev/null \
  | grep -iE 'ContentLength|ETag|Checksum' | sed 's/^/        /'

# --- 3) реальный прогон backup.sh против локального стенда ---
log "прогон backup.sh (PGHOST=$PGHOST) в префикс $S3_PREFIX ..."
PGHOST="$PGHOST" S3_PREFIX="$S3_PREFIX" RUN_ONCE=1 INTERVAL=1 KEEP="${KEEP:-3}" \
  VERIFY=1 VERIFY_FULL=1 VERIFY_REMOTE=1 VERIFY_DOWNLOAD=0 RESTORE_TEST=0 DUMP_GLOBALS=1 \
  sh /usr/local/bin/backup.sh > /tmp/reals3-backup.log 2>&1
rc=$?
sed 's/^/        /' /tmp/reals3-backup.log
if [ "$rc" = "0" ] && grep -q 'размер в S3 сверен' /tmp/reals3-backup.log; then
  ok "backup.sh: выгрузка и проверка объекта без скачивания прошли"
else
  bad "backup.sh завершился с кодом $rc или объект не сверен"
fi

# --- 4) list/delete (основа retention) ---
key="$S3_PREFIX/app/$(date -u +%Y%m%dT%H%M%SZ)_retention_test.dump.zst"
echo probe > /tmp/rk.txt
if aws $EP s3 cp /tmp/rk.txt "s3://$S3_BUCKET/$key" $CH >/dev/null 2>&1 || aws $EP s3 cp /tmp/rk.txt "s3://$S3_BUCKET/$key" >/dev/null 2>&1; then
  n="$(aws $EP s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$S3_PREFIX/app/" \
        --query 'sort_by(Contents,&Key)[].Key' --output text 2>/dev/null | tr '\t' '\n' | grep -c .)"
  ok "list-objects-v2 работает (в $S3_PREFIX/app/ объектов: $n)"
  if aws $EP --only-show-errors s3 rm "s3://$S3_BUCKET/$key" >/dev/null 2>&1; then
    ok "delete-object работает (retention сможет удалять старое)"
  else
    bad "delete-object НЕ работает — retention не сможет чистить"
  fi
else
  bad "не удалось загрузить тестовый объект в $S3_PREFIX/app/"
fi

# --- уборка только своих probe-объектов ---
for k in naive.bin ours.bin sha.bin; do
  aws $EP --only-show-errors s3 rm "s3://$S3_BUCKET/$PROBE/$k" >/dev/null 2>&1 || true
done
rm -f /tmp/probe.txt /tmp/probe-big.bin /tmp/*.out /tmp/rk.txt
log "свои probe-объекты из $PROBE удалены; оставлены бэкапы в $S3_PREFIX/ для ручной проверки"

echo
if [ "$FAILED" = "0" ]; then log "ИТОГ: реальный S3 пригоден — выгрузка, проверка без скачивания и восстановление работают"
else log "ИТОГ: есть проблемы, см. FAIL выше"; fi
exit "$FAILED"
