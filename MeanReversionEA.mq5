//+------------------------------------------------------------------+
//|                                            MeanReversionEA.mq5 |
//|        Copyright 2024, Jules the AI Software Engineer          |
//|                                                                  |
//|      EA based on Mean Reversion principles: ADX filter for       |
//|     ranging markets, Bollinger Bands, and RSI confirmation.      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules the AI Software Engineer"
#property link      "https://example.com"
#property version   "1.00"
#property description "A Mean Reversion EA using ADX, Bollinger Bands, and RSI."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- EA Inputs
input group "Magic Number & Comment"
input ulong    magicNumber = 654321;           // Magic Number for trades
input string   tradeComment = "MeanReversionEA"; // Trade comment

input group "Risk Management"
input double   riskPercent = 1.0;              // Risk percentage of account equity per trade
input double   atrStopLossMultiplier = 2.0;    // Multiplier for initial ATR-based Stop Loss

input group "Regime Filter (ADX)"
input int      adxPeriod = 14;                 // ADX period
input double   adxThreshold = 25.0;            // ADX must be BELOW this to trade

input group "Entry Signal (Bollinger Bands)"
input int      bbPeriod = 20;                  // Bollinger Bands period
input double   bbDeviation = 2.0;              // Bollinger Bands deviation

input group "Confirmation Filter (RSI)"
input int      rsiPeriod = 14;                 // RSI period
input double   rsiOverbought = 70.0;           // RSI Overbought level
input double   rsiOversold = 30.0;             // RSI Oversold level

input group "Volatility (ATR for Stop-Loss)"
input int      atrPeriod = 14;                 // ATR period

//--- Global variables
CTrade        trade;
CPositionInfo position;
int           h_adx, h_bb, h_rsi, h_atr;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize trading object
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- Get indicator handles
   h_adx = iADX(_Symbol, _Period, adxPeriod);
   h_bb = iBands(_Symbol, _Period, bbPeriod, 0, bbDeviation, PRICE_CLOSE);
   h_rsi = iRSI(_Symbol, _Period, rsiPeriod, PRICE_CLOSE);
   h_atr = iATR(_Symbol, _Period, atrPeriod);

   //--- Check for handle errors
   if(h_adx == INVALID_HANDLE || h_bb == INVALID_HANDLE || h_rsi == INVALID_HANDLE || h_atr == INVALID_HANDLE)
   {
      Print("Error getting indicator handles. EA cannot work.");
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
   IndicatorRelease(h_adx);
   IndicatorRelease(h_bb);
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
    if(position.SelectByMagic(_Symbol, magicNumber))
    {
        return;
    }

    //--- Get indicator values for the last 3 bars
    double adx[2], bb_upper[3], bb_lower[3], bb_middle[2], rsi[2], atr[2], close[3];

    if(CopyBuffer(h_adx, 0, 1, 2, adx) < 2 ||
       CopyBuffer(h_bb, 0, 1, 3, bb_upper) < 3 || // Upper Band
       CopyBuffer(h_bb, 1, 1, 2, bb_middle) < 2 || // Middle Band
       CopyBuffer(h_bb, 2, 1, 3, bb_lower) < 3 || // Lower Band
       CopyBuffer(h_rsi, 0, 1, 2, rsi) < 2 ||
       CopyBuffer(h_atr, 0, 1, 2, atr) < 2 ||
       CopyClose(_Symbol, _Period, 1, 3, close) < 3)
    {
        Print("Error copying indicator buffers.");
        return;
    }

    //--- Regime Filter: Only trade in ranging markets
    if(adx[0] >= adxThreshold)
    {
        return; // Market is trending, do not trade
    }

    //--- Buy Signal Logic
    bool buySetup = close[1] < bb_lower[1]; // Bar before last closed outside
    bool buyTrigger = close[0] > bb_lower[0]; // Last bar closed back inside
    bool buyConfirm = rsi[0] < rsiOversold;

    if(buySetup && buyTrigger && buyConfirm)
    {
        OpenPosition(ORDER_TYPE_BUY, atr[0], bb_middle[0]);
        return; // Stop after opening a trade
    }

    //--- Sell Signal Logic
    bool sellSetup = close[1] > bb_upper[1]; // Bar before last closed outside
    bool sellTrigger = close[0] < bb_upper[0]; // Last bar closed back inside
    bool sellConfirm = rsi[0] > rsiOverbought;

    if(sellSetup && sellTrigger && sellConfirm)
    {
        OpenPosition(ORDER_TYPE_SELL, atr[0], bb_middle[0]);
    }
}

//+------------------------------------------------------------------+
//| Open a new position                                              |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType, double atrValue, double tpPrice)
{
    double price = SymbolInfoDouble(_Symbol, orderType == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
    double slPrice;

    //--- Calculate Stop Loss price based on ATR
    double slDistance = atrValue * atrStopLossMultiplier;
    if(orderType == ORDER_TYPE_BUY)
    {
        slPrice = price - slDistance;
    }
    else // ORDER_TYPE_SELL
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
    double accountBalance = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = accountBalance * (riskPercent / 100.0);

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

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

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lotSize = floor(lotSize / lotStep) * lotStep;

    if(lotSize < minLot) lotSize = 0.0;
    if(lotSize > maxLot) lotSize = maxLot;

    return lotSize;
}
//+------------------------------------------------------------------+
