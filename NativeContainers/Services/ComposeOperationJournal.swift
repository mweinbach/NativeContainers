import Darwin
import Foundation

actor ComposeOperationJournal: ComposeOperationJournaling {
  static let maximumRecordByteCount: Int64 = 64 * 1_024

  private let fileStore: ComposeOperationJournalFileStore
  private let codec = ComposeOperationJournalRecordCodec()

  init(
    directoryURL: URL,
    effectiveUserID: uid_t = Darwin.geteuid(),
    durabilitySyncer: any ComposeOperationJournalDurabilitySyncing =
      DarwinComposeOperationJournalDurabilitySyncer(),
    fileManager: FileManager = .default
  ) {
    fileStore = ComposeOperationJournalFileStore(
      directoryURL: directoryURL,
      effectiveUserID: effectiveUserID,
      durabilitySyncer: durabilitySyncer,
      fileManager: fileManager
    )
  }

  func persistPending(_ entry: ComposeOperationJournalEntry) async throws {
    try fileStore.createRecord(
      codec.encode(entry),
      operationID: entry.operationID
    )
  }

  func updatePending(
    operationID: UUID,
    expectedPhase: ComposeOperationJournalPhase,
    progress: ComposeOperationJournalProgress
  ) async throws {
    try fileStore.updateRecord(operationID: operationID) { data in
      let current = try codec.decode(data, expectedOperationID: operationID)
      let updated = try codec.updatedEntry(
        from: current,
        expectedPhase: expectedPhase,
        progress: progress
      )
      return try codec.encode(updated)
    }
  }

  func pendingRecoverySnapshots() async throws -> [ComposeOperationRecoverySnapshot] {
    try fileStore.allRecords().map { record in
      try codec.decode(
        record.data,
        expectedOperationID: record.operationID
      )
    }.sorted {
      if $0.preparedAt != $1.preparedAt {
        return $0.preparedAt < $1.preparedAt
      }
      return $0.operationID.uuidString < $1.operationID.uuidString
    }
  }

  func discardPendingAfterReview(operationID: UUID) async throws {
    try fileStore.discardRecord(operationID: operationID)
  }

  static func recordFilename(for operationID: UUID) -> String {
    ComposeOperationJournalFileStore.recordFilename(for: operationID)
  }
}
