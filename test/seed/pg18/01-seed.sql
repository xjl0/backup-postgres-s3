-- PG18: тестовые данные, использующие фичи именно этой версии.
-- База app бэкапится скриптом, затем восстанавливается и проверяется (test/checks/pg18.sql).
CREATE DATABASE app;

\connect app

CREATE TABLE version_probe (major int not null, feature text not null);
INSERT INTO version_probe VALUES (18, 'uuidv7(), виртуальные генерируемые колонки');

-- «объём» для проверки сжатия и целостности данных
CREATE TABLE items (id bigserial primary key, name text not null, payload jsonb);
INSERT INTO items (name, payload)
SELECT 'item' || g, jsonb_build_object('n', g, 'sin', sin(g))
FROM generate_series(1, 2000) g;

-- PG18: uuidv7() прямо в базе
CREATE TABLE events (id uuid primary key default uuidv7(), name text not null);
INSERT INTO events (name) SELECT 'event-' || g FROM generate_series(1, 500) g;

-- PG18: виртуальная генерируемая колонка
CREATE TABLE measured (a int, b int, total int GENERATED ALWAYS AS (a + b) VIRTUAL);
INSERT INTO measured (a, b) VALUES (1, 2), (3, 4), (5, 6);

-- роль для проверки globals-дампа и не-суперюзерного пути
CREATE ROLE backup_ro LOGIN PASSWORD 'backup_ro';
GRANT pg_read_all_data TO backup_ro;
ALTER ROLE backup_ro CREATEDB;
