//+------------------------------------------------------------------+
//|                                                 CarryTradeEA.mq5 |
//|        Copyright 2024, Jules the AI Software Engineer          |
//|                                                                  |
//|      EA based on FX Carry Trade principles: positive swap,       |
//|         low volatility, and trend-following filter.              |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules the AI Software Engineer"
#property link      "https://example.com"
#property version   "1.00"
#property description "A Carry Trade EA using swap rates, trend and volatility filters."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- EA Inputs
input group "Magic Number & Comment"
input ulong    magicNumber = 97531;            // Magic Number for trades
input string   tradeComment = "CarryTradeEA";    // Trade comment

input group "Risk Management"
input double   riskPercent = 1.0;              // Risk percentage of account equity per trade
input double   atrStopLossMultiplier = 2.0;    // Multiplier for initial ATR-based Stop Loss

input group "Trend Filter Settings"
input int      smaPeriod = 200;                // Period for the long-term SMA trend filter

input group "Volatility Filter Settings"
input int      atrPeriod = 14;                 // ATR period for volatility measurement
input int      atrLookback = 100;              // Lookback for ATR's own moving average

//--- Global variables
CTrade        trade;
CPositionInfo position;
int           h_sma_daily, h_atr_daily;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize trading object
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- Get indicator handles for the daily timeframe
   h_sma_daily = iMA(_Symbol, PERIOD_D1, smaPeriod, 0, MODE_SMA, PRICE_CLOSE);
   h_atr_daily = iATR(_Symbol, PERIOD_D1, atrPeriod);

   //--- Check for handle errors
   if(h_sma_daily == INVALID_HANDLE || h_atr_daily == INVALID_HANDLE)
   {
      Print("Error getting daily indicator handles. EA cannot work.");
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
   IndicatorRelease(h_sma_daily);
   IndicatorRelease(h_atr_daily);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Use a static variable to check for a new day
    static datetime last_check_time = 0;
    datetime current_day_bar_time = (datetime)SeriesInfoInteger(_Symbol, PERIOD_D1, SERIES_LASTBAR_DATE);

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
    if(position.SelectByMagic(_Symbol, magicNumber))
    {
        return;
    }

    //--- Get indicator values from the last completed day
    double sma_val[1], close_val[1];
    if(CopyBuffer(h_sma_daily, 0, 1, 1, sma_val) < 1 || CopyClose(_Symbol, PERIOD_D1, 1, 1, close_val) < 1)
    {
        Print("Error copying daily SMA or Close data for entry check.");
        return;
    }

    //--- Volatility Filter: Check if current ATR is below its long-term average
    double atr_buffer[];
    int data_to_copy = atrLookback + 1; // Get enough data for the lookback period
    if(CopyBuffer(h_atr_daily, 0, 1, data_to_copy, atr_buffer) < data_to_copy)
    {
        Print("Error copying daily ATR data for volatility filter.");
        return;
    }
    double current_atr = atr_buffer[0];
    double sum_atr = 0;
    for(int i = 1; i <= atrLookback; i++)
    {
        sum_atr += atr_buffer[i];
    }
    double avg_atr = (atrLookback > 0) ? sum_atr / atrLookback : 0;

    bool is_low_volatility = (current_atr < avg_atr);

    //--- Get Swap Rates
    double swap_long = SymbolInfoDouble(_Symbol, SYMBOL_SWAP_LONG);
    double swap_short = SymbolInfoDouble(_Symbol, SYMBOL_SWAP_SHORT);

    //--- Check for Long Entry
    if(swap_long > 0 && close_val[0] > sma_val[0] && is_low_volatility)
    {
        OpenPosition(ORDER_TYPE_BUY, current_atr);
    }
    //--- Check for Short Entry
    else if(swap_short > 0 && close_val[0] < sma_val[0] && is_low_volatility)
    {
        OpenPosition(ORDER_TYPE_SELL, current_atr);
    }
}

