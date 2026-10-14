-- Проверка восстановленной базы app для PG18. Любое несоответствие -> ошибка.
\set ON_ERROR_STOP on
DO $$
DECLARE n int; bad int;
BEGIN
  SELECT count(*) INTO n FROM items;
  IF n <> 2000 THEN RAISE EXCEPTION 'PG18 items: ожидалось 2000 строк, есть %', n; END IF;

  -- uuidv7(): uuidv7 существует и значения реально версии 7
  IF to_regprocedure('uuidv7()') IS NULL THEN
    RAISE EXCEPTION 'PG18 uuidv7(): функции нет';
  END IF;
  SELECT count(*) INTO n FROM events;
  IF n <> 500 THEN RAISE EXCEPTION 'PG18 events: ожидалось 500 строк, есть %', n; END IF;
  -- версия UUID — 13-й hex-символ, т.е. позиция 15 в тексте с дефисами
  SELECT count(*) INTO bad FROM events WHERE substr(id::text, 15, 1) <> '7';
  IF bad > 0 THEN RAISE EXCEPTION 'PG18 uuidv7: % значений не версии 7', bad; END IF;

  -- виртуальная генерируемая колонка считается корректно
  SELECT count(*) INTO bad FROM measured WHERE total <> a + b;
  IF bad > 0 THEN RAISE EXCEPTION 'PG18 VIRTUAL: % неверных сумм', bad; END IF;
END $$;
SELECT 'OK';
