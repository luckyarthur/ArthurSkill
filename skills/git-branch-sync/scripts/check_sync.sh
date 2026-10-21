#!/usr/bin/env bash
#
# check_sync.sh - can the current branch be pushed without --force?
#
# Compares the current branch with its remote branch and prints one STATUS:
#   up-to-date   nothing to push, nothing to pull
#   ahead        only local has new commits; a normal push will work
#   behind       only the remote has new commits
#   diverged     both sides have new commits; a normal push will be rejected
#   new-branch   the branch does not exist on the remote yet
#
# --fix   repairs "behind" and "diverged" by replaying the local-only commits
#         on top of the remote branch (git rebase). Both the remote commits
#         and the local commits are kept, and the push becomes a fast-forward.
# --push  pushes once the branch is pushable (implies --fix).
#
# Exit codes:
#   0  in sync or pushable (after the fix, if one was needed)
#   1  check only: behind or diverged; rerun with --fix
#   2  the rebase stopped on a conflict; resolve it, then continue
#   3  cannot proceed (not a repo, detached HEAD, dirty tree, ...)
#   4  the push failed

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: check_sync.sh [--fix] [--push] [--remote <name>]

  (no flags)       fetch and report whether the branch can be pushed
  --fix            if behind/diverged, rebase local commits onto the remote
  --push           --fix, then push
  --remote <name>  compare with <name>/<current-branch> instead of the upstream
EOF
}

FIX=0
PUSH=0
REMOTE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fix) FIX=1 ;;
    --push) FIX=1; PUSH=1 ;;
    --remote) REMOTE_ARG="${2:-}"; [ -n "$REMOTE_ARG" ] || { usage >&2; exit 3; }; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
  esac
  shift
done

fail() { echo "STOP: $1" >&2; exit "${2:-3}"; }

# Print up to 20 commits of a range, indented.
list_commits() {
  local range=$1 total=$2
  git log --oneline --no-decorate -n 20 "$range" | sed 's/^/    /'
  [ "$total" -gt 20 ] && echo "    ... and $((total - 20)) more"
  return 0
}

count_ahead_behind() {
  read -r AHEAD BEHIND <<<"$(git rev-list --left-right --count "HEAD...$TRACKING")"
}

do_push() {
  echo "Pushing: git push -u $REMOTE $BRANCH:$REMOTE_BRANCH"
  git push -u "$REMOTE" "$BRANCH:$REMOTE_BRANCH" ||
    fail "push failed. If it was rejected because the remote moved again, rerun this script." 4
  echo "STATUS: pushed"
}

# --- Preconditions ---------------------------------------------------------

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not inside a git work tree."
cd "$(git rev-parse --show-toplevel)" || fail "cannot cd to the repository root."

for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
  if [ -e "$(git rev-parse --git-path "$marker")" ]; then
    fail "a rebase, merge or cherry-pick is already in progress. Finish it (--continue) or cancel it (--abort) first."
  fi
done

BRANCH=$(git symbolic-ref --quiet --short HEAD) || fail "HEAD is detached. Check out a branch first."
git rev-parse --verify --quiet HEAD >/dev/null || fail "branch '$BRANCH' has no commits yet."

# --- Which remote branch do we compare with? -------------------------------
# 1. --remote <name>         -> <name>/<branch>
# 2. the configured upstream -> what "git push" / "git pull" already use
# 3. otherwise               -> origin/<branch>

if [ -n "$REMOTE_ARG" ]; then
  REMOTE=$REMOTE_ARG
  REMOTE_BRANCH=$BRANCH
