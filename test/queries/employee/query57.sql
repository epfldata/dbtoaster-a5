-- List out the no. of employees on grade wise.

CREATE STREAM EMPLOYEE(
    employee_id     INT, 
    last_name       VARCHAR(30),
    first_name      VARCHAR(20),
    middle_name     CHAR(1),
    job_id          INT,
    manager_id      INT,
    hire_date       DATE,
    salary          FLOAT,
    commission      FLOAT,
    department_id   INT
    ) 
  FROM FILE '../dbtoaster-experiments-data/employee/employee.dat' LINE DELIMITED
  CSV ();

CREATE STREAM SALARY_GRADE(
    grade_id     INT, 
    lower_bound  FLOAT,
    upper_bound  FLOAT
    ) 
  FROM FILE '../dbtoaster-experiments-data/employee/salary_grade.dat' LINE DELIMITED
  CSV ();

SELECT grade_id, count(*) 
FROM employee e, salary_grade s
WHERE salary BETWEEN lower_bound AND upper_bound 
GROUP BY grade_id 
ORDER BY grade_id DESC
