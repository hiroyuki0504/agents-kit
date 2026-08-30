---
name: Bug report
about: Something broke or behaved unexpectedly
title: ''
labels: bug
assignees: ''
---

## Environment

Paste actual command output rather than typing from memory.

- OS and version:
- `git --version`:
- `python3 --version`:
- agents-kit commit (`git rev-parse --short HEAD` in your agents-kit clone, if known):

If your install has it, paste the output of `.agents/bin/agents doctor` (run inside the target repository):

```
(paste here)
```

## Steps to reproduce

Minimal, exact commands. Please note where you ran them (main checkout vs. an agent worktree) and whether other agent sessions were active at the time.

1.
2.
3.

## Expected behavior

What you expected to happen.

## Actual behavior

What actually happened: exact output or error message, and the exit code if you have it (`echo $?`). Where relevant, the output of `.agents/bin/agents sync` and an excerpt of `git log --oneline --stat refs/remotes/origin/agent-state` (the coordination audit log) help a lot.
