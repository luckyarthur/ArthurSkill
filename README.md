# ArthurSkill

A collection of skills for Claude. Each skill is a folder under `skills/` with
a `SKILL.md` (instructions Claude reads) and optional helper scripts.

## Skills

| Skill | What it does |
|-------|--------------|
| [git-branch-sync](skills/git-branch-sync/SKILL.md) | Checks whether the local git branch can be pushed. If it has diverged from the remote, replays the local commits on top of the remote branch so both sides' changes are kept. |

## Install

Claude Code, for all your projects:

```bash
cp -r skills/git-branch-sync ~/.claude/skills/
```

Claude Code, for one project only: copy the folder into that project's
`.claude/skills/` instead.

## Use the script directly

The skill's script also works on its own, without Claude:

```bash
bash skills/git-branch-sync/scripts/check_sync.sh          # check only
bash skills/git-branch-sync/scripts/check_sync.sh --fix    # rebase if needed
bash skills/git-branch-sync/scripts/check_sync.sh --push   # rebase, then push
```

## Tests

```bash
bash tests/test_git_branch_sync.sh
```

Each test builds throwaway repositories in a temp folder, so it never touches
your real repos.
