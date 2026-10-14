# Самодостаточный образ бэкапа: pg_dump + rclone + zstd + скрипт внутри.
#
# ВАЖНО про версии: клиент pg_dump должен быть >= сервера БД. pg_dump умеет дампить серверы
# СТАРЕЕ себя, но НЕ новее. Поэтому по умолчанию берём самый свежий клиент (PG18) — он снимает
# 15/16/17/18 разом. Нужен пин под конкретную версию — соберите с --build-arg PG_MAJOR=16.
ARG PG_MAJOR=18
FROM postgres:${PG_MAJOR}-alpine
# rclone — выгрузка в S3 (по рекомендации провайдера); zstd — сжатие
RUN apk add --no-cache rclone zstd \
 && mkdir -p /etc/rclone && : > /etc/rclone/rclone.conf
COPY backup.sh /usr/local/bin/backup.sh
RUN chmod 0755 /usr/local/bin/backup.sh
USER postgres
ENTRYPOINT ["/usr/local/bin/backup.sh"]
