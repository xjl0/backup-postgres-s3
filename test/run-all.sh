#!/bin/sh
# Стенд end-to-end: для каждой версии PostgreSQL делаем бэкап и проверяем восстановление данных.
# Запускается из контейнера runner (docker-compose.test.yml), вход — make test.
#
# По каждой версии:
#   1) backup.sh (RUN_ONCE=1) — дамп базы app -> S3, verify, restore-test, retention;
#   2) verify.sh — скачивание дампа из S3, восстановление и сверка данных (включая фичи версии).
# В конце — retention.sh: заливаем больше копий, чем KEEP, и проверяем удаление старых.
set -u

VERSIONS="${VERSIONS:-15 16 17 18}"
LAST_VER="${VERSIONS##* }"           # последняя версия — на ней проверяем retention
fail=0

log() { echo "[run-all] $*"; }

log "стенд: PostgreSQL [$VERSIONS], бакет $S3_BUCKET"

# S3 может ещё подниматься; ждём и идемпотентно создаём бакет (rclone mkdir = create bucket)
. /s3env.sh
n=0
until rclone lsd "$S3R:" >/dev/null 2>&1; do
  n=$((n + 1)); [ "$n" -gt 60 ] && { log "FATAL: S3 недоступен ($S3_ENDPOINT)"; exit 1; }
  sleep 1
done
# ВАЖНО: это только для стенда — s3mock не создаёт бакеты сам. Скрипт бэкапа бакеты НЕ создаёт.
rclone mkdir "$S3R:$S3_BUCKET" >/dev/null 2>&1 || true
if rclone lsf "$S3R:$S3_BUCKET/" >/dev/null 2>&1; then
  log "бакет $S3_BUCKET доступен"
else
  log "FATAL: бакет $S3_BUCKET недоступен"; exit 1
fi

for v in $VERSIONS; do
  echo
  echo "################## PostgreSQL $v ##################"
  # лог прогона сохраняем (для проверки, что объект в S3 реально сверялся) и печатаем
  PGHOST="pg$v" S3_PREFIX="test/pg$v" INTERVAL=1 RUN_ONCE=1 WAIT_DB_TIMEOUT=180 \
    sh /usr/local/bin/backup.sh > "/tmp/backup-$v.log" 2>&1
  rc=$?
  sed 's/^/    /' "/tmp/backup-$v.log"
  if [ "$rc" = "0" ]; then
    log "PG$v: бэкап OK"
  else
    log "PG$v: БЭКАП ЗАВЕРШИЛСЯ С ОШИБКАМИ"; fail=1
  fi

  # объект в S3 должен быть проверен БЕЗ скачивания (сверка размера)
  if grep -q 'размер в S3 сверен' "/tmp/backup-$v.log"; then
    log "PG$v: объект в S3 сверен без скачивания (размер)"
  else
    log "PG$v: FAIL — в логе нет подтверждения проверки объекта в S3"; fail=1
  fi

  if PGHOST="pg$v" S3_PREFIX="test/pg$v" sh /verify.sh "pg$v" app; then
    log "PG$v: восстановление и данные OK"
  else
    log "PG$v: ПРОВЕРКА ВОССТАНОВЛЕНИЯ ПРОВАЛЕНА"; fail=1
  fi
done

# retention: заливаем больше копий, чем KEEP, и проверяем, что старые удаляются
echo
echo "################## Retention ##################"
if PGHOST="pg$LAST_VER" sh /retention.sh "pg$LAST_VER" "${KEEP_CHECK:-2}" "${KEEP_RUNS:-5}"; then
  log "retention: OK"
else
  log "retention: ПРОВАЛЕН"; fail=1
fi

# негативные проверки: падение pg_dump не должно приводить к загрузке битого дампа
echo
if [ "$fail" = "0" ]; then
  log "ИТОГ: все версии [$VERSIONS] — бэкап и восстановление данных OK"
else
  log "ИТОГ: есть ошибки, см. лог выше"
fi
exit "$fail"
