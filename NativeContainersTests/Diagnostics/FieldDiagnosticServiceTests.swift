import Foundation
import Testing

@testable import NativeContainers

struct FieldDiagnosticServiceTests {
  @Test
  func startsSourceOnceAndPersistsInitialAndDeliveredPayloads() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let initial = fixturePayload(
      json: #"{"metrics":{"cpu":1}}"#,
      kind: .dailyMetrics
    )
    let source = ScriptedFieldDiagnosticSource(initial: [initial])
    let service = MetricKitFieldDiagnosticService(
      source: source,
      store: FieldDiagnosticStore(rootURL: root)
    )

    service.start()
    service.start()
    var snapshot = try await waitForRecordCount(1, service: service)

    #expect(source.startCount == 1)
    #expect(snapshot.metricPayloadCount == 1)

    source.emit(
      [
        fixturePayload(
          json: #"{"diagnostics":{"hangs":1}}"#,
          kind: .diagnostics,
          categories: FieldDiagnosticCategoryCounts(hangs: 1)
        )
      ]
    )
    snapshot = try await waitForRecordCount(2, service: service)

    #expect(snapshot.diagnosticCount == 1)
    #expect(snapshot.collectionWarning == nil)
  }

  @Test
  func exposesCollectionFailureWithoutDiscardingValidHistory() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let source = ScriptedFieldDiagnosticSource(
      initial: [
        fixturePayload(
          json: #"{"diagnostics":{"crashes":1}}"#,
          kind: .diagnostics,
          categories: FieldDiagnosticCategoryCounts(crashes: 1)
        )
      ]
    )
    let service = MetricKitFieldDiagnosticService(
      source: source,
      store: FieldDiagnosticStore(rootURL: root)
    )
    service.start()
    _ = try await waitForRecordCount(1, service: service)

    source.emit(
      [
        CapturedFieldDiagnosticPayload(
          kind: .dailyMetrics,
          periodStart: Date(timeIntervalSince1970: 1),
          periodEnd: Date(timeIntervalSince1970: 2),
          categories: .zero,
          json: Data("invalid".utf8)
        )
      ]
    )

    let snapshot = try await waitForWarning(service: service)

    #expect(snapshot.records.count == 1)
    #expect(snapshot.diagnosticCount == 1)
    #expect(snapshot.collectionWarning != nil)

    source.emit(
      [
        fixturePayload(
          json: #"{"metrics":{"recovered":true}}"#,
          kind: .dailyMetrics
        )
      ]
    )
    let recovered = try await waitForRecordCount(
      2,
      service: service,
      requiresClearedWarning: true
    )
    #expect(recovered.collectionWarning == nil)

    try await service.removeAll()
    let cleared = try await service.load()
    #expect(cleared.records.isEmpty)
    #expect(cleared.collectionWarning == nil)
  }

  @MainActor
  @Test
  func observableModelRefreshesFromStoreUpdatesAndExports() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let source = ScriptedFieldDiagnosticSource(initial: [])
    let service = MetricKitFieldDiagnosticService(
      source: source,
      store: FieldDiagnosticStore(rootURL: root)
    )
    let model = FieldDiagnosticModel(service: service)

    model.start()
    source.emit(
      [
        fixturePayload(
          json: #"{"diagnostics":{"diskWrites":1}}"#,
          kind: .diagnostics,
          categories: FieldDiagnosticCategoryCounts(
            diskWriteExceptions: 1
          )
        )
      ]
    )

    for _ in 0..<100 where model.snapshot.records.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    let record = try #require(model.snapshot.records.first)
    #expect(model.snapshot.diagnosticCount == 1)

    let exported = await model.prepareExport(id: record.id)
    #expect(exported?.data == Data(#"{"diagnostics":{"diskWrites":1}}"#.utf8))

    await model.removeAll()
    #expect(model.snapshot.records.isEmpty)
  }

  private func waitForRecordCount(
    _ count: Int,
    service: any FieldDiagnosticManaging,
    requiresClearedWarning: Bool = false
  ) async throws -> FieldDiagnosticSnapshot {
    for _ in 0..<100 {
      let snapshot = try await service.load()
      if snapshot.records.count == count,
        !requiresClearedWarning || snapshot.collectionWarning == nil
      {
        return snapshot
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(count) field diagnostic records.")
    return try await service.load()
  }

  private func waitForWarning(
    service: any FieldDiagnosticManaging
  ) async throws -> FieldDiagnosticSnapshot {
    for _ in 0..<100 {
      let snapshot = try await service.load()
      if snapshot.collectionWarning != nil {
        return snapshot
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for a field diagnostic collection warning.")
    return try await service.load()
  }

  private func fixturePayload(
    json: String,
    kind: FieldDiagnosticPayloadKind,
    categories: FieldDiagnosticCategoryCounts = .zero
  ) -> CapturedFieldDiagnosticPayload {
    CapturedFieldDiagnosticPayload(
      kind: kind,
      periodStart: Date(timeIntervalSince1970: 1),
      periodEnd: Date(timeIntervalSince1970: 2),
      categories: categories,
      json: Data(json.utf8)
    )
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appending(
        path: "NativeContainers-FieldDiagnosticServiceTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
  }
}

private final class ScriptedFieldDiagnosticSource:
  FieldDiagnosticPayloadSource,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let initial: [CapturedFieldDiagnosticPayload]
  private var handler: FieldDiagnosticPayloadHandler?
  private var starts = 0
  private var stops = 0

  init(initial: [CapturedFieldDiagnosticPayload]) {
    self.initial = initial
  }

  var startCount: Int {
    lock.withLock { starts }
  }

  func start(handler: @escaping FieldDiagnosticPayloadHandler) {
    lock.withLock {
      starts += 1
      self.handler = handler
    }
    handler(initial)
  }

  func stop() {
    lock.withLock {
      stops += 1
      handler = nil
    }
  }

  func emit(_ payloads: [CapturedFieldDiagnosticPayload]) {
    let current = lock.withLock { handler }
    current?(payloads)
  }
}
