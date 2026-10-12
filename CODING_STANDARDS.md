# Coding standards

Judgement-call rules. Mechanical rules live in `scripts/dev/` and run in `macos-check`.

## Tests

- Wait for a condition by polling with a timeout; CI runners are slow and uneven. Use the `TestSupport` target: `pollUntil`, `waitUntil` (observation) and `AsyncQueue`.
- A fake that simulates long work may sleep. A test that waits for something to happen does not.
- Files: `makeTemporaryDirectory` / `temporaryURL`. They are removed when the test process exits, so tests don't clean up.

## UI

- Strings go in the String Catalog, zh-Hans and en only.
- SwiftUI code follows the swiftui-specialist skill.
