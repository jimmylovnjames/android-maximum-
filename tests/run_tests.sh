#!/usr/bin/env bash
# REDLINE test suite. Runs entirely headless -- no display, no device.
#
#   tests/run_tests.sh [path-to-godot]
#
# Every check is a real run of the game: the reports it parses are produced by
# the engine, not by this script.
set -u

GODOT="${1:-${GODOT:-godot}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Counters live in a file: `report` runs on the right-hand side of a pipe, so
# shell-variable increments there would happen in a subshell and be lost.
TALLY="$(mktemp)"
trap 'rm -f "$TALLY"' EXIT

say()  { printf '%s\n' "$*"; }
ok()   { printf 'P\n' >>"$TALLY"; printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf 'F\n' >>"$TALLY"; printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

if ! command -v "$GODOT" >/dev/null 2>&1; then
  say "Godot binary not found: $GODOT"
  say "Pass the path as the first argument or set GODOT=/path/to/godot"
  exit 127
fi

say "REDLINE test suite"
say "engine: $("$GODOT" --headless --version 2>/dev/null | tail -1)"
say ""

# ---------------------------------------------------------------------------
say "[1] project imports without script or resource errors"
IMPORT_LOG="$(mktemp)"
"$GODOT" --headless --path "$ROOT" --import >"$IMPORT_LOG" 2>&1
if grep -qiE "SCRIPT ERROR|Parse Error|Failed to load script|Failed to instantiate" "$IMPORT_LOG"; then
  bad "import reported script errors"
  grep -iE "SCRIPT ERROR|Parse Error|Failed to" "$IMPORT_LOG" | head -20
else
  ok "no parser or autoload errors"
fi
rm -f "$IMPORT_LOG"

# ---------------------------------------------------------------------------
run_smoke() {
  local label="$1"; shift
  local out
  out="$("$GODOT" --headless --path "$ROOT" "$@" 2>&1)"
  printf '%s' "$out" | awk '/REDLINE_SMOKE_BEGIN/{f=1;next}/REDLINE_SMOKE_END/{f=0}f'
}

check_json() {
  python3 -c "
import json,sys
raw = sys.stdin.read().strip()
if not raw:
    print('NO_REPORT'); sys.exit(0)
r = json.loads(raw)
c = r['counters']
g = r['gamestate']
p = r.get('ground_probe', {})
checks = [
    ('report ok flag', r['ok'], r.get('errors')),
    ('frames rendered', r['frames'] > 30, r['frames']),
    ('chunks streamed', c['chunks_loaded'] > 20, c['chunks_loaded']),
    ('terrain collision above player', p.get('ray_from_above_hits', False),
     'y=%.2f ground=%.2f' % (p.get('player_y', 0), p.get('ground_analytic', 0))),
    ('collision not inverted', not p.get('ray_from_below_hits', True),
     'on_floor=%s' % p.get('on_floor')),
    ('agents simulated', c['npc_total'] > 0, c['npc_total']),
    ('physics bodies active', c['rigid_bodies'] > 0, c['rigid_bodies']),
    ('multimesh instances drawn', c['multimesh_instances'] > 500, c['multimesh_instances']),
    ('stress profile resolved', bool(r['stress']['effective']), None),
    ('quality preset chosen', bool(r['quality']['preset']), r['quality']['preset']),
]
for name, cond, detail in checks:
    print(('OK|' if cond else 'NO|') + name + '|' + str(detail))
for extra in sys.argv[1:]:
    key, op, val = extra.split(':')
    have = c.get(key, g.get(key, 0))
    good = (have > float(val)) if op == 'gt' else (have < float(val))
    print(('OK|' if good else 'NO|') + f'{key} {op} {val}' + '|' + str(have))
" "$@"
}

report() {
  local line
  while IFS= read -r line; do
    case "$line" in
      NO_REPORT) bad "run produced no report (crash or early exit)";;
      OK\|*) ok "${line#OK|}";;
      NO\|*) bad "${line#NO|}";;
    esac
  done
}

# ---------------------------------------------------------------------------
say ""
say "[1b] scripts, geometry, determinism and safety caps"
SELF="$("$GODOT" --headless --path "$ROOT" --selftest 2>&1 \
  | awk '/REDLINE_SELFTEST_BEGIN/{f=1;next}/REDLINE_SELFTEST_END/{f=0}f')"
if [ -z "$SELF" ]; then
  bad "self test produced no report"
else
  python3 -c "
import json,sys
r = json.loads(sys.stdin.read())
labels = {
    'scripts': 'every script compiles',
    'mesh_orientation': 'mesh orientation matches engine primitives',
    'collision_orientation': 'collision surface faces upward',
    'determinism': 'same seed produces identical chunks',
    'safety_caps': 'no stress level exceeds a hard cap',
}
for key, label in labels.items():
    fails = r.get(key, [])
    detail = (str(len(fails)) + ' failures: ' + str(fails[:2])) if fails else (
        str(r.get('script_count', '')) + ' scripts' if key == 'scripts' else 'clean')
    print(('OK|' if not fails else 'NO|') + label + '|' + detail)
" <<<"$SELF" | report
fi

say ""
say "[2] boot + stream, 15 s, stress NORMAL"
run_smoke boot --test-run=15 --stress=1 | check_json | report

say ""
say "[3] travel across chunk boundaries, 90 s -- exercises unload and cache reuse"
run_smoke travel --test-run=90 --test-travel --stress=2 \
  | check_json "chunks_cached:gt:0" "distance_m:gt:150" | report

say ""
say "[4] quality preset + stress level sweep, 40 s"
run_smoke sweep --test-run=40 --test-autopilot --test-sweep | check_json | report

say ""
say "[5] high stress does more work than low stress"
LOW="$(run_smoke low --test-run=14 --test-autopilot --stress=0)"
HIGH="$(run_smoke high --test-run=14 --test-autopilot --stress=4)"
python3 -c "
import json,sys
low  = json.loads(sys.argv[1]); high = json.loads(sys.argv[2])
for key in ['npc_total','rigid_bodies','multimesh_instances']:
    l, h = low['counters'][key], high['counters'][key]
    print(('OK|' if h > l else 'NO|') + f'{key} scales with stress' + f'|{l} -> {h}')
ls = low['stress']['effective']; hs = high['stress']['effective']
for key in ['stream_radius','view_distance','cache_mb','particle_budget','omni_lights']:
    print(('OK|' if hs[key] > ls[key] else 'NO|') + f'{key} scales with stress'
          + f'|{ls[key]} -> {hs[key]}')
" "$LOW" "$HIGH" | report

say ""
PASS=$(grep -c '^P$' "$TALLY" || true)
FAIL=$(grep -c '^F$' "$TALLY" || true)
say "--------------------------------------------"
say "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
