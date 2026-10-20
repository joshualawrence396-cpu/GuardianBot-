# GuardianBot — Test Report

**Build environment:** Windows workstation. MetaTrader 5 desktop was
installed during this task (official `mt5setup.exe` from MetaQuotes) at
`C:\Program Files\MetaTrader 5`.

**Compile evidence:** MetaEditor64 **build 5.0.0.6274**, CLI compile:
```
Result: 0 errors, 0 warnings, 1067 ms elapsed, cpu='X64 Regular'
```
Full log: `compile.log`. Output `GuardianBot.ex5` is committed as build
evidence alongside the source.

**Consequence:** compilation is **VERIFIED**. All runtime/demo/backtest
items remain **NOT RUN** (no broker account / no history in a fresh terminal).

**Static verification performed:**

- Structural check: 162 `{` / 162 `}`, 724 `(` / 724 `)`, 110 `[` / 110 `]` — balanced.
- Manual review of MQL5 API usage against documented signatures
  (`CalendarValueHistory`, `CalendarEventById`, `HistoryDealGet*`,
  `ObjectGetValueByTime`, `SetTypeFillingBySymbol`, `CTrade` methods).
- Logic review of spec §6.3 indexing (break at shift `k=N+1`,
  confirmations `1..N`, clean bars `k+1..k+CleanBars`) and wrapped-session
  window math.

## A. Compilation and initialization

| Test | Status | Evidence |
|---|---|---|
| Compiles, 0 errors / 0 warnings | **PASS** | MetaEditor64 build 5.0.0.6274: `Result: 0 errors, 0 warnings` — `compile.log`, `GuardianBot.ex5` |
| Invalid inputs rejected at init | NOT RUN | `OnInit` validation implemented: negative risk, `RiskReward<=0`, invalid hour ranges, `Buy/SellConfirmCandles<1`, `Lookback` too small, empty `NewsCurrencies` while filter on |
| Missing symbol/history → safe block | NOT RUN | `SymbolSelect` failure disables that leg; `CopyRates` shortfall skips the evaluation; entries blocked when P/L unverifiable |
| 500 ms timer starts / failure handled | NOT RUN | `EventSetMillisecondTimer(500)`; failure logged, `OnTick` path remains |
| Clean deinit | NOT RUN | `EventKillTimer()`, `Comment("")` in `OnDeinit` |

## B. Strategy A

| Test | Status | Notes |
|---|---|---|
| BUY: descending break + N bullish confirmations, ≤1 signal | NOT RUN | Break evaluated only at exact shift `k` |
| SELL: ascending break + N bearish confirmations | NOT RUN | Mirror logic |
| Wrong-direction confirmation blocks | NOT RUN | `close<=open` (buy) / `close>=open` (sell) check |
| Confirmation on wrong side of line blocks | NOT RUN | Close-vs-line check per confirmation shift |
| Clean-trend violation blocks | NOT RUN | Shifts `k+1..k+CleanBars` must stay on original side |
| Only confirmed swings used | NOT RUN | Anchors require `SwingStrength` bars each side; search starts at `max(SwingStrength+1, k+1)` |
| Auto line vs chart examples | NOT RUN | `OBJ_TREND` drawn post-trade (`GB_A_BUY`/`GB_A_SELL`) |
| Manual line mode deterministic | NOT RUN | Most recently created valid line of required slope |
| SL/TP/volume/stops correct | NOT RUN | SL = setup extreme ± `SLBufferPoints`; `SYMBOL_TRADE_STOPS_LEVEL` validated |
| Tester report saved | NOT RUN | — |

## C. Strategy B

| Test | Status | Notes |
|---|---|---|
| Ranges not used before session ends | NOT RUN | `CompletedSessionWindow` returns most recent *completed* window only |
| Prev-day levels = completed D1 | NOT RUN | `CopyRates(PERIOD_D1, shift 1)` |
| BUY sweep/reclaim conditions | NOT RUN | Low below level ≥ `MinSweepPoints`, close back above, bullish |
| SELL sweep/reclaim conditions | NOT RUN | Mirror |
| Wick-through without reclaim → no trade | NOT RUN | Close must be back across the level |
| No duplicate entries per candle | NOT RUN | Single best candidate + persisted signal-bar GV |
| Missing session data blocks safely | NOT RUN | Level skipped + logged; no levels → no trade |
| Tester report saved | NOT RUN | — |

## D. Guardian

| Test | Status | Notes |
|---|---|---|
| Daily profit lock | NOT RUN | GV `GRD_<login>_D` latches day-start ts |
| Daily loss lock | NOT RUN | Same mechanism, negative threshold |
| Weekly profit lock | NOT RUN | GV `GRD_<login>_W` latches week-start ts |
| Lock survives restart + P/L retreat | NOT RUN | Stored timestamp vs current period-start |
| Locks reset next period | NOT RUN | Timestamp match required |
| Lock blocks both strategies | NOT RUN | `TryEnter` checks lock first |
| `GuardAllSymbols=true` closes all | NOT RUN | Enforcement loops all positions/orders |
| `=false` scopes to configured symbols | NOT RUN | `InEnforcementScope` |
| Manual/mobile trade detected & closed | NOT RUN | 500 ms best-effort; see README limitation |
| Pending orders deleted while locked | NOT RUN | `OrderGetTicket` loop + `OrderDelete` |
| Failed close/delete logged & retried | NOT RUN | Retcode logged via throttled `LogT` |
| Two instances share lock | NOT RUN | Global Variables per terminal |
| P/L excludes balance ops, includes costs | NOT RUN | BUY/SELL deals + profit/swap/commission/fee |

## E. News gate

| Test | Status | Notes |
|---|---|---|
| High-impact event in window blocks | NOT RUN | `importance >= NewsMinImportance` in `now∓window` |
| Event outside window doesn't block | NOT RUN | Window is `NewsMinsBefore`/`After` only |
| Calendar failure → fail-closed | NOT RUN | `g_newsAvail=false` blocks gold entries |
| Unavailability visible | NOT RUN | Status panel + log |
| `CloseBeforeNews` closes only EA gold | NOT RUN | Filtered by symbol + `Magic` |
| Tester limitation documented | DONE | README explains calendar-in-tester caveat |

## F. Shared management & resilience

| Test | Status | Notes |
|---|---|---|
| Risk sizing respects % + volume step | NOT RUN | Tick value/size based, floored to step |
| Below-min volume blocks (no risk bump) | NOT RUN | Explicit skip in `CalcVolume` |
| Spread/time filters | NOT RUN | `MaxSpreadPoints`, hour window incl. midnight wrap |
| Breakeven at R, never increases risk | NOT RUN | Initial risk persisted per-ticket in GVs; SL only moves toward/past entry; preserves TP |
| One position per symbol+magic | NOT RUN | `ManagedPositionExists` |
| Daily entry cap + reset | NOT RUN | Distinct `DEAL_POSITION_ID` count since day-start |
| No duplicate entry after restart | NOT RUN | Signal-bar times persisted in GVs; position check |
| No real-money trades in dev | DONE | No terminal access used for trading at all |

## Recommended first test to run

1. Compile in MetaEditor (build ≥ 4000 preferred); paste the compiler output
   into this file and flip section A.
2. Attach to a **demo** Deriv MT5 account on a V75(1s) M5 chart with
   `DailyProfitTarget=1.0`, `DailyMaxLoss=1.0` so locks trigger quickly;
   verify the lock latches, persists across restart, and clears next day.
