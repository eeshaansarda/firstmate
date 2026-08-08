#!/usr/bin/env bash
# tests/fm-herdr-usage-limit-autoresolve-live-e2e.test.sh - opt-in live guard
# for the usage-limit dialog auto-resolve (bin/backends/herdr.sh's
# fm_backend_herdr_autoresolve_usage_limit_dialog, wired into
# bin/fm-push-transition-lib.sh's handle_push_transition;
# docs/verification/runtime-backends.md "Usage-limit dialog auto-resolve",
# .agents/skills/stuck-crewmate-recovery is the one owner of the mechanism's
# contract).
#
# A real end-to-end reproduction of an actual Claude Code usage-limit hit is
# impractical to automate: there is no reliable, on-demand way to force a real
# Claude Code process into that exact interactive state. What this guard
# verifies instead, against a REAL herdr server (never the default session):
# the production code path - real `herdr pane read`, the real detection
# function, and real `herdr pane send-keys` - correctly reads a pane showing
# the EXACT captured dialog text and delivers exactly one real Enter keystroke
# to the real foreground process waiting in that pane, through the real
# handle_push_transition call site, while a real idle->blocked agent-status
# transition (driven the same way tests/fm-backend-herdr-eventwait-smoke.test.sh
# drives one) supplies the transition record. A second pane with the dialog's
# admin option selected instead proves the negative: no keystroke is ever
# delivered, and the ordinary stale wake still fires unchanged.
#
# Opt-in because it drives real keystrokes into a real pane; skips cleanly
# when herdr, jq, or python3 is absent, or when this herdr build is below the
# events.subscribe capability.
#
# Safety (2026-07-02 incident, tests/herdr-test-safety.sh): cleanup uses ONLY
# herdr_safe_stop_and_delete on a private fm-lab-* session, never a bare/ambient
# `herdr server stop`. Every lifecycle op goes through bin/fm-herdr-lab.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_USAGE_LIMIT_AUTORESOLVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_USAGE_LIMIT_AUTORESOLVE_E2E=1 to run the real-herdr usage-limit dialog auto-resolve guard"
  exit 0
fi
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the event subscriber)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

SESSION="fm-lab-usage-limit-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)

if ! fm_backend_herdr_events_capable "$SESSION"; then
  echo "skip: this herdr build is below the events.subscribe capability (protocol < 16 or events surface absent)"
  cleanup_all
  trap - EXIT
  exit 0
fi

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-usagelimit.XXXXXX")
STATE="$SCRATCH/state"; mkdir -p "$STATE"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}

# make_dialog_script: writes a small script to <path> that prints <dialog
# text file> verbatim, then blocks on ONE real keypress from its own
# foreground tty, then records exactly what it received - a real, observable
# consequence of a real Enter keystroke landing on a real foreground process,
# not a mock.
make_dialog_script() {  # <script-path> <dialog-text-path> <marker-path>
  local script=$1 dialog=$2 marker=$3
  cat > "$script" <<SH
#!/usr/bin/env bash
cat "$dialog"
IFS= read -r line
printf 'KEYPRESS_RECEIVED:[%s]\n' "\$line" > "$marker"
SH
  chmod +x "$script"
}

# drive_to_blocked: registers <pane_id>'s agent idle, then blocked, via
# herdr's documented report-agent primitive (same mechanism as the eventwait
# smoke test), waiting on the real event stream so this returns only once the
# transition has genuinely landed. Prints the normalized transition record.
drive_to_blocked() {  # <pane_id> <target>
  local pane_id=$1 target=$2 out rcf out_v rc_v
  fm_herdr_lab_cli "$SESSION" pane report-agent "$pane_id" --source fm-usagelimit-test --agent claude --state idle >/dev/null 2>&1 \
    || return 1
  out="$SCRATCH/wt-out-$pane_id"; rcf="$SCRATCH/wt-rc-$pane_id"
  : > "$out"; : > "$rcf"
  ( fm_backend_herdr_wait_transition "$SESSION" 8 "$STATE" "$target" > "$out"; echo $? > "$rcf" ) &
  local wpid=$!
  sleep 0.5
  fm_herdr_lab_cli "$SESSION" pane report-agent "$pane_id" --source fm-usagelimit-test --agent claude --state blocked >/dev/null 2>&1 \
    || { kill "$wpid" 2>/dev/null; return 1; }
  wait "$wpid"
  rc_v=$(cat "$rcf" 2>/dev/null || echo "")
  out_v=$(cat "$out" 2>/dev/null || echo "")
  [ "$rc_v" = 0 ] || return 1
  printf '%s' "$out_v"
}

# --- positive case: the real captured dialog, "Stop and wait" selected ------

DIALOG_STOP="$SCRATCH/dialog-stop.txt"
printf 'What do you want to do?\n\n\xe2\x9d\xaf 1. Stop and wait for limit to reset\n  2. Ask your admin for more usage\n\nEnter to confirm \xc2\xb7 Esc to cancel\n' > "$DIALOG_STOP"
MARKER_STOP="$SCRATCH/marker-stop"
SCRIPT_STOP="$SCRATCH/dialog-stop.sh"
make_dialog_script "$SCRIPT_STOP" "$DIALOG_STOP" "$MARKER_STOP"

IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-ulmatch /tmp "$SEEDED_TAB_ID") || fail "create_task (match pane) failed"
read -r _TAB1 PANE1 <<EOF
$IDS
EOF
[ -n "$PANE1" ] || fail "create_task did not return a pane id for the match case"
TARGET1="$SESSION:$PANE1"
cat > "$STATE/ulmatch.meta" <<EOF
window=$TARGET1
backend=herdr
kind=ship
EOF

fm_backend_herdr_send_text_line "$TARGET1" "bash '$SCRIPT_STOP'" || fail "could not launch the dialog script in the match pane"
sleep 0.5

# run_handle_push_transition: sources the real production entry point and
# calls it against <record> in its OWN subprocess - never at this script's
# top level - so each of the two cases below gets an independent `wake()`
# override with no risk of one shadowing the other, and so a `wake()` call
# from inside the sourced library can never reach out into this script.
run_handle_push_transition() {  # <record> <wake-marker-path>
  FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    # shellcheck source=bin/fm-push-transition-lib.sh
    . "$0/bin/fm-push-transition-lib.sh"
    sess=$1; rec=$2; wm=$3
    wake() { echo "WAKE_CALLED:$1" >> "$wm"; return 0; }
    handle_push_transition herdr "$sess" "$rec"
  ' "$ROOT" "$SESSION" "$1" "$2"
}

REC1=$(drive_to_blocked "$PANE1" "$TARGET1") || fail "could not drive the match pane to a real idle->blocked transition"
pass "real herdr ($HERDR_VERSION): drove a real idle->blocked transition on the match pane"

run_handle_push_transition "$REC1" "$STATE/.wake-called-match"

[ ! -e "$STATE/.wake-called-match" ] || fail "a real match must never call wake(): $(cat "$STATE/.wake-called-match")"
[ ! -e "$STATE/.wake-queue" ] || fail "a real match must never append to the durable wake queue: $(cat "$STATE/.wake-queue")"

# The keystroke is asynchronous from the pane's perspective; give the real
# foreground process a moment to receive it and write its marker.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "$MARKER_STOP" ] && break
  sleep 0.3
done
[ -e "$MARKER_STOP" ] || fail "the real pane process never observed a keystroke - the real send-keys call did not land"
grep -q 'KEYPRESS_RECEIVED' "$MARKER_STOP" || fail "unexpected marker content: $(cat "$MARKER_STOP")"
pass "real herdr ($HERDR_VERSION): handle_push_transition read the real dialog text, sent a real Enter keystroke that the real pane process observed, and never fired the wake"

# --- negative case: the admin option selected instead - must NEVER resolve -

DIALOG_ADMIN="$SCRATCH/dialog-admin.txt"
printf 'What do you want to do?\n\n  1. Stop and wait for limit to reset\n\xe2\x9d\xaf 2. Ask your admin for more usage\n\nEnter to confirm \xc2\xb7 Esc to cancel\n' > "$DIALOG_ADMIN"
MARKER_ADMIN="$SCRATCH/marker-admin"
SCRIPT_ADMIN="$SCRATCH/dialog-admin.sh"
make_dialog_script "$SCRIPT_ADMIN" "$DIALOG_ADMIN" "$MARKER_ADMIN"

IDS2=$(fm_backend_herdr_create_task "$CONTAINER" fm-ulnomatch /tmp "") || fail "create_task (no-match pane) failed"
read -r _TAB2 PANE2 <<EOF
$IDS2
EOF
[ -n "$PANE2" ] || fail "create_task did not return a pane id for the no-match case"
TARGET2="$SESSION:$PANE2"
cat > "$STATE/ulnomatch.meta" <<EOF
window=$TARGET2
backend=herdr
kind=ship
EOF

fm_backend_herdr_send_text_line "$TARGET2" "bash '$SCRIPT_ADMIN'" || fail "could not launch the dialog script in the no-match pane"
sleep 0.5

REC2=$(drive_to_blocked "$PANE2" "$TARGET2") || fail "could not drive the no-match pane to a real idle->blocked transition"

run_handle_push_transition "$REC2" "$STATE/.wake-called-nomatch"

[ -e "$STATE/.wake-called-nomatch" ] || fail "the admin-selected dialog must still fire the ordinary wake - this is the required divergence assertion"
grep -q 'herdr: agent blocked' "$STATE/.wake-called-nomatch" || fail "the wake reason must still name the herdr-blocked cause unchanged: $(cat "$STATE/.wake-called-nomatch")"
sleep 1
[ ! -e "$MARKER_ADMIN" ] || fail "the admin-selected pane must NEVER receive a keystroke - it must still be blocked on its own read: $(cat "$MARKER_ADMIN")"
pass "real herdr ($HERDR_VERSION): handle_push_transition never sends a keystroke when 'Ask your admin' is selected, and the ordinary wake still fires"

cleanup_all
trap - EXIT
