import Darwin
import Foundation

protocol ImageBuildHistoryStoring: Sendable {
  func load() async throws -> ImageBuildHistorySnapshot
  func record(_ record: ImageBuildHistoryRecord) async throws
  func remove(id: UUID) async throws
  func removeAll() async throws
  func updates() async -> AsyncStream<Void>
}

actor NoopImageBuildHistoryStore: ImageBuildHistoryStoring {
  private let snapshot: ImageBuildHistorySnapshot

  init(
    snapshot: ImageBuildHistorySnapshot = ImageBuildHistorySnapshot(
      records: [],
      rejectedRecordCount: 0
    )
  ) {
    self.snapshot = snapshot
  }

  func load() -> ImageBuildHistorySnapshot {
    snapshot
  }

  func record(_ record: ImageBuildHistoryRecord) {}
  func remove(id: UUID) {}
  func removeAll() {}

  func updates() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }
}

enum ImageBuildHistoryStoreError: LocalizedError, Equatable, Sendable {
  case unsafeStorage(String)
  case invalidTransition(UUID)
  case unsupportedSchema(Int)
  case oversizedRecord(Int)
  case tooManyEntries(Int)
  case maintenanceAfterCommit
  case ioFailure(operation: String, code: Int32)

  var errorDescription: String? {
    switch self {
    case .unsafeStorage:
      "Build history storage is not private to the current user."
    case .invalidTransition(let id):
      "Build history record \(id.uuidString.lowercased()) has an invalid state transition."
    case .unsupportedSchema:
      "A build history record was created by a newer, unsupported schema."
    case .oversizedRecord(let byteCount):
      "A build history record is unexpectedly large (\(byteCount) bytes)."
    case .tooManyEntries(let maximum):
      "Build history contains more than the safe limit of \(maximum) entries."
    case .maintenanceAfterCommit:
      "The build history record was saved, but post-write maintenance did not finish."
    case .ioFailure(let operation, let code):
      "Build history \(operation) failed (errno \(code))."
    }
  }

  var recordWasCommitted: Bool {
    self == .maintenanceAfterCommit
  }

  var shouldDiscardRecord: Bool {
    switch self {
    case .unsafeStorage, .oversizedRecord:
      true
    case .invalidTransition, .unsupportedSchema, .tooManyEntries,
      .maintenanceAfterCommit, .ioFailure:
      false
    }
  }
}

