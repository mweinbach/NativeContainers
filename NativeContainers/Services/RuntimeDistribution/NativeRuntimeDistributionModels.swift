import Foundation

enum NativeRuntimeOrigin: String, CaseIterable, Codable, Sendable {
  case appleOfficial
  case nativeContainers
}

enum NativeRuntimeArtifactRole: Equatable, Sendable {
  case executable(signingIdentifier: String)
  case launchService(
    label: String,
    domain: String,
    signingIdentifier: String
  )
  case data
  case builderArtifactMetadata
}

struct NativeRuntimeBuilderArtifactContract: Codable, Equatable, Sendable {
  static let pinned = NativeRuntimeBuilderArtifactContract(
    shimVersion: "0.12.0-nc.2",
    sourceRevision: "f66f1680fe6b74d814fb5527247e7d81227fcecb",
    imageDigest: "sha256:b3574dc6b867fc91d1ed1d2941c74811961e2645ffa4c1fc68c19ae69e5fdbff"
  )

  let shimVersion: String
  let sourceRevision: String
  let imageDigest: String

  private enum CodingKeys: String, CodingKey {
    case shimVersion = "builderShimVersion"
    case sourceRevision = "builderShimSourceRevision"
    case imageDigest = "builderImageDigest"
  }
}

struct NativeRuntimePackageArtifact: Equatable, Sendable {
  let relativePath: String
  let sha256: String
  let maximumByteCount: Int64
  let role: NativeRuntimeArtifactRole

}

struct NativeRuntimeDistributionManifest: Equatable, Sendable {
  static let nativeContainersTeamIdentifier = "6UHAW5UAT4"

  let origin: NativeRuntimeOrigin
  let packageIdentifier: String
  let packageVersion: String
  let installRootURL: URL
  let teamIdentifier: String
  let builderArtifact: NativeRuntimeBuilderArtifactContract?
  let artifacts: [NativeRuntimePackageArtifact]

  var launchServices: [NativeRuntimeLaunchServiceContract] {
    artifacts.compactMap { artifact in
      guard
        case .launchService(let label, let domain, _) = artifact.role
      else {
        return nil
      }
      return NativeRuntimeLaunchServiceContract(
        label: label,
        domain: domain,
        executableURL: installRootURL.appending(
          path: artifact.relativePath,
          directoryHint: .notDirectory
        )
      )
    }
  }
}

struct NativeRuntimeLaunchServiceContract: Equatable, Hashable, Sendable {
  let label: String
  let domain: String
  let executableURL: URL
}

struct NativeRuntimePackageReceipt: Equatable, Sendable {
  let packageIdentifier: String
  let version: String
}

struct NativeRuntimeArtifactObservation: Equatable, Sendable {
  let sha256: String
  let byteCount: Int64
  let device: UInt64
  let inode: UInt64
}

struct NativeRuntimeVerifiedDistribution: Equatable, Sendable {
  let origin: NativeRuntimeOrigin
  let packageIdentifier: String
  let version: String
  let installRootURL: URL
  let builderArtifact: NativeRuntimeBuilderArtifactContract?
  let serviceExecutablePaths: [String: URL]
}

struct NativeRuntimeLaunchServiceObservation: Equatable, Hashable, Sendable {
  let label: String
  let domain: String
  let executableURL: URL
}

struct NativeRuntimeLaunchGraphContract: Equatable, Sendable {
  let services: [NativeRuntimeLaunchServiceContract]
  let requiredServiceKeys: Set<String>

  init(
    services: [NativeRuntimeLaunchServiceContract],
    requiredServices: [NativeRuntimeLaunchServiceContract]
  ) {
    self.services = services
    requiredServiceKeys = Set(requiredServices.map(Self.key))
  }

  static func key(_ service: NativeRuntimeLaunchServiceContract) -> String {
    "\(service.domain)/\(service.label)"
  }
}

enum NativeRuntimeLaunchGraphState: Equatable, Sendable {
  case inactive
  case active(NativeRuntimeOrigin)
}

struct NativeRuntimeControlCommand: Equatable, Sendable {
  let executableURL: URL
  let startArguments: [String]
  let stopArguments: [String]
  let timeout: Duration

  init(
    executableURL: URL,
    startArguments: [String],
    stopArguments: [String],
    timeout: Duration = .seconds(30 * 60)
  ) {
    self.executableURL = executableURL
    self.startArguments = startArguments
    self.stopArguments = stopArguments
    self.timeout = timeout
  }
}

enum NativeRuntimePersistentDataCategory: String, CaseIterable, Codable, Sendable {
  case imagesAndContent
  case volumes
  case networks
  case kernels
  case configuration
  case machines
}

struct NativeRuntimeMigrationSelection: Equatable, Sendable {
  let category: NativeRuntimePersistentDataCategory
  let sourceRelativePath: String
  let destinationRelativePath: String
  let isRequired: Bool

  init(
    category: NativeRuntimePersistentDataCategory,
    sourceRelativePath: String,
    destinationRelativePath: String,
    isRequired: Bool = true
  ) {
    self.category = category
    self.sourceRelativePath = sourceRelativePath
    self.destinationRelativePath = destinationRelativePath
    self.isRequired = isRequired
  }
}

