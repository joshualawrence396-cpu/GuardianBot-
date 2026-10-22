//+------------------------------------------------------------------+
//|                                                  GuardianBot.mq5 |
//|                        MT5 Guardian EA - trendline break + sweep |
//+------------------------------------------------------------------+
//| Spec: GuardianBot build spec (Devin task).                        |
//|  Module 1  : Account-wide Profit Guardian (daily/weekly locks)   |
//|  Module 2A : Strategy A - M5 trendline break w/ confirmations    |
//|  Module 2B : Strategy B - M15 session liquidity sweep & reclaim  |
//|  Module 3  : Economic-calendar news gate for gold                |
//|  Module 9  : Shared risk, sizing, spread/time filters, breakeven |
//| NOTE: All times are broker server time. Demo use only.           |
//+------------------------------------------------------------------+
#property copyright "GuardianBot"
#property version   "1.00"
#property strict
#property description "Guardian EA: profit/loss lockout + two configurable strategies."
#property description "Demo use only. No profitability is implied."

#include <Trade/Trade.mqh>

//--- Strategy selector
enum ENUM_STRATEGY_MODE
  {
   TRENDBREAK    = 0,   // Strategy A only
   SESSION_SWEEP = 1,   // Strategy B only
   BOTH          = 2,   // Both strategies from one chart
   PULLBACK      = 3,   // Strategy C: H1 trend + TrendTF pullback (V75)
   STRUCTURE     = 4,   // Strategy D: H4 bias + zone + sweep + BOS (V75)
   PULLBACK_GOLD = 5    // Strategy C on trend leg + Strategy B on gold
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Strategy selector ==="
input ENUM_STRATEGY_MODE StrategyMode   = PULLBACK;        // Which strategies are active
input string             TrendSymbol    = "";              // Strategy A symbol (empty = chart symbol)
input string             GoldSymbol     = "XAUUSD";        // Strategy B symbol (broker suffix allowed)
input ENUM_TIMEFRAMES    TrendTF        = PERIOD_M15;      // Entry timeframe (M15 tested best)
input ENUM_TIMEFRAMES    GoldTF         = PERIOD_M15;      // Strategy B timeframe

input group "=== Profit Guardian (account-wide, deposit currency) ==="
input double DailyProfitTarget   = 5.0;     // Daily profit target (0 = disabled)
input double WeeklyProfitTarget  = 15.0;    // Weekly profit target (0 = disabled)
input double DailyMaxLoss        = 5.0;     // Daily max loss (0 = disabled)
input bool   GuardAllSymbols     = true;    // Lock enforcement scope: all symbols

input group "=== Strategy A: trendline break ==="
input int    BuyConfirmCandles   = 2;       // Bullish confirmations after break
input int    SellConfirmCandles  = 3;       // Bearish confirmations after break
input bool   AllowBuys           = true;
input bool   AllowSells          = true;    // Mixed + BE0.75R netted +$141 vs buys-only +$128
input bool   UseManualLines      = false;   // Use manually drawn OBJ_TREND lines
input int    SwingStrength       = 3;       // Fractal strength (bars each side)
input int    Lookback            = 120;     // Bars to search for swings
input int    MinSwingGap         = 6;       // Min bars between anchors
input int    CleanBars           = 8;       // Bars before break on original side
input int    TrendFilterEMA      = 0;       // EMA trend filter on TrendTF (0 = off)

input group "=== Strategy C: trend pullback (H1 filter + TrendTF entry) ==="
input int    H1EMAPeriod         = 50;      // Trend filter EMA period on H1
input int    EntryEMAPeriod      = 20;      // Pullback EMA period on TrendTF
input double ChopFilterPoints    = 2000;    // Min H1 close-EMA distance to avoid chop (0 = off)
input int    PullbackBars        = 3;       // Pullback must touch EMA20 within last N bars
input int    PullbackSwingBars   = 10;      // SL = extreme of last N bars
input bool   UseSRRetest         = true;    // Also allow retest of recent swing level
input int    SRLookback          = 40;      // Bars for support/resistance level
input bool   UseBreakoutEntries  = false;   // Range-breakout alternative entries
input int    RangeBars           = 20;      // Consolidation range lookback
input double MaxRangePoints      = 0;       // Max range width to count as consolidation (0 = off)
input bool   BreakoutStopMidpoint = false;  // SL at range midpoint instead of far side
input bool   H1StructConfirm     = true;    // Require H1 HH/HL (buys) or LH/LL (sells)
input bool   PullbackEMA20       = true;    // EMA20 touch on TrendTF counts as pullback
input bool   PullbackEMA50       = true;    // EMA50 touch on TrendTF also counts as pullback
input double EntryMinBodyPct     = 50;      // Signal-candle body >= this %% of range (0 = any)
input double SellMinBodyPct      = -1;      // Sell signal body %% (-1 = use EntryMinBodyPct)
input bool   UseEngulfing        = true;    // Engulfing candle counts as entry trigger
input bool   UseRSIConfirm       = false;   // RSI(14) must agree: buys >50, sells <50
input int    RSIPeriod           = 14;      // RSI period on TrendTF
input double SellRSIMax          = 0;       // Sells only when RSI(14) below this (0 = off)
input double MoneySL_USD         = 0;       // Fixed risk per trade in deposit ccy (0 = structure SL)
input double MoneyTP_USD         = 0;       // Fixed TP in deposit ccy (0 = RiskReward x SL)
input double MoneySLGold_USD     = 0;       // Gold-leg risk/trade (0 = use MoneySL_USD, -1 = structure SL)
input double MoneyTPGold_USD     = 0;       // Gold-leg TP in ccy (0 = use MoneyTP_USD)
input double MilestoneStep       = 0;       // Balance milestone step for risk scaling (0 = off)
input double MilestoneRiskUSD    = 0;       // Risk $ per milestone step (needs MoneySL_USD>0)

input group "=== Strategy D: structure sweep (H4 bias + entry BOS) ==="
input int    H4SwingStrength     = 2;       // H4 fractal strength for structure
input int    ZoneLookback        = 48;      // H1 bars for S/R zone
input double ZoneTolerancePoints = 3000;    // Sweep must occur near the H1 zone level
input double MinPullbackPoints   = 1000;    // Min drop/rise from H1 extreme to count as pullback (0 = off)
input int    SweepLookback       = 60;      // Entry-TF bars for the swept level
input int    SweepMaxAge         = 8;       // Sweep candle must be within last N bars
input int    MinorBars           = 5;       // Bars between sweep and now for minor-structure BOS
input int    MaxConsecLossesDay  = 2;       // Stop after N consecutive losses today (0 = off)

input group "=== Strategy B: session sweep (server-time hours) ==="
input int AsianStartHour  = 0;              // Asian session start (0-23)
input int AsianEndHour    = 6;              // Asian session end (1-24)
input int LondonStartHour = 8;              // London session start (0-23)
input int LondonEndHour   = 11;             // London session end (1-24)
input int MinSweepPoints  = 20;             // Min sweep beyond level (points)

input group "=== Shared risk & execution ==="
input int    SLBufferPoints   = 50;         // SL buffer beyond setup extreme (points)
input double RiskReward       = 2.0;        // TP = RiskReward x risk
input double SellRiskReward   = 0;          // Sell TP ratio (0 = use RiskReward)
input double BreakevenAtR     = 0.75;       // Move SL to entry at this R (0 = off); 0.75R won the sweep
input double SellBreakevenAtR = -1;         // Sell BE trigger (-1 = use BreakevenAtR)
input int    MaxTradesPerDay  = 5;          // Daily EA entry cap (0 = unlimited)
input int    MaxSpreadPoints  = 0;          // Max spread in points (0 = off)
input double RiskPercent      = 0;          // % equity risked per trade (0 = fixed lot)
input double FixedLot         = 0.05;       // Lot when RiskPercent = 0 (V75 min is 0.05)
input double FixedLotGold     = 0;          // Gold-leg lot when RiskPercent = 0 (0 = use FixedLot)
input double TrailStartR      = 0;          // Trail SL once profit >= this x risk (0 = off)
input double TrailDistR       = 0.5;        // Trail distance behind price (x risk)
input bool   PyramidEnabled   = false;      // Allow add-on entry when position is in profit
input double PyramidMinProfitR= 1.0;        // Min open profit (x initial risk) to pyramid
input int    TradeStartHour   = 0;          // Trading window start (0-23)
input int    TradeEndHour     = 24;         // Trading window end (1-24)
input long   Magic            = 777002;     // EA magic number

input group "=== News filter (gold only, MT5 calendar) ==="
input bool   UseNewsFilterGold   = true;    // Enable news gate for gold entries
input ENUM_CALENDAR_EVENT_IMPORTANCE NewsMinImportance = CALENDAR_IMPORTANCE_HIGH;
input int    NewsMinsBefore      = 30;      // Block window before event (min)
input int    NewsMinsAfter       = 30;      // Block window after event (min)
input bool   CloseBeforeNews     = false;   // Close EA gold positions in window
input string NewsCurrencies      = "USD";   // Comma-separated currencies to watch

//+------------------------------------------------------------------+
//| Constants / globals                                              |
//+------------------------------------------------------------------+
#define DEVIATION_POINTS 50
#define NEWS_CACHE_SEC   60
#define LOG_THROTTLE_SEC 60

CTrade   trade;

string   g_trendSymbol   = "";
string   g_goldSymbol    = "";
bool     g_trendActive   = false;   // Strategy A leg enabled
bool     g_goldActive    = false;   // Strategy B leg enabled
string   g_currency      = "";      // account deposit currency
long     g_login         = 0;

//--- new-bar tracking
datetime g_lastTrendBar = 0;
datetime g_lastGoldBar  = 0;
int      g_emaHandle    = INVALID_HANDLE;
int      g_emaH1        = INVALID_HANDLE;   // Strategy C trend filter
int      g_emaEntry     = INVALID_HANDLE;   // Strategy C pullback EMA
int      g_ema50T       = INVALID_HANDLE;   // Strategy C EMA50 on TrendTF
int      g_rsi          = INVALID_HANDLE;   // Strategy C RSI on TrendTF

//--- signal dedupe (per signal candle time)
datetime g_lastBuyBreakBar  = 0;
datetime g_lastSellBreakBar = 0;
datetime g_lastSweepBar     = 0;
datetime g_lastPbBuyBar     = 0;
datetime g_lastPbSellBar    = 0;
datetime g_lastStBuyBar     = 0;
datetime g_lastStSellBar    = 0;

//--- guardian state
datetime g_dayStart   = 0;
datetime g_weekStart  = 0;
double   g_dailyPL    = 0.0;
double   g_weeklyPL   = 0.0;
bool     g_plValid    = false;
bool     g_dailyLock  = false;
bool     g_weeklyLock = false;
string   g_lockReason = "";
string   g_gvDay      = "";         // GlobalVariable names
string   g_gvWeek     = "";
string   g_gvSigAB    = "";         // last BUY break-candle time (restart dedupe)
string   g_gvSigAS    = "";         // last SELL break-candle time
string   g_gvSigB     = "";         // last sweep signal-candle time
string   g_gvSigPB    = "";         // last pullback BUY signal-candle time
string   g_gvSigPS    = "";         // last pullback SELL signal-candle time
string   g_gvSigDB    = "";         // last structure BUY signal-candle time
string   g_gvSigDS    = "";         // last structure SELL signal-candle time

//--- news gate state
bool     g_newsBlocked    = false;
bool     g_newsAvail      = false;  // calendar query succeeded
string   g_newsReason     = "not checked";
datetime g_newsCheckedAt  = 0;
string   g_newsCurs[];              // parsed currency list

//--- breakeven tracking (initial risk per managed position)
struct BEInfo
  {
   ulong   ticket;
   double  risk;      // initial |entry - SL| in price
   bool    done;      // breakeven already applied
  };
BEInfo g_be[];

//--- log throttling
struct ThrottleEntry
  {
   string   key;
   datetime last;
  };
ThrottleEntry g_throttle[];

//--- last block reason for status panel
string g_lastBlockReason = "none";

//+------------------------------------------------------------------+
//| Logging helper: print each key at most once per LOG_THROTTLE_SEC |
//+------------------------------------------------------------------+
void LogT(const string key, const string msg)
  {
   datetime now = TimeTradeServer();
   int n = ArraySize(g_throttle);
   for(int i = 0; i < n; i++)
      if(g_throttle[i].key == key)
        {
         if(now - g_throttle[i].last < LOG_THROTTLE_SEC)
            return;
         g_throttle[i].last = now;
         Print(msg);
         return;
        }
   ArrayResize(g_throttle, n + 1);
   g_throttle[n].key  = key;
   g_throttle[n].last = now;
   Print(msg);
  }

void SetBlockReason(const string r) { g_lastBlockReason = r; }

//+------------------------------------------------------------------+
//| Broker server time                                               |
//+------------------------------------------------------------------+
datetime ServerTime()
  {
   datetime t = TimeTradeServer();
   if(t <= 0) t = TimeCurrent();
   return t;
  }

//+------------------------------------------------------------------+
//| Start of the current broker-server day                           |
//+------------------------------------------------------------------+
datetime DayStart(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
//| Start of the current broker-server week (Monday 00:00)           |
//+------------------------------------------------------------------+
datetime WeekStart(datetime t)
  {
   datetime d0 = DayStart(t);
   MqlDateTime dt;
   TimeToStruct(d0, dt);
   // day_of_week: 0=Sun ... 6=Sat. Days since Monday:
   int sinceMon = (dt.day_of_week + 6) % 7;
   return d0 - sinceMon * 86400;
  }

//+------------------------------------------------------------------+
//| Hour-in-window check supporting windows that cross midnight      |
//| Window is [startHour, endHour) in server hours.                  |
//+------------------------------------------------------------------+
bool HourInWindow(int hour, int startH, int endH)
  {
   if(startH == endH) return false;          // empty (validated against)
   if(startH < endH)  return (hour >= startH && hour < endH);
   return (hour >= startH || hour < endH);   // crosses midnight
  }

bool InTradeHours(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return HourInWindow(dt.hour, TradeStartHour, TradeEndHour);
  }

//+------------------------------------------------------------------+
//| Symbol helpers                                                   |
//+------------------------------------------------------------------+
double SymPoint(const string sym)   { return SymbolInfoDouble(sym, SYMBOL_POINT); }
int    SymDigits(const string sym)  { return (int)SymbolInfoInteger(sym, SYMBOL_DIGITS); }

double NormPrice(const string sym, double price)
  { return NormalizeDouble(price, SymDigits(sym)); }

// floor a volume to the symbol step and normalise its precision
double FloorToStep(double vol, double step, int vDigits)
  {
   if(step <= 0.0) return -1.0;
   vol = MathFloor(vol / step + 1e-9) * step;
   return NormalizeDouble(vol, vDigits);
  }

int VolumeDigits(double step)
  {
   int d = 0;
   double s = step;
   while(s < 1.0 - 1e-9 && d < 8) { s *= 10.0; d++; }
   return d;
  }

bool SpreadOK(const string sym)
  {
   if(MaxSpreadPoints <= 0) return true;
   long spread = SymbolInfoInteger(sym, SYMBOL_SPREAD);
   if(spread < 0)
     {
      SetBlockReason("spread unavailable for " + sym);
      return false;
     }
   if(spread > MaxSpreadPoints)
     {
      SetBlockReason(StringFormat("spread %d > max %d on %s",
                                  (int)spread, MaxSpreadPoints, sym));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Closed trading P/L in [from,to): buy/sell deals only             |
//| Returns true on success, false if HistorySelect failed.          |
//+------------------------------------------------------------------+
bool ClosedPL(datetime from, datetime to, double &pl)
  {
   pl = 0.0;
   if(!HistorySelect(from, to))
      return false;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      long type = HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;                       // skip balance/credit ops
      pl += HistoryDealGetDouble(ticket, DEAL_PROFIT)
          + HistoryDealGetDouble(ticket, DEAL_SWAP)
          + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
          + HistoryDealGetDouble(ticket, DEAL_FEE);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Floating P/L of all open positions (account-wide)                |
//+------------------------------------------------------------------+
double FloatingPL()
  {
   double pl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      pl += PositionGetDouble(POSITION_PROFIT)
          + PositionGetDouble(POSITION_SWAP);
     }
   return pl;
  }

//+------------------------------------------------------------------+
//| Guardian: refresh P/L and lock state                             |
//+------------------------------------------------------------------+
void GuardianUpdate()
  {
   datetime now = ServerTime();
   g_dayStart  = DayStart(now);
   g_weekStart = WeekStart(now);

   double closedD, closedW;
   bool okD = ClosedPL(g_dayStart,  now + 60, closedD);
   bool okW = ClosedPL(g_weekStart, now + 60, closedW);
   g_plValid = (okD && okW);
   if(!g_plValid)
      LogT("pl_fail", "Guardian: HistorySelect failed - P/L unreliable, guardian still enforces any stored lock.");

   double fl = FloatingPL();
   g_dailyPL  = (okD ? closedD : 0.0) + fl;
   g_weeklyPL = (okW ? closedW : 0.0) + fl;

   //--- read persisted locks (active only for the current period)
   bool storedD = false, storedW = false;
   if(GlobalVariableCheck(g_gvDay))
      storedD = ((datetime)GlobalVariableGet(g_gvDay) == g_dayStart);
   if(GlobalVariableCheck(g_gvWeek))
      storedW = ((datetime)GlobalVariableGet(g_gvWeek) == g_weekStart);

   //--- latch new locks when thresholds are crossed
   if(g_plValid && !storedD)
     {
      bool hitProfit = (DailyProfitTarget > 0 && g_dailyPL >= DailyProfitTarget);
      bool hitLoss   = (DailyMaxLoss > 0 && g_dailyPL <= -DailyMaxLoss);
      if(hitProfit || hitLoss)
        {
         GlobalVariableSet(g_gvDay, (double)g_dayStart);
         storedD = true;
         PrintFormat("Guardian: DAILY LOCK set (day P/L %.2f %s, %s).",
                     g_dailyPL, g_currency,
                     hitProfit ? "profit target" : "max loss");
        }
     }
   if(g_plValid && !storedW && WeeklyProfitTarget > 0 && g_weeklyPL >= WeeklyProfitTarget)
     {
      GlobalVariableSet(g_gvWeek, (double)g_weekStart);
      storedW = true;
      PrintFormat("Guardian: WEEKLY LOCK set (week P/L %.2f %s).",
                  g_weeklyPL, g_currency);
     }

   bool wasLocked = (g_dailyLock || g_weeklyLock);
   g_dailyLock = storedD;
   g_weeklyLock = storedW;

   g_lockReason =
      g_weeklyLock ? "weekly profit target reached" :
      g_dailyLock  ? (g_plValid && DailyMaxLoss > 0 && g_dailyPL <= -DailyMaxLoss
                      ? "daily max loss reached" : "daily threshold reached") :
      "";

   if((g_dailyLock || g_weeklyLock) && !wasLocked)
      Print("Guardian: account locked - " + g_lockReason);
   if(!(g_dailyLock || g_weeklyLock) && wasLocked)
      Print("Guardian: lock released (new period started).");
  }

//+------------------------------------------------------------------+
//| Enforcement scope: is this symbol in scope while locked?         |
//+------------------------------------------------------------------+
bool InEnforcementScope(const string sym)
  {
   if(GuardAllSymbols) return true;
   return (sym == g_trendSymbol || sym == g_goldSymbol);
  }

//+------------------------------------------------------------------+
//| While locked: close positions + delete pendings, retry on fail   |
//+------------------------------------------------------------------+
void GuardianEnforce()
  {
   if(!(g_dailyLock || g_weeklyLock)) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!InEnforcementScope(sym)) continue;
      trade.SetTypeFillingBySymbol(sym);
      if(!trade.PositionClose(ticket))
         LogT("close_fail_" + (string)ticket,
              StringFormat("Guardian: close failed ticket=%I64u %s retcode=%d %s",
                           ticket, sym, trade.ResultRetcode(),
                           trade.ResultRetcodeDescription()));
      else
         PrintFormat("Guardian: closed position ticket=%I64u %s retcode=%d",
                     ticket, sym, trade.ResultRetcode());
     }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      string sym = OrderGetString(ORDER_SYMBOL);
      if(!InEnforcementScope(sym)) continue;
      if(!trade.OrderDelete(ticket))
         LogT("del_fail_" + (string)ticket,
              StringFormat("Guardian: order delete failed ticket=%I64u %s retcode=%d %s",
                           ticket, sym, trade.ResultRetcode(),
                           trade.ResultRetcodeDescription()));
      else
         PrintFormat("Guardian: deleted pending order ticket=%I64u %s", ticket, sym);
     }
  }

//+------------------------------------------------------------------+
//| One open EA position per symbol + magic?                         |
//+------------------------------------------------------------------+
bool ManagedPositionExists(const string sym)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym &&
         PositionGetInteger(POSITION_MAGIC) == Magic)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Pyramid gate: existing managed position is profitable enough     |
