# Queen's Domain VR: rules
- Never read a file over ~300 lines whole: grep -n first, then read line ranges;
  use CODEMAP.md. Never read scripts/libs/* wholesale. Use bare file paths,
  never @file references.
- Never print whole logs: use tools/logsum.sh. I won't paste logs; read them
  yourself.
- Delegate big reads/searches/log summaries to a cheapest-model subagent that
  returns <=15 lines.
- Terse replies: don't re-quote code or restate plans. Small targeted edits; no
  whole-file rewrites; don't re-read unchanged files.
- Back up files before first edit. Wrap new code in pcall; no per-frame table
  allocation in hot callbacks.
- Don't invent class/function names; if unknown, add logging to discover them.
- Keep STATE.md and CODEMAP.md current. You can't run /clear or /compact: tell
  me via the HANDOFF block. Never suggest compacting mid-change.
- Spoilers: I'm avoiding them, so mechanics-only summaries; don't quote story,
  boss, item, or location names from dumps or logs.
