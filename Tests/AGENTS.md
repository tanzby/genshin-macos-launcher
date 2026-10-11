# Tests instructions

Test targets mirror the package modules. Prefer deterministic fakes and `TestSupport` polling with a timeout; avoid fixed sleeps. Follow [`../Sources/AGENTS.md`](../Sources/AGENTS.md) for the Xcode 26.6 async-closure default gotcha. Run `scripts/dev/macos-check` for the full CI/pre-push gate.
