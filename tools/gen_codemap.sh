#!/bin/sh
# Rebuilds CODEMAP.md from tools/codemap_notes.md plus a generated function list.
cd "$(dirname "$0")/.." || exit 1
S="${APPDATA:-$HOME/AppData/Roaming}/UnrealVRMod/QueensDomain-Win64-Shipping/scripts/queens_domain_vr.lua"
{
  cat tools/codemap_notes.md
  echo; echo "## Key lines (generated)"
  echo "6dof_right checks: $(grep -n '6dof_right' "$S" | cut -d: -f1 | tr '\n' ' ')"
  echo "Attack calls: $(grep -n -E 'Attack(Pressed|Released)\(\)' "$S" | cut -d: -f1 | tr '\n' ' ')"
  echo "Notify hooks: $(grep -n -E 'OnNotify(Begin|End)_' "$S" | cut -d: -f1 | tr '\n' ' ')"
  echo; echo "## Functions in queens_domain_vr.lua (generated: line range, name)"
  awk 'BEGIN{p="";s=0} /^(local +)?function |^[A-Za-z_.:]+ *= *function|^[a-zA-Z_.]*(register|callbacks)[A-Za-z_.:]*\(.*function|^register_key_bind/{ if(p!="")printf "%d-%d %s\n",s,NR-1,p; p=$0; gsub(/[ \t\r]+$/,"",p); s=NR; next} /^end/{ if(p!=""){printf "%d-%d %s\n",s,NR,p;p=""}}' "$S" | sed -E 's/\(.*$//; s/^([0-9-]+) (local )?function /\1 /; s/uevr\.sdk\.callbacks\./callback /'
} > CODEMAP.md