//+------------------------------------------------------------------+
//| Manage exit conditions for open positions (runs once per day)    |
//+------------------------------------------------------------------+
void ManageExit()
{
    //--- Check if a position is open
    if(!position.SelectByMagic(_Symbol, magicNumber))
    {
        return;
    }

    //--- Get indicator values from the last completed day
    double sma_val[1], close_val[1];
    if(CopyBuffer(h_sma_daily, 0, 1, 1, sma_val) < 1 || CopyClose(_Symbol, PERIOD_D1, 1, 1, close_val) < 1)
    {
        Print("Error copying daily SMA or Close data for exit management.");
        return;
    }

    //--- Exit condition: Price closes across the daily SMA
    if(position.PositionType() == POSITION_TYPE_BUY && close_val[0] < sma_val[0])
    {
        trade.PositionClose(position.Ticket(), 3);
        Print("Closed LONG position due to daily close below daily SMA.");
    }
    else if(position.PositionType() == POSITION_TYPE_SELL && close_val[0] > sma_val[0])
    {
        trade.PositionClose(position.Ticket(), 3);
        Print("Closed SHORT position due to daily close above daily SMA.");
    }
}

//+------------------------------------------------------------------+
//| Open a new position                                              |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType, double atrValue)
{
    double price = SymbolInfoDouble(_Symbol, orderType == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
    double slPrice, tpPrice = 0;

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

    //--- Construct dynamic comment. Note: Carry trade logic is daily, but comment reflects chart TF.
    string dynamic_comment = StringFormat("%s | %s | %s", _Symbol, PeriodToString(_Period), tradeComment);

    //--- Open the trade
    if(trade.PositionOpen(_Symbol, orderType, lotSize, price, slPrice, tpPrice, dynamic_comment))
    {
       //--- Verify the trade was opened with the correct parameters
       VerifyTradeParameters(trade.ResultPosition(), slPrice, tpPrice, dynamic_comment);
    }
}

//+------------------------------------------------------------------+
//| Verify and correct SL/TP for a newly opened position             |
//+------------------------------------------------------------------+
void VerifyTradeParameters(ulong position_ticket, double intended_sl, double intended_tp, string intended_comment)
{
    //--- Give the trade server a moment to process
    Sleep(500);

    if(!position.SelectByTicket(position_ticket))
    {
        Print("Failed to select position by ticket #", position_ticket, " for verification.");
        return;
    }

    double current_sl = position.StopLoss();
    double current_tp = position.TakeProfit();
    string intended_comment = tradeComment;
    string current_comment = position.Comment();

    bool sl_ok = (MathAbs(current_sl - intended_sl) < _Point);
    bool tp_ok = (intended_tp == 0 && current_tp == 0) || (MathAbs(current_tp - intended_tp) < _Point);
    bool comment_ok = (current_comment == intended_comment);

    if(sl_ok && tp_ok)
    {
        if(!comment_ok)
        {
            Print("Warning: Position #", position_ticket, " comment mismatch. Expected: '", intended_comment, "', Found: '", current_comment, "'. Cannot modify comment.");
        }
        return;
    }

    //--- If SL or TP are incorrect, attempt to modify
    Print("Position #", position_ticket, " parameter mismatch. SL OK: ", sl_ok, ", TP OK: ", tp_ok, ". Attempting to modify.");

    if(!trade.PositionModify(position_ticket, intended_sl, intended_tp))
    {
        Print("PositionModify failed for ticket #", position_ticket, ". Error: ", GetLastError());
    }
    else
    {
        Print("Successfully modified position #", position_ticket, " to correct SL/TP.");
    }
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
        Print("Cannot calculate lot size due to zero values in risk calculation inputs (slDistance, tickValue, or tickSize).");
        return 0.0;
    }

    double lossPerLot = slDistance / tickSize * tickValue;

    if(lossPerLot <= 0)
    {
        Print("Calculated loss per lot is zero or negative, cannot calculate lot size.");
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
