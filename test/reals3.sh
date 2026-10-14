#!/bin/sh
# Проверка РЕАЛЬНОГО S3 через rclone (подключение берётся из вашего rclone.conf).
# Команды — как в документации провайдера: rclone ls / rclone copy / rclone deletefile.
#
#   1) доступность бакета/префикса (rclone ls);
#   2) проба PROBE_MB: загрузка, проверка размера (rclone ls) и скачивание с побайтовым сравнением;
#   3) прогон backup.sh против локального PostgreSQL в отдельный префикс (как в проде);
#   4) list/delete — основа retention.
set -u

: "${S3_BUCKET:?нужен S3_BUCKET}"
: "${S3_ACCESS_KEY_ID:?нужен S3_ACCESS_KEY_ID}"
: "${S3_SECRET_ACCESS_KEY:?нужен S3_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-/etc/rclone/rclone.conf}"
export RCLONE_CONFIG_S3_TYPE=s3
export RCLONE_CONFIG_S3_PROVIDER="${RCLONE_CONFIG_S3_PROVIDER:-Selectel}"
export RCLONE_CONFIG_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_S3_REGION="${S3_REGION:-us-east-1}"
[ -n "${S3_ENDPOINT:-}" ] && export RCLONE_CONFIG_S3_ENDPOINT="$S3_ENDPOINT"

S3_PREFIX="${S3_PREFIX:-test/reals3check}"
PROBE_MB="${PROBE_MB:-128}"
S3R="s3"
s3path() { printf '%s:%s/%s' "$S3R" "$S3_BUCKET" "$1"; }
RCLONE_OPTS="--s3-upload-concurrency 4 --stats=15s --stats-one-line"
FAILED=0
log() { echo "[reals3] $*"; }
ok()  { echo "  OK   | $*"; }
bad() { echo "  FAIL | $*"; FAILED=1; }

# защита: не работать в «боевом» префиксе, чтобы retention не удалил чужие бэкапы
case "$S3_PREFIX" in
  ''|test|backup|prod|production)
    log "ОТКАЗ: небезопасный S3_PREFIX='$S3_PREFIX' (нужен отдельный, напр. test/reals3check)"; exit 2 ;;
esac

log "bucket=$S3_BUCKET prefix=$S3_PREFIX provider=$RCLONE_CONFIG_S3_PROVIDER region=$S3_REGION endpoint=${S3_ENDPOINT:-<AWS>}"
log "rclone: $(rclone version | head -1)"

# --- 1) доступность ---
if rclone ls "$(s3path "$S3_PREFIX/")" >/dev/null 2>&1; then
  ok "S3 и бакет доступны (rclone ls)"
else
  bad "S3 недоступен / нет прав / нет бакета"; exit 1
fi

# --- 2) проба ---
PROBE="$S3_PREFIX/_probe"
head -c $((PROBE_MB * 1024 * 1024)) /dev/urandom > /tmp/probe.bin
l_sz="$(wc -c </tmp/probe.bin)"
log "проба: ${PROBE_MB} МБ"
s=$(date +%s)
if rclone $RCLONE_OPTS copy /tmp/probe.bin "$(s3path "$PROBE/")" 2>/tmp/e; then
  ok "загрузка ${PROBE_MB} МБ ($(($(date +%s)-s))s)"
  r_sz="$(rclone ls "$(s3path "$PROBE/")" 2>/dev/null | awk '$2=="probe.bin"{print $1; exit}')"
  [ "$r_sz" = "$l_sz" ] && ok "размер в S3 сверен: $r_sz B (без скачивания)" || bad "размер в S3 ($r_sz) != локального ($l_sz)"
  rm -rf /tmp/dl; mkdir -p /tmp/dl
  s=$(date +%s)
  if rclone $RCLONE_OPTS copy "$(s3path "$PROBE/")" /tmp/dl 2>/tmp/e; then
    if cmp -s /tmp/probe.bin /tmp/dl/probe.bin; then
      ok "скачивание и побайтовое сравнение ($(($(date +%s)-s))s) — восстановление работает"
    else
      bad "скачанный объект ОТЛИЧАЕТСЯ от исходного"
    fi
  else
    bad "не удалось скачать объект: $(tail -1 /tmp/e)"
  fi
else
  bad "загрузка пробы не удалась ($(($(date +%s)-s))s) :: $(tail -2 /tmp/e | tr '\n' ' ')"
fi

# --- 3) реальный прогон backup.sh ---
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

# --- 4) list/delete ---
kbase="$(date -u +%Y%m%dT%H%M%SZ)_retention_test.dump.zst"
key="$S3_PREFIX/app/$kbase"
rm -rf /tmp/rk; mkdir -p /tmp/rk; printf probe > "/tmp/rk/$kbase"
if rclone $RCLONE_OPTS copy /tmp/rk "$(s3path "$S3_PREFIX/app/")" >/dev/null 2>&1; then
  n="$(rclone ls "$(s3path "$S3_PREFIX/app/")" 2>/dev/null | grep -c . || true)"
  ok "list (rclone ls) работает (в $S3_PREFIX/app/ объектов: $n)"
  if rclone deletefile "$(s3path "$key")" >/dev/null 2>&1; then
    ok "delete (rclone deletefile) работает — retention сможет удалять старое"
  else
    bad "deletefile НЕ работает — retention не сможет чистить"
  fi
else
  bad "не удалось загрузить тестовый объект в $S3_PREFIX/app/"
fi

# --- уборка только своих probe-объектов ---
rclone deletefile "$(s3path "$PROBE/probe.bin")" >/dev/null 2>&1 || true
rm -rf /tmp/probe.bin /tmp/dl /tmp/rk /tmp/e
log "probe-объекты удалены; бэкапы в $S3_PREFIX/ оставлены для ручной проверки"

echo
if [ "$FAILED" = "0" ]; then log "ИТОГ: реальный S3 пригоден — выгрузка, проверка без скачивания и восстановление работают"
else log "ИТОГ: есть проблемы, см. FAIL выше"; fi
exit "$FAILED"
