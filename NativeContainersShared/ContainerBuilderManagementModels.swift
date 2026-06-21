import Foundation

enum ContainerBuilderManagementAction: String, Codable, Equatable, Sendable {
  case stop
  case forceStop
  case deleteBuilderAndCache
}

struct ContainerBuilderRecord: Codable, Equatable, Sendable, Identifiable {
  static let containerID = "buildkit"

  let state: ContainerBuilderRuntimeState
  let createdAt: Date?
  let imageReference: String?
  let imageDigest: String?
  let cpuCount: Int?
  let memoryBytes: UInt64?
  let allocatedBytes: UInt64?
  let identityMismatches: [ContainerBuilderIdentityMismatch]
  let bundlePresent: Bool

  var id: String { Self.containerID }
  var isPresent: Bool { state != .absent }
  var isTrustedBuilder: Bool {
    isPresent && bundlePresent && identityMismatches.isEmpty
  }
  var hasOrphanedBundle: Bool {
    state == .absent && bundlePresent
  }

  static func absent(bundlePresent: Bool) -> ContainerBuilderRecord {
    ContainerBuilderRecord(
      state: .absent,
      createdAt: nil,
      imageReference: nil,
      imageDigest: nil,
      cpuCount: nil,
      memoryBytes: nil,
      allocatedBytes: nil,
      identityMismatches: [],
      bundlePresent: bundlePresent
    )
  }
}

struct ContainerBuilderInspection: Codable, Equatable, Sendable {
  let builder: ContainerBuilderRecord
  let reviewedSnapshot: ContainerBuilderReviewedSnapshot?
  let runtimeApplicationRoot: String
}

struct ContainerBuilderManagementPlan: Codable, Equatable, Sendable, Identifiable {
  let id: UUID
  let action: ContainerBuilderManagementAction
  let builder: ContainerBuilderRecord
  let reviewedSnapshot: ContainerBuilderReviewedSnapshot
  let runtimeApplicationRoot: String
  let generatedAt: Date

  init(
    id: UUID = UUID(),
    action: ContainerBuilderManagementAction,
    inspection: ContainerBuilderInspection,
    generatedAt: Date = Date()
  ) throws {
    guard
      inspection.builder.isTrustedBuilder,
      let reviewedSnapshot = inspection.reviewedSnapshot
    else {
      throw ContainerBuilderManagementError.untrustedBuilder
    }

    switch action {
    case .stop, .forceStop:
      guard inspection.builder.state == .running else {
        throw ContainerBuilderManagementError.builderNotRunning
      }
    case .deleteBuilderAndCache:
      guard inspection.builder.state == .stopped else {
        throw ContainerBuilderManagementError.builderNotStopped
      }
    }

    self.id = id
    self.action = action
    self.builder = inspection.builder
    self.reviewedSnapshot = reviewedSnapshot
    self.runtimeApplicationRoot = inspection.runtimeApplicationRoot
    self.generatedAt = generatedAt
  }
}

struct ContainerBuilderManagementAuthorization: Codable, Equatable, Sendable {
  let allowsInterruptRunningBuilder: Bool

  static let none = ContainerBuilderManagementAuthorization(
    allowsInterruptRunningBuilder: false
  )
}

struct ContainerBuilderManagementResult: Equatable, Sendable {
  let action: ContainerBuilderManagementAction
  let inspection: ContainerBuilderInspection
}

enum ContainerBuilderManagementError: LocalizedError, Equatable, Sendable {
  case builderAbsent
  case orphanedBundle
  case untrustedBuilder
  case builderNotRunning
  case builderNotStopped
  case interruptionRequiresConfirmation
  case staleReview
  case stopFailed
  case deleteFailed
  case incompleteBundleCleanup
  case builderStateUnavailable
  case runtimeUnavailable(String)
  case reconciliationFailed(String)
  case malformedWorkerReply
  case unsupported

  var errorDescription: String? {
    switch self {
    case .builderAbsent:
      "Apple’s shared BuildKit container does not exist."
    case .orphanedBundle:
      "Apple’s service no longer lists the builder, but its bundle remains on disk. NativeContainers will not remove it or recreate the builder automatically."
    case .untrustedBuilder:
      "The container named “buildkit” does not exactly match Apple’s pinned builder identity. NativeContainers will not manage it."
    case .builderNotRunning:
      "The shared builder is not running."
    case .builderNotStopped:
      "Stop the shared builder before deleting it and its cache."
    case .interruptionRequiresConfirmation:
      "Stopping the shared builder can interrupt an external container CLI build and requires explicit confirmation."
    case .staleReview:
      "The shared builder changed after review. Refresh and review the action again."
    case .stopFailed:
      "The shared builder did not stop after Apple’s five-second TERM-to-KILL window."
    case .deleteFailed:
      "Apple’s service did not delete the reviewed stopped builder."
    case .incompleteBundleCleanup:
      "Apple’s service removed the builder from inventory but left its bundle on disk. Cache cleanup is incomplete and requires manual repair."
    case .builderStateUnavailable:
      "The shared builder is stopping or in an unknown state. Wait for a stable state before retrying."
    case .runtimeUnavailable(let message):
      "Builder management could not read Apple’s runtime configuration: \(message)"
    case .reconciliationFailed(let message):
      "The builder action could not be reconciled safely: \(message)"
    case .malformedWorkerReply:
      "The native build worker returned an invalid builder-management result."
    case .unsupported:
      "Shared builder management is unavailable from this service."
    }
  }
}
