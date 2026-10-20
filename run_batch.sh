#!/usr/bin/env bash
# Sequential MT5 tester batch for Strategy C variants on V75.
D="$USERPROFILE/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
INI="C:\\Users\\user\\GuardianBot\\tester_run.ini"
BASE='StrategyMode=3\nTrendSymbol=Volatility 75 (1s) Index.0\nTrendTF=15\nRiskPercent=0\nFixedLot=0.05\nMaxConsecLossesDay=2\nMaxTradesPerDay=5\nAllowSells=0\nEntryMinBodyPct=50\nDailyProfitTarget=5\nDailyMaxLoss=5\nWeeklyProfitTarget=15\n'

# name|extra-settings pairs
printf "%bMoneySL_USD=2.5\nMoneyTP_USD=5\nMilestoneStep=25\nMilestoneRiskUSD=2.5\n" "$BASE" > "$D/MQL5/Profiles/Tester/v_mile.set"
printf "%bRiskReward=1.5\n" "$BASE" > "$D/MQL5/Profiles/Tester/v_rr15.set"
printf "%bBreakevenAtR=0.5\n" "$BASE" > "$D/MQL5/Profiles/Tester/v_be05.set"
printf "%bTrendTF=5\n" "$BASE" | sed 's/TrendTF=15/TrendTF=5/' > "$D/MQL5/Profiles/Tester/v_m5.set"
printf "%bTrailStartR=1.0\nTrailDistR=0.5\n" "$BASE" > "$D/MQL5/Profiles/Tester/v_trail.set"
printf "%bPyramidEnabled=1\nPyramidMinProfitR=1.0\n" "$BASE" > "$D/MQL5/Profiles/Tester/v_pyr.set"

run() {
  local set="$1" report="$2" period="${3:-M15}"
  sed -i "s/ExpertParameters=.*/ExpertParameters=$set.set/; s/Report=.*/Report=$report/; s/Period=.*/Period=$period/" "C:/Users/user/GuardianBot/tester_run.ini"
  rm -f "$D/$report.htm"
  taskkill //F //IM terminal64.exe 2>/dev/null; taskkill //F //IM metatester64.exe 2>/dev/null; sleep 5
  "C:/Program Files/MetaTrader 5/terminal64.exe" /config:"$INI" &
  echo "=== $report launched $(date +%H:%M:%S)"
  for i in $(seq 1 90); do
    sleep 10
    if [ -f "$D/$report.htm" ]; then echo "=== $report done"; return; fi
  done
  echo "=== $report TIMED OUT"
}

run v_mile  GB_v_mile
run v_rr15  GB_v_rr15
run v_be05  GB_v_be05
run v_m5    GB_v_m5 M5
run v_trail GB_v_trail
run v_pyr   GB_v_pyr
echo "=== BATCH COMPLETE $(date +%H:%M:%S)"