actor ImageBuildHistoryStore: ImageBuildHistoryStoring {
  static let maximumTerminalRecordCount = 200
  static let maximumRecordBytes = 64 * 1_024
  static let maximumFilesToScan = 1_000
  static let recordExtension = "json"

  private static let maximumDirectoryEntryCount = 2_000
  private static let removalBatchSize = 1_000

  private struct Envelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let record: ImageBuildHistoryRecord
  }

  private struct EnvelopeHeader: Decodable {
    let schemaVersion: Int
  }

  private struct RecordCandidate {
    let entry: PrivateImageBuildHistoryDirectory.Entry
    let id: UUID
  }

  nonisolated private let directory: PrivateImageBuildHistoryDirectory
  nonisolated private let launchID: UUID
  private let now: @Sendable () -> Date
  private var launchLeaseDescriptor: Int32?
  private var observedDirectoryToken: PrivateImageBuildHistoryDirectory.ChangeToken?
  private var watchedForeignLaunchIDs: Set<UUID> = []
  private var needsReconciliationRefresh = false
  private var latchedRejectedRecordCount = 0
  private var updateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

  init(
    rootURL: URL? = nil,
    launchID: UUID = UUID(),
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let resolvedRoot = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
    directory = PrivateImageBuildHistoryDirectory(
      rootURL: resolvedRoot,
      maximumRecordBytes: Self.maximumRecordBytes
    )
    self.launchID = launchID
    self.now = now
  }

  deinit {
    guard let launchLeaseDescriptor else { return }
    _ = try? directory.withExistingDescriptor { rootDescriptor in
      if try directory.remove(
        named: Self.launchLeaseName(for: launchID),
        rootDescriptor: rootDescriptor
      ) {
        try directory.synchronize(rootDescriptor)
      }
    }
    Darwin.close(launchLeaseDescriptor)
  }

  func load() throws -> ImageBuildHistorySnapshot {
    try withStoreDescriptor { rootDescriptor in
      var rejectedCount = 0
      var didMutate = false
      var shouldPublishUpdate = false
      var records: [ImageBuildHistoryRecord] = []
      var liveForeignLaunchIDs: Set<UUID> = []

      let startingToken = try directory.changeToken(
        rootDescriptor: rootDescriptor
      )
      if let observedDirectoryToken {
        if startingToken != observedDirectoryToken {
          shouldPublishUpdate = true
        }
      } else if !updateContinuations.isEmpty {
        shouldPublishUpdate = true
      }

      do {
        let candidates = try scanCandidates(
          rootDescriptor: rootDescriptor,
          rejectedCount: &rejectedCount,
          didMutate: &didMutate
        )

        for candidate in candidates {
          guard
            var record = try readCandidate(
              candidate,
              rootDescriptor: rootDescriptor,
              rejectedCount: &rejectedCount,
              didMutate: &didMutate
            )
          else {
            continue
          }

          if record.status == .running, record.launchID != launchID {
            let isActive = try directory.isLeaseActive(
              named: Self.launchLeaseName(for: record.launchID),
              rootDescriptor: rootDescriptor
            )
            if isActive {
              liveForeignLaunchIDs.insert(record.launchID)
            } else {
              record = record.finishing(
                at: now(),
                status: .interrupted,
                imageDigest: nil,
                completedTags: [],
                failureKind: nil
              )
              try persist(record, rootDescriptor: rootDescriptor)
              didMutate = true
              shouldPublishUpdate = true
            }
          }
          records.append(record)
        }

        if records.filter({ $0.status.isTerminal }).count
          > Self.maximumTerminalRecordCount
        {
          shouldPublishUpdate = true
        }
        records = try applyRetention(
          to: records,
          maximumTerminalCount: Self.maximumTerminalRecordCount,
          rootDescriptor: rootDescriptor,
          didMutate: &didMutate
        )
      } catch {
        if didMutate {
          try directory.synchronize(rootDescriptor)
        }
        throw error
      }

      if didMutate {
        try directory.synchronize(rootDescriptor)
      }
      watchedForeignLaunchIDs = liveForeignLaunchIDs
      needsReconciliationRefresh = false
      rememberDirectoryToken(rootDescriptor)
      if shouldPublishUpdate {
        publishUpdate()
      }

      latchedRejectedRecordCount = max(
        latchedRejectedRecordCount,
        rejectedCount
      )
      return ImageBuildHistorySnapshot(
        records: canonical(records),
        rejectedRecordCount: latchedRejectedRecordCount
      )
    }
  }

  func record(_ record: ImageBuildHistoryRecord) throws {
    try withStoreDescriptor { rootDescriptor in
      let name = Self.recordName(for: record.id)
      if let existing = try readRecordIfPresent(
        named: name,
        expectedID: record.id,
        rootDescriptor: rootDescriptor
      ) {
        if existing == record { return }
        guard existing.status == .running,
          record.status.isTerminal,
          let finishedAt = record.finishedAt,
          existing.finishing(
            at: finishedAt,
            status: record.status,
            imageDigest: record.imageDigest,
            completedTags: record.completedTags,
            failureKind: record.failureKind,
            retainedImages: record.retainedImages
          ) == record
        else {
          throw ImageBuildHistoryStoreError.invalidTransition(record.id)
        }
      }

      do {
        try persist(record, rootDescriptor: rootDescriptor)
      } catch let error as ImageBuildHistoryStoreError
        where error.recordWasCommitted
      {
        rememberDirectoryToken(rootDescriptor)
        publishUpdate()
        throw error
      }

      if record.status.isTerminal {
        do {
          try enforceRetentionAfterTerminalWrite(
            rootDescriptor: rootDescriptor
          )
        } catch {
          rememberDirectoryToken(rootDescriptor)
          publishUpdate()
          throw ImageBuildHistoryStoreError.maintenanceAfterCommit
        }
      }

      rememberDirectoryToken(rootDescriptor)
      publishUpdate()
    }
  }

  func remove(id: UUID) throws {
    try withStoreDescriptor { rootDescriptor in
      let didRemove = try directory.remove(
        named: Self.recordName(for: id),
        rootDescriptor: rootDescriptor
      )
      if didRemove {
        try directory.synchronize(rootDescriptor)
        rememberDirectoryToken(rootDescriptor)
        publishUpdate()
      }
    }
  }

  func removeAll() throws {
    try withStoreDescriptor { rootDescriptor in
      var didRemoveAny = false

      while true {
        let listing = try directory.entries(
          rootDescriptor: rootDescriptor,
          maximumCount: Self.removalBatchSize
        )
        var didRemoveBatch = false

        do {
          for entry in listing.entries {
            if Self.isHistoryOwnedLeaf(entry.name) {
              didRemoveBatch =
                try directory.remove(
                  named: entry.name,
                  rootDescriptor: rootDescriptor
                ) || didRemoveBatch
            } else if let leaseID = Self.identifier(fromLaunchLeaseName: entry.name),
              leaseID != launchID
            {
              let isActive = try directory.isLeaseActive(
                named: entry.name,
                rootDescriptor: rootDescriptor
              )
              didRemoveBatch = !isActive || didRemoveBatch
            }
          }
        } catch {
          if didRemoveBatch {
            try directory.synchronize(rootDescriptor)
            rememberDirectoryToken(rootDescriptor)
            publishUpdate()
          }
          throw error
        }

        if didRemoveBatch {
          try directory.synchronize(rootDescriptor)
          didRemoveAny = true
        }
        guard listing.hasMore else { break }
        guard didRemoveBatch else {
          throw ImageBuildHistoryStoreError.tooManyEntries(
            Self.removalBatchSize
          )
        }
      }

      let didClearWarning = latchedRejectedRecordCount > 0
      latchedRejectedRecordCount = 0
      if didRemoveAny || didClearWarning {
        watchedForeignLaunchIDs.removeAll()
        needsReconciliationRefresh = false
        rememberDirectoryToken(rootDescriptor)
        publishUpdate()
      }
    }
  }

  func updates() -> AsyncStream<Void> {
    let identifier = UUID()
    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    let isFirstSubscriber = updateContinuations.isEmpty
    updateContinuations[identifier] = continuation
    if isFirstSubscriber || observedDirectoryToken == nil {
      observedDirectoryToken = directoryChangeToken()
    }

    let pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(1))
        } catch {
          return
        }
        await self?.pollForExternalUpdate()
      }
    }
    continuation.onTermination = { [weak self] _ in
      pollingTask.cancel()
      Task {
        await self?.removeUpdateContinuation(identifier)
      }
    }
    return stream
  }

  func releaseLaunchLease() {
    guard let launchLeaseDescriptor else { return }
    self.launchLeaseDescriptor = nil
    _ = try? directory.withExistingDescriptor { rootDescriptor in
      if try directory.remove(
        named: Self.launchLeaseName(for: launchID),
        rootDescriptor: rootDescriptor
      ) {
        try directory.synchronize(rootDescriptor)
      }
    }
    Darwin.close(launchLeaseDescriptor)
    observedDirectoryToken = nil
  }

  func abandonLaunchLease() {
    guard let launchLeaseDescriptor else { return }
    self.launchLeaseDescriptor = nil
    Darwin.close(launchLeaseDescriptor)
    observedDirectoryToken = nil
  }

  private func pollForExternalUpdate() {
    guard
      let sample = try? withStoreDescriptor({ rootDescriptor in
        var didObserveExpiredLease = false
        for foreignLaunchID in watchedForeignLaunchIDs {
          if try !directory.isLeaseActive(
            named: Self.launchLeaseName(for: foreignLaunchID),
            rootDescriptor: rootDescriptor
          ) {
            didObserveExpiredLease = true
          }
        }
        return (
          token: try directory.changeToken(rootDescriptor: rootDescriptor),
          didObserveExpiredLease: didObserveExpiredLease
        )
      })
    else {
      return
    }

    if sample.didObserveExpiredLease {
      needsReconciliationRefresh = true
    }
    defer { observedDirectoryToken = sample.token }

    guard let observedDirectoryToken else {
      publishUpdate()
      return
    }
    if sample.token != observedDirectoryToken || needsReconciliationRefresh {
      publishUpdate()
    }
  }

  private func rememberDirectoryToken(_ rootDescriptor: Int32) {
    observedDirectoryToken = try? directory.changeToken(
      rootDescriptor: rootDescriptor
    )
  }

  private func directoryChangeToken() -> PrivateImageBuildHistoryDirectory.ChangeToken? {
    try? withStoreDescriptor { rootDescriptor in
      try directory.changeToken(rootDescriptor: rootDescriptor)
    }
  }

  private func withStoreDescriptor<T>(
    _ operation: (Int32) throws -> T
  ) throws -> T {
    try directory.withDescriptor { rootDescriptor in
      if launchLeaseDescriptor == nil {
        launchLeaseDescriptor = try directory.acquireLease(
          named: Self.launchLeaseName(for: launchID),
          rootDescriptor: rootDescriptor
        )
      }
      return try operation(rootDescriptor)
    }
  }

  private func enforceRetentionAfterTerminalWrite(
    rootDescriptor: Int32
  ) throws {
    var rejectedCount = 0
    var didMutate = false
    var records: [ImageBuildHistoryRecord] = []

    do {
      let candidates = try scanCandidates(
        rootDescriptor: rootDescriptor,
        rejectedCount: &rejectedCount,
        didMutate: &didMutate
      )
      for candidate in candidates {
        if let record = try readCandidate(
          candidate,
          rootDescriptor: rootDescriptor,
          rejectedCount: &rejectedCount,
          didMutate: &didMutate
        ) {
          records.append(record)
        }
      }

      _ = try applyRetention(
        to: records,
        maximumTerminalCount: Self.maximumTerminalRecordCount,
        rootDescriptor: rootDescriptor,
        didMutate: &didMutate
      )
    } catch {
      if didMutate {
        try directory.synchronize(rootDescriptor)
      }
      throw error
    }

    if didMutate {
      try directory.synchronize(rootDescriptor)
    }
  }

  private func applyRetention(
    to records: [ImageBuildHistoryRecord],
    maximumTerminalCount: Int,
    rootDescriptor: Int32,
    didMutate: inout Bool
  ) throws -> [ImageBuildHistoryRecord] {
    let running = records.filter { !$0.status.isTerminal }
    let terminal = records.filter(\.status.isTerminal).sorted(by: Self.isNewer)
    let retainedTerminal = Array(terminal.prefix(maximumTerminalCount))

    for record in terminal.dropFirst(maximumTerminalCount) {
      didMutate =
        try directory.remove(
          named: Self.recordName(for: record.id),
          rootDescriptor: rootDescriptor
        ) || didMutate
    }
    return running + retainedTerminal
  }

  private func scanCandidates(
    rootDescriptor: Int32,
    rejectedCount: inout Int,
    didMutate: inout Bool
  ) throws -> [RecordCandidate] {
    let listing = try directory.entries(
      rootDescriptor: rootDescriptor,
      maximumCount: Self.maximumDirectoryEntryCount
    )
    guard !listing.hasMore else {
      throw ImageBuildHistoryStoreError.tooManyEntries(
        Self.maximumDirectoryEntryCount
      )
    }

    var candidates: [RecordCandidate] = []
    for entry in listing.entries {
      if let leaseID = Self.identifier(fromLaunchLeaseName: entry.name) {
        if leaseID != launchID {
          _ = try directory.isLeaseActive(
            named: entry.name,
            rootDescriptor: rootDescriptor
          )
        }
        continue
      }
      if Self.isTemporaryName(entry.name) {
        didMutate =
          try directory.discard(
            named: entry.name,
            rootDescriptor: rootDescriptor
          ) || didMutate
        continue
      }
      guard let id = Self.identifier(fromRecordName: entry.name) else { continue }
      guard entry.name == Self.recordName(for: id) else {
        rejectedCount += 1
        didMutate =
          try directory.discard(
            named: entry.name,
            rootDescriptor: rootDescriptor
          ) || didMutate
        continue
      }
      candidates.append(RecordCandidate(entry: entry, id: id))
    }

    guard candidates.count <= Self.maximumFilesToScan else {
      throw ImageBuildHistoryStoreError.tooManyEntries(
        Self.maximumFilesToScan
      )
    }

    candidates.sort {
      if $0.entry.modificationSeconds != $1.entry.modificationSeconds {
        return $0.entry.modificationSeconds > $1.entry.modificationSeconds
      }
      if $0.entry.modificationNanoseconds != $1.entry.modificationNanoseconds {
        return $0.entry.modificationNanoseconds > $1.entry.modificationNanoseconds
      }
      return $0.entry.name < $1.entry.name
    }
    return candidates
  }

  private func readCandidate(
    _ candidate: RecordCandidate,
    rootDescriptor: Int32,
    rejectedCount: inout Int,
    didMutate: inout Bool
  ) throws -> ImageBuildHistoryRecord? {
    do {
      return try readRecord(
        candidate,
        rootDescriptor: rootDescriptor
      )
    } catch let error as ImageBuildHistoryStoreError {
      if case .unsupportedSchema = error {
        rejectedCount += 1
        return nil
      }
      guard error.shouldDiscardRecord else {
        throw error
      }
      rejectedCount += 1
      didMutate =
        try directory.discard(
          named: candidate.entry.name,
          rootDescriptor: rootDescriptor
        ) || didMutate
      return nil
    } catch is DecodingError {
      rejectedCount += 1
      didMutate =
        try directory.discard(
          named: candidate.entry.name,
          rootDescriptor: rootDescriptor
        ) || didMutate
      return nil
    }
  }

  private func readRecord(
    _ candidate: RecordCandidate,
    rootDescriptor: Int32
  ) throws -> ImageBuildHistoryRecord {
    guard
      let record = try readRecordIfPresent(
        named: candidate.entry.name,
        expectedID: candidate.id,
        rootDescriptor: rootDescriptor
      )
    else {
      throw ImageBuildHistoryStoreError.unsafeStorage(candidate.entry.name)
    }
    return record
  }

  private func readRecordIfPresent(
    named name: String,
    expectedID: UUID,
    rootDescriptor: Int32
  ) throws -> ImageBuildHistoryRecord? {
    guard let data = try directory.read(named: name, rootDescriptor: rootDescriptor) else {
      return nil
    }

    let header = try Self.decoder.decode(EnvelopeHeader.self, from: data)
    guard header.schemaVersion == Envelope.currentSchemaVersion else {
      throw ImageBuildHistoryStoreError.unsupportedSchema(
        header.schemaVersion
      )
    }

    let envelope = try Self.decoder.decode(Envelope.self, from: data)
    guard envelope.record.id == expectedID else {
      throw ImageBuildHistoryStoreError.unsafeStorage(name)
    }
    return envelope.record
  }

  private func persist(
    _ record: ImageBuildHistoryRecord,
    rootDescriptor: Int32
  ) throws {
    let envelope = Envelope(
      schemaVersion: Envelope.currentSchemaVersion,
      record: record
    )
    let data = try Self.encoder.encode(envelope)
    let temporaryName =
      ".\(record.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).tmp"
    try directory.write(
      data,
      named: Self.recordName(for: record.id),
      temporaryName: temporaryName,
      rootDescriptor: rootDescriptor
    )
  }

  private func publishUpdate() {
    for continuation in updateContinuations.values {
      continuation.yield()
    }
  }

  private func removeUpdateContinuation(_ identifier: UUID) {
    updateContinuations.removeValue(forKey: identifier)
  }

  private static func recordName(for id: UUID) -> String {
    "\(id.uuidString.lowercased()).\(recordExtension)"
  }

  private static func launchLeaseName(for launchID: UUID) -> String {
    ".launch-\(launchID.uuidString.lowercased()).lease"
  }

  private static func identifier(fromLaunchLeaseName name: String) -> UUID? {
    let prefix = ".launch-"
    let suffix = ".lease"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
    let start = name.index(name.startIndex, offsetBy: prefix.count)
    let end = name.index(name.endIndex, offsetBy: -suffix.count)
    guard let identifier = UUID(uuidString: String(name[start..<end])),
      name == launchLeaseName(for: identifier)
    else {
      return nil
    }
    return identifier
  }

  private static func identifier(fromRecordName name: String) -> UUID? {
    guard name.hasSuffix(".\(recordExtension)") else { return nil }
    let suffixCount = recordExtension.count + 1
    return UUID(uuidString: String(name.dropLast(suffixCount)))
  }

  private static func isTemporaryName(_ name: String) -> Bool {
    guard name.first == ".", name.hasSuffix(".tmp") else { return false }
    let body = name.dropFirst().dropLast(4)
    guard body.count == 73 else { return false }
    let separator = body.index(body.startIndex, offsetBy: 36)
    guard body[separator] == "-" else { return false }
    let first = String(body[..<separator])
    let second = String(body[body.index(after: separator)...])
    return UUID(uuidString: first) != nil && UUID(uuidString: second) != nil
  }

  private static func isHistoryOwnedLeaf(_ name: String) -> Bool {
    identifier(fromRecordName: name) != nil || isTemporaryName(name)
  }

  private static func isNewer(
    _ lhs: ImageBuildHistoryRecord,
    _ rhs: ImageBuildHistoryRecord
  ) -> Bool {
    let left = lhs.finishedAt ?? lhs.startedAt
    let right = rhs.finishedAt ?? rhs.startedAt
    if left != right { return left > right }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private func canonical(
    _ records: [ImageBuildHistoryRecord]
  ) -> [ImageBuildHistoryRecord] {
    records.sorted(by: Self.isNewer)
  }

  private static func defaultRootURL(fileManager: FileManager) -> URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Build History", directoryHint: .isDirectory)
      .appending(path: "v1", directoryHint: .isDirectory)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private static let decoder = JSONDecoder()
}
