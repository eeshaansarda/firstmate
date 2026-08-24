#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: the local-only fast-forward merge must
# resolve the crewmate's branch from state/<id>.meta's branch= field (a
# project-convention name like feat/<slug>) rather than assuming fm/<id>,
# while an older task whose meta predates that field still merges its
# fm/<id> branch unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# make_case <name> <branch>: a project repo on its default branch (main) with
# the crewmate's work committed on <branch>, checked out back to main clean so
# fm-merge-local.sh's preconditions hold.
make_case() {
  local name=$1 branch=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q "$case_dir/project"
  git -C "$case_dir/project" symbolic-ref HEAD refs/heads/main
  printf 'base\n' > "$case_dir/project/feature.txt"
  git -C "$case_dir/project" add feature.txt
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm "baseline"

  git -C "$case_dir/project" checkout -q -b "$branch"
  printf 'shipped\n' > "$case_dir/project/feature.txt"
  git -C "$case_dir/project" add feature.txt
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm "crewmate work"
  git -C "$case_dir/project" checkout -q main

  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1 id=$2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$id"
}

test_merges_recorded_branch_field() {
  local case_dir out
  case_dir=$(make_case custom-branch feat/custom)
  fm_write_meta "$case_dir/state/task-c1.meta" \
    "project=$case_dir/project" \
    "mode=local-only" \
    "branch=feat/custom"

  out=$(run_merge_local "$case_dir" task-c1)

  assert_contains "$out" "merged feat/custom into local main" \
    "custom-branch: should merge the branch= field recorded in meta"
  assert_contains "$(cat "$case_dir/project/feature.txt")" "shipped" \
    "custom-branch: default branch should carry the merged content"
  pass "fm-merge-local reads branch= from meta instead of assuming fm/<id>"
}

test_falls_back_to_fm_id_branch_when_meta_predates_field() {
  local case_dir out
  case_dir=$(make_case legacy-default fm/task-c2)
  fm_write_meta "$case_dir/state/task-c2.meta" \
    "project=$case_dir/project" \
    "mode=local-only"

  out=$(run_merge_local "$case_dir" task-c2)

  assert_contains "$out" "merged fm/task-c2 into local main" \
    "legacy-default: a meta file with no branch= should still merge fm/<id>"
  assert_contains "$(cat "$case_dir/project/feature.txt")" "shipped" \
    "legacy-default: default branch should carry the merged content"
  pass "fm-merge-local falls back to fm/<id> when meta predates the branch= field"
}

test_falls_back_to_fm_id_branch_when_meta_predates_field
test_merges_recorded_branch_field
