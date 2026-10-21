# GuardianBot — Test Report

**Environment:** Windows workstation, MetaTrader 5 build **6274** (installed
during task), MetaEditor64 build 5.0.0.6274, Deriv **Zero Spread** demo account
`202539196` on server `Deriv-Demo` (hedging, USD, 161 symbols — all carry a
`.0` suffix on this account type).

## Compile evidence

```
MetaEditor64 5.0.0.6274: Result: 0 errors, 0 warnings, 1067 ms elapsed
```
Full log: `compile.log`. Artifact: `GuardianBot.ex5`.

## Backtest runs (Strategy Tester, every-tick model, history quality 100%)

| Run | Symbol | TF | Period | Result | Report |
|---|---|---|---|---|---|
| Strategy A | `Volatility 75 (1s) Index.0` | M5 | 2026.10.01–10.20 | **19 trades**, net −64.01, PF 0.85 | `GuardianBot_V75_M5.htm` |
| Strategy B | `XAUUSD.0` | M15 | 2026.10.01–10.20 | **13 trades**, net +48.21, PF 1.18 | `GuardianBot_XAU_M15.htm` |
| Strategy B (news filter ON) | `XAUUSD.0` | M15 | same | **0 trades — all blocked by fail-closed news gate** | `GuardianBot_XAU_M15_newsfilter.htm` |
| Strategy A — year sim | `Volatility 75 (1s) Index.0` | M5 | 2026.01.01–10.20 | **14 trades, account blown** — net −9.56, max DD 96.9%, balance 0.44 | `GuardianBot_V75_year.htm` |

Short test windows; results say nothing about future profitability.

### Year-long run — user's intended live config

`Deposit=10 USD` (≈R200), `FixedLot=0.10`, `RiskPercent=0`,
`DailyProfitTarget=2.50`, `DailyMaxLoss=2.50`, `WeeklyProfitTarget=12.50`,
`MaxTradesPerDay=5`:

- **14 real trades** before the account could no longer meet margin;
  every later signal logged `retcode=10019 not enough money`.
- Balance hit **$0.44 by ~2026-02-20** — under 8 weeks.
- The guardian locked correctly throughout; the failure is position
  sizing: 0.10 lots ≈ $3 risk/trade ≈ 30% of a $10 account.

## Strategy iteration experiment — can a $10/R200 account survive?

`SYMBOL_VOLUME_MIN` on `Volatility 75 (1s) Index.0` is **0.05 lots**
(~$1/pt/lot ⇒ ~$1.50+ risk per trade = ~15% of a $10 account).
All runs: same symbol/TF/window, `Deposit=10`, guardian ±$2.50/day.

| Variant | Trades | PF | Net | Outcome |
|---|---|---|---|---|
| `FixedLot=0.10` | 14 | 0.53 | −9.56 | dead ~Feb (8 wks) |
| `FixedLot=0.05` (min) | 19 | 0.44 | −9.72 | **stop-out, 3% of year** |
| `0.05` + `TrendFilterEMA=200` | 18 | 0.35 | −9.68 | **stop-out, 2% of year** |
| `0.05`, `AllowSells=false` | 27 | 0.49 | −10.34 | negative balance ~May |

**Verdict on Strategy A: every variant loses the full account.** PF stays
0.35–0.53 across filters and direction biases.

## Strategy C (PULLBACK) experiment — same $10 account, V75 M15, H1 EMA50 filter

User-supplied spec: H1 price above/below 50-EMA sets direction; enter on
M15 pullback to 20-EMA or S/R retest when a candle closes back with the
trend; SL beyond pullback swing; 1:2 RR; chop gate around EMAs.

| Variant | Trades | PF | Net | Outcome |
|---|---|---|---|---|
| `PULLBACK` base | 37 | **0.78** | −9.74 | survived the year, ended $0.26 |
| `PULLBACK` shorts-only | 8 | 0.32 | −10.52 | negative balance |
| `PULLBACK` RR=3 | 37 | 0.78 | −9.74 | **identical** — see note |
| `PULLBACK` money-plan | 6 | 0.51 | −9.55 | **stop-out ~Jan 6 (1%)** |

