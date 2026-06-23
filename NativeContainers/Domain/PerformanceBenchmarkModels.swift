import Foundation

enum PerformanceBenchmarkKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case warmInventory
  case privateDiskIO
  case loopbackNetwork
  case coldContainerStartup
  case warmContainerStartup
  case guestRootFileIO
  case bindMountFileIO
  case bindMountMetadata
  case imageBuild
  case imagePullAndDiskGrowth
  case coldLinuxMachineStartup
  case coldMacVirtualMachineStartup
  case externalNetworkTransfer
  case idleContainerResources
  case idleContainerDensity10
  case idleContainerDensity50
  case postStressRetainedMemory
  case postgreSQLDurability
  case natDirectNetworkComparison

  static let settingsSuiteCases: [Self] = [
    .warmInventory,
    .privateDiskIO,
    .loopbackNetwork,
  ]

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .warmInventory:
      "Warm inventory"
    case .privateDiskIO:
      "Private disk I/O"
    case .loopbackNetwork:
      "Loopback TCP"
    case .coldContainerStartup:
      "Cold container startup"
    case .warmContainerStartup:
      "Warm container startup"
    case .guestRootFileIO:
      "Guest root filesystem I/O"
    case .bindMountFileIO:
      "VirtioFS bind-mount I/O"
    case .bindMountMetadata:
      "VirtioFS bind-mount metadata"
    case .imageBuild:
      "No-cache OCI image build"
    case .imagePullAndDiskGrowth:
      "Image pull and allocated disk growth"
    case .coldLinuxMachineStartup:
      "Cold Linux machine startup"
    case .coldMacVirtualMachineStartup:
      "Cold macOS virtual machine startup"
    case .externalNetworkTransfer:
      "External HTTPS transfer"
    case .idleContainerResources:
      "Idle container resources"
    case .idleContainerDensity10:
      "10-container idle memory"
    case .idleContainerDensity50:
      "50-container idle memory"
    case .postStressRetainedMemory:
      "Post-stress retained memory"
    case .postgreSQLDurability:
      "PostgreSQL durability and fsync"
    case .natDirectNetworkComparison:
      "NAT and direct-IP networking"
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
    case .coldContainerStartup:
      "Starts a newly created stopped Apple container and confirms its authoritative running state."
    case .warmContainerStartup:
      "Restarts a previously started and cleanly stopped Apple container and confirms its authoritative running state."
    case .guestRootFileIO:
      "Writes, synchronizes, and reads a fixed file inside a running container’s writable root filesystem."
    case .bindMountFileIO:
      "Writes, synchronizes, and reads a fixed file through a reviewed writable host-folder mount."
    case .bindMountMetadata:
      "Runs a fixed create, stat, chmod, rename, unlink, and directory metadata workload through a reviewed writable host-folder mount."
    case .imageBuild:
      "Builds a fixed local context without cache or registry refresh and exports a reviewed OCI archive."
    case .imagePullAndDiskGrowth:
      "Pulls a reviewed absent image reference, records runtime-allocated disk growth, and removes the exact pulled reference."
    case .coldLinuxMachineStartup:
      "Starts a newly created stopped Apple Linux machine through first-user provisioning and confirmed readiness."
    case .coldMacVirtualMachineStartup:
      "Starts a disposable clone of an installed macOS virtual machine and confirms running console readiness."
    case .externalNetworkTransfer:
      "Downloads and verifies a fixed HTTPS payload through a fresh Apple container."
    case .idleContainerResources:
      "Samples authoritative CPU, memory, I/O, network, and process counters for an idle container."
    case .idleContainerDensity10:
      "Samples authoritative resident-memory counters across exactly 10 concurrently idle containers."
    case .idleContainerDensity50:
      "Samples authoritative resident-memory counters across exactly 50 concurrently idle containers."
    case .postStressRetainedMemory:
      "Measures memory before, during, and after a bounded guest-memory workload, then confirms an identity-pinned stop."
    case .postgreSQLDurability:
      "Runs a fixed transactional PostgreSQL workload with fsync and synchronous_commit enabled, followed by CHECKPOINT."
    case .natDirectNetworkComparison:
      "Measures the same fixed container payload over its published host port and dedicated direct IP."
    }
  }
}

enum PerformanceBenchmarkContractCoverage: String, CaseIterable, Sendable {
  case complete
  case partial
  case missing
}

enum PerformanceBenchmarkContractRequirement: String, CaseIterable, Identifiable, Sendable {
  case containerStartup
  case idleContainerMemory
  case postStressMemory
  case bindMountIO
  case postgreSQLDurability
  case imagePullBuildAndDisk
  case containerNetworking
  case recovery

  var id: Self { self }

  var coverage: PerformanceBenchmarkContractCoverage {
    switch self {
    case .containerStartup, .idleContainerMemory, .postStressMemory, .bindMountIO,
      .postgreSQLDurability, .imagePullBuildAndDisk, .containerNetworking:
      .complete
    case .recovery:
      .missing
    }
  }

  var title: LocalizedStringResource {
    switch self {
    case .containerStartup:
      "Cold and warm container startup"
    case .idleContainerMemory:
      "1, 10, and 50 idle-container memory"
    case .postStressMemory:
      "Post-stress retained memory"
    case .bindMountIO:
      "Bind-mount metadata and sequential I/O"
    case .postgreSQLDurability:
      "PostgreSQL durability and fsync"
    case .imagePullBuildAndDisk:
      "Image pull, build, and disk growth"
    case .containerNetworking:
      "NAT and direct-IP networking"
    case .recovery:
      "Sleep, wake, and crash recovery"
    }
  }

  var gap: LocalizedStringResource {
    switch self {
    case .containerStartup:
      "Cold creation and warm restart are measured separately with authoritative state confirmation."
    case .idleContainerMemory:
      "Runtime-reported resident memory is sampled at exactly 1, 10, and 50 concurrently idle containers."
    case .postStressMemory:
      "A bounded guest-memory workload records baseline, stressed, and post-idle retained memory before a confirmed stop."
    case .bindMountIO:
      "Reviewed VirtioFS lanes cover sequential write/fsync/read and fixed metadata operations."
    case .postgreSQLDurability:
      "A digest-pinned PostgreSQL lane verifies fsync and synchronous commit before transactional writes and CHECKPOINT."
    case .imagePullBuildAndDisk:
      "Separate lanes measure reviewed image pull, no-cache build, and runtime-reported allocated disk growth."
    case .containerNetworking:
      "The same verified payload is compared over a published host port and the container’s dedicated direct IP."
    case .recovery:
      "No benchmark covers host sleep/wake or process and runtime crash recovery."
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
      outcomes: PerformanceBenchmarkKind.settingsSuiteCases.map {
        .failed(
          kind: $0,
          message: "Performance benchmarks are unavailable in this app context."
        )
      }
    )
  }
}
