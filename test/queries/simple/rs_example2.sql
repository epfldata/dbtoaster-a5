CREATE STREAM R(A int, B int) 
  FROM FILE '../../experiments/data/tiny/r.dat' LINE DELIMITED
  CSV (fields := ',');

CREATE STREAM S(B int, C int) 
  FROM FILE '../../experiments/data/tiny/s.dat' LINE DELIMITED
  CSV (fields := ',');

SELECT r.B, SUM(r.A*s.C) as RESULT_1, SUM(r.A+s.C) as RESULT_2 FROM R r, S s WHERE r.B = s.B GROUP BY r.B; 
