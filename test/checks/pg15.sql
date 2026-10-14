-- Проверка восстановленной базы app для PG15. Любое несоответствие -> ошибка.
\set ON_ERROR_STOP on
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM items;
  IF n <> 2000 THEN RAISE EXCEPTION 'PG15 items: ожидалось 2000 строк, есть %', n; END IF;

  -- MERGE сработал
  SELECT count(*) INTO n FROM merge_dst;
  IF n <> 3 THEN RAISE EXCEPTION 'PG15 MERGE: ожидалось 3 строки, есть %', n; END IF;

  -- UNIQUE NULLS NOT DISTINCT: повтор (1, NULL) должен быть отбит
  SELECT count(*) INTO n FROM uniq_nd;
  IF n <> 1 THEN RAISE EXCEPTION 'PG15 NULLS NOT DISTINCT: ожидалась 1 строка, есть %', n; END IF;
END $$;
SELECT 'OK';
