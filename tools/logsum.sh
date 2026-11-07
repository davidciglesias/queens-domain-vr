#!/bin/sh
# Prints [MELEE] lines plus the last 100 lines of the UEVR log, with long lines trimmed.
LOG="${APPDATA:-$HOME/AppData/Roaming}/UnrealVRMod/QueensDomain-Win64-Shipping/log.txt"
[ -f "$LOG" ] || { echo "no log at $LOG"; exit 1; }
echo "== [MELEE] lines"
grep -a -F '[MELEE]' "$LOG" | cut -c1-200
echo "== last 100 lines"
tail -n 100 "$LOG" | cut -c1-200
