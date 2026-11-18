-- The box office: four shows on sale, the booking the app runs for each seat,
-- and the sales dashboard's refresh. Rebuilt by the lesson's init.
DROP TABLE IF EXISTS shows;
CREATE TABLE shows (id int PRIMARY KEY, sold bigint NOT NULL DEFAULT 0);
INSERT INTO shows SELECT g, 0 FROM generate_series(1, 4) g;

-- One seat on show s. The show's row stays locked until the booking commits,
-- and the seat map is rebuilt while it is held.
CREATE OR REPLACE FUNCTION book(s int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE shows SET sold = sold + 1 WHERE id = s;
  PERFORM count(*) FROM generate_series(1, 20000);
END $$;

-- CPU, and no locks.
CREATE OR REPLACE FUNCTION dashboard() RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM generate_series(1, 300000)
$$;
