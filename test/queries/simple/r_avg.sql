CREATE STREAM R(A int, B int)
FROM FILE '../dbtoaster-experiments-data/simple/tiny/r.dat' LINE DELIMITED csv;

SELECT AVG(A) FROM R;
