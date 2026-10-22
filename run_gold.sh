#!/bin/bash
D="$USERPROFILE/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
TERM="C:\Program Files\MetaTrader 5\terminal64.exe"
INI="C:\Users\user\GuardianBot\tester_run.ini"
run() {
  local set=$1 rep=$2
  sed -i "s/ExpertParameters=.*/ExpertParameters=$set/; s/Report=.*/Report=$rep/" "$INI"
  taskkill //F //IM terminal64.exe 2>/dev/null
  taskkill //F //IM metatester64.exe 2>/dev/null
  rm -f "$D/$rep.htm"
  sleep 5
  "$TERM" /config:"$INI" &
  for i in $(seq 1 60); do sleep 40; [ -f "$D/$rep.htm" ] && break; done
  cp "$D/$rep.htm" "C:\Users\user\GuardianBot\$rep.htm" 2>/dev/null
  echo "=== $rep ==="
  iconv -f UTF-16 -t UTF-8 "C:\Users\user\GuardianBot\$rep.htm" 2>/dev/null | grep -aE "Total Net Profit|Profit Factor|Total Trades|Drawdown Maximal|Profit Trades|Expected" -A1 | sed 's/<[^>]*>//g' | tr -s ' \t' ' ' | grep -v '^--' | paste - - 2>/dev/null
}
run GB_g_struct.set GB_g_struct
run GB_g_struct15.set GB_g_struct15
run GB_g_rr2.set GB_g_rr2
run GB_g_deep.set GB_g_deep
taskkill //F //IM terminal64.exe 2>/dev/null
echo ALL_DONE
