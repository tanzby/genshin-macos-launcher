import Foundation

/// An empty `UserDefaults` suite stored in the test root (see TemporaryDirectory.swift) instead of
/// ~/Library/Preferences: a suite named by an absolute path is written to `<path>.plist`. A named suite there outlives
/// the test process, because cfprefsd writes it out asynchronously and `removePersistentDomain` cannot recall that.
/// `name` only helps reading failures. Returns the suite name too, for `persistentDomain(forName:)`.
public func makeTemporaryDefaults(_ name: String = "defaults") -> (defaults: UserDefaults, suite: String) {
  let suite = temporaryURL(name).path
  return (UserDefaults(suiteName: suite)!, suite)
}
