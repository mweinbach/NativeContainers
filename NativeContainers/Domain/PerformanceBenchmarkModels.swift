import Foundation

enum PerformanceBenchmarkKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case warmInventory
  case privateDiskIO
  case loopbackNetwork

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .warmInventory:
      "Warm inventory"
    case .privateDiskIO:
      "Private disk I/O"
    case .loopbackNetwork:
      "Loopback TCP"
    }
  }

  var explanation: LocalizedStringResource {
    switch self {
    case .warmInventory:
      "Loads the current Apple container inventory without changing resources."
    case .privateDiskIO:
      "Writes, synchronizes, and reads a temporary file in the app’s private workspace, then removes it."
    case .loopbackNetwork:
      "Transfers data through Network.framework over localhost without using an external network."
    }
  }
}

struct PerformanceBenchmarkSample: Equatable, Sendable {
  let durationNanoseconds: UInt64
  let processedByteCount: Int64?
}

struct PerformanceBenchmarkResult: Equatable, Identifiable, Sendable {
  let kind: PerformanceBenchmarkKind
  let samples: [PerformanceBenchmarkSample]

  var id: PerformanceBenchmarkKind { kind }

  var medianDurationNanoseconds: UInt64 {
    percentileDurationNanoseconds(0.5)
  }

  var p95DurationNanoseconds: UInt64 {
    percentileDurationNanoseconds(0.95)
  }

  var medianDurationMilliseconds: Double {
    Double(medianDurationNanoseconds) / 1_000_000
  }

  var p95DurationMilliseconds: Double {
    Double(p95DurationNanoseconds) / 1_000_000
  }

  var throughputMebibytesPerSecond: Double? {
    let byteCount = samples.compactMap(\.processedByteCount).reduce(0, +)
    var durationNanoseconds: UInt64 = 0
    for sample in samples {
      let addition = durationNanoseconds.addingReportingOverflow(
        sample.durationNanoseconds
      )
      guard !addition.overflow else { return nil }
      durationNanoseconds = addition.partialValue
    }
    guard byteCount > 0, durationNanoseconds > 0 else { return nil }

    let seconds = Double(durationNanoseconds) / 1_000_000_000
    return Double(byteCount) / 1_048_576 / seconds
  }

  private func percentileDurationNanoseconds(_ percentile: Double) -> UInt64 {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.map(\.durationNanoseconds).sorted()
    let rank = Int(ceil(percentile * Double(sorted.count)))
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
  }
}

enum PerformanceBenchmarkOutcome: Equatable, Identifiable, Sendable {
  case measured(PerformanceBenchmarkResult)
  case failed(kind: PerformanceBenchmarkKind, message: String)

  var id: PerformanceBenchmarkKind {
    switch self {
    case .measured(let result):
      result.kind
    case .failed(let kind, _):
      kind
    }
  }

  var kind: PerformanceBenchmarkKind { id }
}

struct PerformanceBenchmarkReport: Equatable, Sendable {
  let generatedAt: Date
  let outcomes: [PerformanceBenchmarkOutcome]
}

typealias PerformanceBenchmarkProgressHandler =
  @MainActor @Sendable (PerformanceBenchmarkKind?) -> Void

protocol PerformanceBenchmarking: Sendable {
  func run(
    progress: @escaping PerformanceBenchmarkProgressHandler
  ) async throws -> PerformanceBenchmarkReport
}

struct UnavailablePerformanceBenchmarkService: PerformanceBenchmarking {
  func run(
    progress: @escaping PerformanceBenchmarkProgressHandler
  ) async throws -> PerformanceBenchmarkReport {
    await progress(nil)
    return PerformanceBenchmarkReport(
      generatedAt: Date(),
      outcomes: PerformanceBenchmarkKind.allCases.map {
        .failed(
          kind: $0,
          message: "Performance benchmarks are unavailable in this app context."
        )
      }
    )
  }
}
