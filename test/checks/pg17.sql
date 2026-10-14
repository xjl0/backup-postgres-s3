-- Проверка восстановленной базы app для PG17. Любое несоответствие -> ошибка.
\set ON_ERROR_STOP on
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM items;
  IF n <> 2000 THEN RAISE EXCEPTION 'PG17 items: ожидалось 2000 строк, есть %', n; END IF;

  -- JSON_TABLE: развёрнутые строки материализованы и на месте
  SELECT count(*) INTO n FROM ticket_rows WHERE subject LIKE 'prio-%' AND prio BETWEEN 1 AND 3;
  IF n <> 3 THEN RAISE EXCEPTION 'PG17 JSON_TABLE: ожидалось 3 строки, есть %', n; END IF;

  -- GUC transaction_timeout (появился в PG17)
  IF NOT EXISTS (SELECT 1 FROM pg_settings WHERE name = 'transaction_timeout') THEN
    RAISE EXCEPTION 'PG17: нет GUC transaction_timeout';
  END IF;
END $$;
SELECT 'OK';
