import SwiftUI
import UniformTypeIdentifiers

struct FieldDiagnosticSettingsSection: View {
  let model: FieldDiagnosticModel

  @State private var exportDocument: FieldDiagnosticDocument?
  @State private var exportFileName = "NativeContainers-MetricKit.json"
  @State private var showsExporter = false
  @State private var confirmsRemoval = false
  @State private var exportErrorMessage: String?

  var body: some View {
    Section("Field diagnostics") {
      Text(
        "MetricKit reports stay in a private, backup-excluded store on this Mac. NativeContainers never uploads them automatically."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if model.snapshot.records.isEmpty {
        LabeledContent("Stored reports", value: "None")
        Text(
          "macOS delivers diagnostics when they become available and daily metrics at most once per day."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        LabeledContent("Stored payloads") {
          Text(model.snapshot.records.count, format: .number)
        }
        LabeledContent("Reported diagnostics") {
          Text(model.snapshot.diagnosticCount, format: .number)
        }
        LabeledContent("Private storage") {
          Text(
            Int64(model.snapshot.totalPayloadByteCount),
            format: .byteCount(style: .file)
          )
        }

        ForEach(model.snapshot.records.prefix(5)) { record in
          FieldDiagnosticRecordRow(
            record: record,
            isExportDisabled: model.isBusy,
            onExport: { prepareExport(record.id) }
          )
        }

        if model.snapshot.records.count > 5 {
          Text(
            "\(model.snapshot.records.count - 5) older payloads remain in bounded private storage."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      if model.snapshot.rejectedRecordCount > 0 {
        Label(
          "\(model.snapshot.rejectedRecordCount) unsafe or unreadable stored reports were ignored.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }

      if let warning = model.snapshot.collectionWarning {
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }

      HStack {
        Button("Refresh Reports", systemImage: "arrow.clockwise") {
          Task { await model.refresh() }
        }
        .disabled(model.isBusy)

        if !model.snapshot.records.isEmpty {
          Button("Delete Stored Reports", role: .destructive) {
            confirmsRemoval = true
          }
          .disabled(model.isBusy)
        }

        if model.isBusy {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Updating field diagnostics")
        }
      }

      if let errorMessage = model.errorMessage ?? exportErrorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    }
    .task {
      model.start()
    }
    .alert(
      "Delete Stored Reports?",
      isPresented: $confirmsRemoval
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        Task { await model.removeAll() }
      }
    } message: {
      Text(
        "This removes NativeContainers’ private MetricKit copies. It does not change reports already held by macOS or Xcode Organizer."
      )
    }
    .fileExporter(
      isPresented: $showsExporter,
      document: exportDocument,
      contentType: .json,
      defaultFilename: exportFileName
    ) { result in
      exportDocument = nil
      if case .failure(let error) = result {
        exportErrorMessage = error.localizedDescription
      }
    }
  }

  private func prepareExport(_ id: String) {
    Task {
      guard let export = await model.prepareExport(id: id) else { return }
      exportDocument = FieldDiagnosticDocument(data: export.data)
      exportFileName = export.fileName
      exportErrorMessage = nil
      showsExporter = true
    }
  }
}

private struct FieldDiagnosticRecordRow: View {
  let record: FieldDiagnosticRecord
  let isExportDisabled: Bool
  let onExport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Label(record.kind.title, systemImage: record.kind.systemImage)
          .font(.headline)
        Spacer()
        Button("Export JSON", action: onExport)
          .controlSize(.small)
          .disabled(isExportDisabled)
      }

      Text(
        "Period ended \(record.periodEnd, format: .dateTime.year().month().day().hour().minute())"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if record.kind == .diagnostics {
        Text(record.categories.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(Int64(record.payloadByteCount), format: .byteCount(style: .file))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 3)
  }
}

private struct FieldDiagnosticDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.json]

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

extension FieldDiagnosticPayloadKind {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .dailyMetrics:
      "Daily metrics"
    case .diagnostics:
      "Diagnostic report"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .dailyMetrics:
      "chart.xyaxis.line"
    case .diagnostics:
      "waveform.path.ecg"
    }
  }
}

extension FieldDiagnosticCategoryCounts {
  fileprivate var summary: String {
    var values: [String] = []
    if crashes > 0 {
      values.append(String(localized: "\(crashes) crashes"))
    }
    if hangs > 0 {
      values.append(String(localized: "\(hangs) hangs"))
    }
    if cpuExceptions > 0 {
      values.append(String(localized: "\(cpuExceptions) CPU exceptions"))
    }
    if diskWriteExceptions > 0 {
      values.append(
        String(localized: "\(diskWriteExceptions) disk-write exceptions")
      )
    }

    return values.isEmpty
      ? String(localized: "No categorized crash, hang, CPU, or disk-write events")
      : values.formatted(.list(type: .and, width: .short))
  }
}

#Preview("Field Diagnostics") {
  Form {
    FieldDiagnosticSettingsSection(
      model: FieldDiagnosticModel(
        service: PreviewFieldDiagnosticService(
          snapshot: FieldDiagnosticSnapshot(
            records: [
              FieldDiagnosticRecord(
                id: String(repeating: "a", count: 64),
                kind: .diagnostics,
                periodStart: Date().addingTimeInterval(-3_600),
                periodEnd: Date(),
                receivedAt: Date(),
                categories: FieldDiagnosticCategoryCounts(
                  crashes: 1,
                  hangs: 2
                ),
                payloadByteCount: 24_576
              ),
              FieldDiagnosticRecord(
                id: String(repeating: "b", count: 64),
                kind: .dailyMetrics,
                periodStart: Date().addingTimeInterval(-86_400),
                periodEnd: Date(),
                receivedAt: Date(),
                categories: .zero,
                payloadByteCount: 8_192
              ),
            ],
            rejectedRecordCount: 0,
            totalPayloadByteCount: 32_768
          )
        ),
        initialSnapshot: FieldDiagnosticSnapshot(
          records: [
            FieldDiagnosticRecord(
              id: String(repeating: "a", count: 64),
              kind: .diagnostics,
              periodStart: Date().addingTimeInterval(-3_600),
              periodEnd: Date(),
              receivedAt: Date(),
              categories: FieldDiagnosticCategoryCounts(crashes: 1, hangs: 2),
              payloadByteCount: 24_576
            )
          ],
          rejectedRecordCount: 0,
          totalPayloadByteCount: 24_576
        )
      )
    )
  }
  .formStyle(.grouped)
  .frame(width: 680, height: 760)
}

private struct PreviewFieldDiagnosticService: FieldDiagnosticManaging {
  let snapshot: FieldDiagnosticSnapshot

  func start() {}

  func load() async throws -> FieldDiagnosticSnapshot {
    snapshot
  }

  func exportRecord(id: String) async throws -> FieldDiagnosticExport {
    FieldDiagnosticExport(fileName: "MetricKit.json", data: Data("{}".utf8))
  }

  func removeAll() async throws {}

  func updates() async -> AsyncStream<Void> {
    AsyncStream { _ in }
  }
}
