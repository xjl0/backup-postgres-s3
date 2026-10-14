#!/bin/sh
# Логический бэкап всех баз PostgreSQL -> zstd -> S3 (+ проверка целостности).
# Для docker-compose / docker swarm. Цикл раз в INTERVAL секунд.
#
# Версии: клиент pg_dump должен быть >= сервера. Один образ с клиентом PG18 снимает серверы
# 15/16/17/18 (pg_dump умеет дампить серверы СТАРЕЕ себя, но НЕ новее). Скрипт сам
# определяет версию сервера и подстраивается (cross-version флаги). Не-суперюзер поддерживается.
#
# Переменные можно задавать двумя способами (можно смешивать):
#   1) обычным окружением — docker compose: environment:, docker run -e, swarm --env;
#   2) файлом KEY=VALUE — путь в ENV_FILE (по умолчанию /etc/pg-backup/env).
# Переменная, уже заданная в окружении, имеет приоритет над файлом (как environment: поверх env_file:
# в compose). Это же позволяет в swarm, где stack-файл игнорирует env_file:, класть файл томом.
set -u

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# --- env-файл (опционально): KEY=VALUE, окружение приоритетнее ---
ENV_FILE_DEFAULT=/etc/pg-backup/env
ENV_FILE="${ENV_FILE:-$ENV_FILE_DEFAULT}"

env_is_set() { eval "[ \"\${$1+x}\" = x ]"; }   # ключ уже есть в окружении?

load_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    [ "$ENV_FILE" != "$ENV_FILE_DEFAULT" ] && log "WARN: ENV_FILE=$ENV_FILE не найден — читаю только окружение"
    return 0
  fi
  log "читаю переменные из $ENV_FILE (заданные в окружении имеют приоритет)"
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(printf '%s' "$line" | tr -d '\r')"      # терпим CRLF
    case "$line" in ''|'#'*) continue ;; esac       # пустые строки и комментарии
    case "$line" in 'export '*) line="${line#export }" ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in *[!A-Za-z0-9_]*|[0-9]*) log "WARN: пропускаю строку в $ENV_FILE: $line"; continue ;; esac
    [ -z "$key" ] && continue
    case "$val" in                                 # снимаем обрамляющие кавычки
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    env_is_set "$key" && continue                   # окружение важнее файла
    export "$key=$val"
  done < "$ENV_FILE"
}

load_env_file

# --- подключение к БД ---
PGHOST="${PGHOST:?нужен PGHOST}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:?нужен PGUSER}"
export PGPASSWORD="${PGPASSWORD:?нужен PGPASSWORD}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
ADMIN_DB="${ADMIN_DB:-postgres}"          # служебная БД для перечисления/версии (fallback: template1)

# --- S3 ---
S3_BUCKET="${S3_BUCKET:?нужен S3_BUCKET}"
S3_PREFIX="${S3_PREFIX:-backup}"
S3_ENDPOINT="${S3_ENDPOINT:-}"            # пусто = AWS S3; иначе S3-совместимый endpoint
S3_CHECKSUM_ALGORITHM="${S3_CHECKSUM_ALGORITHM:-SHA256}"  # SHA256/CRC32/CRC32C/SHA1 или "" (выкл).
                                                          # S3 проверяет байты при приёмке → сквозная
                                                          # гарантия целостности без скачивания.
                                                          # ЕСЛИ у вашего хранилища составная сумма
                                                          # multipart некорректна, aws-cli может не
                                                          # скачать объект: проверьте `make test-real-s3`
                                                          # и при проблемах поставьте S3_CHECKSUM_ALGORITHM="".
KEEP="${KEEP:-7}"
ZSTD_LEVEL="${ZSTD_LEVEL:-9}"
INTERVAL="${INTERVAL:-86400}"
EXCLUDE_DBS="${EXCLUDE_DBS:-postgres}"
DUMP_GLOBALS="${DUMP_GLOBALS:-1}"

# --- проверки ---
VERIFY="${VERIFY:-1}"            # zstd -t + pg_restore -l (оглавление) перед загрузкой
VERIFY_FULL="${VERIFY_FULL:-1}"  # + полное чтение архива (pg_restore -f /dev/null) — ловит обрыв данных.
                                 # Локально, без исходящего трафика; VERIFY_FULL=0 — быстрее, но слабее.
