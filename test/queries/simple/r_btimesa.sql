-- Expected result: 
-- 1 -> 96
-- 2 -> 224
-- 3 -> 128
-- 4 -> 288
-- 5 -> 256

CREATE STREAM R(A float, B float) 
  FROM FILE '../../experiments/data/tiny_r.dat' LINE DELIMITED
  csv (fields := ',', schema := 'float,float', eventtype := 'insert');

SELECT A, SUM(B * (SELECT SUM(r2.A) FROM R r2)) FROM R r1 GROUP BY A