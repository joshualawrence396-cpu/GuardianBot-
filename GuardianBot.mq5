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
   BOTH          = 2    // Both strategies from one chart
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Strategy selector ==="
input ENUM_STRATEGY_MODE StrategyMode   = TRENDBREAK;      // Which strategies are active
input string             TrendSymbol    = "";              // Strategy A symbol (empty = chart symbol)
input string             GoldSymbol     = "XAUUSD";        // Strategy B symbol (broker suffix allowed)
input ENUM_TIMEFRAMES    TrendTF        = PERIOD_M5;       // Strategy A timeframe
input ENUM_TIMEFRAMES    GoldTF         = PERIOD_M15;      // Strategy B timeframe

input group "=== Profit Guardian (account-wide, deposit currency) ==="
input double DailyProfitTarget   = 50.0;    // Daily profit target (0 = disabled)
input double WeeklyProfitTarget  = 200.0;   // Weekly profit target (0 = disabled)
input double DailyMaxLoss        = 30.0;    // Daily max loss (0 = disabled)
input bool   GuardAllSymbols     = true;    // Lock enforcement scope: all symbols

input group "=== Strategy A: trendline break ==="
input int    BuyConfirmCandles   = 2;       // Bullish confirmations after break
input int    SellConfirmCandles  = 3;       // Bearish confirmations after break
input bool   AllowBuys           = true;
input bool   AllowSells          = true;
input bool   UseManualLines      = false;   // Use manually drawn OBJ_TREND lines
input int    SwingStrength       = 3;       // Fractal strength (bars each side)
input int    Lookback            = 120;     // Bars to search for swings
input int    MinSwingGap         = 6;       // Min bars between anchors
input int    CleanBars           = 8;       // Bars before break on original side
input int    TrendFilterEMA      = 0;       // EMA trend filter on TrendTF (0 = off)

input group "=== Strategy B: session sweep (server-time hours) ==="
input int AsianStartHour  = 0;              // Asian session start (0-23)
input int AsianEndHour    = 6;              // Asian session end (1-24)
input int LondonStartHour = 8;              // London session start (0-23)
input int LondonEndHour   = 11;             // London session end (1-24)
input int MinSweepPoints  = 20;             // Min sweep beyond level (points)

input group "=== Shared risk & execution ==="
input int    SLBufferPoints   = 50;         // SL buffer beyond setup extreme (points)
input double RiskReward       = 2.0;        // TP = RiskReward x risk
input double BreakevenAtR     = 1.0;        // Move SL to entry at this R (0 = off)
input int    MaxTradesPerDay  = 5;          // Daily EA entry cap (0 = unlimited)
input int    MaxSpreadPoints  = 0;          // Max spread in points (0 = off)
input double RiskPercent      = 0.5;        // % equity risked per trade (0 = fixed lot)
input double FixedLot         = 0.01;       // Lot when RiskPercent = 0
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