VERIFY_REMOTE="${VERIFY_REMOTE:-1}"      # проверка объекта в S3 без скачивания (размер + контрольная сумма)
VERIFY_DOWNLOAD="${VERIFY_DOWNLOAD:-0}"  # 1 = дополнительно СКАЧАТЬ объект и проверить целиком (это трафик!)
RESTORE_TEST="${RESTORE_TEST:-0}"

# --- доп. флаги pg_dump (напр. --enable-row-security, --no-large-objects) ---
EXTRA_PGDUMP_ARGS="${EXTRA_PGDUMP_ARGS:-}"

# --- режим запуска ---
RUN_ONCE="${RUN_ONCE:-0}"        # 1 = один прогон и выход (для тестов/CI); код возврата = failed
WAIT_DB_TIMEOUT="${WAIT_DB_TIMEOUT:-0}"   # сек ожидания БД при старте; 0 = ждать бесконечно

# --- уведомления об ошибках ---
NOTIFY_ON="${NOTIFY_ON:-failure}"        # failure (только ошибки) | always (каждый прогон)
NOTIFY_URL="${NOTIFY_URL:-}"             # webhook: POST {"text": "..."} (Slack/Discord/Mattermost)
NOTIFY_CMD="${NOTIFY_CMD:-}"             # произвольная команда; получает STATUS и MESSAGE в окружении
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"   # dead man's switch (healthchecks.io и подобные): GET при успехе
NOTIFY_TIMEOUT="${NOTIFY_TIMEOUT:-15}"   # сек на запрос уведомления

WORKDIR="${WORKDIR:-/tmp/pg-backup}"
EP=""; [ -n "$S3_ENDPOINT" ] && EP="--endpoint-url $S3_ENDPOINT"
CK=""; [ -n "$S3_CHECKSUM_ALGORITHM" ] && CK="--checksum-algorithm $S3_CHECKSUM_ALGORITHM"

# пауза до следующего прогона; при RUN_ONCE=1 — выход с кодом $1 (0 = успех, 1 = были ошибки)
next_run() {
  if [ "$RUN_ONCE" = "1" ]; then log "RUN_ONCE=1 — выход (failed=$1)"; exit "$1"; fi
  sleep "$INTERVAL"
}

# --- уведомления ---
json_escape() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

notify() {  # $1 = ok|fail, $2 = текст
  status="$1"; msg="$2"
  [ "$NOTIFY_ON" = "always" ] || [ "$status" = "fail" ] || return 0
  [ -n "$NOTIFY_URL" ] || [ -n "$NOTIFY_CMD" ] || return 0
  full="pg-s3-backup [$status] run=${TS:-startup} host=${PGHOST} bucket=${S3_BUCKET} prefix=${S3_PREFIX}: $msg"
  log "уведомление: $full"
  if [ -n "$NOTIFY_CMD" ]; then
    STATUS="$status" MESSAGE="$full" sh -c "$NOTIFY_CMD" >/dev/null 2>&1 || log "WARN: NOTIFY_CMD вернул ошибку"
  fi
  if [ -n "$NOTIFY_URL" ]; then
    body="{\"text\":\"$(json_escape "$full")\"}"
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m "$NOTIFY_TIMEOUT" -X POST -H 'Content-Type: application/json' --data "$body" "$NOTIFY_URL" >/dev/null 2>&1 \
        || log "WARN: не удалось отправить на NOTIFY_URL"
    else
      wget -q -T "$NOTIFY_TIMEOUT" --header 'Content-Type: application/json' --post-data "$body" -O /dev/null "$NOTIFY_URL" 2>/dev/null \
        || log "WARN: не удалось отправить на NOTIFY_URL (wget)"
    fi
  fi
}

ping_healthcheck() {  # dead man's switch: пингуем только при успехе; «нет пинга» = алерт на стороне сервиса
  [ -n "$HEALTHCHECK_URL" ] || return 0
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m "$NOTIFY_TIMEOUT" "$HEALTHCHECK_URL" >/dev/null 2>&1 || log "WARN: healthcheck ping не удался"
  else
    wget -q -T "$NOTIFY_TIMEOUT" -O /dev/null "$HEALTHCHECK_URL" 2>/dev/null || log "WARN: healthcheck ping не удался"
  fi
}

