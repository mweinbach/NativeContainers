import SwiftUI

struct PerformanceBenchmarkSettingsSection: View {
  let model: PerformanceBenchmarkModel

  var body: some View {
    Section("Performance baselines") {
      Text(
        "Runs read-only Apple inventory checks plus temporary private-disk and localhost TCP workloads. It does not create, start, stop, or build containers."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if let report = model.report {
        LabeledContent("Measured") {
          Text(report.generatedAt, format: .dateTime.hour().minute().second())
        }

        ForEach(report.outcomes) { outcome in
          PerformanceBenchmarkOutcomeRow(outcome: outcome)
        }
      } else {
        ContentUnavailableView(
          "No baseline yet",
          systemImage: "gauge",
          description: Text("Run the bounded local suite to capture this session’s baseline.")
        )
      }

      if let currentKind = model.currentKind {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(currentKind.title)
          Spacer()
          Button("Cancel", role: .cancel) {
            model.cancel()
          }
        }
      } else {
        Button("Run local benchmarks", systemImage: "gauge") {
          model.start()
        }
        .disabled(model.isRunning)
      }

      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      Text(
        "Cold launch, real image builds, guest I/O, and external-network throughput remain separate opt-in benchmark lanes because they can mutate runtime state or depend on the host environment."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      LabeledContent("Product contract") {
        Text(contractCoverageSummary)
          .textSelection(.enabled)
      }

      DisclosureGroup("Coverage against the feature contract") {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(PerformanceBenchmarkContractRequirement.allCases) { requirement in
            VStack(alignment: .leading, spacing: 4) {
              HStack(alignment: .firstTextBaseline) {
                Text(requirement.title)
                  .fontWeight(.medium)
                Spacer()
                Label(
                  coverageTitle(requirement.coverage),
                  systemImage: coverageSymbol(requirement.coverage)
                )
                .font(.caption)
                .foregroundStyle(coverageColor(requirement.coverage))
              }
              Text(requirement.gap)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.top, 8)
      }
    }
  }

  private var contractCoverageSummary: String {
    let requirements = PerformanceBenchmarkContractRequirement.allCases
    let complete = requirements.count(where: { $0.coverage == .complete })
    let partial = requirements.count(where: { $0.coverage == .partial })
    let missing = requirements.count(where: { $0.coverage == .missing })
    return "\(complete) complete · \(partial) partial · \(missing) missing"
  }

  private func coverageTitle(_ coverage: PerformanceBenchmarkContractCoverage) -> String {
    switch coverage {
    case .complete: "Complete"
    case .partial: "Partial"
    case .missing: "Missing"
    }
  }

  private func coverageSymbol(_ coverage: PerformanceBenchmarkContractCoverage) -> String {
    switch coverage {
    case .complete: "checkmark.circle.fill"
    case .partial: "exclamationmark.circle.fill"
    case .missing: "xmark.circle.fill"
    }
  }

  private func coverageColor(_ coverage: PerformanceBenchmarkContractCoverage) -> Color {
    switch coverage {
    case .complete: .green
    case .partial: .orange
    case .missing: .red
    }
  }
}

private struct PerformanceBenchmarkOutcomeRow: View {
  let outcome: PerformanceBenchmarkOutcome

  var body: some View {
    switch outcome {
    case .measured(let result):
      VStack(alignment: .leading, spacing: 5) {
        Text(result.kind.title)
          .font(.headline)
        Text(result.kind.explanation)
          .font(.caption)
          .foregroundStyle(.secondary)

        ViewThatFits {
          HStack(spacing: 12) {
            measurementSummary(result)
          }
          VStack(alignment: .leading, spacing: 2) {
            measurementSummary(result)
          }
        }
        .font(.caption.monospacedDigit())
      }

    case .failed(let kind, let message):
      VStack(alignment: .leading, spacing: 4) {
        Label(kind.title, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  @ViewBuilder
  private func measurementSummary(_ result: PerformanceBenchmarkResult) -> some View {
    Text(
      "Median \(result.medianDurationMilliseconds, format: .number.precision(.fractionLength(1))) ms"
    )
    Text(
      "P95 \(result.p95DurationMilliseconds, format: .number.precision(.fractionLength(1))) ms"
    )
    if let throughput = result.throughputMebibytesPerSecond {
      Text(
        "\(throughput, format: .number.precision(.fractionLength(1))) MiB/s"
      )
    }
  }
}

#Preview("Performance Baselines") {
  Form {
    PerformanceBenchmarkSettingsSection(
      model: PerformanceBenchmarkModel(
        service: UnavailablePerformanceBenchmarkService(),
        initialReport: PerformanceBenchmarkReport(
          generatedAt: Date(),
          outcomes: [
            .measured(
              PerformanceBenchmarkResult(
                kind: .warmInventory,
                samples: [
                  PerformanceBenchmarkSample(
                    durationNanoseconds: 38_000_000,
                    processedByteCount: nil
                  ),
                  PerformanceBenchmarkSample(
                    durationNanoseconds: 42_000_000,
                    processedByteCount: nil
                  ),
                  PerformanceBenchmarkSample(
                    durationNanoseconds: 47_000_000,
                    processedByteCount: nil
                  ),
                ]
              )
            ),
            .measured(
              PerformanceBenchmarkResult(
                kind: .privateDiskIO,
                samples: [
                  PerformanceBenchmarkSample(
                    durationNanoseconds: 70_000_000,
                    processedByteCount: 32 * 1_048_576
                  ),
                  PerformanceBenchmarkSample(
                    durationNanoseconds: 75_000_000,
                    processedByteCount: 32 * 1_048_576
                  ),
                  PerformanceBenchmarkSample(
                    durationNanoseconds: 80_000_000,
                    processedByteCount: 32 * 1_048_576
                  ),
                ]
              )
            ),
            .failed(
              kind: .loopbackNetwork,
              message: "The local Network.framework TCP connection failed."
            ),
          ]
        )
      )
    )
  }
  .formStyle(.grouped)
  .frame(width: 680, height: 800)
}
