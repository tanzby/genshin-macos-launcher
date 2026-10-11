# AGENTS.md

Yaagl is a native Swift 6 / SwiftUI launcher for Genshin Impact's CN server. It runs the Windows game through a modified Wine with DXMT on Apple Silicon and macOS 26+.

## Project-wide rules

- Reply in Simplified Chinese.
- Before a nontrivial change, state assumptions and verifiable checks. Keep the change scoped, preserve unrelated work, and ask through AskUserQuestion when a decision blocks progress (up to four questions; recommended option first).
- Use the named `worker`, `explorer`, and `Reviewer` roles for implementation, exploration, and quality cleanup/review as applicable; the primary agent coordinates and synthesizes.
- Read the closest `AGENTS.md` before changing a directory. Every Git-tracked project directory has a local guide; its `CLAUDE.md` imports that guide for Claude Code.
- For current library, framework, SDK, API, CLI, or cloud-service documentation, follow [`docs/agents/context7.md`](docs/agents/context7.md).
- For domain terms, read [`CONTEXT.md`](CONTEXT.md). Before changing a module boundary or an accepted architectural decision, read the relevant ADR in [`docs/adr/`](docs/adr/).
- If a change adds an external process, keep it within Wine, the x86_64 helpers, or the existing `codesign`, `tar`, and `ditto` tools.

## Find the right guide

- Before creating a worktree, validating, pushing, merging, releasing, or running the game, read [`docs/agents/development-workflow.md`](docs/agents/development-workflow.md).
- When creating or updating issues, read [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md); when classifying them, read [`docs/agents/triage-labels.md`](docs/agents/triage-labels.md).
- SwiftUI app and localization: [`App/AGENTS.md`](App/AGENTS.md).
- Swift modules: [`Sources/AGENTS.md`](Sources/AGENTS.md); tests: [`Tests/AGENTS.md`](Tests/AGENTS.md).
- Build and diagnostic scripts: [`scripts/AGENTS.md`](scripts/AGENTS.md); CI and release automation: [`.github/AGENTS.md`](.github/AGENTS.md).
- The 1.0.0 session retrospective and resulting harness decisions: [`docs/agents/retrospective-native-launcher-1.0.0.md`](docs/agents/retrospective-native-launcher-1.0.0.md).
