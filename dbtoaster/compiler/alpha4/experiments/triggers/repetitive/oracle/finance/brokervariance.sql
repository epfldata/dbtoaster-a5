BEGIN
   EXECUTE IMMEDIATE 'DROP TABLE RESULTS';
EXCEPTION
   WHEN OTHERS THEN
      IF SQLCODE != -942 THEN
         RAISE;
      END IF;
END;

/

CREATE TABLE RESULTS (
    broker_id integer,
    total     float
);

CREATE OR REPLACE PROCEDURE recompute_query AS
    item RESULTS%ROWTYPE;
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    EXECUTE IMMEDIATE 'TRUNCATE TABLE RESULTS';
    INSERT INTO RESULTS (
        SELECT x.broker_id,
            case when sum(x.volume * x.price * y.volume * y.price * 0.5) is null then 0
            else sum(x.volume * x.price * y.volume * y.price * 0.5) end
        FROM bids x, bids y
        WHERE x.broker_id = y.broker_id
        GROUP BY x.broker_id
    );
    COMMIT;
END;

/

CREATE OR REPLACE TRIGGER refresh_bids
    AFTER INSERT OR DELETE ON BIDS
    FOR EACH ROW
BEGIN EXECUTE IMMEDIATE 'CALL recompute_query()'; END;

/

CREATE DIRECTORY bsvlog AS '/tmp';
CALL dispatch('BSVLOG', 'brokervariance.log');
SELECT * FROM RESULTS;

DROP TABLE RESULTS;
DROP PROCEDURE recompute_query;
DROP DIRECTORY bsvlog;
DROP TRIGGER refresh_bids;

exit