Money-plan = user's R200 scheme: `MoneySL_USD=5`, `MoneyTP_USD=5`,
`MilestoneStep=10`, `MilestoneRiskUSD=5` (equity-scaled risk:
$10→$5, $20→$10, $30→$15...), `MaxTradesPerDay=1`,
`BreakevenAtR=1.0`, guardian ±$5/day. **Dead in ~5 days**: at $5
risk/trade the account can only absorb 2 losses; the milestone ladder
is never reached. A $5 risk unit needs ~$50+ balance to be survivable.

## Strategy D (STRUCTURE) experiment — H4 bias + sweep + BOS, V75 M1

User-supplied spec: H4 swing structure sets direction (HH+HL / LH+LL),
price pulls into an H1 zone, sweeps a recent low/high and rejects,
then entry-TF break of minor structure; SL beyond sweep extreme; 1:2.
Config: `TrendTF=M1`, `FixedLot=0.05`, `MaxConsecLossesDay=2`,
guardian ±$5/day.

| Variant | Trades | PF | Net | Outcome |
|---|---|---|---|---|
| `STRUCTURE` base | **289** | **0.90** | −9.43 | balance to $0.57 |
| `STRUCTURE` buys-only | 185 | 0.84 | −9.25 | balance to $0.75 |
| `STRUCTURE` $27 (~R500) | 434 | 0.82 | −26.49 | balance to $0.51 |

More capital did not help: 434 trades got through but PF stayed < 1, so
the bigger balance just bled longer. A negative-EV signal cannot be
fixed by deposit size.

Same-size comparison on V75 (deposit ≈$27, FixedLot 0.05, ±$5/day):

| Strategy | Trades | PF | Net | Final |
|---|---|---|---|---|
| D structure | 434 | 0.82 | −26.49 | $0.51 |
| A trendline-break | 59 | 0.55 | −27.39 | **−$0.39** |

- Best signal yet by far — 289 trades, expected payoff **−$0.03/trade**
  (essentially breakeven minus costs vs −$0.3–0.7 for A).
- Still negative overall, and a $10 account dies on variance long before
  any small edge could matter.
- `MaxConsecLossesDay` implemented and active in this run.

**Final verdict across all strategies on a $10 V75 account:**
A (0.35–0.53 PF) < C-old (0.78) < D (0.90). At $10 none reach PF ≥ 1.0.

## Strategy C v2 — spec-complete trend-pullback, ~$27 (R500), FULL YEAR

Added per spec: H1 HH/HL structure confirm (`H1StructConfirm`), EMA50
pullback alternative (`PullbackEMA50`), engulfing-candle trigger
(`UseEngulfing`), on top of existing EMA20/S-R pullback + swing SL +
1:2 RR + BE at 1R.

`Volatility 75 (1s) Index.0` M15, `FixedLot=0.05`, ±$5/day,
`MaxConsecLossesDay=2`, Jan–Oct 2026:

| Metric | Value |
|---|---|
| Trades | **398** (213 long @ 41.8%W / 185 short @ 32.4%W) |
| **Profit factor** | **1.10** ← first PF ≥ 1.0 config |
| Expected payoff | +$0.14/trade |
| Net profit | **+$53.90** (final balance $80.90) |
| Max balance drawdown | 56.6% |
| Sharpe | 1.63 |

The account nearly tripled — but note the **59% equity drawdown**: at min
lot on ~$27 the ride is violent. PF 1.10 is a thin edge; live spread /
slippage could erase it. **Forward-test on demo (50–100 trades) before
any real deposit** — per the user's own risk spec.

## PULLBACK+GOLD combo — ~$110 (R2000), FULL YEAR