# --- инструменты ---
command -v aws  >/dev/null 2>&1 || apk add --no-cache aws-cli >/dev/null 2>&1
command -v zstd >/dev/null 2>&1 || apk add --no-cache zstd    >/dev/null 2>&1
command -v aws  >/dev/null 2>&1 || { log "FATAL: нет aws-cli"; exit 1; }
command -v zstd >/dev/null 2>&1 || { log "FATAL: нет zstd";    exit 1; }
aws configure set default.s3.addressing_style path >/dev/null 2>&1 || true
# aws-cli >= 2.23 по умолчанию сам добавляет суммы (CRC64) на загрузке. У части S3-совместимых
# хранилищ такая сумма для multipart некорректна, и тогда aws-cli ОТКАЗЫВАЕТСЯ скачивать объект —
# то есть ломается восстановление. Поэтому не навязываем суммы, если их не просят явно.
# (Явная сквозная сумма — S3_CHECKSUM_ALGORITHM=... — для AWS S3, где она реализована корректно.)
aws configure set default.request_checksum_calculation when_required >/dev/null 2>&1 || true
aws configure set default.response_checksum_validation when_required >/dev/null 2>&1 || true

mkdir -p "$WORKDIR"

# --- эффективная конфигурация (пароли не логируем) ---
log "--- конфигурация ---"
log "  БД:        PGHOST=$PGHOST PGPORT=$PGPORT PGUSER=$PGUSER ADMIN_DB=$ADMIN_DB (PGPASSWORD=***)"
log "  S3:        bucket=$S3_BUCKET prefix=$S3_PREFIX endpoint=${S3_ENDPOINT:-<AWS>} region=${AWS_DEFAULT_REGION:-<default>}"
log "  режим:     KEEP=$KEEP ZSTD_LEVEL=$ZSTD_LEVEL INTERVAL=${INTERVAL}s RUN_ONCE=$RUN_ONCE EXCLUDE_DBS='$EXCLUDE_DBS' DUMP_GLOBALS=$DUMP_GLOBALS"
log "  проверки:  VERIFY=$VERIFY VERIFY_FULL=$VERIFY_FULL VERIFY_REMOTE=$VERIFY_REMOTE VERIFY_DOWNLOAD=$VERIFY_DOWNLOAD RESTORE_TEST=$RESTORE_TEST S3_CHECKSUM='$S3_CHECKSUM_ALGORITHM'"
log "  алерты:    NOTIFY_ON=$NOTIFY_ON NOTIFY_URL=${NOTIFY_URL:-нет} NOTIFY_CMD=${NOTIFY_CMD:+задан}${NOTIFY_CMD:-нет} HEALTHCHECK_URL=${HEALTHCHECK_URL:-нет}"
log "  прочее:    WORKDIR=$WORKDIR WAIT_DB_TIMEOUT=${WAIT_DB_TIMEOUT}s EXTRA_PGDUMP_ARGS='$EXTRA_PGDUMP_ARGS' ENV_FILE=$ENV_FILE"

# версия клиента (одна на весь прогон)
CLIENT_MAJOR="$(pg_dump --version | sed -n 's/.* \([0-9][0-9]*\)\..*/\1/p')"
[ -z "$CLIENT_MAJOR" ] && CLIENT_MAJOR=0

psqlA() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$ADMIN_DB" -At "$@"; }

retain() {
  prefix="$1"
  keys="$(aws $EP s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$prefix" \
            --query 'sort_by(Contents,&Key)[].Key' --output text 2>/dev/null)"
  [ -z "$keys" ] && { log "  retention $prefix: объектов нет"; return 0; }
  count="$(printf '%s\n' "$keys" | tr '\t' '\n' | grep -c .)"
  if [ "$count" -le "$KEEP" ]; then
    log "  retention $prefix: $count объектов, удалять нечего (KEEP=$KEEP)"
    return 0
  fi
  drop=$((count - KEEP))
  log "  retention $prefix: $count объектов, удаляю $drop старейших (KEEP=$KEEP)"
  printf '%s\n' "$keys" | tr '\t' '\n' | grep . | head -n "$drop" | while IFS= read -r k; do
    [ -n "$k" ] && aws $EP --only-show-errors s3 rm "s3://$S3_BUCKET/$k" >/dev/null 2>&1 \
      && log "    удалён $k"
  done
}

