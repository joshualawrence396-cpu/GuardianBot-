# GuardianBot (MT5 Expert Advisor)

Single-file MT5 EA implementing an account-wide **Profit Guardian** plus two
selectable strategies:

- **Strategy A (TRENDBREAK):** M5 trendline break with confirmation candles
  (intended: Volatility 75 (1s) Index).
- **Strategy B (SESSION_SWEEP):** M15 session liquidity sweep & reclaim
  (default symbol: XAUUSD).

**Demo use only.** This is an implementation of a specification, not a promise
of profitability. Never move to live trading on the strength of a compile or a
short backtest.

## Files

| File | Purpose |
|---|---|
| `GuardianBot.mq5` | The EA (single file, `#include <Trade/Trade.mqh>`, `CTrade`) |
| `README.md` | This document |
| `TEST_REPORT.md` | Acceptance-test checklist with evidence/status |

## Installation

1. Copy `GuardianBot.mq5` to `<MT5 data folder>\MQL5\Experts\GuardianBot.mq5`.
   (In MT5: *File → Open Data Folder*.)
2. Open MetaEditor, open the file, press **Compile** (F7). Target: zero errors,
   zero warnings.
3. Attach the EA to **one** chart. With `StrategyMode=BOTH` it manages both
   configured symbols from that single chart (see *Decisions* below).
4. Ensure *Algo Trading* is enabled and the symbols are in Market Watch.

## Inputs

### Strategy selector

| Input | Default | Meaning |
|---|---|---|
| `StrategyMode` | `TRENDBREAK` | `TRENDBREAK`, `SESSION_SWEEP`, or `BOTH` |
| `TrendSymbol` | `""` | Strategy A symbol; empty = chart symbol. Set the exact broker name incl. suffix, e.g. `Volatility 75 (1s) Index` |
| `GoldSymbol` | `XAUUSD` | Strategy B symbol; set the broker's exact name (e.g. `XAUUSD.m`) |
| `TrendTF` | `PERIOD_M5` | Strategy A timeframe |
| `GoldTF` | `PERIOD_M15` | Strategy B timeframe |

### Profit Guardian (account-wide, deposit currency)

| Input | Default | Meaning |
|---|---|---|
| `DailyProfitTarget` | `50.0` | Daily lock when day P/L ≥ this (0 = off) |
| `WeeklyProfitTarget` | `200.0` | Weekly lock when week P/L ≥ this (0 = off) |
| `DailyMaxLoss` | `30.0` | Daily lock when day P/L ≤ −this (0 = off) |
| `GuardAllSymbols` | `true` | `true`: lock enforcement covers the whole account. `false`: only configured EA symbols |

### Strategy A

`BuyConfirmCandles=2`, `SellConfirmCandles=3`, `AllowBuys`, `AllowSells`,
`UseManualLines=false`, `SwingStrength=3`, `Lookback=120`, `MinSwingGap=6`,
`CleanBars=8`, `TrendFilterEMA=0` (EMA on TrendTF; only trades in the
direction of the trend — 0 disables).

**Strategy C — trend pullback (`StrategyMode=PULLBACK`):** designed for
Volatility indices. H1 close vs `H1EMAPeriod` (50) sets allowed direction;
`ChopFilterPoints` distance from that EMA must be exceeded (anti-chop).
Entry on `TrendTF` (use M15): price must have tagged `EntryEMAPeriod`
(20) — or, if `UseSRRetest`, retested a recent `SRLookback` swing level —
within `PullbackBars`, then the signal candle must close back in trend
direction. SL = `PullbackSwingBars` extreme ± `SLBufferPoints`; TP from
`RiskReward`. Optional `UseBreakoutEntries` adds consolidation-range
breakouts (`RangeBars`, optional `MaxRangePoints` width cap,
`BreakoutStopMidpoint`). Signal-bar dedupe persisted via Global
Variables, same as other legs.

### Strategy B (broker server-time hours)

`AsianStartHour=0`, `AsianEndHour=6`, `LondonStartHour=8`, `LondonEndHour=11`,
`MinSweepPoints=20`. Sessions crossing midnight (e.g. 22→2) are handled
explicitly. Start==end is rejected at init.

### Shared risk & execution

`SLBufferPoints=50`, `RiskReward=2.0`, `BreakevenAtR=1.0` (0 = off),
`MaxTradesPerDay=5` (0 = unlimited), `MaxSpreadPoints=0` (0 = off),
`RiskPercent=0.5` (0 → `FixedLot`), `FixedLot=0.01`,
`TradeStartHour=0`, `TradeEndHour=24` (all day; windows may cross midnight),
`Magic=777002`. Deviation is fixed at 50 points; filling mode is taken from
the symbol (`SetTypeFillingBySymbol`).