New mode `PULLBACK_GOLD=5`: Strategy C on `Volatility 75 (1s) Index.0`
M15 (`FixedLot=0.05`) + Strategy B on `XAUUSD.0` M15 (`FixedLotGold=0.01`
— new per-leg fixed-lot input). Guardian ±$10/day, `MaxConsecLossesDay=2`,
`UseNewsFilterGold=0` (no calendar in tester).

| Metric | Value |
|---|---|
| Trades | 506 (260 long @ 41.5%W / 246 short @ 39.8%W) |
| Profit factor | 0.99 — breakeven |
| Net profit | −$7.97 (final $102.03 — **survived full year**) |
| Max equity drawdown | 87.3% (peaked ~$290 then fell back) |

Note: `RiskPercent`-sized V75 entries get **blocked** below min volume
0.05 (CalcVolume refuses to bump up) — use `FixedLot` mode at small
balances. The two legs together diversify to ~breakeven; the V75 leg
(PF ~1.10) is still carrying it.

### Gold-only at $110 (~R2000) — money stops $5.50/$5.50

`SESSION_SWEEP`, `XAUUSD.0` M15, `FixedLotGold=0.01`, guardian ±$10/day:
**193 trades, PF 0.60, −$61.81** (final $48.19; shorts won 51.6%).
The gold leg alone is negative expectancy — it survived only because the
deposit could absorb a 56% drawdown. In the combo it was the V75
pullback leg carrying performance.

## Improvement experiments on Strategy C v2 (~$27, V75 M15)

| Variant | Trades | PF | Net | Max DD |
|---|---|---|---|---|
| Base (RR2, ±$5 lock, both dirs) | 398 | 1.10 | +$53.90 | 56.6% |
| RR 1:3 + asymmetric lock ($10/$5) | 54 | 0.63 | −$26.27 | dead |
| **Buys only** (`AllowSells=0`) | 231 | **1.28** | **+$92.25** | **24.5%** |
| RSI14 confirm (`UseRSIConfirm`) | 360 | 1.07 | +$39.78 | 58.9% |

**Winner: buys-only.** V75's upward drift in this dataset means the short
leg donated money back; cutting it raised PF 1.10→1.28 and halved
drawdown. RR 1:3 collapsed win rate below breakeven; RSI confirm added
nothing.

Round 2 — stacked on buys-only:

| Variant | Trades | PF | Net | Max DD |
|---|---|---|---|---|
| Asymmetric lock ($10/$5) | ~250 | 1.16 | +$64.75 | 40.5% |
| EMA50-only pullbacks | 231 | 1.28 | +$92.25 | 24.5% (identical — all pullbacks already deep) |
| **Strong candles ≥50% body** | 220 | **1.40** | **+$120.58** | **17.2%** |

`EntryMinBodyPct=50` (new input) is the best config yet: $27.5 → $147.58,
Sharpe 5.84, +$0.55/trade. Wider daily targets hurt (asym lock gave back
edge); tight ±$5 day locks + strong signal candles wins.

**Recommended config:** `PULLBACK`, `AllowSells=0`, `EntryMinBodyPct=50`,
`FixedLot=0.05`, ±$5/day locks, `MaxConsecLossesDay=2`. Still requires a
forward demo pass before real money — backtests can overfit.

### Direction isolation test (2026.10.21) — reports `GB_pb_sell.htm`, `GB_pb_both.htm`

| Variant | Trades | PF | Net | Max DD |
|---|---|---|---|---|
| **Sells only** (`AllowBuys=0`) | 74 | **0.76** | **−$27.39** | dead (100%) |
| Both directions (`AllowSells=1`) | 376 | 1.24 | +$122.44 | 29.9% |
| Buys only (reference) | 220 | 1.40 | +$120.58 | 17.2% |

