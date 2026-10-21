#!/usr/bin/env bash
#
# Tests for skills/git-branch-sync/scripts/check_sync.sh.
#
# Each test builds a throwaway "remote" (a bare repo) and two clones:
#   me    - the local clone whose branch we check and fix
#   other - a teammate who pushes to the remote in the meantime
#
# Run: bash tests/test_git_branch_sync.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/skills/git-branch-sync/scripts/check_sync.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Isolate from the user's git config so results do not depend on it.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

PASS=0
FAILED=0
OUT=""
RC=0

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAILED=$((FAILED + 1)); echo "  FAIL - $1"; sed 's/^/         | /' <<<"$OUT"; }
expect() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
has()   { grep -qF -- "$1" <<<"$OUT"; }
lacks() { ! has "$1"; }
rc_is() { [ "$RC" -eq "$1" ]; }

# run <dir> [flags...]: run the script in <dir>, keep its output and exit code.
run() { local dir=$1; shift; OUT=$(cd "$dir" && bash "$SCRIPT" "$@" 2>&1); RC=$?; }

# commit <dir> <file> <content> <message>
commit() {
  (cd "$1" && mkdir -p "$(dirname "$2")" && printf '%s\n' "$3" >"$2" &&
    git add "$2" && git commit -qm "$4")
}
push() { (cd "$1" && git push -q origin "${2:-main}" 2>/dev/null); }
remote_has() { git -C "$TMP/w/remote.git" cat-file -e "main:$1" 2>/dev/null; }

setup() {
  rm -rf "$TMP/w"
  mkdir -p "$TMP/w"
  cd "$TMP/w" || exit 1
  git init -q --bare -b main remote.git
  git clone -q remote.git seed 2>/dev/null
  commit seed base.txt "base" "base"
  commit seed shared.txt "line1
line2
line3" "add shared"
  push seed
  git clone -q remote.git me
  git clone -q remote.git other
}

echo "1. up-to-date"
setup
run me
expect "exit 0" rc_is 0
expect "reports up-to-date" has "STATUS: up-to-date"

echo "2. ahead (run from a subdirectory)"
setup
commit me sub/a.txt "a" "local a"
run me/sub
expect "exit 0" rc_is 0
expect "reports ahead" has "STATUS: ahead"
expect "lists the local commit" has "local a"

echo "3. behind, then --fix fast-forwards"
setup
commit other b.txt "b" "remote b"; push other
run me
expect "check exits 1" rc_is 1
expect "reports behind" has "STATUS: behind"
run me --fix
expect "fix exits 0" rc_is 0
expect "now up-to-date" has "STATUS: up-to-date"
expect "local main equals origin/main" \
  test "$(git -C me rev-parse main)" = "$(git -C me rev-parse origin/main)"

echo "4. diverged without conflict, --push keeps both sides"
setup
commit other b.txt "b" "remote b"; push other
OTHER_SHA=$(git -C other rev-parse HEAD)
commit me a.txt "a" "local a"
run me
expect "check exits 1" rc_is 1
expect "reports diverged" has "STATUS: diverged"
run me --push
expect "push exits 0" rc_is 0
expect "reports pushed" has "STATUS: pushed"
expect "remote keeps the remote file" remote_has b.txt
expect "remote gets the local file" remote_has a.txt
expect "remote commit kept unchanged (same hash)" \
  git -C remote.git merge-base --is-ancestor "$OTHER_SHA" main
expect "history is linear (no merge commits)" \
  test "$(git -C remote.git rev-list --merges --count main)" = 0
expect "local commit sits on top" \
  test "$(git -C remote.git log -1 --format=%s main)" = "local a"
expect "backup ref saved" git -C me show-ref --verify -q refs/sync-backup/main

echo "5. diverged with a conflict"
setup
commit other shared.txt "line1
line2 remote
line3" "remote edits line2"; push other
commit me shared.txt "line1
line2 local
line3" "local edits line2"
OLD=$(git -C me rev-parse HEAD)
run me --fix
expect "fix exits 2" rc_is 2
expect "reports conflict" has "STATUS: conflict"
expect "names the file" has "shared.txt"
run me
expect "second run refuses while the rebase is in progress" rc_is 3
expect "says a rebase is in progress" has "already in progress"
# Resolve by keeping both versions of line2.
printf 'line1\nline2 remote\nline2 local\nline3\n' >me/shared.txt
(cd me && git add shared.txt && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1)
run me --push
expect "after resolving, push exits 0" rc_is 0
expect "remote has both edits" \
  test "$(git -C remote.git show main:shared.txt)" = "$(printf 'line1\nline2 remote\nline2 local\nline3')"

