import Foundation

enum ComposeBridgeConformanceStatus: String, CaseIterable, Equatable, Sendable {
  case supported
  case partial
  case unsupported
  case upstreamBlocked
  case policyBlocked
}

struct ComposeBridgeConformanceResult: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let status: ComposeBridgeConformanceStatus
  let summary: String
  let evidence: String
  let missingOperations: [String]
}

struct ComposeBridgeConformanceReport: Equatable, Sendable {
  let bridgeVersion: String
  let engineAPIVersion: String
  let sourceRevision: String
  let results: [ComposeBridgeConformanceResult]

  var supportedCount: Int {
    results.count(where: { $0.status == .supported })
  }

  var gapCount: Int {
    results.count - supportedCount
  }

  var projectLifecycleIsEligible: Bool {
    guard let status = results.first(where: { $0.id == "compose-project-lifecycle" })?.status
    else { return false }
    return status == .supported || status == .partial
  }
}