struct NativeRuntimeMigrationLayout: Equatable, Sendable {
  let sourceRootURL: URL
  let destinationRootURL: URL
  let selections: [NativeRuntimeMigrationSelection]
}

enum NativeRuntimeMigrationResult: Equatable, Sendable {
  case migrated(fingerprint: String)
  case alreadyCompleted(fingerprint: String)
}

enum NativeRuntimeDistributionError: LocalizedError, Equatable, Sendable {
  case invalidManifest(String)
  case packageReceiptMissing(String)
  case packageReceiptMismatch
  case unsafeArtifact(String)
  case artifactDigestMismatch(String)
  case artifactChangedDuringVerification(String)
  case artifactSignatureInvalid(String)
  case artifactSignerMismatch(String)
  case builderImageDigestMismatch
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidManifest(let detail):
      "The runtime distribution manifest is invalid: \(detail)"
    case .packageReceiptMissing(let identifier):
      "The package receipt \(identifier) is missing."
    case .packageReceiptMismatch:
      "The installed package receipt does not match the reviewed runtime version."
    case .unsafeArtifact(let path):
      "The runtime artifact at \(path) is missing or unsafe."
    case .artifactDigestMismatch(let path):
      "The runtime artifact digest does not match for \(path)."
    case .artifactChangedDuringVerification(let path):
      "The runtime artifact changed while it was being verified: \(path)."
    case .artifactSignatureInvalid(let path):
      "The runtime artifact signature is invalid: \(path)."
    case .artifactSignerMismatch(let path):
      "The runtime artifact signer does not match the reviewed distribution: \(path)."
    case .builderImageDigestMismatch:
      "The installed builder image digest does not match the reviewed release."
    case .commandFailed(let detail):
      "Runtime distribution inspection failed: \(detail)"
    }
  }
}

enum NativeRuntimeLaunchGraphError: LocalizedError, Equatable, Sendable {
  case duplicateService(String)
  case unknownOwner(label: String, executable: String)
  case mixedOwners
  case incompleteGraph(NativeRuntimeOrigin)
  case inspectionFailed(String)

  var errorDescription: String? {
    switch self {
    case .duplicateService(let label):
      "The launchd graph contains duplicate service \(label)."
    case .unknownOwner(let label, let executable):
      "Launch service \(label) has an unknown executable owner at \(executable)."
    case .mixedOwners:
      "Apple and NativeContainers launch services are loaded at the same time."
    case .incompleteGraph(let origin):
      "The \(origin.rawValue) launchd graph is incomplete."
    case .inspectionFailed(let detail):
      "The launchd graph could not be inspected: \(detail)"
    }
  }
}

enum NativeRuntimeConnectionError: LocalizedError, Equatable, Sendable {
  case inactive

  var errorDescription: String? {
    switch self {
    case .inactive:
      "No verified Apple or NativeContainers runtime is active."
    }
  }
}

enum NativeRuntimeActivationError: LocalizedError, Equatable, Sendable {
  case graphDidNotStop(NativeRuntimeOrigin)
  case graphDidNotStart(NativeRuntimeOrigin)
  case commandFailed(origin: NativeRuntimeOrigin, operation: String, detail: String)
  case activationFailed(String)
  case rollbackFailed(activation: String, rollback: String)

  var errorDescription: String? {
    switch self {
    case .graphDidNotStop(let origin):
      "The \(origin.rawValue) runtime graph did not stop completely."
    case .graphDidNotStart(let origin):
      "The \(origin.rawValue) runtime graph did not become active."
    case .commandFailed(let origin, let operation, let detail):
      "The \(origin.rawValue) runtime \(operation) command failed: \(detail)"
    case .activationFailed(let detail):
      "Runtime activation failed: \(detail)"
    case .rollbackFailed(let activation, let rollback):
      "Runtime activation failed (\(activation)) and rollback also failed (\(rollback))."
    }
  }
}

enum NativeRuntimeMigrationError: LocalizedError, Equatable, Sendable {
  case runtimeActive
  case invalidLayout(String)
  case migrationInProgress
  case destinationExists
  case unsafeSource(String)
  case unsupportedSourceEntry(String)
  case copyFailed(String)
  case validationFailed(String)
  case publishFailed(String)
  case invalidCompletionMarker

  var errorDescription: String? {
    switch self {
    case .runtimeActive:
      "Both runtime graphs must be inactive before migration."
    case .invalidLayout(let detail):
      "The runtime migration layout is invalid: \(detail)"
    case .migrationInProgress:
      "Another runtime migration is already in progress."
    case .destinationExists:
      "The NativeContainers runtime destination already exists without a valid migration marker."
    case .unsafeSource(let path):
      "The Apple runtime source is unsafe at \(path)."
    case .unsupportedSourceEntry(let path):
      "The Apple runtime source contains an unsupported entry at \(path)."
    case .copyFailed(let detail):
      "The runtime data could not be copied: \(detail)"
    case .validationFailed(let detail):
      "The staged runtime data failed validation: \(detail)"
    case .publishFailed(let detail):
      "The staged runtime data could not be published atomically: \(detail)"
    case .invalidCompletionMarker:
      "The existing runtime migration marker is invalid."
    }
  }
}
