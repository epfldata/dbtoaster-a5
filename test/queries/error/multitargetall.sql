CREATE STREAM R(A int, B int)
FROM FILE '../dbtoaster-experiments-data/simple/tiny/r.dat' LINE DELIMITED
CSV ();

SELECT * FROM R r2 
WHERE r2.A < ALL (
  SELECT AVG(r1.A), B FROM R r1 WHERE r1.B = r2.B GROUP BY B
);
