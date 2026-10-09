// Verifies a Sparkle EdDSA signature against the public key the app ships with.
// Usage: swift verify-ed-signature.swift <public-key-base64> <signature-base64> <file>
// Exits non-zero when the signature does not match, so a secret holding the
// wrong private key can never publish an appcast that clients would reject.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
  FileHandle.standardError.write(Data("usage: verify-ed-signature <public-key-b64> <signature-b64> <file>\n".utf8))
  exit(2)
}
guard let keyData = Data(base64Encoded: args[1]),
  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else {
  FileHandle.standardError.write(Data("invalid public key\n".utf8))
  exit(1)
}
guard let signature = Data(base64Encoded: args[2]) else {
  FileHandle.standardError.write(Data("invalid signature\n".utf8))
  exit(1)
}
guard let file = FileManager.default.contents(atPath: args[3]) else {
  FileHandle.standardError.write(Data("cannot read \(args[3])\n".utf8))
  exit(1)
}
guard key.isValidSignature(signature, for: file) else {
  FileHandle.standardError.write(Data("signature does not match SUPublicEDKey\n".utf8))
  exit(1)
}
print("signature matches SUPublicEDKey")
