# Sources instructions

Swift package module boundaries and dependency direction are defined in `docs/adr/0002-native-architecture.md`. Declare Swift package targets and dependencies in `Package.swift`; `project.yml` defines the app and helpers. Keep external process execution within the root guide's allowlist.

On Xcode 26.6, an async-closure parameter defaulted with a closure literal can abort at runtime (#48). Use a named function as the default.