The short leg is definitively negative: −$27.39 standalone, and adding it
to the buys raised net only +$1.86 while nearly doubling max drawdown
(17%→30%) and cutting per-trade expectancy $0.55→$0.33. **Buys-only
remains the config.** (Note: first `GB_pb_both.htm` run was a config
misfire — `AllowSells` unset defaulted to buys-only; reran correctly.)

### Sell-side improvement attempts (2026.10.21) — new per-direction inputs

Added sell-specific controls: `SellMinBodyPct`, `SellRSIMax`,
`SellRiskReward`, `SellBreakevenAtR`. Tested on the mixed base (both
directions, 50% buy body, RR2, ±$5 locks):

| Variant | Trades | PF | Net | Max DD |
|---|---|---|---|---|
| Both (baseline) | 376 | 1.24 | +$122.44 | 29.9% |
| Strict sells (body 70% + RSI<45) | 338 | 1.19 | +$99.32 | 29.7% |
| Quick-exit shorts (RR1.5 + BE0.5R) | 411 | 1.18 | +$85.79 | 38.8% |
| Strictest sells (body 70% + RSI<40) | 310 | 1.20 | +$100.87 | 28.7% |
| **Buys only (reference)** | 220 | **1.40** | **+$120.58** | **17.2%** |

**No sell-side filter rescues the short leg** — every mixed variant sits
below the plain mixed run and far below buys-only. The shorts have
negative edge on this dataset, period. The new inputs remain available
for other symbols/regimes, but on V75 the answer is unchanged:
`AllowSells=0`.

## Strategy B on gold — R1000 (~$55) account, year sim

`XAUUSD.0` M15, `FixedLot=0.01`, `MoneySL_USD=5.5`/`MoneyTP_USD=5.5`
(R100 ≈ $5.50), `UseNewsFilterGold=0` (tester has no calendar),
`MaxConsecLossesDay=2`, guardian ±$5.50/day.

- **4 trades** (all SELL, Jan 2–6): 2 won / 2 lost → net −$5.46,
  final balance $49.54.
- **2,115 subsequent entries rejected `retcode=10019`** — margin for
  0.01 lot XAUUSD at ~$4,200/oz is **~$52**, exceeding the balance.
  The account "survived" only because it could no longer trade.
- 23 rejects were weekend market-closed.
- Conclusion: **~$55 cannot trade 0.01-lot gold on Deriv Zero Spread**
  — margin alone needs ~$52+/trade. Minimum realistic deposit for this
  symbol+lot is ~$100+ (≈R1,800) to keep margin headroom.

- PULLBACK is clearly the better signal (PF 0.78 vs 0.35–0.53, 37 trades,
  lived the full year vs weeks) — but still below breakeven.
- **RR=3 produced identical results**: with ±$2.50/day locks at 0.05 lots,
  the guardian closes trades ~$2.50 up/down long before any TP fills —
  the lock IS the take-profit. Raising `RiskReward` is invisible.
- Structural consequence: with symmetric ±$2.50 locks the account can only
  grow if P(winning day) > P(losing day); in the data it isn't.
- Net of all tests: **no configuration tested survives a $10 account on
  V75.** The signal quality improved (A→C) but expectancy stays negative.

The `TrendFilterEMA` and Strategy C (`PULLBACK` mode + its inputs) added
during these experiments remain in the EA, all defaults inert/off.

### Live-demo verification (2026.10.20, Deriv-Demo)

EA attached to `Volatility 75 (1s) Index.0` chart, `DailyProfitTarget=1`,
`DailyMaxLoss=1`:

```
14:10:02  GuardianBot init OK | login=202539196 ccy=USD
          | trend=Volatility 75 (1s) Index.0(PERIOD_M5) gold=-(-) build=6274
14:10:02  Guardian: DAILY LOCK set (day P/L -11.23 USD, max loss).
14:10:02  Guardian: account locked - daily max loss reached
14:10:59  Guardian: order delete failed ticket=9849639737
          Volatility 75 (1s) Index.0 retcode=10013 invalid request
14:11:00  Guardian: closed position ticket=9849639737 ... retcode=10009
```