//+------------------------------------------------------------------+
bool PyramidOK(const string sym)
  {
   if(!PyramidEnabled) return false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double risk = 0.0;
      string rn = GVBEName(ticket);
      if(GlobalVariableCheck(rn)) risk = GlobalVariableGet(rn);
      else if(sl > 0.0) risk = MathAbs(open - sl);
      if(risk <= 0.0) return false;
      double profitDist = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                          ? SymbolInfoDouble(sym, SYMBOL_BID) - open
                          : open - SymbolInfoDouble(sym, SYMBOL_ASK);
      return (profitDist >= PyramidMinProfitR * risk);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Entry permission: flat OR profitable enough to pyramid           |
//+------------------------------------------------------------------+
bool EntryOKForSymbol(const string sym)
  {
   if(!ManagedPositionExists(sym)) return true;
   return PyramidOK(sym);
  }

//+------------------------------------------------------------------+
//| Count today's EA entries. Distinct DEAL_POSITION_ID are counted  |
//| so partial fills of one position are not double-counted.         |
//+------------------------------------------------------------------+
int TodayEntryCount()
  {
   if(!HistorySelect(g_dayStart, ServerTime() + 60))
      return -1;
   ulong posIds[];
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != Magic) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      ulong pid = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      bool seen = false;
      int m = ArraySize(posIds);
      for(int j = 0; j < m; j++)
         if(posIds[j] == pid) { seen = true; break; }
      if(!seen)
        {
         ArrayResize(posIds, m + 1);
         posIds[m] = pid;
        }
     }
   return ArraySize(posIds);
  }

