// Sparkle comes in through this package rather than straight from project.yml, so SwiftPM and Xcode resolve the
// same dependency graph and agree on Package.resolved (#87). The app imports `Updates` and uses Sparkle directly.
@_exported import Sparkle