elif REMOTE=$(git config --get "branch.$BRANCH.remote") && [ "$REMOTE" != "." ]; then
  MERGE=$(git config --get "branch.$BRANCH.merge")
  MERGE=${MERGE:-refs/heads/$BRANCH}
  REMOTE_BRANCH=${MERGE#refs/heads/}
else
  REMOTE=origin
  REMOTE_BRANCH=$BRANCH
fi

git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "there is no remote named '$REMOTE'."
TRACKING="refs/remotes/$REMOTE/$REMOTE_BRANCH"

# --- Fetch the latest remote state -----------------------------------------

echo "Checking $REMOTE/$REMOTE_BRANCH ..."
git ls-remote --exit-code "$REMOTE" "refs/heads/$REMOTE_BRANCH" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  echo "STATUS: new-branch"
  echo "'$REMOTE_BRANCH' does not exist on '$REMOTE' yet. A normal push creates it:"
  echo "    git push -u $REMOTE $BRANCH:$REMOTE_BRANCH"
  [ "$PUSH" -eq 1 ] && do_push
  exit 0
elif [ "$rc" -ne 0 ]; then
  fail "cannot reach remote '$REMOTE' (network or permission problem)."
fi

# The explicit refspec also works in single-branch and shallow clones, and
# the leading "+" accepts a remote branch that was force-pushed.
git fetch --quiet "$REMOTE" "+refs/heads/$REMOTE_BRANCH:$TRACKING" ||
  fail "git fetch from '$REMOTE' failed."

# In a shallow clone, local history stops at the commit that was cloned. If
# the remote branch was rewritten since then, that commit is no longer on it,
# and git cannot see where the branches split. --deepen does not help here
# (it only digs along the remote branch); --unshallow fetches the rest.
if ! git merge-base HEAD "$TRACKING" >/dev/null 2>&1; then
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "Shallow clone: fetching full history to find where the branches split ..."
    git fetch --quiet --unshallow "$REMOTE" "+refs/heads/$REMOTE_BRANCH:$TRACKING" ||
      fail "this shallow clone needs more history, but 'git fetch --unshallow' failed."
  fi
  git merge-base HEAD "$TRACKING" >/dev/null 2>&1 ||
    fail "'$BRANCH' and '$REMOTE/$REMOTE_BRANCH' share no common commit (unrelated histories). Ask the user how to combine them."
fi

# --- Compare ---------------------------------------------------------------

count_ahead_behind
echo "Local:  $BRANCH @ $(git rev-parse --short HEAD)"
echo "Remote: $REMOTE/$REMOTE_BRANCH @ $(git rev-parse --short "$TRACKING")"
echo "Local-only commits: $AHEAD    Remote-only commits: $BEHIND"

if [ "$AHEAD" -eq 0 ] && [ "$BEHIND" -eq 0 ]; then
  echo "STATUS: up-to-date"
  exit 0
fi

if [ "$BEHIND" -eq 0 ]; then
  echo "STATUS: ahead"
  echo "Local commits a normal push will send:"
  list_commits "$TRACKING..HEAD" "$AHEAD"
  [ "$PUSH" -eq 1 ] && do_push
  exit 0
fi

if [ "$AHEAD" -eq 0 ]; then STATE=behind; else STATE=diverged; fi
echo "STATUS: $STATE"
echo "Remote-only commits (will be kept, and become the new base):"
list_commits "HEAD..$TRACKING" "$BEHIND"
if [ "$AHEAD" -gt 0 ]; then
  echo "Local-only commits (will be kept, and replayed on top):"
  list_commits "$TRACKING..HEAD" "$AHEAD"
fi

if [ "$FIX" -eq 0 ]; then
  if [ "$STATE" = diverged ]; then
    echo "A normal push would be rejected. Rerun with --fix to replay the local commits on top of $REMOTE/$REMOTE_BRANCH."
  else
    echo "Nothing to push, but the local branch is out of date. Rerun with --fix to fast-forward it."
  fi
  exit 1
fi

# --- Fix: replay local-only commits on top of the remote branch -------------

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  fail "there are uncommitted changes to tracked files. Commit them or run 'git stash', then rerun."
fi

OLD=$(git rev-parse HEAD)
git update-ref "refs/sync-backup/$BRANCH" "$OLD"
echo "Backup of the old local branch: refs/sync-backup/$BRANCH ($OLD)"
echo "To undo the fix later: git reset --hard $OLD"

if ! GIT_EDITOR=true git rebase "$TRACKING"; then
  if [ -e "$(git rev-parse --git-path rebase-merge)" ] || [ -e "$(git rev-parse --git-path rebase-apply)" ]; then
    echo "STATUS: conflict"
    echo "Files with conflicts:"
    git diff --name-only --diff-filter=U | sed 's/^/    /'
    echo "Resolve each file so it keeps BOTH sides' changes, then:"
    echo "    git add <file> ...  &&  GIT_EDITOR=true git rebase --continue"
    echo "Or cancel everything and return to the old state: git rebase --abort"
    exit 2
  fi
  fail "git rebase failed before starting."
fi

count_ahead_behind
[ "$BEHIND" -eq 0 ] || fail "still $BEHIND commit(s) behind after the rebase; inspect manually."

if [ "$AHEAD" -eq 0 ]; then
  echo "STATUS: up-to-date"
  echo "Fixed. '$BRANCH' now matches $REMOTE/$REMOTE_BRANCH, so there is nothing to push."
  exit 0
fi

echo "STATUS: ahead"
echo "Fixed. '$BRANCH' is now $REMOTE/$REMOTE_BRANCH plus these local commits on top:"
list_commits "$TRACKING..HEAD" "$AHEAD"
[ "$PUSH" -eq 1 ] && do_push
exit 0
