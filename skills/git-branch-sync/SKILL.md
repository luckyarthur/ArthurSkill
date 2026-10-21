---
name: git-branch-sync
description: Check whether the current git branch matches its remote branch and can be pushed, and fix a diverged branch by rebasing the local-only commits on top of the remote head so that both the remote and the local changes are kept. Use this before any git push, whenever a push is rejected ("non-fast-forward", "Updates were rejected", "fetch first", "tip of your current branch is behind"), whenever git status says the branch "is behind" or "have diverged", and whenever the user asks to sync, update, or catch up a local branch with origin, even if they never say "rebase".
---

# Git branch sync

A push only works when the remote branch is an ancestor of the local branch,
meaning the local branch contains everything the remote has, plus maybe more.
When someone else pushed while you were working, both sides have commits the
other lacks. The branches have **diverged**, and a normal push is rejected.

The fix this skill applies: take the commits that exist only locally and
replay them on top of the newest remote commit (`git rebase`). Afterwards the
local branch is "remote + my commits", so a normal push succeeds. Nothing is
lost: the remote commits stay as they are, and every local change is re-applied.

```
before:   A---B---C   origin/main  (C was pushed by someone else)
               \
                D---E  main        (your local commits)

after:    A---B---C---D'---E'  main  (D' and E' = D and E, replayed on C)
```

## Step 1: check

Run the bundled script from inside the repository (it lives in this skill's
`scripts/` folder):

```bash
bash <skill-dir>/scripts/check_sync.sh
```

It fetches the remote branch, compares, and prints a `STATUS:` line. It only
updates remote-tracking refs, so it is safe to run at any time.

| STATUS       | Meaning                                  | What to do |
|--------------|------------------------------------------|------------|
| `up-to-date` | same commit on both sides                | nothing to push |
| `ahead`      | only local has new commits               | a normal `git push` works |
| `new-branch` | the remote has no branch with this name  | `git push -u <remote> <branch>` works |
| `behind`     | only the remote has new commits          | run `--fix` to fast-forward |
| `diverged`   | both sides have new commits              | run `--fix` (step 2) |

It compares with the branch's configured upstream, or `origin/<branch>` if none
is set. Use `--remote <name>` to compare with `<name>/<branch>` instead.

Read the two commit lists it prints before fixing. The local-only list should
hold only the user's own new work. If it also holds commits the user did not
make, someone probably rewrote the remote branch (force-pushed) and removed
those commits on purpose. `--fix` would put them back, so ask the user first.

## Step 2: fix

```bash
bash <skill-dir>/scripts/check_sync.sh --fix     # rebase only
bash <skill-dir>/scripts/check_sync.sh --push    # rebase, then push
```

Use `--push` only when the user asked for a push or the task already includes
pushing. Otherwise use `--fix` and leave the push to them.

Before rebasing, the script:

- refuses to run if tracked files have uncommitted changes. A rebase rewrites
  the working tree, so first commit those changes (if they belong to the work)
  or `git stash` them, and `git stash pop` after the fix.
- saves the old branch tip in `refs/sync-backup/<branch>` and prints its hash.
  `git reset --hard <hash>` brings the old state back.

Exit codes: `0` pushable or in sync, `1` needs `--fix`, `2` stopped on a
conflict, `3` cannot proceed (the message says why), `4` push failed.

If the push fails because someone pushed again in the meantime, run `--push`
again. It fetches the new state and rebases once more.

## Step 3: resolve conflicts (only when the exit code is 2)

A conflict means a local commit and a remote commit changed the same lines.
Git pauses on that local commit and leaves markers in the file. The goal is a
result that contains **both** changes. Picking one side whole would silently
drop someone's work, which is exactly what this skill exists to prevent.

**Watch out: during a rebase, "ours" and "theirs" are swapped from what most
people expect.**

```
<<<<<<< HEAD                              <- REMOTE side (the base being built on)
remote version of the lines
=======
local version of the lines
>>>>>>> 1a2b3c4 (local commit message)    <- LOCAL commit being replayed
```

So `git checkout --ours` takes the remote version and `--theirs` takes the
local version. Do not use either one, or `-X ours` / `-X theirs`, unless one
side's change truly replaces the other's.

For each file the script listed:

1. Learn what each side meant to do. `<remote>/<branch>` is the remote branch
   the script printed, for example `origin/main`.
   ```bash
   git show REBASE_HEAD -- <file>                    # the local change being replayed
   git log -p REBASE_HEAD..<remote>/<branch> -- <file>   # the remote changes
   git checkout --conflict=diff3 -- <file>           # redo markers with the original text shown
   ```
   The `diff3` view adds a `||||||| base` section with the text before either
   side changed it. Comparing each side with that original shows what each
   side actually changed. Its labels read `ours` (still the remote side),
   `base`, and `theirs` (still the local commit).
2. Edit the file so it contains both changes and still makes sense. For
   example, if the remote renamed a function and the local commit added a call
   to it, keep the rename and update the new call to the new name.
3. Remove every marker line (`<<<<<<<`, `|||||||`, `=======`, `>>>>>>>`).
   `git diff --check` reports any that are left.
4. `git add <file>`.

Then continue. `GIT_EDITOR=true` stops git from opening an editor for the
commit message:

```bash
GIT_EDITOR=true git rebase --continue
```

The rebase may stop again on a later local commit. Repeat until it finishes.
If git says a commit became empty (its change is already on the remote), run
`git rebase --skip`.

When the rebase finishes, run the script again without flags. It should print
`STATUS: ahead`. If the project has a fast test or build command, run it, since
two changes can merge cleanly and still not work together. Then push if the
user wants that.

If a conflict is unclear and you cannot tell what one side intended, run
`git rebase --abort`. It restores the branch exactly as it was before the fix.
Then show the user both versions and ask how to combine them.

## Things not to do, and why

- **No `git push --force` to "fix" divergence.** Force-pushing replaces the
  remote branch with the local one and deletes the commits others pushed.
  After this skill's rebase, a normal push works, so force is never needed.
- **No `git reset --hard origin/<branch>`.** It makes the branch match the
  remote by throwing away every local commit.
- **No `git pull` with default settings as the fix.** Depending on the user's
  config it may merge, rebase, or refuse. The script runs one known operation.

## When the script cannot run

The same steps by hand (replace `origin` and `main` with the real names):

```bash
git fetch origin main
git rev-list --left-right --count HEAD...origin/main   # prints "<ahead> <behind>"
git log --oneline origin/main..HEAD                    # local-only commits
git log --oneline HEAD..origin/main                    # remote-only commits
git rebase origin/main                                 # replay local commits on top
git push origin main
```

The script also handles cases the short version does not: an upstream with a
different name, a branch not yet on the remote, and shallow clones that need
more history before git can find where the branches split.
