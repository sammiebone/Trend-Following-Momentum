//+------------------------------------------------------------------+
//|                                            MeanReversionEA.mq4 |
//|        Copyright 2024, Jules the AI Software Engineer          |
//|                                                                  |
//|      EA based on Mean Reversion principles: ADX filter for       |
//|     ranging markets, Bollinger Bands, and RSI confirmation.      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules the AI Software Engineer"
#property link      "https://example.com"
#property version   "1.00"
#property strict
#property description "A Mean Reversion EA using ADX, Bollinger Bands, and RSI."

//--- EA Inputs
input int      magicNumber = 654321;           // Magic Number for trades
input string   tradeComment = "MeanReversionEA"; // Trade comment

input double   riskPercent = 1.0;              // Risk percentage of account equity per trade
input double   atrStopLossMultiplier = 2.0;    // Multiplier for initial ATR-based Stop Loss

input int      adxPeriod = 14;                 // ADX period
input double   adxThreshold = 25.0;            // ADX must be BELOW this to trade

input int      bbPeriod = 20;                  // Bollinger Bands period
input double   bbDeviation = 2.0;              // Bollinger Bands deviation

input int      rsiPeriod = 14;                 // RSI period
input double   rsiOverbought = 70.0;           // RSI Overbought level
input double   rsiOversold = 30.0;             // RSI Oversold level

input int      atrPeriod = 14;                 // ATR period

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
    if(Time[0] > lastBarTime)
    {
        lastBarTime = Time[0];
        CheckForSignal();
    }
}

//+------------------------------------------------------------------+
//| Check for trading signals                                        |
//+------------------------------------------------------------------+
void CheckForSignal()
{
    //--- Do not open a new trade if one is already open
    if(CountOpenTrades() > 0)
    {
        return;
    }

    //--- Get indicator values for the last closed bar (shift=1)
    double adx = iADX(Symbol(), 0, adxPeriod, PRICE_CLOSE, MODE_MAIN, 1);
    double rsi = iRSI(Symbol(), 0, rsiPeriod, PRICE_CLOSE, 1);
    double atr = iATR(Symbol(), 0, atrPeriod, 1);
    double middle_bb = iBands(Symbol(), 0, bbPeriod, bbDeviation, 0, PRICE_CLOSE, MODE_MAIN, 1);

    //--- Regime Filter: Only trade in ranging markets
    if(adx >= adxThreshold)
    {
        return; // Market is trending, do not trade
    }

    //--- Buy Signal Logic
    double close_1 = iClose(Symbol(), 0, 1); // Last closed bar
    double close_2 = iClose(Symbol(), 0, 2); // Bar before last
    double lower_bb_1 = iBands(Symbol(), 0, bbPeriod, bbDeviation, 0, PRICE_CLOSE, MODE_LOWER, 1);
    double lower_bb_2 = iBands(Symbol(), 0, bbPeriod, bbDeviation, 0, PRICE_CLOSE, MODE_LOWER, 2);

    bool buySetup = close_2 < lower_bb_2;
    bool buyTrigger = close_1 > lower_bb_1;
    bool buyConfirm = rsi < rsiOversold;

    if(buySetup && buyTrigger && buyConfirm)
    {
        OpenPosition(OP_BUY, atr, middle_bb);
        return; // Stop after opening a trade
    }

    //--- Sell Signal Logic
    double upper_bb_1 = iBands(Symbol(), 0, bbPeriod, bbDeviation, 0, PRICE_CLOSE, MODE_UPPER, 1);
    double upper_bb_2 = iBands(Symbol(), 0, bbPeriod, bbDeviation, 0, PRICE_CLOSE, MODE_UPPER, 2);

    bool sellSetup = close_2 > upper_bb_2;
    bool sellTrigger = close_1 < upper_bb_1;
    bool sellConfirm = rsi > rsiOverbought;

    if(sellSetup && sellTrigger && sellConfirm)
    {
        OpenPosition(OP_SELL, atr, middle_bb);
    }
}

//+------------------------------------------------------------------+
//| Open a new position                                              |
//+------------------------------------------------------------------+
void OpenPosition(int orderType, double atrValue, double tpPrice)
{
    double price = (orderType == OP_BUY) ? Ask : Bid;
    double slPrice;

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
    tpPrice = NormalizeDouble(tpPrice, _Digits);

    //--- Open the trade
    if(OrderSend(Symbol(), orderType, lotSize, price, 3, slPrice, tpPrice, tradeComment, magicNumber, 0, clrNONE) < 0)
    {
       Print("OrderSend failed. Error #", GetLastError());
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
