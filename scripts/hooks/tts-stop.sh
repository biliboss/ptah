#!/usr/bin/env bash
# Ptah Stop hook — speak the gist of the last assistant turn via Kokoro Dora.
# Registered in each Claude Code profile's settings.json (Stop event).
# OPTIMISTIC: never blocks the turn — any failure exits 0 silently.
PTAH=/Users/billiboss/src/ptah/zig-out/bin/ptah
payload=$(cat 2>/dev/null)
[ -x "$PTAH" ] || exit 0
python3 - "$payload" "$PTAH" <<'PY' 2>/dev/null || true
import sys, json, re, subprocess
try:
    p = json.loads(sys.argv[1]); ptah = sys.argv[2]
    tp = p.get("transcript_path")
    if not tp:
        sys.exit(0)
    last = None
    with open(tp, encoding="utf-8") as f:
        for line in f:
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("type") == "assistant":
                parts = o.get("message", {}).get("content", [])
                txt = "".join(b.get("text", "") for b in parts
                              if isinstance(b, dict) and b.get("type") == "text")
                if txt.strip():
                    last = txt.strip()
    if not last or len(last) < 40:
        sys.exit(0)                       # skip trivial turns
    clean = re.sub(r'[#*`_>\[\]()|]', '', last)
    clean = re.sub(r'\s+', ' ', clean).strip()
    first = re.split(r'(?<=[.!?])\s', clean)[0][:240]
    if len(first) < 20:
        sys.exit(0)
    subprocess.run([ptah, first], timeout=8)
except Exception:
    pass
PY
exit 0
