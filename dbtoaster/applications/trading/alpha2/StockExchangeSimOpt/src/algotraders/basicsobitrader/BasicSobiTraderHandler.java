/*
 * To change this template, choose Tools | Templates
 * and open the template in the editor.
 */
package algotraders.basicsobitrader;

import algotraders.utils.GeneralStockPropts;
import algotraders.utils.WatchList;
import codecs.TupleDecoder;
import java.io.IOException;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.logging.Logger;
import org.jboss.netty.channel.Channel;
import org.jboss.netty.channel.ChannelFuture;
import org.jboss.netty.channel.ChannelHandlerContext;
import org.jboss.netty.channel.MessageEvent;
import org.jboss.netty.channel.SimpleChannelHandler;
import rules.impl.BasicMatcher;
import state.OrderBook;
import state.OrderBook.OrderBookEntry;
import state.StockState;

/**
 *
 * @author kunal
 */
public class BasicSobiTraderHandler extends SimpleChannelHandler {

    OrderBook orderBook;
    TupleDecoder parser;
    List<String> schema;
    BasicMatcher matchMaker;
    StockState stockState;
    Map<Integer, GeneralStockPropts> stockInfo;
    WatchList watchList;
    static final Logger logger = Logger.getLogger("handler_log");

    BasicSobiTraderHandler(OrderBook simOrderBook, WatchList watchList, Map<Integer, GeneralStockPropts> stockInfo, BasicMatcher matchMaker, StockState stockState, TupleDecoder t) {
        this.matchMaker = matchMaker;
        this.orderBook = simOrderBook;
        this.parser = t;
        this.schema = OrderBook.getSchemaKeys();
        this.stockState = stockState;
        this.watchList = watchList;
        this.stockInfo = stockInfo;
    }

    @Override
    public void messageReceived(ChannelHandlerContext ctx, MessageEvent e) {
        String buffer = (String) e.getMessage();
        String[] payloads = buffer.split("\n");
        for (String payload : payloads) {
            System.out.println("MarketUpdate: " + payload);
            runSim(payload, e.getChannel());

        }
    }

    public void runSim(String payload, Channel ch) {
        String[] contents = payload.split(";");
        Map<String, Object> decodedLoad = parser.createTuples(contents[1]);

        if (decodedLoad != null) {
            Object a[] = new Object[schema.size()];
            for (int i = 0; i < schema.size(); i++) {
                a[i] = decodedLoad.get(schema.get(i));
            }
            //a[4] = e.getChannel().hashCode();
            OrderBookEntry newEntry = orderBook.createEntry((Integer) a[0],
                    (Integer) a[1],
                    (Integer) a[2],
                    new Date().getTime(),
                    Integer.MAX_VALUE);
            try {
                orderBook.executeCommand(contents[0], newEntry);
            } catch (IOException ex) {
                logger.severe(ex.getMessage());
            }

            matchMaker.match(contents[0], newEntry);

            BasicSobiPropts oldPropts = (BasicSobiPropts) stockInfo.get(newEntry.stockId);
            oldPropts.updatePrice(stockState.getStockPrice(newEntry.stockId));
            System.out.println("-------Stock Price changed to : " + stockState.getStockPrice(newEntry.stockId));
            oldPropts.updatePending(orderBook);
            //String trade = generateTrade(newEntry.stockId, oldPropts);


            String trade = null;
            Integer trader = 0;
            if (a[4] != null) {
                trader = (Integer)a[4];
            }
            if (trader == this.hashCode()) {
                trade = null;
            } else {
                trade = oldPropts.getTrade();
            }
            if (trade != null) {
                trade = String.format("%s stock_id:%s trader:%s", trade, newEntry.stockId, this.hashCode());
                ChannelFuture cf = ch.write(trade + "\n");
                System.out.println("Adding new order: " + trade);
                cf.awaitUninterruptibly();

            }


        }
    }
}