### News filter (gold only)

`UseNewsFilterGold=true`, `NewsMinImportance=CALENDAR_IMPORTANCE_HIGH`,
`NewsMinsBefore=30`, `NewsMinsAfter=30`, `CloseBeforeNews=false`,
`NewsCurrencies="USD"` (comma-separated override).

## How the Guardian works

- **P/L:** daily = closed BUY/SELL deal P/L (profit + swap + commission + fee)
  since 00:00 **broker server time** + floating P/L (position profit + swap) of
  all open positions. Weekly = same since Monday 00:00 server time. Balance
  operations are never counted.
- **Lock:** when a threshold is crossed, a terminal Global Variable is set:
  `GRD_<login>_D` / `GRD_<login>_W` storing the period-start timestamp. The
  lock latches for the whole period even if P/L retreats, persists across EA
  restarts, and clears automatically at the next day/week. There is
  deliberately **no input or UI to clear a lock**.
- **While locked:** no new EA entries; the EA attempts to close open positions
  and delete pending orders every tick and every timer beat, scoped by
  `GuardAllSymbols`. Failures are logged and retried.
- **Multi-chart:** Global Variables are shared by all EA instances on the
  same terminal, so two charts observe one account lock. Global Variables are
  **per terminal/computer** — they do not sync across different machines/VPSs.
- **Honesty note:** the 500 ms timer is best-effort, not guaranteed. The EA
  cannot block a manual order sent from MT5 mobile; it detects and closes/
  deletes after the account update arrives. Broker execution, connectivity,
  and freezes can delay enforcement.

## News gate

Uses the built-in MT5 economic calendar (`CalendarValueHistory`,
`CalendarEventById`) — no `WebRequest`. Results are cached 60 s. If the
calendar query fails while the filter is enabled, gold entries are blocked
(**fail-closed**) and the status panel shows `UNAVAILABLE`.

To check calendar coverage: open MT5 → Toolbox → Calendar. If your broker/
terminal has no calendar data, `UseNewsFilterGold=true` will block all gold
entries — either set it `false` (documented risk) or fix coverage. In the
Strategy Tester, calendar availability varies by build; treat news-gate tests
as **not verified in tester** unless your terminal proves otherwise.

## Decisions on spec ambiguities

- `BOTH` mode runs both symbols from **one** chart instance (preferred option).
- `MaxTradesPerDay` is **shared** across strategies; entries are counted by
  distinct `DEAL_POSITION_ID` of `DEAL_ENTRY_IN` deals so partial fills don't
  double-count.
- Multiple manual trendlines: the **most recently created** valid line of the
  required slope is used (`OBJPROP_CREATETIME`, name tie-break). MQL5 does not
  expose a reliable "modified" timestamp.
- News currencies: explicit `NewsCurrencies` input (default `USD`); automatic
  base/quote detection was judged unreliable across brokers and left out.
- P/L is always account-wide; `GuardAllSymbols` only scopes *enforcement*.

## Known limitations

- Floating P/L cannot include commissions already paid at open unless the
  broker exposes them via position fields (they are counted when the deal
  closes).
- Manual trendlines drawn on **MT5 mobile** do not reach the desktop terminal;
  draw lines on the desktop/VPS chart.
- `HistorySelect` failure blocks new entries (safe direction) and is logged.
- A restart during the *same* signal candle is deduplicated via persisted
  signal-bar Global Variables; a pre-existing position also blocks re-entry.

## Verification status

- **Compilation: VERIFIED.** MetaEditor64 build **5.0.0.6274**:
  `Result: 0 errors, 0 warnings` — see `compile.log`, `GuardianBot.ex5`.
- **Strategy A backtest: RUN.** `Volatility 75 (1s) Index.0` M5,
  2026.10.01–10.20, 19 trades — report `GuardianBot_V75_M5.htm`.
- **Strategy B backtest: RUN.** `XAUUSD.0` M15, same window, 13 trades —
  report `GuardianBot_XAU_M15.htm`.
- **Guardian: partially verified in tester** — daily profit AND loss locks
  latched, positions force-closed, locks reset next day.
- **News gate: fail-closed verified** — calendar empty in tester → all gold
  entries blocked; not verified against real events.
- Live-demo items (restart persistence, manual-trade enforcement,
  weekly lock) remain NOT RUN — see `TEST_REPORT.md`.

**Broker symbol note:** on Deriv **Zero Spread** accounts every symbol
carries a `.0` suffix, e.g. `Volatility 75 (1s) Index.0`, `XAUUSD.0`.
Set `TrendSymbol`/`GoldSymbol` to your broker's exact names.
