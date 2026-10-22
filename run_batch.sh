cd "/c/Users/user/GuardianBot"
D="$USERPROFILE/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
TLOG="$D/Tester/logs/20261022.log"
finals() { iconv -f UTF-16 -t UTF-8 "$TLOG" 2>/dev/null | grep -ac "final balance"; }
termup() { tasklist | grep -qiE "terminal64|metatester"; }
run() {
  sed -i "s/ExpertParameters=.*/ExpertParameters=$2/; s/Report=.*/Report=$3/" tester_run.ini
  FB=$(finals)
  taskkill //F //IM terminal64.exe //IM metatester64.exe 2>/dev/null
  for i in $(seq 1 30); do sleep 3; termup || break; done
  sleep 5
  "C:\Program Files\MetaTrader 5\terminal64.exe" /config:"$PWD/tester_run.ini" &
  for i in $(seq 1 20); do sleep 6; tasklist | grep -qi metatester64 && break; done
  if ! tasklist | grep -qi metatester64; then
    taskkill //F //IM terminal64.exe 2>/dev/null
    for i in $(seq 1 30); do sleep 3; termup || break; done
    sleep 5
    "C:\Program Files\MetaTrader 5\terminal64.exe" /config:"$PWD/tester_run.ini" &
    for i in $(seq 1 20); do sleep 6; tasklist | grep -qi metatester64 && break; done
  fi
  echo "=== $1 started $(date +%H:%M)"
  for i in $(seq 1 95); do sleep 40; [ "$(finals)" -gt "$FB" ] && break; done
  sleep 5; cp "$D/$3.htm" "$3.htm" 2>/dev/null
  taskkill //F //IM terminal64.exe //IM metatester64.exe 2>/dev/null
  echo "=== $1 done $(date +%H:%M): $3.htm"
}
run "Loose gates"      GB_ge_loose.set  GB_ge_loose
run "RR 3.0"           GB_ge_rr3.set    GB_ge_rr3
run "RiskPercent 1"    GB_ge_risk.set   GB_ge_risk
run "Strict quality"   GB_ge_strict.set GB_ge_strict
echo ALL_DONE
