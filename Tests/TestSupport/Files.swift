import Foundation

/// Writes `data` to `url`, creating the missing parent directories first.
public func writeFile(_ data: Data, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: url)
}

/// Writes `text` as UTF-8 to `url`, creating the missing parent directories first.
public func writeFile(_ text: String, to url: URL) throws {
  try writeFile(Data(text.utf8), to: url)
}
