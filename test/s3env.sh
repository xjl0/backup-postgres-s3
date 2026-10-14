# Настройка S3 для ТЕСТОВОГО стенда (s3mock). Прод использует переменные из .env.
# Экспортируем и S3_* (их читает backup.sh), и RCLONE_CONFIG_* (для прямых вызовов rclone в тестах).
: "${S3_BUCKET:=pg-backup-test}"
export S3_BUCKET
export S3_ENDPOINT="${S3_ENDPOINT:-http://s3:9090}"
export S3_REGION="${S3_REGION:-us-east-1}"
export S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-test}"
export S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-test}"

export RCLONE_CONFIG="${RCLONE_CONFIG:-/etc/rclone/rclone.conf}"
RV=S3
export "RCLONE_CONFIG_${RV}_TYPE=s3"
export "RCLONE_CONFIG_${RV}_PROVIDER=Other"
export "RCLONE_CONFIG_${RV}_ACCESS_KEY_ID=$S3_ACCESS_KEY_ID"
export "RCLONE_CONFIG_${RV}_SECRET_ACCESS_KEY=$S3_SECRET_ACCESS_KEY"
export "RCLONE_CONFIG_${RV}_REGION=$S3_REGION"
export "RCLONE_CONFIG_${RV}_ENDPOINT=$S3_ENDPOINT"
export "RCLONE_CONFIG_${RV}_FORCE_PATH_STYLE=true"   # s3mock требует path-style

s3path() { printf '%s:%s/%s' "s3" "$S3_BUCKET" "$1"; }   # $1 — путь внутри бакета
S3R="s3"
RCLONE_OPTS="--s3-upload-concurrency 4"
# ключи (относительно префикса) по возрастанию: `rclone ls` -> "размер путь"
s3_list() { rclone ls "$(s3path "$1")" 2>/dev/null | awk '{print $2}' | grep . | sort || true; }
# удалить объект по полному ключу
s3_del()  { rclone deletefile "$(s3path "$1")" >/dev/null 2>&1; }