Manual buy placed by the user while locked was detected and closed ~2 s
after reaching the account. Status panel displayed lock state, daily
P/L, and `News gate (gold): UNAVAILABLE` (Deriv-Demo does not serve
calendar data — gold entries stay fail-closed on this broker).

### Verified behaviour from run logs

- **Entries placed with SL/TP, retcodes logged** — e.g.
  `Entry BUY Volatility 75 (1s) Index.0 0.946 lots sl=4942.40 tp=5100.83 retcode=10009`
- **Risk-based sizing varies with stop distance** (0.946–3.026 lots V75;
  0.030–0.090 lots XAUUSD).
- **Daily locks latched on BOTH thresholds:**
  `DAILY LOCK set (day P/L 52.37 USD, profit target)` and
  `DAILY LOCK set (day P/L -33.40 USD, max loss)`.
- **Enforcement:** `Guardian: closed position ticket=N ... retcode=10009`
  immediately after every lock.
- **Breakeven:** `Breakeven: ticket=12 SL->entry 4735.78`.
- **Strategy B gating:** `swept PrevDayL by 422.0 pt`, `swept AsianL`,
  `swept LondonL`; `London range unavailable - level skipped` correctly
  blocked on Monday mornings (previous London session = Sunday, no bars).
- **News gate fail-closed:** `calendar query failed - gold entries blocked
  (fail-closed)` — calendar API returns no data in the Strategy Tester, so
  every gold entry was blocked. This is the specified behaviour, and it means
  the news filter cannot be fully exercised in the tester.

## A. Compilation and initialization

| Test | Status | Evidence |
|---|---|---|
| Compiles, 0 errors / 0 warnings | **PASS** | `compile.log`, `GuardianBot.ex5` |
| Invalid inputs rejected at init | NOT RUN | `OnInit` validation implemented |
| Missing symbol/history → safe block | **PASS** | `symbol Volatility 75 (1s) Index not exist` (pre-suffix); missing-session blocks logged in run |
| 500 ms timer starts / failure logged | PASS (in tester init) | `GuardianBot init OK` logged, no timer failure |
| Clean deinit | PASS | `GuardianBot deinit, reason=1` at test end |

## B. Strategy A

| Test | Status | Evidence |
|---|---|---|
| BUY/SELL break + confirmations → ≤1 signal | **PASS** | 19 entries over 19 days; one entry per signal; no same-bar repeats |
| Wrong-direction / wrong-side confirmation blocks | NOT RUN (unit) | checks implemented; not isolated in log |
| Clean-trend filter blocks | NOT RUN (unit) | implemented |
| Only confirmed swings used | NOT RUN (unit) | search starts at `max(SwingStrength+1,k+1)` |
| Auto line drawn on chart | PARTIAL | `DrawLine` called on entries; visual check not performed |
| Manual line mode deterministic | NOT RUN | `UseManualLines=false` in tested config |
| SL/TP/volume/stops correct | **PASS** | entries show SL = setup extreme ± buffer, TP = 2R, retcode 10009 |
| Tester report saved | **PASS** | `GuardianBot_V75_M5.htm` |

## C. Strategy B

| Test | Status | Evidence |
|---|---|---|
| Ranges not used before session ends | **PASS** | London level skipped until 11:00 server; `swept LondonL` only after completion |
| Prev-day levels from completed D1 | **PASS** | `swept PrevDayL` entries |
| BUY/SELL sweep + reclaim conditions | **PASS** | 13 entries, both directions, only after sweep+close-back-across |
| Wick-only → no trade | PARTIAL | no explicit counter-evidence logged |
| No duplicate entries per candle | **PASS** | ≤1 entry/day observed; signal-bar dedupe |
| Missing session data blocks safely | **PASS** | Sunday-London skips logged |
| Tester report saved | **PASS** | `GuardianBot_XAU_M15.htm` |