//+------------------------------------------------------------------+
//| Lot sizing. Returns false -> skip trade (never raise risk).      |
//+------------------------------------------------------------------+
bool CalcVolume(const string sym, double entry, double sl, double &vol)
  {
   vol = 0.0;
   double vmin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(vmin <= 0 || vmax <= 0 || vstep <= 0)
     {
      SetBlockReason("invalid volume limits on " + sym);
      return false;
     }
   int vd = VolumeDigits(vstep);

   if(RiskPercent <= 0.0)
     {
      double fl = (g_goldActive && sym == g_goldSymbol && FixedLotGold > 0)
                  ? FixedLotGold : FixedLot;
      vol = FloorToStep(fl, vstep, vd);
      if(vol < vmin) { SetBlockReason("FixedLot below volume min"); return false; }
      if(vol > vmax) vol = FloorToStep(vmax, vstep, vd);
      return (vol >= vmin);
     }

   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0)
     {
      SetBlockReason("tick value/size unavailable on " + sym);
      return false;
     }
   double stopDist = MathAbs(entry - sl);
   if(stopDist <= 0) { SetBlockReason("zero stop distance"); return false; }

   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercent / 100.0;
   double lossPerLot = (stopDist / tickSize) * tickVal;
   if(lossPerLot <= 0) { SetBlockReason("cannot compute per-lot risk"); return false; }

   vol = FloorToStep(riskMoney / lossPerLot, vstep, vd);
   if(vol < vmin)
     {
      SetBlockReason(StringFormat("risk-sized volume %.*f below min %.*f - skipped",
                                  vd, vol, vd, vmin));
      return false;                       // never bump up and increase risk
     }
   if(vol > vmax) vol = FloorToStep(vmax, vstep, vd);
   if(vol < vmin) { SetBlockReason("volume clamp failed"); return false; }

   double estRisk = vol * lossPerLot;
   PrintFormat("Sizing %s: risk %.2f %s -> %.*f lots (est. risk %.2f %s)",
               sym, riskMoney, g_currency, vd, vol, estRisk, g_currency);
   return true;
  }

//+------------------------------------------------------------------+
//| Stops-level validation                                           |
//+------------------------------------------------------------------+
bool StopsValid(const string sym, bool isBuy, double entry, double sl, double tp)
  {
   double pt = SymPoint(sym);
   long stopsLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLvl * pt;
   double slDist = MathAbs(entry - sl);
   double tpDist = MathAbs(tp - entry);
   if(slDist < minDist || tpDist < minDist)
     {
      SetBlockReason(StringFormat("stops too close on %s (need %.1f pt)",
                                  sym, minDist / pt));
      return false;
     }
   if(isBuy  && (sl >= entry || tp <= entry)) { SetBlockReason("invalid buy SL/TP"); return false; }
   if(!isBuy && (sl <= entry || tp >= entry)) { SetBlockReason("invalid sell SL/TP"); return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Consecutive losing closes today (EA magic)                       |
//+------------------------------------------------------------------+
int TodayConsecLosses()
  {
   datetime now = ServerTime();
   MqlDateTime dt; TimeToStruct(now, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   if(!HistorySelect(StructToTime(dt), now)) return -1;
   int streak = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != Magic) continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      double p = HistoryDealGetDouble(tk, DEAL_PROFIT)
               + HistoryDealGetDouble(tk, DEAL_SWAP)
               + HistoryDealGetDouble(tk, DEAL_COMMISSION);
      if(p < 0) streak++;
      else break;
     }
   return streak;
  }

//+------------------------------------------------------------------+
//| Shared entry path: all gates, then send order                    |
//+------------------------------------------------------------------+
bool TryEnter(const string sym, bool isBuy, double sl, string tag, double tpIn = -1, double rrIn = 0)
  {
   //--- guardian lock
   if(g_dailyLock || g_weeklyLock)
     { SetBlockReason("guardian lock: " + g_lockReason); return false; }
   if(!g_plValid)
     { SetBlockReason("P/L unverified - entries blocked"); return false; }
   //--- symbol selectable + tradable
   if(!SymbolSelect(sym, true))
     { SetBlockReason("symbol not selectable: " + sym); return false; }
   long tmode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(tmode != SYMBOL_TRADE_MODE_FULL)
     { SetBlockReason("trade mode not full on " + sym); return false; }
   //--- terminal/account permissions
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     { SetBlockReason("trading not allowed (terminal/account)"); return false; }
   //--- one position per symbol+magic (unless pyramid criteria met)
   if(!EntryOKForSymbol(sym))
     { SetBlockReason("position already open on " + sym); return false; }
   //--- daily entry cap (shared across both strategies)
   if(MaxTradesPerDay > 0)
     {
      int cnt = TodayEntryCount();
      if(cnt < 0) { SetBlockReason("entry count unavailable"); return false; }
      if(cnt >= MaxTradesPerDay)
        { SetBlockReason("daily entry cap reached"); return false; }
     }
   //--- consecutive-loss circuit breaker
   if(MaxConsecLossesDay > 0)
     {
      int streak = TodayConsecLosses();
      if(streak < 0) { SetBlockReason("loss streak unavailable"); return false; }
      if(streak >= MaxConsecLossesDay)
        { SetBlockReason("consecutive daily losses"); return false; }
     }
   //--- time + spread
   if(!InTradeHours(ServerTime()))
     { SetBlockReason("outside trading hours"); return false; }
   if(!SpreadOK(sym)) return false;
   //--- news gate (gold only)
   if(sym == g_goldSymbol && UseNewsFilterGold)
     {
      if(!g_newsAvail)
        { SetBlockReason("news calendar unavailable - gold blocked (fail-closed)"); return false; }
      if(g_newsBlocked)
        { SetBlockReason("news gate: " + g_newsReason); return false; }
     }
   //--- quotes
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
     { SetBlockReason("quotes unavailable on " + sym); return false; }
   double entry = isBuy ? ask : bid;
   sl = NormPrice(sym, sl);
   double risk = MathAbs(entry - sl);
   if(risk <= 0) { SetBlockReason("zero risk distance"); return false; }
   double rr = rrIn > 0 ? rrIn : RiskReward;
   double tp = NormPrice(sym, tpIn > 0 ? tpIn
                         : isBuy ? entry + rr * risk
                                 : entry - rr * risk);
   if(!StopsValid(sym, isBuy, entry, sl, tp)) return false;
   //--- volume
   double vol;
   if(!CalcVolume(sym, entry, sl, vol)) return false;

   trade.SetTypeFillingBySymbol(sym);
   bool sent = isBuy ? trade.Buy(vol, sym, 0.0, sl, tp, tag)
                     : trade.Sell(vol, sym, 0.0, sl, tp, tag);
   uint rc = trade.ResultRetcode();
   PrintFormat("Entry %s %s %.3f lots sl=%.*f tp=%.*f retcode=%d %s",
               isBuy ? "BUY" : "SELL", sym, vol, SymDigits(sym), sl,
               SymDigits(sym), tp, rc, trade.ResultRetcodeDescription());
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
     { SetBlockReason(StringFormat("order rejected rc=%d", rc)); return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| News gate: refresh at most once per NEWS_CACHE_SEC. Fail-closed. |
//+------------------------------------------------------------------+
void NewsUpdate()
  {
   if(!UseNewsFilterGold || !g_goldActive) return;
   datetime now = ServerTime();
   if(now - g_newsCheckedAt < NEWS_CACHE_SEC) return;
   g_newsCheckedAt = now;

   datetime from = now - NewsMinsBefore * 60;
   datetime to   = now + NewsMinsAfter  * 60;

   bool anyOk = false, anyFail = false;
   string hitDesc = "";
   for(int c = 0; c < ArraySize(g_newsCurs); c++)
     {
      MqlCalendarValue vals[];
      int n = CalendarValueHistory(vals, from, to, NULL, g_newsCurs[c]);
      if(n < 0) { anyFail = true; continue; }
      anyOk = true;
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev)) continue;
         if(ev.importance >= NewsMinImportance)
           {
            hitDesc = StringFormat("%s event '%s' at %s", g_newsCurs[c],
                                   ev.name, TimeToString((datetime)vals[i].time));
            break;
           }
        }
      if(hitDesc != "") break;
     }

   if(hitDesc != "")
     {
      if(!g_newsBlocked) Print("News gate: BLOCKED - " + hitDesc);
      g_newsBlocked = true; g_newsAvail = true; g_newsReason = hitDesc;
     }
   else if(anyFail && !anyOk)
     {
      if(g_newsAvail || g_newsReason != "calendar query failed")
         Print("News gate: calendar query failed - gold entries blocked (fail-closed).");
      g_newsBlocked = true; g_newsAvail = false;
      g_newsReason = "calendar query failed";
     }
   else
     {
      if(g_newsBlocked) Print("News gate: clear.");
      g_newsBlocked = false; g_newsAvail = true; g_newsReason = "clear";
     }

   //--- optionally close EA-managed gold positions while blocked
   if(g_newsBlocked && CloseBeforeNews)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != g_goldSymbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != Magic) continue;
         trade.SetTypeFillingBySymbol(g_goldSymbol);
         if(trade.PositionClose(ticket))
            PrintFormat("News gate: closed gold position %I64u before news.", ticket);
         else
            LogT("news_close_" + (string)ticket,
                 StringFormat("News gate: close failed ticket=%I64u rc=%d %s",
                              ticket, trade.ResultRetcode(),
                              trade.ResultRetcodeDescription()));
        }
     }
  }

