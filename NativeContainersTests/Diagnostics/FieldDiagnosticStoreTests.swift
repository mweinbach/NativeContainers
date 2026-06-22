import Darwin
import Foundation
import Testing

@testable import NativeContainers

struct FieldDiagnosticStoreTests {
  @Test
  func storesDeduplicatesAndExportsPrivateMetricKitPayload() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let receivedAt = Date(timeIntervalSince1970: 3_000)
    let store = FieldDiagnosticStore(
      rootURL: root,
      now: { receivedAt }
    )
    let payload = fixturePayload(
      json: #"{"diagnostics":[{"kind":"crash"}]}"#,
      categories: FieldDiagnosticCategoryCounts(crashes: 1)
    )

    try await store.record(payload)
    try await store.record(payload)
    let snapshot = try await store.load()

    #expect(snapshot.records.count == 1)
    #expect(snapshot.rejectedRecordCount == 0)
    #expect(snapshot.totalPayloadByteCount == payload.json.count)
    let record = try #require(snapshot.records.first)
    #expect(record.receivedAt == receivedAt)
    #expect(record.categories.crashes == 1)

    let export = try await store.exportRecord(id: record.id)
    #expect(export.data == payload.json)
    #expect(export.fileName.hasSuffix(".json"))
    #expect(!export.fileName.contains(":"))

    #expect(permissions(at: root) == 0o700)
    let files = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    )
    let report = try #require(
      files.first { $0.lastPathComponent.hasSuffix(".field-diagnostic.json") }
    )
    #expect(permissions(at: report) == 0o600)
  }

  @Test
  func enforcesBoundedRecordRetention() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = FieldDiagnosticStore(rootURL: root)
    for index in 0..<(FieldDiagnosticStore.maximumRecordCount + 5) {
      try await store.record(
        fixturePayload(
          json: "{\"metric\":\(index)}",
          periodEnd: Date(timeIntervalSince1970: Double(index + 2))
        )
      )
    }

    let snapshot = try await store.load()

    #expect(snapshot.records.count == FieldDiagnosticStore.maximumRecordCount)
    #expect(snapshot.rejectedRecordCount == 0)
    #expect(
      snapshot.totalPayloadByteCount
        == snapshot.records.map(\.payloadByteCount).reduce(0, +)
    )
  }

  @Test
  func ignoresCorruptAndSymbolicLinkRecords() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = FieldDiagnosticStore(rootURL: root)
    _ = try await store.load()

    let corrupt = root.appending(path: "corrupt.field-diagnostic.json")
    try Data("not-json".utf8).write(to: corrupt)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: corrupt.path
    )

    let symbolicLink = root.appending(path: "link.field-diagnostic.json")
    try FileManager.default.createSymbolicLink(
      at: symbolicLink,
      withDestinationURL: URL(filePath: "/etc/hosts")
    )

    let snapshot = try await store.load()

    #expect(snapshot.records.isEmpty)
    #expect(snapshot.rejectedRecordCount == 2)
  }

  @Test
  func removalTouchesOnlyRecognizedPrivateReports() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = FieldDiagnosticStore(rootURL: root)
    try await store.record(fixturePayload(json: #"{"metric":1}"#))

    let unrelated = root.appending(path: "operator-note.txt")
    try Data("keep".utf8).write(to: unrelated)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: unrelated.path
    )

    try await store.removeAll()

    #expect((try await store.load()).records.isEmpty)
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
  }

  @Test
  func rejectsSymbolicLinkRootWithoutChangingItsTarget() async throws {
    let parent = FileManager.default.temporaryDirectory
      .appending(
        path: "NativeContainers-FieldDiagnosticRootTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    let target = parent.appending(path: "target", directoryHint: .isDirectory)
    let root = parent.appending(path: "root", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: parent) }

    try FileManager.default.createDirectory(
      at: target,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755]
    )
    #expect(Darwin.chmod(target.path, 0o755) == 0)
    let permissionsBefore = permissions(at: target)
    try FileManager.default.createSymbolicLink(
      at: root,
      withDestinationURL: target
    )
    let store = FieldDiagnosticStore(rootURL: root)

    await #expect(throws: FieldDiagnosticServiceError.unsafeStorage) {
      _ = try await store.load()
    }
    #expect(permissions(at: target) == permissionsBefore)
  }

  @Test
  func rejectsInvalidAndOversizedPayloads() async {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FieldDiagnosticStore(rootURL: root)

    await #expect(throws: FieldDiagnosticServiceError.invalidPayload) {
      try await store.record(fixturePayload(json: "not-json"))
    }

    let oversized = Data(
      repeating: 0x20,
      count: FieldDiagnosticStore.maximumPayloadBytes + 1
    )
    await #expect(throws: FieldDiagnosticServiceError.payloadTooLarge) {
      try await store.record(
        CapturedFieldDiagnosticPayload(
          kind: .dailyMetrics,
          periodStart: Date(timeIntervalSince1970: 1),
          periodEnd: Date(timeIntervalSince1970: 2),
          categories: .zero,
          json: oversized
        )
      )
    }
  }

  @Test
  func rejectsUnboundedStoredCategoryCounts() {
    let negative = Data(
      #"{"crashes":-1,"hangs":0,"cpuExceptions":0,"diskWriteExceptions":0}"#.utf8
    )
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(
        FieldDiagnosticCategoryCounts.self,
        from: negative
      )
    }

    let excessive = Data(
      #"{"crashes":1000001,"hangs":0,"cpuExceptions":0,"diskWriteExceptions":0}"#.utf8
    )
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(
        FieldDiagnosticCategoryCounts.self,
        from: excessive
      )
    }
  }

  private func fixturePayload(
    json: String,
    periodEnd: Date = Date(timeIntervalSince1970: 2),
    categories: FieldDiagnosticCategoryCounts = .zero
  ) -> CapturedFieldDiagnosticPayload {
    CapturedFieldDiagnosticPayload(
      kind: categories.total == 0 ? .dailyMetrics : .diagnostics,
      periodStart: Date(timeIntervalSince1970: 1),
      periodEnd: periodEnd,
      categories: categories,
      json: Data(json.utf8)
    )
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appending(
        path: "NativeContainers-FieldDiagnosticTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
  }

  private func permissions(at url: URL) -> mode_t? {
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0 else { return nil }
    return metadata.st_mode & 0o777
  }
}
