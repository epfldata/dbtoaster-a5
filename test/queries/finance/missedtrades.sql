CREATE STREAM bids(t FLOAT, id INT, broker_id INT, volume FLOAT, price FLOAT)
  FROM FILE '../../experiments/data/vwap5k.csv'
  LINE DELIMITED orderbook (book := 'bids', brokers := '10', 
                            deterministic := 'yes');

CREATE STREAM asks(t FLOAT, id INT, broker_id INT, volume FLOAT, price FLOAT)
  FROM FILE '../../experiments/data/vwap5k.csv'
  LINE DELIMITED orderbook (book := 'asks', brokers := '10', 
                            deterministic := 'yes');

SELECT b.broker_id, sum((a.price * a.volume) + (-1 * b.price * b.volume)) AS mst
FROM bids b, asks a
WHERE 0.25*(SELECT sum(a1.volume) FROM asks a1) >
           (SELECT sum(a2.volume) FROM asks a2 WHERE a2.price > a.price)
AND   0.25*(SELECT sum(b1.volume) FROM bids b1) >
           (SELECT sum(b2.volume) FROM bids b2 WHERE b2.price > b.price)
GROUP BY b.broker_id;