//+------------------------------------------------------------------+
//| Parse NewsCurrencies into g_newsCurs                             |
//+------------------------------------------------------------------+
void ParseNewsCurrencies()
  {
   string sep = ",";
   ushort u = StringGetCharacter(sep, 0);
   string parts[];
   int n = StringSplit(NewsCurrencies, u, parts);
   for(int i = 0; i < n; i++)
     {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(s == "") continue;
      // dedupe
      bool dup = false;
      for(int j = 0; j < ArraySize(g_newsCurs); j++)
         if(g_newsCurs[j] == s) { dup = true; break; }
      if(!dup)
        {
         int m = ArraySize(g_newsCurs);
         ArrayResize(g_newsCurs, m + 1);
         g_newsCurs[m] = s;
        }
     }
   if(ArraySize(g_newsCurs) == 0)
     {
      ArrayResize(g_newsCurs, 1);
      g_newsCurs[0] = "USD";
     }
  }

//+------------------------------------------------------------------+
//| Breakeven: move SL to entry once price reaches BreakevenAtR.     |
//| Initial risk persisted in terminal Global Variables so restarts  |
//| do not lose it.                                                  |
//+------------------------------------------------------------------+
string GVBEName(ulong ticket) { return StringFormat("GRD_%I64d_BER_%I64u", g_login, ticket); }
string GVBEDone(ulong ticket) { return StringFormat("GRD_%I64d_BED_%I64u", g_login, ticket); }

int BEFind(ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_be); i++)
      if(g_be[i].ticket == ticket) return i;
   return -1;
  }