echo "6. conflict, then abort restores the old branch"
setup
commit other shared.txt "x" "remote x"; push other
commit me shared.txt "y" "local y"
OLD=$(git -C me rev-parse HEAD)
run me --fix
(cd me && git rebase --abort)
expect "branch is back at the old commit" test "$(git -C me rev-parse HEAD)" = "$OLD"
expect "backup ref points at the old commit" \
  test "$(git -C me rev-parse refs/sync-backup/main)" = "$OLD"

echo "7. uncommitted changes block --fix but not the check"
setup
commit other b.txt "b" "remote b"; push other
commit me a.txt "a" "local a"
echo "edit" >>me/base.txt
run me
expect "check still works (exit 1)" rc_is 1
run me --fix
expect "fix exits 3" rc_is 3
expect "explains why" has "uncommitted changes"
expect "nothing was rebased" test "$(git -C me log -1 --format=%s)" = "local a"

echo "8. new branch not on the remote yet"
setup
(cd me && git checkout -q -b feature)
commit me f.txt "f" "feature work"
run me
expect "exit 0" rc_is 0
expect "reports new-branch" has "STATUS: new-branch"
run me --push
expect "push exits 0" rc_is 0
expect "remote has the branch" git -C remote.git show-ref --verify -q refs/heads/feature
expect "upstream is set" \
  test "$(git -C me rev-parse --abbrev-ref '@{u}')" = "origin/feature"

echo "9. local branch name differs from its upstream"
setup
(cd me && git checkout -q -b mywork origin/main)
commit other b.txt "b" "remote b"; push other
commit me a.txt "a" "local a"
run me --push
expect "push exits 0" rc_is 0
expect "compared with origin/main" has "Remote: origin/main"
expect "remote main has both files" remote_has a.txt
expect "remote main kept the remote file" remote_has b.txt

echo "10. local commit already on the remote (same change)"
setup
commit other a.txt "same" "remote adds a"; push other
commit me a.txt "same" "local adds a"
run me --fix
expect "fix exits 0" rc_is 0
expect "duplicate dropped, nothing to push" has "STATUS: up-to-date"

echo "11. shallow clone, diverged"
setup
for i in 1 2 3; do commit other "o$i.txt" "$i" "remote $i"; done; push other
git clone -q --depth 1 "file://$TMP/w/remote.git" shallow
for i in 4 5; do commit other "o$i.txt" "$i" "remote $i"; done; push other
commit shallow s.txt "s" "shallow local"
run shallow --push
expect "push exits 0" rc_is 0
expect "no extra history needed" lacks "Shallow clone"
expect "remote has the local file" remote_has s.txt
expect "remote kept the newest remote file" remote_has o5.txt

echo "12. shallow clone, remote was force-pushed (needs more history)"
setup
commit other c.txt "c" "remote c"; push other
git clone -q --depth 1 "file://$TMP/w/remote.git" shallow
commit shallow s.txt "s" "shallow local"
(cd other && git reset -q --hard HEAD~1)
commit other d.txt "d" "remote d (rewritten)"
(cd other && git push -q --force origin main 2>/dev/null)
run shallow
expect "check exits 1" rc_is 1
expect "fetched more history" has "Shallow clone"
expect "lists the commit removed from the remote as local-only" has "remote c"
run shallow --fix
expect "fix exits 0" rc_is 0
expect "result is ahead" has "STATUS: ahead"
expect "rewritten remote is the new base" \
  git -C shallow merge-base --is-ancestor origin/main HEAD
expect "local commit is on top" \
  test "$(git -C shallow log -1 --format=%s)" = "shallow local"

echo "13. detached HEAD"
setup
(cd me && git checkout -q --detach)
run me
expect "exit 3" rc_is 3
expect "explains why" has "detached"

echo "14. unreachable remote"
setup
(cd me && git remote set-url origin "$TMP/does-not-exist")
run me
expect "exit 3" rc_is 3
expect "explains why" has "cannot reach"

echo
echo "passed: $PASS   failed: $FAILED"
[ "$FAILED" -eq 0 ]
