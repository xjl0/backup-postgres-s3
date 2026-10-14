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

# --- S3 (rclone) ---
S3_BUCKET="${S3_BUCKET:?нужен S3_BUCKET}"
S3_PREFIX="${S3_PREFIX:-backup}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
KEEP="${KEEP:-7}"
ZSTD_LEVEL="${ZSTD_LEVEL:-9}"
INTERVAL="${INTERVAL:-86400}"
EXCLUDE_DBS="${EXCLUDE_DBS:-postgres}"
DUMP_GLOBALS="${DUMP_GLOBALS:-1}"

# --- проверки ---
VERIFY="${VERIFY:-1}"            # zstd -t + pg_restore -l (оглавление) перед загрузкой
VERIFY_FULL="${VERIFY_FULL:-1}"  # + полное чтение архива (pg_restore -f /dev/null) — ловит обрыв данных.
                                 # Локально, без исходящего трафика; VERIFY_FULL=0 — быстрее, но слабее.
VERIFY_REMOTE="${VERIFY_REMOTE:-1}"      # проверка объекта в S3 без скачивания (сверка размера)
VERIFY_DOWNLOAD="${VERIFY_DOWNLOAD:-0}"  # 1 = дополнительно СКАЧАТЬ объект и проверить целиком (это трафик!)
RESTORE_TEST="${RESTORE_TEST:-0}"

# --- доп. флаги pg_dump (напр. --enable-row-security, --no-large-objects) ---
EXTRA_PGDUMP_ARGS="${EXTRA_PGDUMP_ARGS:-}"

# --- режим запуска ---
RUN_ONCE="${RUN_ONCE:-0}"        # 1 = один прогон и выход (для тестов/CI); код возврата = failed
WAIT_DB_TIMEOUT="${WAIT_DB_TIMEOUT:-0}"   # сек ожидания БД при старте; 0 = ждать бесконечно

WORKDIR="${WORKDIR:-/tmp/pg-backup}"

# --- rclone: подключение из переменных окружения; потоки загрузки всегда 4, остальное по умолчанию ---
export RCLONE_CONFIG="${RCLONE_CONFIG:-/etc/rclone/rclone.conf}"   # пустая заглушка (создаётся в образе)
export RCLONE_CONFIG_S3_TYPE=s3
export RCLONE_CONFIG_S3_PROVIDER="${RCLONE_CONFIG_S3_PROVIDER:-Selectel}"
export RCLONE_CONFIG_S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:?нужен S3_ACCESS_KEY_ID}"
export RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:?нужен S3_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_S3_REGION="$S3_REGION"
[ -n "$S3_ENDPOINT" ] && export RCLONE_CONFIG_S3_ENDPOINT="$S3_ENDPOINT"
RCLONE_OPTS="--s3-upload-concurrency 4 --timeout 15m --retries 5 --low-level-retries 25 --stats=15s --stats-one-line -v"
S3R="s3"   # имя remote; должно совпадать с префиксом RCLONE_CONFIG_<NAME>_* выше
s3path() { printf '%s:%s/%s' "$S3R" "$S3_BUCKET" "$1"; }   # $1 = путь внутри бакета
# Бакет НЕ создаём: он уже есть, объекты пишутся в подпапки (префиксы).

# запуск rclone: вывод (прогресс/события) идёт в лог, код возврата — в RCLONE_RC.
# Сторожевой таймаут попытки: 15 минут минимум; для больших дампов растёт (~размер/300 КБ/с),
RCLONE_RC=0
RCLONE_EXTRA=""            # доп. флаги для одной конкретной попытки (см. ниже)
RCLONE_KBPS_FLOOR=300
rclone_run() {
  _rcf="$WORKDIR/.rclone.rc"; rm -f "$_rcf"
  _sz=0; [ -n "${RCLONE_CAP_SRC:-}" ] && [ -f "$RCLONE_CAP_SRC" ] && _sz="$(wc -c <"$RCLONE_CAP_SRC")"
  _cap=$(( _sz / 1024 / RCLONE_KBPS_FLOOR )); [ "$_cap" -lt 900 ] && _cap=900   # 900s = 15 мин
  { timeout "$_cap" rclone $RCLONE_OPTS $RCLONE_EXTRA "$@"; echo $? >"$_rcf"; } 2>&1 \
    | while IFS= read -r _ln; do [ -n "$_ln" ] && log "    rclone| $_ln"; done
  RCLONE_RC="$(cat "$_rcf" 2>/dev/null || echo 1)"
  RCLONE_EXTRA=""          # флаги действуют только на один вызов
  [ "$RCLONE_RC" = "124" ] && log "    rclone| передача прервана сторожем (медленнее ${RCLONE_KBPS_FLOOR} КБ/с) через ${_cap}s"
  rm -f "$_rcf"
}

