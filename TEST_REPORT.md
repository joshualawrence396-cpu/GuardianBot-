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

Short test windows; results say nothing about future profitability.

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