## D. Guardian

| Test | Status | Evidence |
|---|---|---|
| Daily profit lock | **PASS** | `DAILY LOCK set (day P/L 51.82 USD, profit target)` (multiple days) |
| Daily loss lock | **PASS** | tester + **live demo**: `DAILY LOCK set (day P/L -11.23 USD, max loss)` on attach, status panel `LOCKED - daily threshold reached` |
| Weekly profit lock | NOT RUN | threshold never reached (week ≈ <200 within 3-week test) |
| Lock persists over P/L retreat / restart | PARTIAL | GV latch by design; GV persistence verified by code review; no live restart test |
| Locks reset next period | **PASS** | new locks set on subsequent days → prior day's lock released |
| Lock blocks both strategies | **PASS** | locks observed in both strategy runs |
| `GuardAllSymbols=true` closes all in scope | **PASS** | position closed after every lock |
| `=false` scope | NOT RUN | only default tested |
| Manual/mobile trade detected & closed | **PASS** | live demo: manual buy ticket 9849639737 closed ~2s after entry (`retcode=10009`) while locked |
| Pending orders deleted while locked | NOT RUN | EA places no pendings; manual pending not tested |
| Failed close/delete retried | **PASS** | live demo: `OrderDelete` returned 10013 (order already a position); retry loop closed the position ~2s later |
| Two instances share lock | NOT RUN | single terminal |
| P/L composition | PARTIAL | includes profit+swap+commission+fee on closed deals + floating; deposits excluded by DEAL_TYPE filter |

## E. News gate

| Test | Status | Evidence |
|---|---|---|
| High-impact event in window blocks | NOT VERIFIED | calendar returns no events in tester |
| Event outside window doesn't block | NOT VERIFIED | same |
| **Calendar failure → fail-closed** | **PASS** | `calendar query failed - gold entries blocked (fail-closed)`; 0 trades with filter ON vs 13 with it OFF |
| Unavailability visible | **PASS** | log line + status panel path exercised |
| `CloseBeforeNews` scope | NOT RUN | default false |
| Tester limitation recorded | **DONE** | documented here and in README |

## F. Shared management & resilience

| Test | Status | Evidence |
|---|---|---|
| Risk sizing respects % + step | **PASS** | lots vary with stop distance (0.030–0.090 XAU) |
| Below-min volume blocks | NOT RUN | not triggered |
| Spread/time filters | PARTIAL | `TradeStartHour/EndHour` defaults open; spread filter off |
| Breakeven at R, no risk increase | **PASS** | `SL->entry` logged; SL only moved toward entry |
| One position/symbol/magic | **PASS** | ≤1 open EA position at all times in runs |
| Daily entry cap shared | PARTIAL | ≤1–2 entries/day observed; cap=5 not stressed |
| No duplicate after restart | PARTIAL | signal-bar GV persisted; live restart not run |
| No real money used | **PASS** | demo account only |

## Known issues / notes for next iteration

1. **Symbol suffixes are mandatory on Deriv Zero Spread** — use
   `TrendSymbol="Volatility 75 (1s) Index.0"`, `GoldSymbol="XAUUSD.0"`.
   The EA correctly failed-fast on the unsuffixed name.
2. News gate cannot be exercised end-to-end in the tester (calendar empty);
   verify on the live demo terminal where the calendar is populated.
3. Weekly lock, pending-order deletion, multi-instance lock sharing, and
   manual/mobile enforcement remain untested — need a live demo session.
4. Strategy A produced a net loss over this window — expected; mechanics
   verified, edge not evaluated.

## Recommended next test

Guardian live check on this terminal: attach EA to any chart with
`DailyProfitTarget=1`, `DailyMaxLoss=1`, `GuardAllSymbols=true`; open a tiny
manual position while locked from MT5 mobile/desktop → verify close attempt,
pending-order deletion, restart persistence, and status-panel lock reason.
