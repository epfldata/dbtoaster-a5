
CREATE STREAM R(A int, B int) 
  FROM FILE '../dbtoaster-experiments-data/simple/tiny/r.dat' LINE DELIMITED
  CSV ();

SELECT A, B, (A + B) FROM R WHERE A = (SELECT 3) AND A >= A;