# пауза до следующего прогона; при RUN_ONCE=1 — выход с кодом $1 (0 = успех, 1 = были ошибки)
next_run() {
  if [ "$RUN_ONCE" = "1" ]; then log "RUN_ONCE=1 — выход (failed=$1)"; exit "$1"; fi
  sleep "$INTERVAL"
}

# --- инструменты ---
command -v rclone >/dev/null 2>&1 || apk add --no-cache rclone >/dev/null 2>&1
command -v zstd   >/dev/null 2>&1 || apk add --no-cache zstd   >/dev/null 2>&1
command -v rclone >/dev/null 2>&1 || { log "FATAL: нет rclone"; exit 1; }
command -v zstd   >/dev/null 2>&1 || { log "FATAL: нет zstd";   exit 1; }

mkdir -p "$WORKDIR"

# --- эффективная конфигурация (пароли не логируем) ---
log "--- конфигурация ---"
log "  БД:        PGHOST=$PGHOST PGPORT=$PGPORT PGUSER=$PGUSER ADMIN_DB=$ADMIN_DB (PGPASSWORD=***)"
log "  S3:        bucket=$S3_BUCKET prefix=$S3_PREFIX provider=$RCLONE_CONFIG_S3_PROVIDER region=$S3_REGION endpoint=${S3_ENDPOINT:-<AWS>}"
log "  режим:     KEEP=$KEEP ZSTD_LEVEL=$ZSTD_LEVEL INTERVAL=${INTERVAL}s RUN_ONCE=$RUN_ONCE EXCLUDE_DBS='$EXCLUDE_DBS' DUMP_GLOBALS=$DUMP_GLOBALS"
log "  проверки:  VERIFY=$VERIFY VERIFY_FULL=$VERIFY_FULL VERIFY_REMOTE=$VERIFY_REMOTE VERIFY_DOWNLOAD=$VERIFY_DOWNLOAD RESTORE_TEST=$RESTORE_TEST"
log "  прочее:    WORKDIR=$WORKDIR WAIT_DB_TIMEOUT=${WAIT_DB_TIMEOUT}s EXTRA_PGDUMP_ARGS='$EXTRA_PGDUMP_ARGS' ENV_FILE=$ENV_FILE"

# версия клиента (одна на весь прогон)
CLIENT_MAJOR="$(pg_dump --version | sed -n 's/.* \([0-9][0-9]*\)\..*/\1/p')"
[ -z "$CLIENT_MAJOR" ] && CLIENT_MAJOR=0

psqlA() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$ADMIN_DB" -At "$@"; }

