CREATE STREAM R(A int, B int)
FROM FILE '../dbtoaster-experiments-data/simple/tiny/r.dat' LINE DELIMITED
CSV ();

CREATE STREAM S(B int, C int)
FROM FILE '../dbtoaster-experiments-data/simple/tiny/s.dat' LINE DELIMITED
CSV ();

SELECT * FROM R NATURAL JOIN S WHERE R.A < S.C
