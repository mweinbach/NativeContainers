import Foundation
import MetricKit
import OSLog

typealias FieldDiagnosticPayloadHandler =
  @Sendable ([CapturedFieldDiagnosticPayload]) -> Void

protocol FieldDiagnosticPayloadSource: Sendable {
  func start(handler: @escaping FieldDiagnosticPayloadHandler)
  func stop()
}

final class MetricKitFieldDiagnosticPayloadSource:
  NSObject,
  MXMetricManagerSubscriber,
  FieldDiagnosticPayloadSource,
  @unchecked Sendable
{
  private let manager: MXMetricManager
  private let stateLock = NSLock()
  private var handler: FieldDiagnosticPayloadHandler?
  private var isStarted = false

  init(manager: MXMetricManager = .shared) {
    self.manager = manager
  }

  deinit {
    stop()
  }

  func start(handler: @escaping FieldDiagnosticPayloadHandler) {
    let shouldStart = stateLock.withLock {
      self.handler = handler
      guard !isStarted else { return false }
      isStarted = true
      return true
    }
    guard shouldStart else { return }

    manager.add(self)
  }

  func stop() {
    let shouldStop = stateLock.withLock {
      guard isStarted else { return false }
      isStarted = false
      handler = nil
      return true
    }
    if shouldStop {
      manager.remove(self)
    }
  }

  func didReceive(_ payloads: [MXMetricPayload]) {
    deliver(payloads.map(Self.capture))
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    deliver(payloads.map(Self.capture))
  }

  private func deliver(_ payloads: [CapturedFieldDiagnosticPayload]) {
    guard !payloads.isEmpty else { return }
    let currentHandler = stateLock.withLock { handler }
    currentHandler?(payloads)
  }

  private static func capture(
    _ payload: MXMetricPayload
  ) -> CapturedFieldDiagnosticPayload {
    CapturedFieldDiagnosticPayload(
      kind: .dailyMetrics,
      periodStart: payload.timeStampBegin,
      periodEnd: payload.timeStampEnd,
      categories: .zero,
      json: payload.jsonRepresentation()
    )
  }

  private static func capture(
    _ payload: MXDiagnosticPayload
  ) -> CapturedFieldDiagnosticPayload {
    CapturedFieldDiagnosticPayload(
      kind: .diagnostics,
      periodStart: payload.timeStampBegin,
      periodEnd: payload.timeStampEnd,
      categories: FieldDiagnosticCategoryCounts(
        crashes: payload.crashDiagnostics?.count ?? 0,
        hangs: payload.hangDiagnostics?.count ?? 0,
        cpuExceptions: payload.cpuExceptionDiagnostics?.count ?? 0,
        diskWriteExceptions:
          payload.diskWriteExceptionDiagnostics?.count ?? 0
      ),
      json: payload.jsonRepresentation()
    )
  }
}

private actor FieldDiagnosticCollectionState {
  private var warning: String?

  func record(_ error: any Error) -> Bool {
    let message = error.localizedDescription
    guard warning != message else { return false }
    warning = message
    return true
  }

  func clearWarning() -> Bool {
    guard warning != nil else { return false }
    warning = nil
    return true
  }

  func currentWarning() -> String? {
    warning
  }
}

final class MetricKitFieldDiagnosticService:
  FieldDiagnosticManaging,
  @unchecked Sendable
{
  private static let logger = Logger(
    subsystem: "com.nativecontainers.app",
    category: "FieldDiagnostics"
  )

  private let source: any FieldDiagnosticPayloadSource
  private let store: FieldDiagnosticStore
  private let collectionState = FieldDiagnosticCollectionState()
  private let stateLock = NSLock()
  private var isStarted = false

  init(
    source: any FieldDiagnosticPayloadSource =
      MetricKitFieldDiagnosticPayloadSource(),
    store: FieldDiagnosticStore = FieldDiagnosticStore()
  ) {
    self.source = source
    self.store = store
  }

  deinit {
    source.stop()
  }

  func start() {
    let shouldStart = stateLock.withLock {
      guard !isStarted else { return false }
      isStarted = true
      return true
    }
    guard shouldStart else { return }

    source.start { [weak self] payloads in
      guard let self else { return }
      Task {
        await self.ingest(payloads)
      }
    }
  }

  func load() async throws -> FieldDiagnosticSnapshot {
    let snapshot = try await store.load()
    return snapshot.withCollectionWarning(
      await collectionState.currentWarning()
    )
  }

  func exportRecord(id: String) async throws -> FieldDiagnosticExport {
    try await store.exportRecord(id: id)
  }

  func removeAll() async throws {
    try await store.removeAll()
    if await collectionState.clearWarning() {
      await store.notifyObservers()
    }
  }

  func updates() async -> AsyncStream<Void> {
    await store.updates()
  }

  private func ingest(_ payloads: [CapturedFieldDiagnosticPayload]) async {
    var lastError: (any Error)?
    for payload in payloads {
      do {
        try await store.record(payload)
      } catch {
        lastError = error
        Self.logger.error(
          "Could not retain a MetricKit payload: \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    if let lastError {
      if await collectionState.record(lastError) {
        await store.notifyObservers()
      }
    } else if await collectionState.clearWarning() {
      await store.notifyObservers()
    }
  }
}

extension FieldDiagnosticSnapshot {
  fileprivate func withCollectionWarning(_ collectionWarning: String?) -> Self {
    Self(
      records: records,
      rejectedRecordCount: rejectedRecordCount,
      totalPayloadByteCount: totalPayloadByteCount,
      collectionWarning: collectionWarning
    )
  }
}
