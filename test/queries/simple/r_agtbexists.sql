-- Expected result: 
-- 1,1 -> 1
-- 1,3 -> 3
-- 2,1 -> 2
-- 2,3 -> 6
-- 3,1 -> 1
-- 3,3 -> 3
-- 3,4 -> 1
-- 4,1 -> 1
-- 4,2 -> 2
-- 4,3 -> 5
-- 4,4 -> 1
-- 4,5 -> 1
-- 5,1 -> 2
-- 5,2 -> 2
-- 5,3 -> 6
-- 5,4 -> 1
-- 5,5 -> 1


CREATE STREAM R(A int, B int) 
  FROM FILE '../../experiments/data/tiny_r.dat' LINE DELIMITED
  csv (fields := ',', schema := 'int,int', eventtype := 'insert');

SELECT r1.A, SUM(1)
FROM R r1
WHERE EXISTS (SELECT r2.B FROM R r2 WHERE r1.A > r2.A)
GROUP BY r1.A