verify_archive() {
  f="$1"
  log "  verify: zstd -t $f"
  zstd -t "$f" >/dev/null 2>&1 || { log "  verify: zstd -t FAILED"; return 1; }
  log "  verify: pg_restore -l (оглавление архива)"
  unzstd -c "$f" | pg_restore -l >/dev/null 2>&1 || { log "  verify: pg_restore -l FAILED"; return 1; }
  if [ "${VERIFY_FULL:-0}" = "1" ]; then
    # полное чтение архива (читает все данные, но SQL никуда не исполняется) — БД/права не нужны.
    # Локально, без обращения к S3 — это и есть проверка «дамп не сломан» до загрузки.
    log "  verify: полное чтение архива (pg_restore -f /dev/null)"
    unzstd -c "$f" | pg_restore -f /dev/null >/dev/null 2>&1 || { log "  verify: full read FAILED"; return 1; }
  fi
  log "  verify: OK"
  return 0
}

# Проверка объекта в S3 БЕЗ скачивания данных: размер + контрольная сумма.
#  - размер (ContentLength) ловит недолитую/отсутствующую загрузку;
#  - ChecksumSHA256 (если провайдер отдал и объект не multipart) сверяем точно;
#  - для multipart S3 отдаёт composite-сумму (…-N) — её локально не собрать, но S3 уже
#    проверил байты на приёмке (мы грузим с --checksum-algorithm), поэтому просто фиксируем;
#  - ETag == MD5 только для single-part без SSE-KMS, поэтому MD5 — информационно.
# Ноль исходящего трафика.
verify_remote_object() {
  key="$1"; f="$2"
  remote_sz="$(aws $EP s3api head-object --bucket "$S3_BUCKET" --key "$key" --query ContentLength --output text 2>/dev/null)"
  local_sz="$(wc -c <"$f")"
  if [ "${remote_sz:-}" != "$local_sz" ]; then
    log "  ERROR: размер в S3 (${remote_sz:-нет}) != локального ($local_sz)"; return 1
  fi
  log "  размер в S3 сверен: $remote_sz B (без скачивания)"

  etag_raw="$(aws $EP s3api head-object --bucket "$S3_BUCKET" --key "$key" --query ETag --output text 2>/dev/null)"
  csha="$(aws $EP s3api head-object --bucket "$S3_BUCKET" --key "$key" --checksum-mode ENABLED \
            --query ChecksumSHA256 --output text 2>/dev/null || true)"

  case "${csha:-}" in
    ''|None) : ;;                                   # провайдер не отдал — идём к ETag
    *-*) log "  SHA256 (multipart composite $csha): проверен S3 при загрузке"; ;;
    *)
      local_hex="$(sha256sum "$f" | cut -d' ' -f1)"
      remote_hex="$(printf '%s' "$csha" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')"
      if [ -n "$remote_hex" ] && [ "$local_hex" = "$remote_hex" ]; then
        log "  SHA256 сверен с S3 (без скачивания)"
        return 0
      fi
      log "  ERROR: SHA256 в S3 не совпал с локальным"; return 1 ;;
  esac

  et="$(printf '%s' "$etag_raw" | tr -d '"')"
  case "$et" in
    ''|None) log "  WARN: S3 не вернул ETag для проверки" ;;
    *-*) log "  ETag multipart ($et): побайтовая сверка недоступна, подтверждён размер" ;;
    *)   lmd5="$(md5sum "$f" | cut -d' ' -f1)"
         if [ "$lmd5" = "$et" ]; then log "  MD5 (ETag) сверен с S3 (без скачивания)"
         else log "  WARN: ETag ($et) != MD5 ($lmd5) — норма для SSE-KMS/некоторых провайдеров"; fi ;;
  esac
  return 0
}

# --- ждём БД, определяем версию сервера и права ---
log "ждём БД $PGHOST:$PGPORT (шаг 3s, таймаут ${WAIT_DB_TIMEOUT}s, 0=без лимита) ..."
waited=0
while ! pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -q; do
  if [ "$WAIT_DB_TIMEOUT" -gt 0 ] && [ "$waited" -ge "$WAIT_DB_TIMEOUT" ]; then
    log "FATAL: БД $PGHOST:$PGPORT не поднялась за ${WAIT_DB_TIMEOUT}s"
    notify fail "БД $PGHOST:$PGPORT не поднялась за ${WAIT_DB_TIMEOUT}s"
    exit 1
  fi
  sleep 3; waited=$((waited + 3))
done
log "БД готова (ждали ${waited}s)"