void ManageBreakeven()
  {
   if(BreakevenAtR <= 0.0 && TrailStartR <= 0.0 && SellBreakevenAtR <= 0.0) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      if(sym != g_trendSymbol && sym != g_goldSymbol) continue;

      int idx = BEFind(ticket);
      if(idx < 0)
        {
         // rebuild state (survives EA restart)
         idx = ArraySize(g_be);
         ArrayResize(g_be, idx + 1);
         g_be[idx].ticket = ticket;
         g_be[idx].done   = false;
         g_be[idx].risk   = 0.0;
         string rn = GVBEName(ticket);
         if(GlobalVariableCheck(rn))
           {
            g_be[idx].risk = GlobalVariableGet(rn);
            g_be[idx].done = (GlobalVariableCheck(GVBEDone(ticket)));
           }
         else
           {
            double open = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl   = PositionGetDouble(POSITION_SL);
            if(sl > 0.0)
              {
               g_be[idx].risk = MathAbs(open - sl);
               GlobalVariableSet(rn, g_be[idx].risk);
              }
            else
               g_be[idx].done = true;   // no SL -> cannot derive risk
           }
        }
      if(g_be[idx].risk <= 0.0) continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double profitDist = (type == POSITION_TYPE_BUY)
                          ? SymbolInfoDouble(sym, SYMBOL_BID) - open
                          : open - SymbolInfoDouble(sym, SYMBOL_ASK);

      double pt = SymPoint(sym);
      long stopsLvl  = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
      long freezeLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
      double minDist = MathMax(stopsLvl, freezeLvl) * pt;
      double cur = (type == POSITION_TYPE_BUY)
                   ? SymbolInfoDouble(sym, SYMBOL_BID)
                   : SymbolInfoDouble(sym, SYMBOL_ASK);

      //--- breakeven move (once); sells may use their own trigger
      double beR = (type == POSITION_TYPE_SELL && SellBreakevenAtR >= 0.0)
                   ? SellBreakevenAtR : BreakevenAtR;
      if(!g_be[idx].done && beR > 0.0 &&
         profitDist >= beR * g_be[idx].risk)
        {
         // never increase risk: SL moves only toward/past entry
         bool improves = (type == POSITION_TYPE_BUY) ? (open > sl || sl == 0.0)
                                                     : (open < sl || sl == 0.0);
         if(!improves) { g_be[idx].done = true; }
         else if(MathAbs(cur - open) < minDist)
            LogT("be_lvl_" + (string)ticket, "Breakeven deferred: inside stops/freeze level.");
         else
           {
            trade.SetTypeFillingBySymbol(sym);
            if(trade.PositionModify(ticket, NormPrice(sym, open), tp))
              {
               PrintFormat("Breakeven: ticket=%I64u SL->entry %.*f", ticket, SymDigits(sym), open);
               g_be[idx].done = true;
               GlobalVariableSet(GVBEDone(ticket), 1.0);
              }
            else
               LogT("be_fail_" + (string)ticket,
                    StringFormat("Breakeven modify failed ticket=%I64u rc=%d %s",
                                 ticket, trade.ResultRetcode(),
                                 trade.ResultRetcodeDescription()));
           }
        }

      //--- trailing stop (ratchets, never loosens)
      if(TrailStartR > 0.0 && profitDist >= TrailStartR * g_be[idx].risk)
        {
         double tsl = (type == POSITION_TYPE_BUY)
                      ? NormPrice(sym, cur - TrailDistR * g_be[idx].risk)
                      : NormPrice(sym, cur + TrailDistR * g_be[idx].risk);
         bool better = (type == POSITION_TYPE_BUY) ? (sl == 0.0 || tsl > sl)
                                                   : (sl == 0.0 || tsl < sl);
         // keep SL at least minDist away from current price
         bool farEnough = (type == POSITION_TYPE_BUY) ? (cur - tsl >= minDist)
                                                      : (tsl - cur >= minDist);
         if(better && farEnough)
           {
            trade.SetTypeFillingBySymbol(sym);
            if(!trade.PositionModify(ticket, tsl, tp))
               LogT("tr_fail_" + (string)ticket,
                    StringFormat("Trailing modify failed ticket=%I64u rc=%d %s",
                                 ticket, trade.ResultRetcode(),
                                 trade.ResultRetcodeDescription()));
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| New-bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar(const string sym, ENUM_TIMEFRAMES tf, datetime &lastBar)
  {
   datetime t = iTime(sym, tf, 0);
   if(t <= 0) return false;
   if(t != lastBar) { lastBar = t; return true; }
   return false;
  }

//+------------------------------------------------------------------+
//| STRATEGY A - trendline break with confirmation                   |
//+------------------------------------------------------------------+
//| Series indexing: shift 1 = last closed candle.                   |
//| Break candle sits exactly at shift k = N+1 (N = confirmations).  |
//+------------------------------------------------------------------+

bool IsSwingHigh(const MqlRates &r[], int s, int strength)
  {
   int n = ArraySize(r);
   if(s - strength < 0 || s + strength >= n) return false;
   for(int j = 1; j <= strength; j++)
      if(r[s].high <= r[s - j].high || r[s].high <= r[s + j].high)
         return false;
   return true;
  }

bool IsSwingLow(const MqlRates &r[], int s, int strength)
  {
   int n = ArraySize(r);
   if(s - strength < 0 || s + strength >= n) return false;
   for(int j = 1; j <= strength; j++)
      if(r[s].low >= r[s - j].low || r[s].low >= r[s + j].low)
         return false;
   return true;
  }

// line through (s1,p1) older and (s2,p2) newer, evaluated at shift s
double LineAt(double p1, int s1, double p2, int s2, int s)
  {
   return p1 + (p2 - p1) * (double)(s - s1) / (double)(s2 - s1);
  }

// Objects are drawn on / read from the chart the EA is attached to (id 0).
// If the EA trades a different symbol than the chart shows, the drawn
// line is still created but is only meaningful on the trend symbol's chart.
void DrawLine(const string name, const MqlRates &r[], int s1, double p1,
              int s2, double p2, color clr)
  {
   const long cid = 0;
   if(ObjectFind(cid, name) < 0)
      ObjectCreate(cid, name, OBJ_TREND, 0, r[s1].time, p1, r[s2].time, p2);
   else
     {
      ObjectMove(cid, name, 0, r[s1].time, p1);
      ObjectMove(cid, name, 1, r[s2].time, p2);
     }
   ObjectSetInteger(cid, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(cid, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(cid, name, OBJPROP_WIDTH, 2);
  }

//--- automatic-mode: find a descending (BUY) or ascending (SELL) line
//--- sMin/sMax are shift bounds for anchor search
bool FindAutoLine(const MqlRates &r[], bool forBuy, int sMin, int sMax,
                  int &a1, double &p1, int &a2, double &p2)
  {
   a1 = a2 = -1;
   // newest qualifying swing = a2
   for(int s = sMin; s <= sMax; s++)
     {
      bool isSw = forBuy ? IsSwingHigh(r, s, SwingStrength)
                         : IsSwingLow(r, s, SwingStrength);
      if(isSw) { a2 = s; break; }
     }
   if(a2 < 0) return false;
   // next older swing >= MinSwingGap away that forms lower-high/higher-low
   for(int s = a2 + MinSwingGap; s <= sMax; s++)
     {
      bool isSw = forBuy ? IsSwingHigh(r, s, SwingStrength)
                         : IsSwingLow(r, s, SwingStrength);
      if(!isSw) continue;
      double pOld = forBuy ? r[s].high : r[s].low;
      double pNew = forBuy ? r[a2].high : r[a2].low;
      bool shape = forBuy ? (pOld > pNew)   // lower highs -> descending
                          : (pOld < pNew);  // higher lows -> ascending
      if(shape) { a1 = s; p1 = pOld; p2 = pNew; return true; }
     }
   return false;
  }

//--- manual-mode: pick deterministically the most recently created
//--- valid OBJ_TREND of the needed slope direction. Returns object name.
bool FindManualLine(bool forBuy, string &name)
  {
   name = "";
   const long cid = 0;
   datetime bestCreate = 0;
   int n = ObjectsTotal(cid, 0, OBJ_TREND);
   for(int i = 0; i < n; i++)
     {
      string on = ObjectName(cid, i, 0, OBJ_TREND);
      datetime t1 = (datetime)ObjectGetInteger(cid, on, OBJPROP_TIME, 0);
      datetime t2 = (datetime)ObjectGetInteger(cid, on, OBJPROP_TIME, 1);
      double   p1 = ObjectGetDouble(cid, on, OBJPROP_PRICE, 0);
      double   p2 = ObjectGetDouble(cid, on, OBJPROP_PRICE, 1);
      if(t1 <= 0 || t2 <= 0 || t1 == t2 || p1 <= 0 || p2 <= 0) continue;
      // order anchors by time so "falling over time" is well-defined
      double pEarly = (t1 < t2) ? p1 : p2;
      double pLate  = (t1 < t2) ? p2 : p1;
      bool falling = (pLate < pEarly);       // descending -> BUY candidate
      if(falling != forBuy) continue;
      datetime ct = (datetime)ObjectGetInteger(cid, on, OBJPROP_CREATETIME);
      if(ct > bestCreate || (ct == bestCreate && (name == "" || on < name)))
        { bestCreate = ct; name = on; }
     }
   return (name != "");
  }

double ManualLineAt(const string name, datetime t)
  {
   const long cid = 0;
   return ObjectGetValueByTime(cid, name, t);
  }

//--- shared break evaluation. getLine(s) is supplied by caller mode:
//--- autoMode=true uses formula, else reads manual object value.
bool CheckBreak(const MqlRates &r[], bool isBuy, int N, bool autoMode,
                const string manualName, int a1, double p1, int a2, double p2)
  {
   int k = N + 1;
   int n = ArraySize(r);
   if(k + CleanBars >= n) { SetBlockReason("insufficient history for setup"); return false; }

   // line value accessor (inline lambda not available; compute directly)
   // break candle: first close beyond the line
   double lv;
   if(autoMode) lv = LineAt(p1, a1, p2, a2, k);
   else         lv = ManualLineAt(manualName, r[k].time);
   if(lv <= 0) { SetBlockReason("invalid line value"); return false; }
   if(isBuy  && r[k].close <= lv) return false;
   if(!isBuy && r[k].close >= lv) return false;

   // clean-trend: candles k+1 .. k+CleanBars stay on original side
   for(int s = k + 1; s <= k + CleanBars; s++)
     {
      lv = autoMode ? LineAt(p1, a1, p2, a2, s)
                    : ManualLineAt(manualName, r[s].time);
      if(lv <= 0) return false;
      if(isBuy  && r[s].close >= lv) return false;
      if(!isBuy && r[s].close <= lv) return false;
     }

   // confirmations: shifts 1..N correct direction AND beyond the line
   for(int s = 1; s <= N; s++)
     {
      lv = autoMode ? LineAt(p1, a1, p2, a2, s)
                    : ManualLineAt(manualName, r[s].time);
      if(lv <= 0) return false;
      if(isBuy)
        { if(r[s].close <= r[s].open || r[s].close <= lv) return false; }
      else
        { if(r[s].close >= r[s].open || r[s].close >= lv) return false; }
     }
   return true;
  }

void StrategyA()
  {
   int maxN   = MathMax(BuyConfirmCandles, SellConfirmCandles);
   int need   = MathMax(Lookback, maxN + 1 + CleanBars + SwingStrength + 2) + 5;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(g_trendSymbol, TrendTF, 0, need, r) < need)
     { LogT("a_hist", "Strategy A: insufficient history on " + g_trendSymbol); return; }

   int sMin = MathMax(SwingStrength + 1, 1);               // confirmed swings only
   int sMax = MathMin(Lookback, ArraySize(r) - SwingStrength - 1);

   //--- optional EMA trend filter: trade only with the prevailing trend
   bool emaBuyOK = true, emaSellOK = true;
   if(g_emaHandle != INVALID_HANDLE)
     {
      double ev[];
      ArraySetAsSeries(ev, true);
      if(CopyBuffer(g_emaHandle, 0, 1, 1, ev) == 1)
        { emaBuyOK = (r[1].close > ev[0]); emaSellOK = (r[1].close < ev[0]); }
      else { emaBuyOK = emaSellOK = false; }    // fail safe: no filter data, no trades
     }

   //--- BUY
   if(AllowBuys && emaBuyOK && !ManagedPositionExists(g_trendSymbol))
     {
      int k = BuyConfirmCandles + 1;
      int a1, a2; double p1 = 0, p2 = 0;
      string mname = "";
      bool haveLine = UseManualLines
                      ? FindManualLine(true, mname)
                      : FindAutoLine(r, true, MathMax(sMin, k + 1), sMax, a1, p1, a2, p2);
      if(haveLine && r[k].time != g_lastBuyBreakBar &&
         CheckBreak(r, true, BuyConfirmCandles, !UseManualLines, mname, a1, p1, a2, p2))
        {
         double lo = r[1].low;
         for(int s = 2; s <= k; s++) lo = MathMin(lo, r[s].low);
         double sl = lo - SLBufferPoints * SymPoint(g_trendSymbol);
         if(TryEnter(g_trendSymbol, true, sl, "GB_A_BUY"))
           {
            g_lastBuyBreakBar = r[k].time;
            GlobalVariableSet(g_gvSigAB, (double)g_lastBuyBreakBar);
            if(!UseManualLines)
               DrawLine("GB_A_BUY", r, a1, p1, a2, p2, clrDodgerBlue);
           }
        }
     }
   //--- SELL
   if(AllowSells && emaSellOK && !ManagedPositionExists(g_trendSymbol))
     {
      int k = SellConfirmCandles + 1;
      int a1, a2; double p1 = 0, p2 = 0;
      string mname = "";
      bool haveLine = UseManualLines
                      ? FindManualLine(false, mname)
                      : FindAutoLine(r, false, MathMax(sMin, k + 1), sMax, a1, p1, a2, p2);
      if(haveLine && r[k].time != g_lastSellBreakBar &&
         CheckBreak(r, false, SellConfirmCandles, !UseManualLines, mname, a1, p1, a2, p2))
        {
         double hi = r[1].high;
         for(int s = 2; s <= k; s++) hi = MathMax(hi, r[s].high);
         double sl = hi + SLBufferPoints * SymPoint(g_trendSymbol);
         if(TryEnter(g_trendSymbol, false, sl, "GB_A_SELL"))
           {
            g_lastSellBreakBar = r[k].time;
            GlobalVariableSet(g_gvSigAS, (double)g_lastSellBreakBar);
            if(!UseManualLines)
               DrawLine("GB_A_SELL", r, a1, p1, a2, p2, clrTomato);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Money-based risk: flat or milestone-scaled fixed-$ risk          |
//+------------------------------------------------------------------+
double MoneyRiskUSD(double base)
  {
   if(base <= 0) return 0;
   if(MilestoneStep <= 0 || MilestoneRiskUSD <= 0) return base;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0) return base;
   int steps = (int)MathFloor(eq / MilestoneStep);
   return MilestoneRiskUSD * MathMax(1, steps);
  }

//+------------------------------------------------------------------+
//| Money-based SL/TP: returns true and fills sl/tp when enabled     |
//+------------------------------------------------------------------+
bool MoneyStops(const string sym, bool isBuy, double &sl, double &tp)
  {
   double slUSD = MoneySL_USD, tpUSD = MoneyTP_USD;
   if(g_goldActive && sym == g_goldSymbol)
     {
      if(MoneySLGold_USD != 0) slUSD = MoneySLGold_USD;   // -1 forces structure SL on gold
      if(MoneyTPGold_USD != 0) tpUSD = MoneyTPGold_USD;
     }
   double riskUSD = MoneyRiskUSD(slUSD);
   if(riskUSD <= 0 || RiskPercent > 0) return false;
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double px = SymbolInfoDouble(sym, isBuy ? SYMBOL_BID : SYMBOL_ASK);
   double lot = (g_goldActive && sym == g_goldSymbol && FixedLotGold > 0)
                ? FixedLotGold : FixedLot;
   if(tv <= 0 || ts <= 0 || px <= 0) return false;
   double dist = riskUSD * ts / (tv * lot);
   sl = isBuy ? px - dist : px + dist;
   tp = -1;
   if(tpUSD > 0)
      tp = isBuy ? px + dist * (tpUSD / slUSD)
                 : px - dist * (tpUSD / slUSD);
   return true;
  }

//+------------------------------------------------------------------+
//| STRATEGY C - H1 trend filter + TrendTF pullback entry            |
//+------------------------------------------------------------------+
void StrategyPullback()
  {
   int need = MathMax(MathMax(SRLookback, RangeBars), PullbackSwingBars) + PullbackBars + 10;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(g_trendSymbol, TrendTF, 0, need, r) < need)
     { LogT("c_hist", "Strategy C: insufficient history on " + g_trendSymbol); return; }

   double pt = SymPoint(g_trendSymbol);

   //--- H1 trend filter: only trade with the H1 EMA side, skip chop
   double e50[]; ArraySetAsSeries(e50, true);
   MqlRates h1[];  ArraySetAsSeries(h1, true);
   if(CopyBuffer(g_emaH1, 0, 1, 1, e50) != 1 ||
      CopyRates(g_trendSymbol, PERIOD_H1, 1, 1, h1) != 1)
     { SetBlockReason("strategy C: H1 trend filter data unavailable"); return; }
   bool up = h1[0].close > e50[0], dn = h1[0].close < e50[0];
   if(ChopFilterPoints > 0 && MathAbs(h1[0].close - e50[0]) < ChopFilterPoints * pt)
     { SetBlockReason("chop: H1 price hugging EMA50"); up = dn = false; }
   if(H1StructConfirm && (up || dn))
     {
      bool sUp = false, sDn = false;
      TFStructure(g_trendSymbol, PERIOD_H1, 2, sUp, sDn);
      up = up && sUp; dn = dn && sDn;
      if(!up && !dn) { SetBlockReason("strategy C: no H1 structure confirm"); return; }
     }
   if((UseRSIConfirm || SellRSIMax > 0) && (up || dn))
     {
      double rsi[]; ArraySetAsSeries(rsi, true);
      if(CopyBuffer(g_rsi, 0, 1, 1, rsi) != 1)
        { SetBlockReason("strategy C: RSI data unavailable"); return; }
      if(UseRSIConfirm) up = up && rsi[0] > 50.0;
      double dnCap = 101.0;
      if(UseRSIConfirm) dnCap = MathMin(dnCap, 50.0);
      if(SellRSIMax > 0)  dnCap = MathMin(dnCap, SellRSIMax);
      dn = dn && rsi[0] < dnCap;
      if(!up && !dn) { SetBlockReason("strategy C: RSI not confirming"); return; }
     }

   //--- entry EMA buffer on TrendTF
   int pb = MathMin(PullbackBars, ArraySize(r) - 2);
   double e20[]; ArraySetAsSeries(e20, true);
   if(CopyBuffer(g_emaEntry, 0, 1, pb + 1, e20) < pb + 1)
     { SetBlockReason("strategy C: entry EMA data unavailable"); return; }
   // e20[i] = entry EMA at bar shift (i+1)
   double e50t[]; ArraySetAsSeries(e50t, true);
   if(PullbackEMA50 && CopyBuffer(g_ema50T, 0, 1, pb + 1, e50t) < pb + 1)
     { SetBlockReason("strategy C: TrendTF EMA50 data unavailable"); return; }

   //--- recent S/R level (broken level retest)
   double srHigh = 0, srLow = 0;
   if(UseSRRetest)
     {
      int hb = MathMin(SRLookback, ArraySize(r) - 1);
      srHigh = r[2].high; srLow = r[2].low;
      for(int i = 2; i <= hb; i++) { srHigh = MathMax(srHigh, r[i].high); srLow = MathMin(srLow, r[i].low); }
     }

   //--- pullback detection: price touched EMA within last PullbackBars, or retested S/R
   bool pbBuy = false, pbSell = false;
   for(int s = 1; s <= pb; s++)
     {
      if((PullbackEMA20 && r[s].low  <= e20[s - 1]) ||
         (PullbackEMA50 && r[s].low  <= e50t[s - 1])) pbBuy  = true;
      if((PullbackEMA20 && r[s].high >= e20[s - 1]) ||
         (PullbackEMA50 && r[s].high >= e50t[s - 1])) pbSell = true;
     }
   if(UseSRRetest)
     {
      if(r[1].low  <= srHigh && r[1].low  >= srLow) pbBuy  = true;
      if(r[1].high >= srLow  && r[1].high <= srHigh) pbSell = true;
     }

   //--- optional money-based stop sizing (fixed $ or milestone-scaled)
   double riskUSD = MoneyRiskUSD(MoneySL_USD);
   double tv = 0, ts = 0;
   if(riskUSD > 0)
     {
      tv = SymbolInfoDouble(g_trendSymbol, SYMBOL_TRADE_TICK_VALUE);
      ts = SymbolInfoDouble(g_trendSymbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv <= 0 || ts <= 0 || RiskPercent > 0)
        { SetBlockReason("money stop: tick data missing or RiskPercent>0"); return; }
     }

   //--- engulfing candles also qualify as trend-direction triggers
   bool engB = UseEngulfing && r[1].close > r[1].open &&
               r[2].close < r[2].open && r[1].close > r[2].open;
   bool engS = UseEngulfing && r[1].close < r[1].open &&
               r[2].close > r[2].open && r[1].close < r[2].open;

   //--- signal-candle strength: body >= EntryMinBodyPct% of range
   double range1 = r[1].high - r[1].low;
   bool strongB = r[1].close > r[1].open &&
                  (EntryMinBodyPct <= 0 || range1 <= 0 ||
                   (r[1].close - r[1].open) >= range1 * EntryMinBodyPct / 100.0);
   double sBody = SellMinBodyPct >= 0 ? SellMinBodyPct : EntryMinBodyPct;
   bool strongS = r[1].close < r[1].open &&
                  (sBody <= 0 || range1 <= 0 ||
                   (r[1].open - r[1].close) >= range1 * sBody / 100.0);

   //--- BUY: close back in trend direction above the EMA
   if(AllowBuys && up && pbBuy && (engB || (strongB && r[1].close > e20[0])) &&
      r[1].time != g_lastPbBuyBar && EntryOKForSymbol(g_trendSymbol))
     {
      double sl, tp = -1;
      if(riskUSD > 0)
        {
         double px = SymbolInfoDouble(g_trendSymbol, SYMBOL_BID);
         double dist = riskUSD * ts / (tv * FixedLot);
         sl = px - dist;
         if(MoneyTP_USD > 0) tp = px + dist * (MoneyTP_USD / MoneySL_USD);
        }
      else
        {
         int sw = MathMin(PullbackSwingBars, ArraySize(r) - 1);
         double lo = r[1].low;
         for(int s = 1; s <= sw; s++) lo = MathMin(lo, r[s].low);
         sl = lo - SLBufferPoints * pt;
        }
      if(TryEnter(g_trendSymbol, true, sl, "GB_C_BUY", tp))
        { g_lastPbBuyBar = r[1].time; GlobalVariableSet(g_gvSigPB, (double)g_lastPbBuyBar); }
     }
   //--- SELL: mirror
   if(AllowSells && dn && pbSell && (engS || (strongS && r[1].close < e20[0])) &&
      r[1].time != g_lastPbSellBar && EntryOKForSymbol(g_trendSymbol))
     {
      double sl, tp = -1;
      if(riskUSD > 0)
        {
         double px = SymbolInfoDouble(g_trendSymbol, SYMBOL_ASK);
         double dist = riskUSD * ts / (tv * FixedLot);
         sl = px + dist;
         if(MoneyTP_USD > 0) tp = px - dist * (MoneyTP_USD / MoneySL_USD);
        }
      else
        {
         int sw = MathMin(PullbackSwingBars, ArraySize(r) - 1);
         double hi = r[1].high;
         for(int s = 1; s <= sw; s++) hi = MathMax(hi, r[s].high);
         sl = hi + SLBufferPoints * pt;
        }
      if(TryEnter(g_trendSymbol, false, sl, "GB_C_SELL", tp, SellRiskReward))
        { g_lastPbSellBar = r[1].time; GlobalVariableSet(g_gvSigPS, (double)g_lastPbSellBar); }
     }

   //--- range-breakout alternative entries
   if(UseBreakoutEntries && EntryOKForSymbol(g_trendSymbol))
     {
      int rb = MathMin(RangeBars, ArraySize(r) - 2);
      double rh = r[2].high, rl = r[2].low;
      for(int s = 2; s <= rb + 1; s++) { rh = MathMax(rh, r[s].high); rl = MathMin(rl, r[s].low); }
      if(MaxRangePoints <= 0 || (rh - rl) <= MaxRangePoints * pt)
        {
         double mid = (rh + rl) / 2.0;
         if(AllowBuys && up && r[1].close > rh && r[1].time != g_lastPbBuyBar)
           {
            double sl, tp = -1;
            if(riskUSD > 0)
              {
               double px = SymbolInfoDouble(g_trendSymbol, SYMBOL_BID);
               double dist = riskUSD * ts / (tv * FixedLot);
               sl = px - dist;
               if(MoneyTP_USD > 0) tp = px + dist * (MoneyTP_USD / MoneySL_USD);
              }
            else sl = (BreakoutStopMidpoint ? mid : rl) - SLBufferPoints * pt;
            if(TryEnter(g_trendSymbol, true, sl, "GB_C_BO_BUY", tp))
              { g_lastPbBuyBar = r[1].time; GlobalVariableSet(g_gvSigPB, (double)g_lastPbBuyBar); }
           }
         if(AllowSells && dn && r[1].close < rl && r[1].time != g_lastPbSellBar)
           {
            double sl, tp = -1;
            if(riskUSD > 0)
              {
               double px = SymbolInfoDouble(g_trendSymbol, SYMBOL_ASK);
               double dist = riskUSD * ts / (tv * FixedLot);
               sl = px + dist;
               if(MoneyTP_USD > 0) tp = px - dist * (MoneyTP_USD / MoneySL_USD);
              }
            else sl = (BreakoutStopMidpoint ? mid : rh) + SLBufferPoints * pt;
            if(TryEnter(g_trendSymbol, false, sl, "GB_C_BO_SELL", tp, SellRiskReward))
              { g_lastPbSellBar = r[1].time; GlobalVariableSet(g_gvSigPS, (double)g_lastPbSellBar); }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Swing structure on a given TF: HH+HL => up, LH+LL => dn          |
//+------------------------------------------------------------------+
bool TFStructure(const string sym, const ENUM_TIMEFRAMES tf, const int strength,
                 bool &up, bool &dn)
  {
   MqlRates h[];
   ArraySetAsSeries(h, true);
   int n4 = CopyRates(sym, tf, 0, 200, h);
   if(n4 < strength * 4 + 6) return false;
   int st = strength;
   double sh1 = 0, sh2 = 0, sl1 = 0, sl2 = 0;
   int foundH = 0, foundL = 0;
   for(int i = st + 1; i < n4 - st && (foundH < 2 || foundL < 2); i++)
     {
      bool isH = true, isL = true;
      for(int j = 1; j <= st; j++)
        {
         if(h[i].high <= h[i - j].high || h[i].high <= h[i + j].high) isH = false;
         if(h[i].low  >= h[i - j].low  || h[i].low  >= h[i + j].low)  isL = false;
        }
      if(isH) { if(foundH == 0) sh1 = h[i].high; else if(foundH == 1) sh2 = h[i].high; foundH++; }
      if(isL) { if(foundL == 0) sl1 = h[i].low;  else if(foundL == 1) sl2 = h[i].low;  foundL++; }
     }
   if(foundH < 2 || foundL < 2) return false;
   up = (sh1 > sh2 && sl1 > sl2);      // higher highs AND higher lows
   dn = (sh1 < sh2 && sl1 < sl2);      // lower highs AND lower lows
   return true;
  }

bool H4Direction(const string sym, bool &up, bool &dn)
  { return TFStructure(sym, PERIOD_H4, H4SwingStrength, up, dn); }

//+------------------------------------------------------------------+
//| STRATEGY D - H4 bias + H1 zone + entry-TF liquidity sweep + BOS  |
//+------------------------------------------------------------------+
void StrategyStructure()
  {
   int need = SweepLookback + SweepMaxAge + MinorBars + 10;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(g_trendSymbol, TrendTF, 0, need, r) < need)
     { LogT("d_hist", "Strategy D: insufficient history on " + g_trendSymbol); return; }

   double pt = SymPoint(g_trendSymbol);

   //--- 4H structural bias
   bool up = false, dn = false;
   if(!H4Direction(g_trendSymbol, up, dn) || (!up && !dn))
     { SetBlockReason("strategy D: no clear H4 structure"); return; }

   //--- 1H zone
   MqlRates h1[]; ArraySetAsSeries(h1, true);
   int zn = CopyRates(g_trendSymbol, PERIOD_H1, 1, ZoneLookback, h1);
   if(zn < ZoneLookback)
     { SetBlockReason("strategy D: H1 zone data unavailable"); return; }
   double zoneHi = h1[0].high, zoneLo = h1[0].low;
   for(int i = 0; i < zn; i++) { zoneHi = MathMax(zoneHi, h1[i].high); zoneLo = MathMin(zoneLo, h1[i].low); }

   //--- find most recent sweep within SweepMaxAge bars
   int swBuy = -1, swSell = -1;
   for(int i = 2; i <= SweepMaxAge + 1; i++)
     {
      double lo = r[i + 1].low, hi = r[i + 1].high;    // level = extremes BEFORE candle i
      for(int j = i + 1; j <= i + SweepLookback && j < ArraySize(r); j++)
        { lo = MathMin(lo, r[j].low); hi = MathMax(hi, r[j].high); }
      if(swBuy < 0 && r[i].low < lo && r[i].close > lo)  swBuy  = i;   // swept low, rejected
      if(swSell < 0 && r[i].high > hi && r[i].close < hi) swSell = i;  // swept high, rejected
      if(swBuy >= 0 && swSell >= 0) break;
     }

   //--- BUY: bullish H4 + swept a low near/above H1 support + BOS above minor high
   if(AllowBuys && up && swBuy > 0 &&
      r[1].time != g_lastStBuyBar && !ManagedPositionExists(g_trendSymbol))
     {
      double sweptLo = r[swBuy + 1].low;
      for(int j = swBuy + 1; j <= swBuy + SweepLookback && j < ArraySize(r); j++)
         sweptLo = MathMin(sweptLo, r[j].low);
      bool inZone = (sweptLo >= zoneLo - ZoneTolerancePoints * pt);
      bool pulled = (MinPullbackPoints <= 0 || zoneHi - sweptLo >= MinPullbackPoints * pt);
      if(inZone && pulled)
        {
         double minorHi = r[swBuy].high;
         for(int j = 2; j < swBuy; j++) minorHi = MathMax(minorHi, r[j].high);
         if(r[1].close > minorHi)                                   // 1M break of structure
           {
            double sl = r[swBuy].low - SLBufferPoints * pt;
            if(TryEnter(g_trendSymbol, true, sl, "GB_D_BUY"))
              { g_lastStBuyBar = r[1].time; GlobalVariableSet(g_gvSigDB, (double)g_lastStBuyBar); }
           }
         else SetBlockReason("sweep found, BOS confirm pending");
        }
      else SetBlockReason("buy sweep out of zone / no pullback");
     }
   //--- SELL: mirror
   if(AllowSells && dn && swSell > 0 &&
      r[1].time != g_lastStSellBar && !ManagedPositionExists(g_trendSymbol))
     {
      double sweptHi = r[swSell + 1].high;
      for(int j = swSell + 1; j <= swSell + SweepLookback && j < ArraySize(r); j++)
         sweptHi = MathMax(sweptHi, r[j].high);
      bool inZone = (sweptHi <= zoneHi + ZoneTolerancePoints * pt);
      bool pulled = (MinPullbackPoints <= 0 || sweptHi - zoneLo >= MinPullbackPoints * pt);
      if(inZone && pulled)
        {
         double minorLo = r[swSell].low;
         for(int j = 2; j < swSell; j++) minorLo = MathMin(minorLo, r[j].low);
         if(r[1].close < minorLo)
           {
            double sl = r[swSell].high + SLBufferPoints * pt;
            if(TryEnter(g_trendSymbol, false, sl, "GB_D_SELL"))
              { g_lastStSellBar = r[1].time; GlobalVariableSet(g_gvSigDS, (double)g_lastStSellBar); }
           }
         else SetBlockReason("sweep found, BOS confirm pending");
        }
      else SetBlockReason("sell sweep out of zone / no pullback");
     }
  }

//+------------------------------------------------------------------+
//| STRATEGY B - session liquidity sweep & reclaim                   |
//+------------------------------------------------------------------+
//| Returns the most recent COMPLETED window [startH,endH) in server |
//| time (handles wrap past midnight), or false if none yet.         |
//+------------------------------------------------------------------+
bool CompletedSessionWindow(int startH, int endH, datetime now,
                            datetime &wStart, datetime &wEnd)
  {
   datetime d0 = DayStart(now);
   if(startH < endH)
     {
      // non-wrapped: today's window, or yesterday's if today's not done
      datetime ws = d0 + startH * 3600;
      datetime we = d0 + endH   * 3600;
      if(now < we) { ws -= 86400; we -= 86400; }
      wStart = ws; wEnd = we;
      return true;
     }
   // wrapped (startH > endH): duration = (24 - startH + endH) hours,
   // most recent window ends at endH on the current or previous day
   int durSec = (24 - startH + endH) * 3600;
   wEnd = d0 + endH * 3600;
   if(now < wEnd) wEnd -= 86400;
   wStart = wEnd - durSec;
   return true;
  }

bool SessionRange(int startH, int endH, datetime now, double &hi, double &lo)
  {
   datetime ws, we;
   if(!CompletedSessionWindow(startH, endH, now, ws, we)) return false;
   MqlRates r[];
   int n = CopyRates(g_goldSymbol, GoldTF, ws, we - 1, r);
   if(n <= 0)
     {
      SetBlockReason(StringFormat("session %d-%d range data missing", startH, endH));
      return false;
     }
   hi = r[0].high; lo = r[0].low;
   for(int i = 1; i < n; i++)
     { hi = MathMax(hi, r[i].high); lo = MathMin(lo, r[i].low); }
   return (hi > lo);
  }

void StrategyB()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(g_goldSymbol, GoldTF, 0, 3, r) < 3)
     { LogT("b_hist", "Strategy B: insufficient history on " + g_goldSymbol); return; }
   MqlRates sig = r[1];                     // last closed candle
   if(sig.time == g_lastSweepBar) return;   // already processed

   datetime now = ServerTime();
   double pt = SymPoint(g_goldSymbol);
   double minSweep = MinSweepPoints * pt;

   //--- gather levels
   double levelsHi[], levelsLo[];
   string namesHi[], namesLo[];
   double v1, v2;
   if(SessionRange(AsianStartHour, AsianEndHour, now, v1, v2))
     {
      int m = ArraySize(levelsHi); ArrayResize(levelsHi, m + 1); ArrayResize(namesHi, m + 1);
      levelsHi[m] = v1; namesHi[m] = "AsianH";
      m = ArraySize(levelsLo); ArrayResize(levelsLo, m + 1); ArrayResize(namesLo, m + 1);
      levelsLo[m] = v2; namesLo[m] = "AsianL";
     }
   else LogT("b_asian", "Strategy B: Asian range unavailable - level skipped.");
   if(SessionRange(LondonStartHour, LondonEndHour, now, v1, v2))
     {
      int m = ArraySize(levelsHi); ArrayResize(levelsHi, m + 1); ArrayResize(namesHi, m + 1);
      levelsHi[m] = v1; namesHi[m] = "LondonH";
      m = ArraySize(levelsLo); ArrayResize(levelsLo, m + 1); ArrayResize(namesLo, m + 1);
      levelsLo[m] = v2; namesLo[m] = "LondonL";
     }
   else LogT("b_london", "Strategy B: London range unavailable - level skipped.");
   // previous completed daily candle
   MqlRates d[];
   ArraySetAsSeries(d, true);
   if(CopyRates(g_goldSymbol, PERIOD_D1, 1, 1, d) == 1)
     {
      int m = ArraySize(levelsHi); ArrayResize(levelsHi, m + 1); ArrayResize(namesHi, m + 1);
      levelsHi[m] = d[0].high; namesHi[m] = "PrevDayH";
      m = ArraySize(levelsLo); ArrayResize(levelsLo, m + 1); ArrayResize(namesLo, m + 1);
      levelsLo[m] = d[0].low; namesLo[m] = "PrevDayL";
     }
   else LogT("b_daily", "Strategy B: previous day data unavailable - level skipped.");

   if(ArraySize(levelsHi) == 0 && ArraySize(levelsLo) == 0)
     { SetBlockReason("no liquidity levels available"); return; }

   //--- best SELL candidate (largest sweep above a high, bearish close back below)
   double bestSweep = 0.0; int bestIdx = -1;
   if(sig.close < sig.open)
      for(int i = 0; i < ArraySize(levelsHi); i++)
        {
         double sw = sig.high - levelsHi[i];
         if(sw >= minSweep && sig.close < levelsHi[i] && sw > bestSweep)
           { bestSweep = sw; bestIdx = i; }
        }
   //--- best BUY candidate (largest sweep below a low, bullish close back above)
   double bestSweepB = 0.0; int bestIdxB = -1;
   if(sig.close > sig.open)
      for(int i = 0; i < ArraySize(levelsLo); i++)
        {
         double sw = levelsLo[i] - sig.low;
         if(sw >= minSweep && sig.close > levelsLo[i] && sw > bestSweepB)
           { bestSweepB = sw; bestIdxB = i; }
        }

   // deterministic: at most one entry per signal candle
   if(bestIdx < 0 && bestIdxB < 0) return;
   bool doSell = (bestIdx >= 0 && bestSweep >= bestSweepB);
   double sl;
   if(doSell)
     {
      sl = sig.high + SLBufferPoints * pt;
      double tps = -1, msl = sl, mtp = -1;
      if(MoneyStops(g_goldSymbol, false, msl, mtp)) { sl = msl; tps = mtp; }
      PrintFormat("Strategy B SELL setup: swept %s by %.1f pt", namesHi[bestIdx], bestSweep / pt);
      if(TryEnter(g_goldSymbol, false, sl, "GB_B_SELL", tps))
        {
         g_lastSweepBar = sig.time;
         GlobalVariableSet(g_gvSigB, (double)g_lastSweepBar);
        }
     }
   else
     {
      sl = sig.low - SLBufferPoints * pt;
      double tpb = -1, mslb = sl, mtpb = -1;
      if(MoneyStops(g_goldSymbol, true, mslb, mtpb)) { sl = mslb; tpb = mtpb; }
      PrintFormat("Strategy B BUY setup: swept %s by %.1f pt", namesLo[bestIdxB], bestSweepB / pt);
      if(TryEnter(g_goldSymbol, true, sl, "GB_B_BUY", tpb))
        {
         g_lastSweepBar = sig.time;
         GlobalVariableSet(g_gvSigB, (double)g_lastSweepBar);
        }
     }
  }

//+------------------------------------------------------------------+
//| Status panel                                                     |
//+------------------------------------------------------------------+
void DrawStatus()
  {
   string lock = (g_dailyLock || g_weeklyLock) ? "LOCKED - " + g_lockReason : "CLEAR";
   string news = !UseNewsFilterGold ? "disabled" :
                 !g_newsAvail       ? "UNAVAILABLE (gold blocked)" :
                 g_newsBlocked      ? "BLOCKED: " + g_newsReason : "clear";
   string mode = (StrategyMode == TRENDBREAK) ? "TRENDBREAK" :
                 (StrategyMode == SESSION_SWEEP) ? "SESSION_SWEEP" :
                 (StrategyMode == PULLBACK) ? "PULLBACK" :
                 (StrategyMode == STRUCTURE) ? "STRUCTURE" :
                 (StrategyMode == PULLBACK_GOLD) ? "PULLBACK+GOLD" : "BOTH";
   Comment(StringFormat(
      "GuardianBot v1.00 | mode=%s\n"
      "Trend: %s %s %s | Gold: %s %s %s\n"
      "Server time: %s\n"
      "Daily P/L: %.2f %s (target %.2f / maxloss %.2f)\n"
      "Weekly P/L: %.2f %s (target %.2f)\n"
      "Guardian: %s\n"
      "News gate (gold): %s\n"
      "Last block: %s",
      mode,
      g_trendSymbol, EnumToString(TrendTF), g_trendActive ? "ON" : "OFF",
      g_goldSymbol,  EnumToString(GoldTF),  g_goldActive  ? "ON" : "OFF",
      TimeToString(ServerTime()),
      g_dailyPL, g_currency, DailyProfitTarget, DailyMaxLoss,
      g_weeklyPL, g_currency, WeeklyProfitTarget,
      lock, news, g_lastBlockReason));
  }

//+------------------------------------------------------------------+
//| Validation                                                       |
//+------------------------------------------------------------------+
bool ValidHourRange(int s, int e, const string name)
  {
   if(s < 0 || s > 23 || e < 1 || e > 24 || s == e)
     {
      PrintFormat("INIT FAIL: %s invalid (%d-%d). start 0-23, end 1-24, must differ.",
                  name, s, e);
      return false;
     }
   return true;
  }

int OnInit()
  {
   g_login    = AccountInfoInteger(ACCOUNT_LOGIN);
   g_currency = AccountInfoString(ACCOUNT_CURRENCY);
   g_gvDay    = StringFormat("GRD_%I64d_D", g_login);
   g_gvWeek   = StringFormat("GRD_%I64d_W", g_login);
   g_gvSigAB  = StringFormat("GRD_%I64d_SA_B", g_login);
   g_gvSigAS  = StringFormat("GRD_%I64d_SA_S", g_login);
   g_gvSigB   = StringFormat("GRD_%I64d_SB", g_login);
   g_gvSigPB  = StringFormat("GRD_%I64d_SC_B", g_login);
   g_gvSigPS  = StringFormat("GRD_%I64d_SC_S", g_login);
   g_gvSigDB  = StringFormat("GRD_%I64d_SD_B", g_login);
   g_gvSigDS  = StringFormat("GRD_%I64d_SD_S", g_login);
   // restore signal-bar dedupe so a restart cannot re-fire an old signal
   if(GlobalVariableCheck(g_gvSigAB)) g_lastBuyBreakBar  = (datetime)GlobalVariableGet(g_gvSigAB);
   if(GlobalVariableCheck(g_gvSigAS)) g_lastSellBreakBar = (datetime)GlobalVariableGet(g_gvSigAS);
   if(GlobalVariableCheck(g_gvSigB))  g_lastSweepBar     = (datetime)GlobalVariableGet(g_gvSigB);
   if(GlobalVariableCheck(g_gvSigPB)) g_lastPbBuyBar     = (datetime)GlobalVariableGet(g_gvSigPB);
   if(GlobalVariableCheck(g_gvSigPS)) g_lastPbSellBar    = (datetime)GlobalVariableGet(g_gvSigPS);
   if(GlobalVariableCheck(g_gvSigDB)) g_lastStBuyBar     = (datetime)GlobalVariableGet(g_gvSigDB);
   if(GlobalVariableCheck(g_gvSigDS)) g_lastStSellBar    = (datetime)GlobalVariableGet(g_gvSigDS);

   //--- input validation
   if(RiskPercent < 0 || FixedLot <= 0 || RiskReward <= 0 ||
      BreakevenAtR < 0 || MaxTradesPerDay < 0 || MaxSpreadPoints < 0 ||
      SLBufferPoints < 0 || MinSweepPoints <= 0 ||
      DailyProfitTarget < 0 || WeeklyProfitTarget < 0 || DailyMaxLoss < 0 ||
      NewsMinsBefore < 0 || NewsMinsAfter < 0 ||
      MoneySL_USD < 0 || MoneyTP_USD < 0 || MilestoneStep < 0 || MilestoneRiskUSD < 0 ||
      SellRiskReward < 0 || SellMinBodyPct < -1 || SellBreakevenAtR < -1 || SellRSIMax < 0 ||
      MoneySLGold_USD < -1 || MoneyTPGold_USD < 0)
     { Print("INIT FAIL: negative/invalid numeric input."); return INIT_PARAMETERS_INCORRECT; }
   if(BuyConfirmCandles < 1 || SellConfirmCandles < 1)
     { Print("INIT FAIL: confirmation candles must be >= 1."); return INIT_PARAMETERS_INCORRECT; }
   if(SwingStrength < 1 || MinSwingGap < 1 || CleanBars < 0 ||
      Lookback < SwingStrength * 2 + MinSwingGap + 2)
     { Print("INIT FAIL: swing/lookback parameters too small."); return INIT_PARAMETERS_INCORRECT; }
   if(!ValidHourRange(TradeStartHour, TradeEndHour, "TradeHours") ||
      !ValidHourRange(AsianStartHour, AsianEndHour, "AsianSession") ||
      !ValidHourRange(LondonStartHour, LondonEndHour, "LondonSession"))
      return INIT_PARAMETERS_INCORRECT;
   if(UseNewsFilterGold && NewsCurrencies == "")
     { Print("INIT FAIL: NewsCurrencies empty while filter enabled."); return INIT_PARAMETERS_INCORRECT; }
   // confirmation count must be supportable by available history
   if(MathMax(BuyConfirmCandles, SellConfirmCandles) + 1 + CleanBars > Lookback + 10)
     { Print("INIT FAIL: confirmations+clean bars exceed Lookback."); return INIT_PARAMETERS_INCORRECT; }

   //--- resolve symbols
   g_trendSymbol = (TrendSymbol == "") ? _Symbol : TrendSymbol;
   g_goldSymbol  = GoldSymbol;
   g_trendActive = (StrategyMode == TRENDBREAK || StrategyMode == BOTH ||
                    StrategyMode == PULLBACK || StrategyMode == STRUCTURE ||
                    StrategyMode == PULLBACK_GOLD);
   g_goldActive  = (StrategyMode == SESSION_SWEEP || StrategyMode == BOTH ||
                    StrategyMode == PULLBACK_GOLD);

   if(g_trendActive && !SymbolSelect(g_trendSymbol, true))
     { Print("INIT: trend symbol '" + g_trendSymbol + "' unavailable - trend leg disabled."); g_trendActive = false; }
   if(g_goldActive && !SymbolSelect(g_goldSymbol, true))
     { Print("INIT: gold symbol '" + g_goldSymbol + "' unavailable - Strategy B disabled."); g_goldActive = false; }
   if(!g_trendActive && !g_goldActive)
     { Print("INIT FAIL: no strategy leg could be enabled."); return INIT_FAILED; }

   //--- optional EMA trend filter for Strategy A
   if(TrendFilterEMA > 0 && g_trendActive &&
      StrategyMode != PULLBACK && StrategyMode != PULLBACK_GOLD)
     {
      g_emaHandle = iMA(g_trendSymbol, TrendTF, TrendFilterEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_emaHandle == INVALID_HANDLE)
        { Print("INIT: EMA handle failed on " + g_trendSymbol + " - Strategy A disabled."); g_trendActive = false; }
     }
   if(H4SwingStrength < 1 || ZoneLookback < 10 || SweepLookback < 10 ||
      SweepMaxAge < 1 || MinorBars < 1 || MaxConsecLossesDay < 0)
     { Print("INIT FAIL: strategy D parameters too small."); return INIT_PARAMETERS_INCORRECT; }

   //--- Strategy C handles
   if((StrategyMode == PULLBACK || StrategyMode == PULLBACK_GOLD) && g_trendActive)
     {
      g_emaH1    = iMA(g_trendSymbol, PERIOD_H1, H1EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_emaEntry = iMA(g_trendSymbol, TrendTF, EntryEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_ema50T   = iMA(g_trendSymbol, TrendTF, 50, 0, MODE_EMA, PRICE_CLOSE);
      if(UseRSIConfirm || SellRSIMax > 0)
         g_rsi = iRSI(g_trendSymbol, TrendTF, RSIPeriod, PRICE_CLOSE);
      if(g_emaH1 == INVALID_HANDLE || g_emaEntry == INVALID_HANDLE || g_ema50T == INVALID_HANDLE ||
         ((UseRSIConfirm || SellRSIMax > 0) && g_rsi == INVALID_HANDLE))
        { Print("INIT: pullback EMA handles failed on " + g_trendSymbol + " - Strategy C disabled."); g_trendActive = false; }
     }
   if(!g_trendActive && !g_goldActive)
     { Print("INIT FAIL: no strategy leg could be enabled."); return INIT_FAILED; }

   //--- trade object
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(DEVIATION_POINTS);
   trade.SetTypeFillingBySymbol(g_trendActive ? g_trendSymbol : g_goldSymbol);
   trade.SetAsyncMode(false);

   ParseNewsCurrencies();

   if(!EventSetMillisecondTimer(500))
      Print("INIT: 500ms timer failed to start - OnTick monitoring remains active.");

   PrintFormat("GuardianBot init OK | login=%I64d ccy=%s | trend=%s(%s) gold=%s(%s) build=%d",
               g_login, g_currency,
               g_trendActive ? g_trendSymbol : "-",
               g_trendActive ? EnumToString(TrendTF) : "-",
               g_goldActive ? g_goldSymbol : "-",
               g_goldActive ? EnumToString(GoldTF) : "-",
               TerminalInfoInteger(TERMINAL_BUILD));

   GuardianUpdate();   // restore any persisted lock immediately
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   if(g_emaH1 != INVALID_HANDLE) IndicatorRelease(g_emaH1);
   if(g_emaEntry != INVALID_HANDLE) IndicatorRelease(g_emaEntry);
   if(g_ema50T != INVALID_HANDLE) IndicatorRelease(g_ema50T);
   if(g_rsi != INVALID_HANDLE) IndicatorRelease(g_rsi);
   Comment("");
   Print("GuardianBot deinit, reason=", reason);
  }

//+------------------------------------------------------------------+
//| Core monitoring pass (called from OnTick and OnTimer)            |
//+------------------------------------------------------------------+
void Monitor()
  {
   GuardianUpdate();
   GuardianEnforce();
   NewsUpdate();
   ManageBreakeven();
   DrawStatus();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   Monitor();
   if(g_trendActive && IsNewBar(g_trendSymbol, TrendTF, g_lastTrendBar))
     {
      if(StrategyMode == PULLBACK || StrategyMode == PULLBACK_GOLD) StrategyPullback();
      else if(StrategyMode == STRUCTURE) StrategyStructure();
      else StrategyA();
     }
   if(g_goldActive && IsNewBar(g_goldSymbol, GoldTF, g_lastGoldBar))
      StrategyB();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   Monitor();
   // also check for new bars here so a quiet chart still evaluates
   if(g_trendActive && IsNewBar(g_trendSymbol, TrendTF, g_lastTrendBar))
     {
      if(StrategyMode == PULLBACK || StrategyMode == PULLBACK_GOLD) StrategyPullback();
      else if(StrategyMode == STRUCTURE) StrategyStructure();
      else StrategyA();
     }
   if(g_goldActive && IsNewBar(g_goldSymbol, GoldTF, g_lastGoldBar))
      StrategyB();
  }
//+------------------------------------------------------------------+
