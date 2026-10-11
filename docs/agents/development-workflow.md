# Development workflow

## Worktrees

- Keep the main checkout on a clean `main`. Use one worktree per change under `.claude/worktrees/<name>`, based on `origin/main`:

  ```bash
  git fetch origin
  git worktree add .claude/worktrees/<name> -b <branch> origin/main
  ```

- The installed app, `~/Library/Application Support/Yaagl`, and game files are shared across worktrees. Run the game in one worktree at a time.
- The stash stack is shared by all worktrees. Use a WIP commit when a checkpoint is needed.

## Checks and review

- `scripts/dev/macos-check` is the CI `swift` check and lefthook pre-push gate. Use it for the complete local gate; it also fails if `Package.resolved` changes.
- Bound a local command with `scripts/dev/run-with-timeout <seconds> <command> [args…]`. It uses Python's standard library and exits 124 after terminating the command's process group; this works on macOS where GNU `timeout` may be absent.
- Before the first push, run `/simplify` and resolve its findings. Before merge, run `/code-review` on the PR diff; include workflow, YAML, `project.yml`, and documentation changes.
- After opening a PR, address or reply to every inline comment from `chatgpt-codex-connector[bot]`, push the result, then comment `@codex review`. Repeat until the bot raises no new findings. Merge only after review threads are addressed and the required `swift` check is green.
- Keep the current turn active through review, CI, merge, and cleanup. Bound each command or status wait to 30 minutes, then check progress again. Save long command output in a task-specific log under `${TMPDIR:-/tmp}`; if a command stops making progress, inspect its log and process once, then resume from a safe point or report the concrete blocker.
- Historical review-policy changes are recorded in [`retrospective-native-launcher-1.0.0.md`](retrospective-native-launcher-1.0.0.md).

## Swift runtime note

On Xcode 26.6, a closure literal used as the default value for an async-closure parameter can abort at runtime (#48). A named function is the supported default.

## Merge and cleanup

- Squash-merge after review and the required check pass. Then remove the worktree and branch, fast-forward the main checkout, and remove temporary files.
- Before deleting a squash-merged branch, confirm it contains no unique tree changes:

  ```bash
  git merge-tree --write-tree origin/main <branch>
  git rev-parse 'origin/main^{tree}'
  ```

  The branch is safe to delete when both commands return the same tree hash.

## Runtime and release verification

- For game behavior, follow the deterministic, time-boxed text-output procedure in [`../genshin-macos.md`](../genshin-macos.md), then close the game.
- For release versioning, packaging, signing, and publication gates, follow [`../release.md`](../release.md).
