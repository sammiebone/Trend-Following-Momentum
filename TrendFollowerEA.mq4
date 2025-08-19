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

    //--- Construct dynamic comment
    string dynamic_comment = StringFormat("%s | %s | %s", tradeComment, Symbol(), PeriodToString(Period()));

    //--- Open the trade
    int ticket = OrderSend(Symbol(), orderType, lotSize, price, 3, slPrice, tpPrice, dynamic_comment, magicNumber, 0, clrNONE);
    if(ticket > 0)
    {
        //--- Verify the trade was opened with the correct parameters
        VerifyTradeParameters(ticket, slPrice, tpPrice, dynamic_comment);
    }
    else
    {
        Print("OrderSend failed with error #", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Verify and correct SL/TP for a newly opened order                |
//+------------------------------------------------------------------+
void VerifyTradeParameters(int ticket, double intended_sl, double intended_tp, string intended_comment)
{
    //--- Give the trade server a moment to process
    Sleep(500);

    if(!OrderSelect(ticket, SELECT_BY_TICKET))
    {
        Print("Failed to select order by ticket #", ticket, " for verification.");
        return;
    }

    double current_sl = OrderStopLoss();
    double current_tp = OrderTakeProfit();
    string current_comment = OrderComment();

    // Normalize comparison to avoid floating point issues
    bool sl_ok = (MathAbs(current_sl - intended_sl) < Point);
    bool tp_ok = (intended_tp == 0 && current_tp == 0) || (MathAbs(current_tp - intended_tp) < Point);
    bool comment_ok = (current_comment == intended_comment);

    if(sl_ok && tp_ok)
    {
        if(!comment_ok)
        {
            Print("Warning: Order #", ticket, " comment mismatch. Expected: '", intended_comment, "', Found: '", current_comment, "'. Cannot modify comment.");
        }
        return;
    }

    Print("Order #", ticket, " parameter mismatch. SL OK: ", sl_ok, ", TP OK: ", tp_ok, ". Attempting to modify.");

    if(!OrderModify(ticket, OrderOpenPrice(), intended_sl, intended_tp, 0, clrNONE))
    {
        Print("OrderModify failed for ticket #", ticket, ". Error #", GetLastError());
    }
    else
    {
        Print("Successfully modified order #", ticket, " to correct SL/TP.");
    }
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
                        bool result = OrderModify(OrderTicket(), OrderOpenPrice(), NormalizeDouble(newStopLoss, _Digits), OrderTakeProfit(), 0, clrNONE);
                        if(!result)
                        {
                           Print("OrderModify failed for trailing stop. Error #", GetLastError());
                        }
                    }
                }
                else // OP_SELL
                {
                    newStopLoss = Ask + trailingStopDistance;
                    if(newStopLoss < OrderOpenPrice() && (OrderStopLoss() == 0 || newStopLoss < OrderStopLoss()))
                    {
                        bool result = OrderModify(OrderTicket(), OrderOpenPrice(), NormalizeDouble(newStopLoss, _Digits), OrderTakeProfit(), 0, clrNONE);
                        if(!result)
                        {
                           Print("OrderModify failed for trailing stop. Error #", GetLastError());
                        }
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
//| Converts a timeframe enumeration into a string                   |
//+------------------------------------------------------------------+
string PeriodToString(int period)
{
    switch(period)
    {
        case PERIOD_M1:  return "M1";
        case PERIOD_M5:  return "M5";
        case PERIOD_M15: return "M15";
        case PERIOD_M30: return "M30";
        case PERIOD_H1:  return "H1";
        case PERIOD_H4:  return "H4";
        case PERIOD_D1:  return "D1";
        case PERIOD_W1:  return "W1";
        case PERIOD_MN1: return "MN1";
        default:         return "Unknown";
    }
}
//+------------------------------------------------------------------+
