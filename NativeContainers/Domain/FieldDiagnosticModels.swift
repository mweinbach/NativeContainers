import Foundation

enum FieldDiagnosticPayloadKind: String, Codable, CaseIterable, Equatable, Sendable {
  case dailyMetrics
  case diagnostics
}

struct FieldDiagnosticCategoryCounts: Codable, Equatable, Sendable {
  let crashes: Int
  let hangs: Int
  let cpuExceptions: Int
  let diskWriteExceptions: Int

  init(
    crashes: Int = 0,
    hangs: Int = 0,
    cpuExceptions: Int = 0,
    diskWriteExceptions: Int = 0
  ) {
    self.crashes = max(0, crashes)
    self.hangs = max(0, hangs)
    self.cpuExceptions = max(0, cpuExceptions)
    self.diskWriteExceptions = max(0, diskWriteExceptions)
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let values = (
      crashes: try container.decode(Int.self, forKey: .crashes),
      hangs: try container.decode(Int.self, forKey: .hangs),
      cpuExceptions: try container.decode(Int.self, forKey: .cpuExceptions),
      diskWriteExceptions:
        try container.decode(Int.self, forKey: .diskWriteExceptions)
    )
    guard
      Self.isValidStoredCount(values.crashes),
      Self.isValidStoredCount(values.hangs),
      Self.isValidStoredCount(values.cpuExceptions),
      Self.isValidStoredCount(values.diskWriteExceptions)
    else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: container.codingPath,
          debugDescription: "Diagnostic category counts are outside the bounded range."
        )
      )
    }
    self.init(
      crashes: values.crashes,
      hangs: values.hangs,
      cpuExceptions: values.cpuExceptions,
      diskWriteExceptions: values.diskWriteExceptions
    )
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(crashes, forKey: .crashes)
    try container.encode(hangs, forKey: .hangs)
    try container.encode(cpuExceptions, forKey: .cpuExceptions)
    try container.encode(diskWriteExceptions, forKey: .diskWriteExceptions)
  }

  private enum CodingKeys: String, CodingKey {
    case crashes
    case hangs
    case cpuExceptions
    case diskWriteExceptions
  }

  private static func isValidStoredCount(_ value: Int) -> Bool {
    (0...1_000_000).contains(value)
  }

  var total: Int {
    crashes + hangs + cpuExceptions + diskWriteExceptions
  }

  static let zero = FieldDiagnosticCategoryCounts()
}

struct FieldDiagnosticRecord: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let kind: FieldDiagnosticPayloadKind
  let periodStart: Date
  let periodEnd: Date
  let receivedAt: Date
  let categories: FieldDiagnosticCategoryCounts
  let payloadByteCount: Int

  init(
    id: String,
    kind: FieldDiagnosticPayloadKind,
    periodStart: Date,
    periodEnd: Date,
    receivedAt: Date,
    categories: FieldDiagnosticCategoryCounts,
    payloadByteCount: Int
  ) {
    self.id = id
    self.kind = kind
    self.periodStart = periodStart
    self.periodEnd = periodEnd
    self.receivedAt = receivedAt
    self.categories = categories
    self.payloadByteCount = max(0, payloadByteCount)
  }
}

struct FieldDiagnosticSnapshot: Equatable, Sendable {
  let records: [FieldDiagnosticRecord]
  let rejectedRecordCount: Int
  let totalPayloadByteCount: Int
  let collectionWarning: String?

  init(
    records: [FieldDiagnosticRecord],
    rejectedRecordCount: Int,
    totalPayloadByteCount: Int,
    collectionWarning: String? = nil
  ) {
    self.records = records
    self.rejectedRecordCount = max(0, rejectedRecordCount)
    self.totalPayloadByteCount = max(0, totalPayloadByteCount)
    self.collectionWarning = collectionWarning
  }

  static let empty = FieldDiagnosticSnapshot(
    records: [],
    rejectedRecordCount: 0,
    totalPayloadByteCount: 0
  )

  var diagnosticCount: Int {
    records.lazy
      .filter { $0.kind == .diagnostics }
      .map(\.categories.total)
      .reduce(0, +)
  }

  var metricPayloadCount: Int {
    records.count(where: { $0.kind == .dailyMetrics })
  }
}

struct FieldDiagnosticExport: Equatable, Sendable {
  let fileName: String
  let data: Data
}

struct CapturedFieldDiagnosticPayload: Equatable, Sendable {
  let kind: FieldDiagnosticPayloadKind
  let periodStart: Date
  let periodEnd: Date
  let categories: FieldDiagnosticCategoryCounts
  let json: Data
}

protocol FieldDiagnosticManaging: Sendable {
  func start()
  func load() async throws -> FieldDiagnosticSnapshot
  func exportRecord(id: String) async throws -> FieldDiagnosticExport
  func removeAll() async throws
  func updates() async -> AsyncStream<Void>
}

struct UnavailableFieldDiagnosticService: FieldDiagnosticManaging {
  func start() {}

  func load() async throws -> FieldDiagnosticSnapshot {
    .empty
  }

  func exportRecord(id: String) async throws -> FieldDiagnosticExport {
    throw FieldDiagnosticServiceError.unavailable
  }

  func removeAll() async throws {}

  func updates() async -> AsyncStream<Void> {
    AsyncStream { continuation in
      continuation.finish()
    }
  }
}

enum FieldDiagnosticServiceError: LocalizedError, Equatable, Sendable {
  case unavailable
  case recordNotFound
  case invalidPayload
  case payloadTooLarge
  case unsafeStorage
  case storageLimitExceeded
  case ioFailure(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Field diagnostics are unavailable in this app context."
    case .recordNotFound:
      "The selected diagnostic report is no longer available."
    case .invalidPayload:
      "MetricKit returned an invalid diagnostic payload."
    case .payloadTooLarge:
      "A MetricKit payload exceeded the private storage limit."
    case .unsafeStorage:
      "Field diagnostic storage is not private to the current user."
    case .storageLimitExceeded:
      "Field diagnostic storage exceeded its bounded scan limit."
    case .ioFailure(let operation):
      "Field diagnostic storage could not \(operation)."
    }
  }
}
