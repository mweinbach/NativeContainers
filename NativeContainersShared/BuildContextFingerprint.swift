import CryptoKit
import Darwin
import Foundation

enum BuildContextFingerprint {
  static func normalizedEntries(
    _ entries: [BuildContextStagedEntry]
  ) -> [BuildContextStagedEntryIdentity] {
    entries.map {
      BuildContextStagedEntryIdentity(
        relativePath: $0.relativePath,
        kind: $0.kind,
        snapshot: $0.snapshot
      )
    }.sorted {
      $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
    }
  }

  static func tree(
    _ entries: [BuildContextStagedEntry],
    rootSnapshot: BuildContextFileSnapshot
  ) throws -> String {
    var hasher = SHA256()
    hasher.update(data: Data("NativeContainers.BuildContext.v2\0".utf8))
    updateMetadata(rootSnapshot, hasher: &hasher)

    for entry in entries.sorted(by: BuildContextFileSystem.entryByteOrder) {
      try Task.checkCancellation()
      let pathData = Data(entry.relativePath.utf8)
      hasher.update(data: Data([entry.kind == .directory ? 0x44 : 0x46]))
      hasher.update(data: encodedUInt64(UInt64(pathData.count)))
      hasher.update(data: pathData)
      updateMetadata(entry.snapshot, hasher: &hasher)

      guard entry.kind == .regularFile else { continue }
      guard entry.snapshot.size >= 0 else {
        throw BuildContextStagingError.sourceChanged(entry.relativePath)
      }
      hasher.update(data: encodedUInt64(UInt64(entry.snapshot.size)))
      try streamRegularFile(
        at: entry.url,
        expected: entry.snapshot,
        displayPath: entry.relativePath
      ) { data in
        hasher.update(data: data)
      }
    }
    return hex(hasher.finalize())
  }

  static func regularFileData(
    at url: URL,
    expected: BuildContextFileSnapshot,
    displayPath: String,
    expectedByteCount: Int
  ) throws -> Data {
    var result = Data()
    result.reserveCapacity(expectedByteCount)
    try streamRegularFile(at: url, expected: expected, displayPath: displayPath) { data in
      result.append(data)
    }
    return result
  }

  static func hashRegularFile(
    at url: URL,
    expected: BuildContextFileSnapshot,
    displayPath: String
  ) throws -> String {
    var hasher = SHA256()
    try streamRegularFile(at: url, expected: expected, displayPath: displayPath) { data in
      hasher.update(data: data)
    }
    return hex(hasher.finalize())
  }

  static func hasCustomSyntaxDirective(_ data: Data) -> Bool {
    var contents = String(decoding: data, as: UTF8.self)
    if contents.first == "\u{feff}" {
      contents.removeFirst()
    }

    for line in contents.split(
      omittingEmptySubsequences: false,
      whereSeparator: \Character.isNewline
    ) {
      let trimmed = line.drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" })
      if trimmed.isEmpty { continue }
      guard trimmed.first == "#" else { return false }

      let comment = trimmed.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
      let lowercased = comment.lowercased()
      guard lowercased.hasPrefix("syntax") else { continue }
      let suffix = comment.dropFirst("syntax".count)
      guard suffix.first.map({ $0 == "=" || $0 == " " || $0 == "\t" }) == true else {
        continue
      }
      if suffix.drop(while: { $0 == " " || $0 == "\t" }).first == "=" {
        return true
      }
    }
    return false
  }

  static func sha256(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }

  private static func updateMetadata(
    _ snapshot: BuildContextFileSnapshot,
    hasher: inout SHA256
  ) {
    hasher.update(data: encodedUInt64(UInt64(snapshot.permissions)))
    hasher.update(data: encodedUInt64(UInt64(snapshot.owner)))
    hasher.update(data: encodedUInt64(UInt64(snapshot.group)))
    hasher.update(data: encodedInt64(Int64(snapshot.size)))
    hasher.update(data: encodedInt64(Int64(snapshot.modifiedSeconds)))
    hasher.update(data: encodedInt64(Int64(snapshot.modifiedNanoseconds)))
  }

  private static func streamRegularFile(
    at url: URL,
    expected: BuildContextFileSnapshot,
    displayPath: String,
    consume: (Data) -> Void
  ) throws {
    guard expected.kind == .regularFile else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw BuildContextFileSystem.posixError("open staged file", url)
    }
    defer { Darwin.close(descriptor) }
    guard
      try BuildContextFileSystem.snapshot(
        descriptor: descriptor,
        displayPath: displayPath
      ) == expected
    else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }

    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      try Task.checkCancellation()
      let bytesRead = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      guard bytesRead >= 0 else {
        throw BuildContextFileSystem.posixError("read staged file", url)
      }
      if bytesRead == 0 { break }
      consume(Data(buffer[0..<bytesRead]))
    }
    guard
      try BuildContextFileSystem.snapshot(
        descriptor: descriptor,
        displayPath: displayPath
      ) == expected,
      try BuildContextFileSystem.snapshot(at: url, displayPath: displayPath) == expected
    else {
      throw BuildContextStagingError.sourceChanged(displayPath)
    }
  }

  private static func encodedUInt64(_ value: UInt64) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func encodedInt64(_ value: Int64) -> Data {
    encodedUInt64(UInt64(bitPattern: value))
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