# служебная БД для перечисления/версии: postgres, иначе template1
if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$ADMIN_DB" -Atqc 'select 1' >/dev/null 2>&1; then
  if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d template1 -Atqc 'select 1' >/dev/null 2>&1; then
    log "ADMIN_DB=$ADMIN_DB недоступна — использую template1"
    ADMIN_DB=template1
  else
    log "WARN: ADMIN_DB=$ADMIN_DB и template1 недоступны для $PGUSER"
  fi
fi

detect_env() {
  SERVER_VER_NUM="$(psqlA -c 'show server_version_num' 2>/dev/null || echo 0)"
  [ -z "$SERVER_VER_NUM" ] && SERVER_VER_NUM=0
  SERVER_MAJOR=$((SERVER_VER_NUM / 10000))
  # NB: boolean::text даёт 'true'/'false', а psql показывает 't'/'f' — используем 1/0, чтобы не путаться
  ROLS="$(psqlA -c "select (rolsuper)::int || '/' || (rolbypassrls)::int || '/' || (rolcreatedb)::int from pg_roles where rolname = current_user" 2>/dev/null || echo '0/0/0')"
  ROLESUPER="$(printf '%s' "$ROLS" | cut -d/ -f1)"
  BYPASSRLS="$(printf '%s' "$ROLS" | cut -d/ -f2)"
  CREATEDB="$(printf '%s' "$ROLS" | cut -d/ -f3)"
  # членство в pg_read_all_data (PG14+) — через pg_auth_members (роль может быть и недоступна на старых версиях)
  READALL="$(psqlA -c "select case when exists(select 1 from pg_auth_members m join pg_roles g on g.oid=m.roleid join pg_roles r on r.oid=m.member where g.rolname='pg_read_all_data' and r.rolname=current_user) then 1 else 0 end" 2>/dev/null || echo 0)"
}

detect_env
log "сервер PostgreSQL: ${SERVER_MAJOR} (server_version_num=${SERVER_VER_NUM}); клиент pg_dump: ${CLIENT_MAJOR}"
if [ "$SERVER_MAJOR" -gt "$CLIENT_MAJOR" ]; then
  log "FATAL: сервер (${SERVER_MAJOR}) новее клиента pg_dump (${CLIENT_MAJOR}). Соберите образ с PG_MAJOR>=${SERVER_MAJOR}."
fi
if [ "$ROLESUPER" = "1" ]; then log "права роли: SUPERUSER"
elif [ "$READALL"  = "1" ]; then log "права роли: pg_read_all_data"
else log "WARN: роль без SUPERUSER и без pg_read_all_data — часть объектов может не выгрузиться (permission denied)."; fi
if [ "$RESTORE_TEST" = "1" ] && [ "$ROLESUPER" != "1" ] && [ "$CREATEDB" != "1" ]; then
  log "WARN: RESTORE_TEST=1, но роль без CREATEDB — тест восстановления будет пропущен (выдайте CREATEDB или уберите RESTORE_TEST)."
fi