retain() {
  prefix="$1"     # напр. "zooclub/app/" — путь внутри бакета
  keys="$(rclone ls "$(s3path "$prefix")" 2>/dev/null | awk '{print $2}' | grep . | sort)"
  [ -z "$keys" ] && { log "  retention $prefix: объектов нет"; return 0; }
  count="$(printf '%s\n' "$keys" | grep -c .)"
  if [ "$count" -le "$KEEP" ]; then
    log "  retention $prefix: $count объектов, удалять нечего (KEEP=$KEEP)"
    return 0
  fi
  drop=$((count - KEEP))
  log "  retention $prefix: $count объектов, удаляю $drop старейших (KEEP=$KEEP)"
  printf '%s\n' "$keys" | head -n "$drop" | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rclone deletefile "$(s3path "$prefix$rel")" >/dev/null 2>&1 && log "    удалён $prefix$rel"
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

# Проверка объекта в S3 БЕЗ скачивания: сверяем размер по `rclone ls`.
# (MD5/ETag у multipart-объектов не равен MD5 файла, поэтому полагаемся на размер + локальную
#  проверку архива до загрузки; VERIFY_DOWNLOAD=1 — опционально скачать и проверить целиком.)
verify_remote_object() {
  key="$1"; f="$2"
  dir="${key%/*}/"; base="${key##*/}"
  local_sz="$(wc -c <"$f")"

  # 1) размер
  remote_sz="$(rclone ls "$(s3path "$dir")" 2>/dev/null | awk -v b="$base" '$2==b {print $1; exit}')"
  if [ "${remote_sz:-}" != "$local_sz" ]; then
    log "  ERROR: размер в S3 (${remote_sz:-нет}) != локального ($local_sz)"; return 1
  fi
  log "  размер в S3 сверен: $remote_sz B (без скачивания)"

  # 2) MD5. В S3 ETag == MD5 только для объектов, загруженных одним запросом (не multipart).
  # rclone грузит одним запросом всё, что меньше ~200 МиБ, поэтому сумму сверяем только для таких.
  if [ "$local_sz" -lt 209715200 ]; then
    remote_md5="$(rclone md5sum "$(s3path "$key")" 2>/dev/null | awk '{print $1}')"
    if [ -n "$remote_md5" ]; then
      local_md5="$(md5sum "$f" | cut -d' ' -f1)"
      if [ "$remote_md5" = "$local_md5" ]; then
        log "  MD5 сверен с S3 (без скачивания)"
      else
        log "  ERROR: MD5 в S3 ($remote_md5) != локального ($local_md5)"; return 1
      fi
    fi
  else
    log "  MD5 не сравниваем: объект ≥ 200 МиБ (multipart, ETag != MD5)"
  fi
  return 0
}

# --- ждём БД, определяем версию сервера и права ---
log "ждём БД $PGHOST:$PGPORT (шаг 3s, таймаут ${WAIT_DB_TIMEOUT}s, 0=без лимита) ..."
waited=0
while ! pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -q; do
  if [ "$WAIT_DB_TIMEOUT" -gt 0 ] && [ "$waited" -ge "$WAIT_DB_TIMEOUT" ]; then
    log "FATAL: БД $PGHOST:$PGPORT не поднялась за ${WAIT_DB_TIMEOUT}s"
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
    gout="$WORKDIR/$TS.sql.zst"
    { pg_dumpall -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --globals-only --no-role-passwords; echo $? > "$gstat_f"; } 2>/dev/null \
      | zstd -q -6 -c > "$gout" || gz=$?
    gstat="$(cat "$gstat_f" 2>/dev/null || echo 1)"; rm -f "$gstat_f"
    if [ "$gstat" = "0" ] && [ "$gz" = "0" ]; then
      log "  размер globals: $(wc -c <"$gout") B"
      RCLONE_CAP_SRC="$gout"
      rclone_run copy "$gout" "$(s3path "$S3_PREFIX/_globals/")"
      if [ "$RCLONE_RC" = "0" ]; then
        log "upload OK: $S3_PREFIX/_globals/$TS.sql.zst"; retain "$S3_PREFIX/_globals/"
      else
        log "ERROR: globals upload failed"; FAILED=1
      fi
      rm -f "$gout"
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
    mkdir -p "$WORKDIR/$db"
    out="$WORKDIR/$db/$TS.dump.zst"
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
    log "  загрузка: $out -> $S3_BUCKET/$key"
    up_ok=0
    attempt=1
    while [ "$attempt" -le 3 ]; do
      RCLONE_EXTRA=""; [ "$attempt" = "3" ] && RCLONE_EXTRA="--s3-disable-http2"
      log "  rclone copy: попытка $attempt/3${RCLONE_EXTRA:+ (HTTP/2 отключён)}"
      RCLONE_CAP_SRC="$out"
      rclone_run copy "$out" "$(s3path "$S3_PREFIX/$db/")"
      [ "$RCLONE_RC" = "0" ] && { up_ok=1; break; }
      log "  WARN: попытка $attempt/3 не удалась (см. вывод rclone выше)"
      attempt=$((attempt + 1))
      if [ "$attempt" -le 3 ]; then
        log "  повтор через 10s"
        sleep 10
      fi
    done
    if [ "$up_ok" = "1" ]; then
      if [ "$VERIFY_REMOTE" = "1" ]; then
        verify_remote_object "$key" "$out" || FAILED=1
      else
        log "upload OK: $key ($(wc -c <"$out") B; VERIFY_REMOTE=0 — без проверки в S3)"
      fi
      if [ "$VERIFY_DOWNLOAD" = "1" ]; then
        log "  VERIFY_DOWNLOAD=1: скачиваю объект и проверяю полностью (это исходящий трафик!)"
        rm -rf "$WORKDIR/_dl"; mkdir -p "$WORKDIR/_dl"
        rclone_run copy "$(s3path "$key")" "$WORKDIR/_dl"
        if [ "$RCLONE_RC" = "0" ] && verify_archive "$WORKDIR/_dl/$TS.dump.zst"; then
          log "  скачанный из S3 объект цел"
        else
          log "  ERROR: скачанный из S3 объект повреждён"; FAILED=1
        fi
        rm -rf "$WORKDIR/_dl"
      fi
      retain "$S3_PREFIX/$db/"
    else
      log "ERROR: upload failed: $db"; FAILED=1
    fi
    rm -f "$out"
    log "  БАЗА $db: готово за $(( $(date +%s) - db_t0 ))s"
  done

  log "прогон завершён. failed=$FAILED, всего за $(( $(date +%s) - run_t0 ))s; следующий через ${INTERVAL}s"
  next_run "$FAILED"
done
