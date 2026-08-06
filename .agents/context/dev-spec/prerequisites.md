# Prerequisites

What must be installed and configured before development or agent workflows can
run. Every skill in [`../../skills/`](../../skills/) verifies its prerequisites
before acting and stops — rather than partially executing — when one is unmet.

## Required

| Tool | Check | If missing |
|------|-------|------------|
| macOS | `sw_vers -productVersion` | This project is macOS-only; there is no alternative. |
| Xcode | `xcodebuild -version` | Install from the App Store or developer.apple.com. |
| Active Xcode selection | `xcode-select -p` | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` — needs the user's password, so the user runs it, not the agent. |
| Command Line Tools | `xcode-select --install` | Follow the installer prompt. |
| Swift | `swift --version` | Ships with Xcode; a failure here usually means `xcode-select` points somewhere wrong. |
| Git | `git --version` | Ships with the Command Line Tools. |
| `git worktree` | `git worktree list` | Requires git ≥ 2.5; ships with the Command Line Tools. Required by the default [worktree workflow](worktree-workflow.md). |
| `origin` remote | `git remote -v` | Every worktree is based on `origin/main`. Create the GitHub repo and add the remote before using the worktree skills. |
| `gh` | `gh auth status` | Required by `draft-pr`, `open-pr`, and the PR-status refresh in `list-all-worktrees` / `delete-worktree`. Install with `brew install gh`, then `gh auth login`. |

## Optional

| Tool | Check | Purpose |
|------|-------|---------|
| `xcbeautify` | `xcbeautify --version` | Readable `xcodebuild` output. |

## Not yet applicable

The application target does not exist yet, so `xcodebuild -scheme Doppelganger`
will fail with "scheme not found" until the Xcode project is created. That is the
expected state, not a broken setup.

## Test fixtures

Per [Principle 3](../../../AGENTS.md#principles), never point development or test
runs at real camera cards or user footage. Generate synthetic media of realistic
size in a scratch directory outside the repository, and delete it when done.
