
CREATE STREAM R(A int, B int) 
  FROM FILE '../dbtoaster-experiments-data/simple/tiny/r.dat' LINE DELIMITED
  CSV ();

SELECT * FROM (SELECT * FROM R) n;
