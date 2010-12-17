DROP TABLE IF EXISTS bids;
CREATE TABLE bids(broker_id float, price float, volume float);

COPY BIDS FROM '@@PATH@@/testdata/BIDS.dbtdat' WITH DELIMITER ',';

SELECT b1.price, sum(b1.volume) 
FROM   bids b1
WHERE  0.25 * (select sum(b3.volume) from bids b3)
       > (select case when v is null then 0 else v end
          from (select sum(b2.volume) as v
                from bids b2 where b2.price > b1.price) as R)
GROUP BY b1.price;

DROP TABLE bids;