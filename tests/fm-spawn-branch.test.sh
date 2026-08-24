#!/usr/bin/env bash
# Behavior tests for bin/fm-spawn.sh's --branch flag: it records the task's
# actual branch as branch= in state/<id>.meta, resolved the same way
# bin/fm-brief.sh resolves it (--branch when the caller passes one, otherwise
# fm/<id>), and is refused wherever it does not apply.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-branch)

# --- fast-fail argument validation (no real backend/worktree reached) -------

# Clear ambient firstmate overrides so the behavior test owns its environment,
# matching tests/fm-spawn-batch.test.sh's convention for pure argument-routing
# cases that fail before any tmux/treehouse side effect.
run_spawn_argcheck() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

test_branch_flag_is_refused_where_it_does_not_apply() {
  local label args expect out status
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_spawn_argcheck $args)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
branch on a scout spawn|nope-branch-scout-z1 projects/none --scout --branch feat/x|--branch applies only to ship spawns
branch on a secondmate spawn|nope-branch-sm-z2 --secondmate --branch feat/x|--branch applies only to ship spawns
branch requires a non-empty value|nope-branch-empty-z3 projects/none --mode no-mistakes --yolo off --branch=|--branch requires a non-empty value
branch is refused on relaunch|nope-branch-relaunch-z4 --relaunch --branch feat/x|--relaunch reuses the task's recorded branch
ROWS
  pass "fm-spawn.sh: --branch is refused on scout/secondmate/relaunch spawns and rejects an empty value"
}

# --- real spawn: branch= recorded in state/<id>.meta ------------------------

# make_case <id>: a home with an origin-backed project and its worktree already
# in place, a placeholder brief, and a fake tmux/treehouse that report the
# worktree as already settled - mirroring tests/fm-spawn-worktree-settle.test.sh's
# minimal harness, since this suite only asserts on the recorded branch= field.
make_case() {
  local id=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

run_case_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

test_default_branch_recorded_when_flag_omitted() {
  local id rec home proj wt fakebin out status
  id=spawn-branch-default-z1
  rec=$(make_case "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_case_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn without --branch should succeed (got: $out)"
  assert_grep "branch=fm/$id" "$home/state/$id.meta" \
    "meta did not record the default fm/<id> branch when --branch was omitted"
  pass "fm-spawn.sh: a ship spawn without --branch records the default fm/<id> in meta"
}

test_explicit_branch_recorded_in_meta() {
  local id rec home proj wt fakebin out status
  id=spawn-branch-explicit-z2
  rec=$(make_case "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_case_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off --branch feat/example)
  status=$?
  expect_code 0 "$status" "spawn with --branch feat/example should succeed (got: $out)"
  assert_grep "branch=feat/example" "$home/state/$id.meta" \
    "meta did not record the explicit --branch value"
  assert_no_grep "branch=fm/$id" "$home/state/$id.meta" \
    "meta recorded the default fm/<id> branch alongside the explicit override"
  pass "fm-spawn.sh: --branch <name> records <name> in meta instead of fm/<id>"
}

test_scout_spawn_records_no_branch() {
  local id rec home proj wt fakebin out status
  id=spawn-branch-scout-z3
  rec=$(make_case "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_case_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout)
  status=$?
  expect_code 0 "$status" "scout spawn should succeed (got: $out)"
  assert_no_grep "branch=" "$home/state/$id.meta" \
    "scout meta recorded a branch= field; a scout has no delivery branch"
  pass "fm-spawn.sh: a scout spawn records no branch= field"
}

test_branch_flag_is_refused_where_it_does_not_apply
test_default_branch_recorded_when_flag_omitted
test_explicit_branch_recorded_in_meta
test_scout_spawn_records_no_branch

echo "# all fm-spawn-branch tests passed"