//--- signal dedupe (per signal candle time)
datetime g_lastBuyBreakBar  = 0;
datetime g_lastSellBreakBar = 0;
datetime g_lastSweepBar     = 0;

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
      vol = FloorToStep(FixedLot, vstep, vd);
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
//| Shared entry path: all gates, then send order                    |
//+------------------------------------------------------------------+
bool TryEnter(const string sym, bool isBuy, double sl, string tag)
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
   //--- one position per symbol+magic
   if(ManagedPositionExists(sym))
     { SetBlockReason("position already open on " + sym); return false; }
   //--- daily entry cap (shared across both strategies)
   if(MaxTradesPerDay > 0)
     {
      int cnt = TodayEntryCount();
      if(cnt < 0) { SetBlockReason("entry count unavailable"); return false; }
      if(cnt >= MaxTradesPerDay)
        { SetBlockReason("daily entry cap reached"); return false; }
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
   double tp = NormPrice(sym, isBuy ? entry + RiskReward * risk
                                    : entry - RiskReward * risk);
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
   if(BreakevenAtR <= 0.0) return;
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
      if(g_be[idx].done || g_be[idx].risk <= 0.0) continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double profitDist = (type == POSITION_TYPE_BUY)
                          ? SymbolInfoDouble(sym, SYMBOL_BID) - open
                          : open - SymbolInfoDouble(sym, SYMBOL_ASK);
      if(profitDist < BreakevenAtR * g_be[idx].risk) continue;

      // never increase risk: SL moves only toward/past entry
      bool improves = (type == POSITION_TYPE_BUY) ? (open > sl || sl == 0.0)
                                                  : (open < sl || sl == 0.0);
      if(!improves) { g_be[idx].done = true; continue; }

      double pt = SymPoint(sym);
      long stopsLvl  = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
      long freezeLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
      double minDist = MathMax(stopsLvl, freezeLvl) * pt;
      double cur = (type == POSITION_TYPE_BUY)
                   ? SymbolInfoDouble(sym, SYMBOL_BID)
                   : SymbolInfoDouble(sym, SYMBOL_ASK);
      if(MathAbs(cur - open) < minDist)
        {
         LogT("be_lvl_" + (string)ticket, "Breakeven deferred: inside stops/freeze level.");
         continue;
        }
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
      PrintFormat("Strategy B SELL setup: swept %s by %.1f pt", namesHi[bestIdx], bestSweep / pt);
      if(TryEnter(g_goldSymbol, false, sl, "GB_B_SELL"))
        {
         g_lastSweepBar = sig.time;
         GlobalVariableSet(g_gvSigB, (double)g_lastSweepBar);
        }
     }
   else
     {
      sl = sig.low - SLBufferPoints * pt;
      PrintFormat("Strategy B BUY setup: swept %s by %.1f pt", namesLo[bestIdxB], bestSweepB / pt);
      if(TryEnter(g_goldSymbol, true, sl, "GB_B_BUY"))
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
                 (StrategyMode == SESSION_SWEEP) ? "SESSION_SWEEP" : "BOTH";
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
   // restore signal-bar dedupe so a restart cannot re-fire an old signal
   if(GlobalVariableCheck(g_gvSigAB)) g_lastBuyBreakBar  = (datetime)GlobalVariableGet(g_gvSigAB);
   if(GlobalVariableCheck(g_gvSigAS)) g_lastSellBreakBar = (datetime)GlobalVariableGet(g_gvSigAS);
   if(GlobalVariableCheck(g_gvSigB))  g_lastSweepBar     = (datetime)GlobalVariableGet(g_gvSigB);

   //--- input validation
   if(RiskPercent < 0 || FixedLot <= 0 || RiskReward <= 0 ||
      BreakevenAtR < 0 || MaxTradesPerDay < 0 || MaxSpreadPoints < 0 ||
      SLBufferPoints < 0 || MinSweepPoints <= 0 ||
      DailyProfitTarget < 0 || WeeklyProfitTarget < 0 || DailyMaxLoss < 0 ||
      NewsMinsBefore < 0 || NewsMinsAfter < 0)
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
   g_trendActive = (StrategyMode == TRENDBREAK || StrategyMode == BOTH);
   g_goldActive  = (StrategyMode == SESSION_SWEEP || StrategyMode == BOTH);

   if(g_trendActive && !SymbolSelect(g_trendSymbol, true))
     { Print("INIT: trend symbol '" + g_trendSymbol + "' unavailable - Strategy A disabled."); g_trendActive = false; }
   if(g_goldActive && !SymbolSelect(g_goldSymbol, true))
     { Print("INIT: gold symbol '" + g_goldSymbol + "' unavailable - Strategy B disabled."); g_goldActive = false; }
   if(!g_trendActive && !g_goldActive)
     { Print("INIT FAIL: no strategy leg could be enabled."); return INIT_FAILED; }

   //--- optional EMA trend filter for Strategy A
   if(TrendFilterEMA > 0 && g_trendActive)
     {
      g_emaHandle = iMA(g_trendSymbol, TrendTF, TrendFilterEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_emaHandle == INVALID_HANDLE)
        { Print("INIT: EMA handle failed on " + g_trendSymbol + " - Strategy A disabled."); g_trendActive = false; }
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
      StrategyA();
   if(g_goldActive && IsNewBar(g_goldSymbol, GoldTF, g_lastGoldBar))
      StrategyB();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   Monitor();
   // also check for new bars here so a quiet chart still evaluates
   if(g_trendActive && IsNewBar(g_trendSymbol, TrendTF, g_lastTrendBar))
      StrategyA();
   if(g_goldActive && IsNewBar(g_goldSymbol, GoldTF, g_lastGoldBar))
      StrategyB();
  }
//+------------------------------------------------------------------+
