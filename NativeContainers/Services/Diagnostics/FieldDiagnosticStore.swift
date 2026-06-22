import CryptoKit
import Darwin
import Foundation

actor FieldDiagnosticStore {
  static let maximumRecordCount = 30
  static let maximumPayloadBytes = 8 * 1_024 * 1_024
  static let maximumTotalPayloadBytes = 20 * 1_024 * 1_024
  static let maximumFilesToScan = 100

  private static let recordSuffix = ".field-diagnostic.json"
  private static let maximumEnvelopeBytes = 12 * 1_024 * 1_024

  private struct Envelope: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let record: FieldDiagnosticRecord
    let payloadSHA256: String
    let payload: Data
  }

  private struct Candidate {
    let url: URL
    let envelope: Envelope
  }

  private let rootURL: URL
  private let fileManager: FileManager
  private let now: @Sendable () -> Date
  private var updateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

  init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.fileManager = fileManager
    self.now = now
    self.rootURL =
      rootURL
      ?? Self.defaultRootURL(fileManager: fileManager)
  }

  func record(_ payload: CapturedFieldDiagnosticPayload) throws {
    guard
      !payload.json.isEmpty,
      payload.json.count <= Self.maximumPayloadBytes,
      payload.periodStart <= payload.periodEnd,
      (try? JSONSerialization.jsonObject(with: payload.json)) != nil
    else {
      if payload.json.count > Self.maximumPayloadBytes {
        throw FieldDiagnosticServiceError.payloadTooLarge
      }
      throw FieldDiagnosticServiceError.invalidPayload
    }

    try ensurePrivateRoot()
    let identifier = Self.identifier(for: payload)
    let record = FieldDiagnosticRecord(
      id: identifier,
      kind: payload.kind,
      periodStart: payload.periodStart,
      periodEnd: payload.periodEnd,
      receivedAt: now(),
      categories: payload.categories,
      payloadByteCount: payload.json.count
    )
    let envelope = Envelope(
      schemaVersion: Envelope.currentSchemaVersion,
      record: record,
      payloadSHA256: Self.sha256(payload.json),
      payload: payload.json
    )
    let destination = recordURL(id: identifier)

    if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
      let existing = try readCandidate(at: destination)
      guard existing.envelope.payload == payload.json else {
        throw FieldDiagnosticServiceError.unsafeStorage
      }
      return
    }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(envelope)
    guard encoded.count <= Self.maximumEnvelopeBytes else {
      throw FieldDiagnosticServiceError.payloadTooLarge
    }

    do {
      try encoded.write(to: destination, options: [.atomic])
      guard
        Darwin.chmod(destination.path(percentEncoded: false), 0o600) == 0
      else {
        throw FieldDiagnosticServiceError.ioFailure("secure a report")
      }
      _ = try validateRegularFile(at: destination)
      try excludeFromBackup(destination)
      _ = try loadAndApplyRetention()
      publishUpdate()
    } catch {
      try? fileManager.removeItem(at: destination)
      throw map(error, operation: "save a report")
    }
  }

  func load() throws -> FieldDiagnosticSnapshot {
    try ensurePrivateRoot()
    return try loadAndApplyRetention()
  }

  func exportRecord(id: String) throws -> FieldDiagnosticExport {
    guard Self.isValidIdentifier(id) else {
      throw FieldDiagnosticServiceError.recordNotFound
    }
    try ensurePrivateRoot()
    let candidate: Candidate
    do {
      candidate = try readCandidate(at: recordURL(id: id))
    } catch {
      if (error as? CocoaError)?.code == .fileNoSuchFile {
        throw FieldDiagnosticServiceError.recordNotFound
      }
      throw map(error, operation: "read a report")
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp = formatter.string(from: candidate.envelope.record.periodEnd)
      .replacingOccurrences(of: ":", with: "-")
    return FieldDiagnosticExport(
      fileName:
        "NativeContainers-MetricKit-\(candidate.envelope.record.kind.rawValue)-\(timestamp).json",
      data: candidate.envelope.payload
    )
  }

  func removeAll() throws {
    guard fileManager.fileExists(atPath: Self.fileSystemPath(rootURL)) else {
      return
    }
    try ensurePrivateRoot()

    var didRemove = false
    for url in try recordURLs() {
      do {
        _ = try validateRegularFile(at: url)
        try fileManager.removeItem(at: url)
        didRemove = true
      } catch {
        throw map(error, operation: "remove stored reports")
      }
    }
    if didRemove {
      publishUpdate()
    }
  }

  func updates() -> AsyncStream<Void> {
    let identifier = UUID()
    return AsyncStream { continuation in
      updateContinuations[identifier] = continuation
      continuation.onTermination = { [weak self] _ in
        Task {
          await self?.removeUpdateContinuation(identifier)
        }
      }
    }
  }

  func notifyObservers() {
    publishUpdate()
  }

  private func loadAndApplyRetention() throws -> FieldDiagnosticSnapshot {
    var rejectedCount = 0
    var candidates: [Candidate] = []

    for url in try recordURLs() {
      do {
        candidates.append(try readCandidate(at: url))
      } catch {
        rejectedCount += 1
      }
    }

    candidates.sort {
      if $0.envelope.record.receivedAt != $1.envelope.record.receivedAt {
        return $0.envelope.record.receivedAt > $1.envelope.record.receivedAt
      }
      return $0.envelope.record.id < $1.envelope.record.id
    }

    var retained: [Candidate] = []
    var retainedBytes = 0
    var didRemove = false
    for candidate in candidates {
      let payloadBytes = candidate.envelope.record.payloadByteCount
      let keepsCount = retained.count < Self.maximumRecordCount
      let keepsBytes =
        payloadBytes <= Self.maximumTotalPayloadBytes - retainedBytes

      if keepsCount && keepsBytes {
        retained.append(candidate)
        retainedBytes += payloadBytes
      } else {
        try fileManager.removeItem(at: candidate.url)
        didRemove = true
      }
    }

    if didRemove {
      publishUpdate()
    }

    return FieldDiagnosticSnapshot(
      records: retained.map(\.envelope.record),
      rejectedRecordCount: rejectedCount,
      totalPayloadByteCount: retainedBytes
    )
  }

  private func recordURLs() throws -> [URL] {
    let contents = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    guard contents.count <= Self.maximumFilesToScan else {
      throw FieldDiagnosticServiceError.storageLimitExceeded
    }
    return
      contents
      .filter { $0.lastPathComponent.hasSuffix(Self.recordSuffix) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func readCandidate(at url: URL) throws -> Candidate {
    let metadata = try validateRegularFile(at: url)
    guard
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumEnvelopeBytes,
      let byteCount = Int(exactly: metadata.st_size)
    else {
      throw FieldDiagnosticServiceError.unsafeStorage
    }

    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count == byteCount else {
      throw FieldDiagnosticServiceError.unsafeStorage
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(Envelope.self, from: data)
    guard
      envelope.schemaVersion == Envelope.currentSchemaVersion,
      envelope.record.id
        == url.deletingPathExtension()
        .deletingPathExtension().lastPathComponent,
      envelope.record.payloadByteCount == envelope.payload.count,
      envelope.payload.count <= Self.maximumPayloadBytes,
      envelope.payloadSHA256 == Self.sha256(envelope.payload),
      envelope.record.id
        == Self.identifier(
          for: CapturedFieldDiagnosticPayload(
            kind: envelope.record.kind,
            periodStart: envelope.record.periodStart,
            periodEnd: envelope.record.periodEnd,
            categories: envelope.record.categories,
            json: envelope.payload
          )
        ),
      envelope.record.periodStart <= envelope.record.periodEnd,
      (try? JSONSerialization.jsonObject(with: envelope.payload)) != nil
    else {
      throw FieldDiagnosticServiceError.unsafeStorage
    }
    return Candidate(url: url, envelope: envelope)
  }

  private func ensurePrivateRoot() throws {
    do {
      let path = Self.fileSystemPath(rootURL)
      var metadata = stat()
      if Darwin.lstat(path, &metadata) == 0 {
        guard
          metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          metadata.st_uid == geteuid()
        else {
          throw FieldDiagnosticServiceError.unsafeStorage
        }
      } else {
        guard errno == ENOENT else {
          throw FieldDiagnosticServiceError.unsafeStorage
        }
        try fileManager.createDirectory(
          at: rootURL,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      }

      guard Darwin.chmod(path, 0o700) == 0 else {
        throw FieldDiagnosticServiceError.ioFailure("secure its directory")
      }
      guard
        Darwin.lstat(path, &metadata) == 0,
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid(),
        metadata.st_mode & 0o077 == 0
      else {
        throw FieldDiagnosticServiceError.unsafeStorage
      }
      try excludeFromBackup(rootURL)
    } catch let error as FieldDiagnosticServiceError {
      throw error
    } catch {
      throw map(error, operation: "prepare its directory")
    }
  }

  private func validateRegularFile(at url: URL) throws -> stat {
    var metadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0 else {
      if errno == ENOENT {
        throw FieldDiagnosticServiceError.recordNotFound
      }
      throw FieldDiagnosticServiceError.unsafeStorage
    }
    guard
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      metadata.st_mode & 0o077 == 0
    else {
      throw FieldDiagnosticServiceError.unsafeStorage
    }
    return metadata
  }

  private func recordURL(id: String) -> URL {
    rootURL.appending(path: "\(id)\(Self.recordSuffix)", directoryHint: .notDirectory)
  }

  private func excludeFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
  }

  private func publishUpdate() {
    for continuation in updateContinuations.values {
      continuation.yield(())
    }
  }

  private func removeUpdateContinuation(_ identifier: UUID) {
    updateContinuations.removeValue(forKey: identifier)
  }

  private func map(_ error: any Error, operation: String) -> FieldDiagnosticServiceError {
    if let error = error as? FieldDiagnosticServiceError {
      return error
    }
    return .ioFailure(operation)
  }

  private static func identifier(for payload: CapturedFieldDiagnosticPayload) -> String {
    var data = Data(payload.kind.rawValue.utf8)
    var start = payload.periodStart.timeIntervalSinceReferenceDate.bitPattern.bigEndian
    var end = payload.periodEnd.timeIntervalSinceReferenceDate.bitPattern.bigEndian
    withUnsafeBytes(of: &start) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: &end) { data.append(contentsOf: $0) }
    for count in [
      payload.categories.crashes,
      payload.categories.hangs,
      payload.categories.cpuExceptions,
      payload.categories.diskWriteExceptions,
    ] {
      var value = UInt64(count).bigEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    data.append(payload.json)
    return sha256(data)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func isValidIdentifier(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private static func fileSystemPath(_ url: URL) -> String {
    var path = url.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  private static func defaultRootURL(fileManager: FileManager) -> URL {
    let applicationSupport =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support", directoryHint: .isDirectory)
    return
      applicationSupport
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "FieldDiagnostics", directoryHint: .isDirectory)
  }
}
