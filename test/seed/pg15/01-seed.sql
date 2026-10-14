-- PG15: тестовые данные, использующие фичи именно этой версии.
-- База app бэкапится скриптом, затем восстанавливается и проверяется (test/checks/pg15.sql).
CREATE DATABASE app;

\connect app

-- маркер версии/фичи: сверяется при проверке восстановления
CREATE TABLE version_probe (major int not null, feature text not null);
INSERT INTO version_probe VALUES (15, 'MERGE, UNIQUE NULLS NOT DISTINCT');

-- «объём» для проверки сжатия и целостности данных
CREATE TABLE items (id bigserial primary key, name text not null, payload jsonb);
INSERT INTO items (name, payload)
SELECT 'item' || g, jsonb_build_object('n', g, 'sin', sin(g))
FROM generate_series(1, 2000) g;

-- PG15: UNIQUE NULLS NOT DISTINCT — повтор (1, NULL) отбивается ON CONFLICT
CREATE TABLE uniq_nd (a int, b int, UNIQUE NULLS NOT DISTINCT (a, b));
INSERT INTO uniq_nd VALUES (1, NULL), (1, NULL) ON CONFLICT DO NOTHING;

-- PG15: MERGE
CREATE TABLE merge_src (id int primary key, v text);
CREATE TABLE merge_dst (id int primary key, v text);
INSERT INTO merge_src VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');
MERGE INTO merge_dst t USING merge_src s ON t.id = s.id
  WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.v);
