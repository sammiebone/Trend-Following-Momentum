//+------------------------------------------------------------------+
//|                                                 CarryTradeEA.mq4 |
//|        Copyright 2024, Jules the AI Software Engineer          |
//|                                                                  |
//|      EA based on FX Carry Trade principles: positive swap,       |
//|         low volatility, and trend-following filter.              |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules the AI Software Engineer"
#property link      "https://example.com"
#property version   "1.00"
#property strict
#property description "A Carry Trade EA using swap rates, trend and volatility filters."


//--- EA Inputs
input int      magicNumber = 97531;            // Magic Number for trades
input string   tradeComment = "CarryTradeEA";    // Trade comment

input double   riskPercent = 1.0;              // Risk percentage of account equity per trade
input double   atrStopLossMultiplier = 2.0;    // Multiplier for initial ATR-based Stop Loss

input int      smaPeriod = 200;                // Period for the long-term SMA trend filter

input int      atrPeriod = 14;                 // ATR period for volatility measurement
input int      atrLookback = 100;              // Lookback for ATR's own moving average

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
    //--- Use a static variable to check for a new day
    static datetime last_check_time = 0;
    datetime current_day_bar_time = iTime(Symbol(), PERIOD_D1, 0);

    //--- Run all logic once per day on the close of the daily bar
    if(current_day_bar_time > last_check_time)
    {
        last_check_time = current_day_bar_time;

        // First, manage any open positions based on the new daily data
        ManageExit();

        // Then, check for new entries if no position is open
        CheckForEntry();
    }
}

//+------------------------------------------------------------------+
//| Check for a new trade entry (runs once per day)                  |
//+------------------------------------------------------------------+
void CheckForEntry()
{
    //--- Do not open a new trade if one is already open
    if(CountOpenTrades() > 0)
    {
        return;
    }

    //--- Get indicator values from the last completed day
    double sma_val = iMA(Symbol(), PERIOD_D1, smaPeriod, 0, MODE_SMA, PRICE_CLOSE, 1);
    double close_val = iClose(Symbol(), PERIOD_D1, 1);

    //--- Volatility Filter: Check if current ATR is below its long-term average
    double current_atr = iATR(Symbol(), PERIOD_D1, atrPeriod, 1);
    double sum_atr = 0;
    for(int i = 2; i < atrLookback + 2; i++) // Start from shift 2 to get previous values
    {
        sum_atr += iATR(Symbol(), PERIOD_D1, atrPeriod, i);
    }
    double avg_atr = (atrLookback > 0) ? sum_atr / atrLookback : 0;

    bool is_low_volatility = (current_atr < avg_atr);

    //--- Get Swap Rates
    double swap_long = MarketInfo(Symbol(), MODE_SWAPLONG);
    double swap_short = MarketInfo(Symbol(), MODE_SWAPSHORT);

    //--- Check for Long Entry
    if(swap_long > 0 && close_val > sma_val && is_low_volatility)
    {
        OpenPosition(OP_BUY, current_atr);
    }
    //--- Check for Short Entry
    else if(swap_short > 0 && close_val < sma_val && is_low_volatility)
    {
        OpenPosition(OP_SELL, current_atr);
    }
}

//+------------------------------------------------------------------+
//| Manage exit conditions for open positions (runs once per day)    |
//+------------------------------------------------------------------+
void ManageExit()
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == magicNumber)
            {
                //--- Get indicator values from the last completed day
                double sma_val = iMA(Symbol(), PERIOD_D1, smaPeriod, 0, MODE_SMA, PRICE_CLOSE, 1);
                double close_val = iClose(Symbol(), PERIOD_D1, 1);

                //--- Exit condition: Price closes across the daily SMA
                if(OrderType() == OP_BUY && close_val < sma_val)
                {
                    if(!OrderClose(OrderTicket(), OrderLots(), Bid, 3, clrNONE))
                    {
                       Print("OrderClose failed. Error #", GetLastError());
                    }
                    Print("Closed LONG position due to daily close below daily SMA.");
                    break; // Exit loop after closing
                }
                else if(OrderType() == OP_SELL && close_val > sma_val)
                {
                    if(!OrderClose(OrderTicket(), OrderLots(), Ask, 3, clrNONE))
                    {
                       Print("OrderClose failed. Error #", GetLastError());
                    }
                    Print("Closed SHORT position due to daily close above daily SMA.");
                    break; // Exit loop after closing
                }
            }
        }
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
    int ticket = OrderSend(Symbol(), orderType, lotSize, price, 3, slPrice, tpPrice, tradeComment, magicNumber, 0, clrNONE);
    if(ticket > 0)
    {
        //--- Verify the trade was opened with the correct parameters
        VerifyTradeParameters(ticket, slPrice, tpPrice);
    }
    else
    {
       Print("OrderSend failed. Error #", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Verify and correct SL/TP for a newly opened order                |
//+------------------------------------------------------------------+
void VerifyTradeParameters(int ticket, double intended_sl, double intended_tp)
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
    string intended_comment = tradeComment;
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

    double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
    double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);

    if(slDistance <= 0 || tickValue <= 0 || tickSize <= 0)
    {
       return 0.0;
    }

    double lossPerLot = slDistance / tickSize * tickValue;

    if(lossPerLot <= 0)
    {
       return 0.0;
    }

    double lotSize = riskAmount / lossPerLot;

    double minLot = MarketInfo(Symbol(), MODE_MINLOT);
    double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
    double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

    lotSize = MathFloor(lotSize / lotStep) * lotStep;

    if(lotSize < minLot) lotSize = 0.0;
    if(lotSize > maxLot) lotSize = maxLot;

    return lotSize;
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
