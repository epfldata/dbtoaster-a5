
CREATE STREAM R(A int, B int) 
  FROM FILE '../../experiments/data/tiny_r.dat' LINE DELIMITED csv;

SELECT COUNT(*) FROM (SELECT * FROM R) n;