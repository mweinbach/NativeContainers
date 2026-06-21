import Foundation

protocol ComposeServiceHashDecoding: Sendable {
  func decode(_ output: String) throws -> [String: String]
}

struct ComposeServiceHashDecoder: ComposeServiceHashDecoding {
  func decode(_ output: String) throws -> [String: String] {
    var hashes: [String: String] = [:]
    for line in output.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count == 2 else {
        throw ComposeProjectLifecycleError.configOutputInvalid(
          "A service configuration hash row was malformed."
        )
      }
      let service = String(fields[0])
      let hash = String(fields[1])
      guard
        hashes[service] == nil,
        hash.count == 64,
        hash.utf8.allSatisfy({
          ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        })
      else {
        throw ComposeProjectLifecycleError.configOutputInvalid(
          "A service configuration hash was invalid or duplicated."
        )
      }
      hashes[service] = hash
    }
    guard !hashes.isEmpty else {
      throw ComposeProjectLifecycleError.configOutputInvalid(
        "No service configuration hashes were returned."
      )
    }
    return hashes
  }
}
