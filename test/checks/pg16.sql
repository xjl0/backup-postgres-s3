-- Проверка восстановленной базы app для PG16. Любое несоответствие -> ошибка.
\set ON_ERROR_STOP on
DO $$
DECLARE n int; v text;
BEGIN
  SELECT count(*) INTO n FROM items;
  IF n <> 2000 THEN RAISE EXCEPTION 'PG16 items: ожидалось 2000 строк, есть %', n; END IF;

  -- SQL/JSON конструкторы: данные из JSON_OBJECT на месте
  SELECT count(*) INTO n FROM users WHERE profile ? 'name';
  IF n <> 2 THEN RAISE EXCEPTION 'PG16 JSON_OBJECT: ожидалось 2 профиля, есть %', n; END IF;
  SELECT profile->>'name' INTO v FROM users ORDER BY id LIMIT 1;
  IF v <> 'alice' THEN RAISE EXCEPTION 'PG16 JSON_OBJECT: name=% (ожидалось alice)', v; END IF;

  -- random_normal() существует и данные заполнены
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'random_normal') THEN
    RAISE EXCEPTION 'PG16 random_normal(): функции нет';
  END IF;
  SELECT count(*) INTO n FROM samples;
  IF n <> 10 THEN RAISE EXCEPTION 'PG16 random_normal: ожидалось 10 строк, есть %', n; END IF;
END $$;
SELECT 'OK';
