-- PG17: тестовые данные, использующие фичи именно этой версии.
-- База app бэкапится скриптом, затем восстанавливается и проверяется (test/checks/pg17.sql).
CREATE DATABASE app;

\connect app

CREATE TABLE version_probe (major int not null, feature text not null);
INSERT INTO version_probe VALUES (17, 'JSON_TABLE, GUC transaction_timeout');

-- «объём» для проверки сжатия и целостности данных
CREATE TABLE items (id bigserial primary key, name text not null, payload jsonb);
INSERT INTO items (name, payload)
SELECT 'item' || g, jsonb_build_object('n', g, 'sin', sin(g))
FROM generate_series(1, 2000) g;

-- PG17: JSON_TABLE — разворачиваем JSON в строки и материализуем в таблицу
CREATE TABLE tickets (id int primary key, doc jsonb);
INSERT INTO tickets VALUES
  (1, '{"subject":"prio-alpha","prio":1}'),
  (2, '{"subject":"prio-beta", "prio":2}'),
  (3, '{"subject":"prio-gamma","prio":3}');
CREATE TABLE ticket_rows AS
SELECT jt.subject, jt.prio
FROM json_table(
       (SELECT jsonb_agg(doc ORDER BY id) FROM tickets),
       '$[*]' COLUMNS (subject text PATH '$.subject', prio int PATH '$.prio')
     ) AS jt;

-- PG17: GUC transaction_timeout (он же упоминается в cross-version restore в backup.sh)
SELECT set_config('transaction_timeout', '0', false);

-- Крупные несжимаемые данные (~12 МБ): дамп переваливает за порог multipart (8 МБ), поэтому
-- в каждом прогоне проверяется и multipart-загрузка, и проверка composite-суммы в S3.
CREATE EXTENSION pgcrypto;
CREATE TABLE blob_data (id bigserial primary key, payload bytea);
INSERT INTO blob_data (payload) SELECT gen_random_bytes(1024) FROM generate_series(1, 12000);
