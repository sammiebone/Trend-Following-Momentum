//+------------------------------------------------------------------+
//|                                              TrendFollowerEA.mq4 |
//|        Copyright 2023, Jules the AI Software Engineer          |
//|                                                                  |
//|    Expert Advisor based on "An Institutional Guide to Momentum   |
//|                 and Trend-Following Strategies"                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Jules the AI Software Engineer"
#property link      "https://example.com"
#property version   "1.00"
#property strict

//--- EA Inputs
input group "Magic Number & Comment"
input int      magicNumber = 13579;         // Magic Number for trades
input string   tradeComment = "TrendFollowerEA"; // Trade comment

input group "Risk Management"
input double   riskPercent = 1.0;           // Risk percentage of account equity per trade

input group "EMA Settings"
input int      fastEMAPeriod = 50;          // Fast EMA period
input int      slowEMAPeriod = 200;         // Slow EMA period

input group "ADX Filter Settings"
input int      adxPeriod = 14;              // ADX period
input double   adxThreshold = 25.0;         // ADX level to confirm trend

input group "RSI Filter Settings"
input int      rsiPeriod = 14;              // RSI period

input group "ATR Stop-Loss & Trailing Stop"
input int      atrPeriod = 14;              // ATR period for stops
input double   atrStopLossMultiplier = 3.0; // Multiplier for initial Stop Loss
input double   atrTrailingStopMultiplier = 2.0; // Multiplier for Trailing Stop

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Check for new bar to run logic only once per bar
    static datetime lastBarTime = 0;
    if(Time[0] != lastBarTime)
    {
        lastBarTime = Time[0];
        CheckForSignal();
    }

    //--- Trailing stop logic runs on every tick
    ManageTrailingStop();
}

//+------------------------------------------------------------------+
//| Check for trading signals                                        |
//+------------------------------------------------------------------+
void CheckForSignal()
{
    //--- Only trade if no position is open for this symbol and magic number
    if(CountOpenTrades() > 0)
    {
        return;
    }

    //--- Get indicator values for the last 2 completed bars
    double last_emaFast = iMA(Symbol(), 0, fastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
    double last_emaSlow = iMA(Symbol(), 0, slowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
    double prior_emaFast = iMA(Symbol(), 0, fastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 2);
    double prior_emaSlow = iMA(Symbol(), 0, slowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 2);

    double last_adx = iADX(Symbol(), 0, adxPeriod, PRICE_CLOSE, MODE_MAIN, 1);
    double last_rsi = iRSI(Symbol(), 0, rsiPeriod, PRICE_CLOSE, 1);
    double last_atr = iATR(Symbol(), 0, atrPeriod, 1);

    //--- Check for Buy Signal (Golden Cross)
    bool buySignal = (prior_emaFast <= prior_emaSlow) &&
                     (last_emaFast > last_emaSlow) &&
                     (last_adx > adxThreshold) &&
                     (last_rsi > 50);

    //--- Check for Sell Signal (Death Cross)
    bool sellSignal = (prior_emaFast >= prior_emaSlow) &&
                      (last_emaFast < last_emaSlow) &&
                      (last_adx > adxThreshold) &&
                      (last_rsi < 50);

    if(buySignal)
    {
        OpenPosition(OP_BUY, last_atr);
    }
    else if(sellSignal)
    {
        OpenPosition(OP_SELL, last_atr);
    }
}

//+------------------------------------------------------------------+
//| Open a new position                                              |
//+------------------------------------------------------------------+
void OpenPosition(int orderType, double atrValue)
{
    double price = (orderType == OP_BUY) ? Ask : Bid;
    double slPrice, tpPrice = 0;

    //--- Calculate Stop Loss price based on ATR
    double slDistance = atrValue * atrStopLossMultiplier;
    if(orderType == OP_BUY)
    {
        slPrice = price - slDistance;
    }
    else // OP_SELL
    {
        slPrice = price + slDistance;
    }

    //--- Calculate Lot Size based on risk
    double lotSize = CalculateLotSize(slDistance);
    if(lotSize <= 0)
    {
        Print("Invalid lot size calculated: ", lotSize, ". Cannot open trade.");
        return;
    }

    //--- Normalize SL/TP to broker requirements
    slPrice = NormalizeDouble(slPrice, _Digits);

    //--- Open the trade
    OrderSend(Symbol(), orderType, lotSize, price, 3, slPrice, tpPrice, tradeComment, magicNumber, 0, clrNONE);
}

//+------------------------------------------------------------------+
//| Calculate position size based on risk and SL distance            |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
    double accountBalance = AccountEquity();
    double riskAmount = accountBalance * (riskPercent / 100.0);

    //--- Calculate loss per lot
    double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
    double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);

    if(slDistance <= 0 || tickValue <= 0 || tickSize <= 0)
    {
       Print("Cannot calculate lot size due to zero values in risk calculation inputs.");
       return 0.0;
    }

    double lossPerLot = slDistance / tickSize * tickValue;

    if(lossPerLot <= 0)
    {
       Print("Calculated loss per lot is zero or negative.");
       return 0.0;
    }

    double lotSize = riskAmount / lossPerLot;

    //--- Normalize and check against limits
    double minLot = MarketInfo(Symbol(), MODE_MINLOT);
    double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
    double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

    lotSize = MathFloor(lotSize / lotStep) * lotStep;

    if(lotSize < minLot) lotSize = 0.0; // If calculated lot is less than minimum, do not trade
    if(lotSize > maxLot) lotSize = maxLot;

    return lotSize;
}

//+------------------------------------------------------------------+
//| Manage trailing stop for open positions                          |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == magicNumber)
            {
                double currentAtr = iATR(Symbol(), 0, atrPeriod, 0);
                double trailingStopDistance = currentAtr * atrTrailingStopMultiplier;
                double newStopLoss = 0;

                if(OrderType() == OP_BUY)
                {
                    newStopLoss = Bid - trailingStopDistance;
                    if(newStopLoss > OrderOpenPrice() && newStopLoss > OrderStopLoss())
                    {
                        OrderModify(OrderTicket(), OrderOpenPrice(), NormalizeDouble(newStopLoss, _Digits), OrderTakeProfit(), 0, clrNONE);
                    }
                }
                else // OP_SELL
                {
                    newStopLoss = Ask + trailingStopDistance;
                    if(newStopLoss < OrderOpenPrice() && (OrderStopLoss() == 0 || newStopLoss < OrderStopLoss()))
                    {
                        OrderModify(OrderTicket(), OrderOpenPrice(), NormalizeDouble(newStopLoss, _Digits), OrderTakeProfit(), 0, clrNONE);
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Count open trades for this EA/Symbol                             |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
    int count = 0;
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == magicNumber)
            {
                count++;
            }
        }
    }
    return count;
}
//+------------------------------------------------------------------+