while true; do
  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  log "================ прогон $TS ================"

  detect_env
  if [ "$SERVER_MAJOR" -gt "$CLIENT_MAJOR" ]; then
    log "ERROR: сервер (${SERVER_MAJOR}) > клиента (${CLIENT_MAJOR}) — пропускаю прогон. Нужен образ с PG_MAJOR>=${SERVER_MAJOR}."
    notify fail "сервер PostgreSQL ${SERVER_MAJOR} новее клиента pg_dump ${CLIENT_MAJOR} — нужен образ с PG_MAJOR>=${SERVER_MAJOR}"
    next_run 1
  fi
  # cross-version (клиент и сервер разных мажоров) — рекомендуют quote-all-identifiers
  CROSS=""; [ "$SERVER_MAJOR" != "$CLIENT_MAJOR" ] && CROSS="--quote-all-identifiers"

  DBS="$(psqlA -c 'select datname from pg_database where datistemplate=false and datallowconn order by datname')" \
     || { log "ERROR: не перечислить базы; повтор через ${INTERVAL}s"; next_run 1; }
  log "найдено баз: $(printf '%s\n' "$DBS" | grep -c .)  (сервер ${SERVER_MAJOR}, client ${CLIENT_MAJOR}${CROSS:+, cross-version})"

  FAILED=0
  if [ "$DUMP_GLOBALS" = "1" ]; then
    log "globals (роли/привилегии, без паролей): pg_dumpall --globals-only --no-role-passwords"
    # NB: статус конвейера в POSIX sh = статус последней команды (zstd), поэтому код возврата
    # pg_dumpall пишем в файл — иначе оборванный globals-дамп можно принять за валидный.
    gstat_f="$WORKDIR/.globals.rc"; rm -f "$gstat_f"; gz=0
    { pg_dumpall -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --globals-only --no-role-passwords; echo $? > "$gstat_f"; } 2>/dev/null \
      | zstd -q -6 -c > "$WORKDIR/_globals.sql.zst" || gz=$?
    gstat="$(cat "$gstat_f" 2>/dev/null || echo 1)"; rm -f "$gstat_f"
    if [ "$gstat" = "0" ] && [ "$gz" = "0" ]; then
      log "  размер globals: $(wc -c <"$WORKDIR/_globals.sql.zst") B"
      aws $EP --only-show-errors s3 cp "$WORKDIR/_globals.sql.zst" \
          "s3://$S3_BUCKET/$S3_PREFIX/_globals/$TS.sql.zst" $CK \
        && { log "upload OK: $S3_PREFIX/_globals/$TS.sql.zst"; retain "$S3_PREFIX/_globals/"; } \
        || { log "ERROR: globals upload failed"; FAILED=1; }
    else
      log "ERROR: globals не выгружены (pg_dumpall=$gstat, zstd=$gz)"; FAILED=1
    fi
  fi

  run_t0="$(date +%s)"
  for db in $DBS; do
    case ",$EXCLUDE_DBS," in *",$db,"*) log "skip: $db (в EXCLUDE_DBS)"; continue;; esac
    log "-----------------------------------------------"
    log "БАЗА: $db"
    db_t0="$(date +%s)"

    # предпроверка CONNECT (чтобы не городить ошибки)
    if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$db" -Atqc 'select 1' >/dev/null 2>&1; then
      log "SKIP $db: нет CONNECT у $PGUSER"; continue
    fi

    # RLS без обхода -> pg_dump упадёт; предупредим заранее
    if [ "$ROLESUPER" != "1" ] && [ "$BYPASSRLS" != "1" ]; then
      rls="$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$db" -Atc 'select count(*) from pg_class where relrowsecurity' 2>/dev/null || echo 0)"
      [ "${rls:-0}" != "0" ] && log "  WARN: в $db есть RLS-таблицы ($rls) — нужен BYPASSRLS у роли или EXTRA_PGDUMP_ARGS='--enable-row-security'"
    fi

    log "dump: $db (сервер ${SERVER_MAJOR}, клиент ${CLIENT_MAJOR}${CROSS:+, cross-version})"
    log "  команда: pg_dump -Fc -Z0 $CROSS $EXTRA_PGDUMP_ARGS -d '$db' | zstd -$ZSTD_LEVEL"
    out="$WORKDIR/$db.dump.zst"
    dstat_f="$WORKDIR/.${db}.rc"; rm -f "$dstat_f"
    dump_t0="$(date +%s)"
    # NB: в POSIX sh статус конвейера = статус последней команды (zstd), поэтому падение
    # pg_dump отдельно пишем в файл: иначе оборванный дамп (валидное оглавление + часть
    # данных) может пройти verify и уехать в S3 как «успешный».
    zstat=0
    { pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -Fc -Z0 $CROSS $EXTRA_PGDUMP_ARGS -d "$db"; echo $? > "$dstat_f"; } \
        | zstd -q -"$ZSTD_LEVEL" -c > "$out" || zstat=$?
    dstat="$(cat "$dstat_f" 2>/dev/null || echo 1)"; rm -f "$dstat_f"
    if [ "$dstat" != "0" ] || [ "$zstat" != "0" ] || [ ! -s "$out" ]; then
      log "ERROR: дамп не удался: pg_dump=$dstat, zstd=$zstat, размер $(wc -c <"$out" 2>/dev/null || echo 0) B — в S3 не загружаю"
      FAILED=1; rm -f "$out"; continue
    fi
    log "  размер дампа: $(wc -c <"$out") B (zstd -$ZSTD_LEVEL, за $(( $(date +%s) - dump_t0 ))s)"

    if [ "$VERIFY" = "1" ]; then
      log "  проверка целостности: $db"
      if ! verify_archive "$out"; then
        log "ERROR: проверка целостности не пройдена: $db"; FAILED=1; rm -f "$out"; continue
      fi
    else
      log "  проверка целостности пропущена (VERIFY=0)"
    fi

    if [ "$RESTORE_TEST" = "1" ] && [ "$db" != "postgres" ] \
       && { [ "$ROLESUPER" = "1" ] || [ "$CREATEDB" = "1" ]; }; then
      scratch="restore_test_$(date -u +%s)_$$"
      errlog="$WORKDIR/restore_$db.err"
      log "  restore-test: создаю $scratch и восстанавливаю $db"
      if createdb -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" "$scratch" 2>/dev/null \
         && unzstd -c "$out" | pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$scratch" \
              --no-owner --no-privileges 2>"$errlog"; then
        log "  restore-test OK: $db -> $scratch"
      else
        # кросс-версия: клиент новее сервера может слать SET для GUC, которых нет в старом сервере
        # (напр. transaction_timeout в PG17+ при restore в PG15/16) — это безобидно, не считаем за провал
        errors="$(grep -c 'pg_restore: error' "$errlog" 2>/dev/null || echo 0)"
        nonbenign="$(grep 'pg_restore: error' "$errlog" 2>/dev/null | grep -vc 'unrecognized configuration parameter' || true)"
        if [ "${errors:-0}" -gt 0 ] && [ "${nonbenign:-1}" = "0" ]; then
          log "  restore-test OK (cross-version: проигнорированы несовместимые SET, всего предупреждений ${errors})"
        else
          log "ERROR: restore-test FAILED: $db"
          [ -f "$errlog" ] && sed 's/^/    /' "$errlog"
          FAILED=1
        fi
      fi
      dropdb -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --if-exists "$scratch" 2>/dev/null || true
      rm -f "$errlog"
    elif [ "$RESTORE_TEST" = "1" ]; then
      log "  restore-test пропущен: нет CREATEDB/SUPERUSER или база postgres"
    fi

    key="$S3_PREFIX/$db/$TS.dump.zst"
    log "  загрузка: $out -> s3://$S3_BUCKET/$key${S3_CHECKSUM_ALGORITHM:+ (сквозная сумма $S3_CHECKSUM_ALGORITHM)}"
    ck="$CK"
    up_ok=1
    if ! aws $EP --only-show-errors s3 cp "$out" "s3://$S3_BUCKET/$key" $ck 2>"$WORKDIR/.cp.err"; then
      if [ -n "$ck" ] && grep -qiE 'checksum|not implemented|InvalidRequest' "$WORKDIR/.cp.err"; then
        log "  WARN: провайдер не принял $S3_CHECKSUM_ALGORITHM — повтор без контрольной суммы"
        aws $EP --only-show-errors s3 cp "$out" "s3://$S3_BUCKET/$key" || up_ok=0
      else
        up_ok=0
      fi
    fi
    if [ "$up_ok" = "1" ]; then
      if [ "$VERIFY_REMOTE" = "1" ]; then
        verify_remote_object "$key" "$out" || FAILED=1
      else
        log "upload OK: $key ($(wc -c <"$out") B; VERIFY_REMOTE=0 — без проверки в S3)"
      fi
      if [ "$VERIFY_DOWNLOAD" = "1" ]; then
        log "  VERIFY_DOWNLOAD=1: скачиваю объект и проверяю полностью (это исходящий трафик!)"
        if aws $EP s3api get-object --bucket "$S3_BUCKET" --key "$key" "$WORKDIR/_dl.zst" >/dev/null 2>&1 \
           && verify_archive "$WORKDIR/_dl.zst"; then
          log "  скачанный из S3 объект цел"
        else
          log "  ERROR: скачанный из S3 объект повреждён"; FAILED=1
        fi
        rm -f "$WORKDIR/_dl.zst"
      fi
      retain "$S3_PREFIX/$db/"
    else
      log "ERROR: upload failed: $db"; FAILED=1
    fi
    rm -f "$out"
    log "  БАЗА $db: готово за $(( $(date +%s) - db_t0 ))s"
  done

  log "прогон завершён. failed=$FAILED, всего за $(( $(date +%s) - run_t0 ))s; следующий через ${INTERVAL}s"
  if [ "$FAILED" = "0" ]; then
    notify ok "прогон ${TS} успешен: баз обработано, ошибок нет"
    ping_healthcheck
  else
    notify fail "прогон ${TS} завершился с ошибками (failed=1) — смотрите логи"
  fi
  next_run "$FAILED"
done
