//+------------------------------------------------------------------+
//|                                              TrendFollowerEA.mq5 |
//|        Copyright 2023, Jules the AI Software Engineer          |
//|                                                                  |
//|    Expert Advisor based on "An Institutional Guide to Momentum   |
//|                 and Trend-Following Strategies"                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Jules the AI Software Engineer"
#property link      "https://example.com"
#property version   "1.00"
#property description "A trend-following EA based on EMA crossover, ADX filter, and ATR-based risk management."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- EA Inputs
input group "Magic Number & Comment"
input ulong    magicNumber = 13579;         // Magic Number for trades
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

//--- Global variables
CTrade      trade;
CPositionInfo position;
int         h_emaFast, h_emaSlow, h_adx, h_rsi, h_atr;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize trading object
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- Get indicator handles
   h_emaFast = iMA(_Symbol, _Period, fastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   h_emaSlow = iMA(_Symbol, _Period, slowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   h_adx = iADX(_Symbol, _Period, adxPeriod);
   h_rsi = iRSI(_Symbol, _Period, rsiPeriod, PRICE_CLOSE);
   h_atr = iATR(_Symbol, _Period, atrPeriod);

   //--- Check for handle errors
   if(h_emaFast == INVALID_HANDLE || h_emaSlow == INVALID_HANDLE || h_adx == INVALID_HANDLE || h_rsi == INVALID_HANDLE || h_atr == INVALID_HANDLE)
   {
      Print("Error getting indicator handles. EA will not work.");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Release indicator handles
   IndicatorRelease(h_emaFast);
   IndicatorRelease(h_emaSlow);
   IndicatorRelease(h_adx);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_atr);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Check for new bar to run logic only once per bar
    static datetime lastBarTime = 0;
    datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);

    if(currentBarTime > lastBarTime)
    {
        lastBarTime = currentBarTime;
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
    if(position.SelectByMagic(_Symbol, magicNumber))
    {
        return;
    }

    //--- Get indicator values for the last 2 completed bars
    double emaFast[3], emaSlow[3], adx[2], rsi[2], atr[2];
    if(CopyBuffer(h_emaFast, 0, 1, 3, emaFast) < 3 ||
       CopyBuffer(h_emaSlow, 0, 1, 3, emaSlow) < 3 ||
       CopyBuffer(h_adx, 0, 1, 2, adx) < 2 || // ADX Main line
       CopyBuffer(h_rsi, 0, 1, 2, rsi) < 2 ||
       CopyBuffer(h_atr, 0, 1, 2, atr) < 2)
    {
        Print("Error copying indicator buffers");
        return;
    }

    //--- Define values for easier reading (index 0 is the most recently closed bar)
    double last_emaFast = emaFast[0];
    double last_emaSlow = emaSlow[0];
    double prior_emaFast = emaFast[1];
    double prior_emaSlow = emaSlow[1];

    double last_adx = adx[0];
    double last_rsi = rsi[0];
    double last_atr = atr[0];

    //--- Check for Buy Signal (Golden Cross)
    bool buySignal = (prior_emaFast <= prior_emaSlow) && // Prior bar's EMAs had not crossed or were crossed down
                     (last_emaFast > last_emaSlow) &&    // Last closed bar's fast EMA crossed above slow EMA
                     (last_adx > adxThreshold) &&
                     (last_rsi > 50);

    //--- Check for Sell Signal (Death Cross)
    bool sellSignal = (prior_emaFast >= prior_emaSlow) && // Prior bar's EMAs had not crossed or were crossed up
                      (last_emaFast < last_emaSlow) &&    // Last closed bar's fast EMA crossed below slow EMA
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
void OpenPosition(ENUM_ORDER_TYPE orderType, double atrValue)
{
    double price = SymbolInfoDouble(_Symbol, orderType == OP_BUY ? SYMBOL_ASK : SYMBOL_BID);
    double slPrice, tpPrice = 0; // No take profit, let the trailing stop manage it

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

    //--- Open the trade
    trade.PositionOpen(_Symbol, orderType, lotSize, price, slPrice, tpPrice, tradeComment);
}

//+------------------------------------------------------------------+
//| Calculate position size based on risk and SL distance            |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
    //--- Get account and symbol info
    double accountBalance = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = accountBalance * (riskPercent / 100.0);

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    //--- Check for division by zero
    if(slDistance <= 0 || tickValue <= 0 || tickSize <= 0)
    {
        Print("Cannot calculate lot size due to zero values in risk calculation inputs.");
        return 0.0;
    }

    //--- Calculate loss per lot
    double lossPerLot = slDistance / tickSize * tickValue;

    //--- Check for division by zero
    if(lossPerLot <= 0)
    {
        Print("Calculated loss per lot is zero or negative.");
        return 0.0;
    }

    //--- Calculate lot size
    double lotSize = riskAmount / lossPerLot;

    //--- Normalize and check against limits
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lotSize = floor(lotSize / lotStep) * lotStep;

    if(lotSize < minLot) lotSize = 0.0; // If calculated lot is less than minimum, do not trade
    if(lotSize > maxLot) lotSize = maxLot;

    return lotSize;
}

//+------------------------------------------------------------------+
//| Manage trailing stop for open positions                          |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(!position.SelectByMagic(_Symbol, magicNumber))
    {
        return; // No open position
    }

    double currentAtr = 0;
    double atrBuffer[1];
    if(CopyBuffer(h_atr, 0, 0, 1, atrBuffer) > 0)
    {
        currentAtr = atrBuffer[0];
    }
    else
    {
        return; // Can't get ATR, can't trail
    }

    double trailingStopDistance = currentAtr * atrTrailingStopMultiplier;
    double newStopLoss = 0;
    double currentStopLoss = position.StopLoss();
    double openPrice = position.PriceOpen();

    if(position.PositionType() == POSITION_TYPE_LONG)
    {
        double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        newStopLoss = currentPrice - trailingStopDistance;
        //--- Ensure new SL is above open price (locking in profit) and higher than existing SL
        if(newStopLoss > openPrice && newStopLoss > currentStopLoss)
        {
            trade.PositionModify(_Symbol, newStopLoss, position.TakeProfit());
        }
    }
    else if(position.PositionType() == POSITION_TYPE_SHORT)
    {
        double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        newStopLoss = currentPrice + trailingStopDistance;
        //--- Ensure new SL is below open price (locking in profit) and lower than existing SL
        if(newStopLoss < openPrice && (newStopLoss < currentStopLoss || currentStopLoss == 0))
        {
            trade.PositionModify(_Symbol, newStopLoss, position.TakeProfit());
        }
    }
}
//+------------------------------------------------------------------+
