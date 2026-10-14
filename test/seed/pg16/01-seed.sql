-- PG16: тестовые данные, использующие фичи именно этой версии.
-- База app бэкапится скриптом, затем восстанавливается и проверяется (test/checks/pg16.sql).
CREATE DATABASE app;

\connect app

CREATE TABLE version_probe (major int not null, feature text not null);
INSERT INTO version_probe VALUES (16, 'конструкторы SQL/JSON (JSON_OBJECT/JSON_ARRAY), random_normal()');

-- «объём» для проверки сжатия и целостности данных
CREATE TABLE items (id bigserial primary key, name text not null, payload jsonb);
INSERT INTO items (name, payload)
SELECT 'item' || g, jsonb_build_object('n', g, 'sin', sin(g))
FROM generate_series(1, 2000) g;

-- PG16: SQL/JSON конструкторы
CREATE TABLE users (id int generated always as identity primary key, profile jsonb);
INSERT INTO users (profile) VALUES
  (json_object('name' VALUE 'alice', 'tags' VALUE json_array('a', 'b'))),
  (json_object('name' VALUE 'bob',   'tags' VALUE json_array('c')));

-- PG16: random_normal()
CREATE TABLE samples (id bigserial primary key, val double precision);
INSERT INTO samples (val) SELECT random_normal() FROM generate_series(1, 10);
