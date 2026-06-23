import CryptoKit
import Darwin
import Foundation

protocol NativeRuntimePackageReceiptReading: Sendable {
  func receipt(packageIdentifier: String) async throws -> NativeRuntimePackageReceipt?
}

protocol NativeRuntimeArtifactInspecting: Sendable {
  func inspect(
    installRootURL: URL,
    artifact: NativeRuntimePackageArtifact
  ) throws -> NativeRuntimeArtifactObservation

  func readSmallUTF8File(
    installRootURL: URL,
    artifact: NativeRuntimePackageArtifact,
    maximumByteCount: Int
  ) throws -> String
}

protocol NativeRuntimeCodeSignatureValidating: Sendable {
  func validate(
    codeAt url: URL,
    teamIdentifier: String,
    signingIdentifier: String
  ) throws
}

protocol NativeRuntimeDistributionVerifying: Sendable {
  func verify(
    _ manifest: NativeRuntimeDistributionManifest
  ) async throws -> NativeRuntimeVerifiedDistribution
}

struct PkgutilNativeRuntimePackageReceiptReader: NativeRuntimePackageReceiptReading {
  private let commandExecutor: any HostCommandExecuting

  init(
    commandExecutor: any HostCommandExecuting = FoundationHostCommandExecutor()
  ) {
    self.commandExecutor = commandExecutor
  }

  func receipt(packageIdentifier: String) async throws -> NativeRuntimePackageReceipt? {
    let result: HostCommandResult
    do {
      result = try await commandExecutor.execute(
        executableURL: URL(filePath: "/usr/sbin/pkgutil"),
        arguments: ["--pkg-info-plist", packageIdentifier],
        environment: nil,
        timeout: .seconds(10)
      )
    } catch {
      throw NativeRuntimeDistributionError.commandFailed(error.localizedDescription)
    }
    if result.exitCode != 0 {
      let combined = result.standardError + result.standardOutput
      if combined.localizedCaseInsensitiveContains("No receipt") {
        return nil
      }
      throw NativeRuntimeDistributionError.commandFailed(Self.detail(result))
    }

    guard
      let data = result.standardOutput.data(using: .utf8),
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ),
      let dictionary = propertyList as? [String: Any],
      let identifier = dictionary["pkgid"] as? String,
      let version = dictionary["pkg-version"] as? String
    else {
      throw NativeRuntimeDistributionError.commandFailed(
        "pkgutil returned an invalid receipt."
      )
    }
    return NativeRuntimePackageReceipt(
      packageIdentifier: identifier,
      version: version
    )
  }

  private static func detail(_ result: HostCommandResult) -> String {
    let value = [result.standardError, result.standardOutput]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(value.suffix(2_000))
  }
}

struct DescriptorRelativeNativeRuntimeArtifactInspector:
  NativeRuntimeArtifactInspecting
{
  private let requiredOwnerUID: uid_t
  private let allowedDirectoryOwnerUIDs: Set<uid_t>

  init(
    requiredOwnerUID: uid_t = 0,
    allowedDirectoryOwnerUIDs: Set<uid_t>? = nil
  ) {
    self.requiredOwnerUID = requiredOwnerUID
    self.allowedDirectoryOwnerUIDs =
      allowedDirectoryOwnerUIDs ?? [requiredOwnerUID, getuid()]
  }

  func inspect(
    installRootURL: URL,
    artifact: NativeRuntimePackageArtifact
  ) throws -> NativeRuntimeArtifactObservation {
    let descriptor = try openArtifact(
      installRootURL: installRootURL,
      artifact: artifact
    )
    defer { Darwin.close(descriptor.file) }

    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor.file, $0.baseAddress, $0.count)
      }
      guard count >= 0 else {
        if errno == EINTR { continue }
        throw NativeRuntimeDistributionError.unsafeArtifact(
          artifact.relativePath
        )
      }
      if count == 0 { break }
      hasher.update(data: Data(buffer[0..<count]))
    }
    let digest = hasher.finalize()
      .map { String(format: "%02x", $0) }
      .joined()

    return NativeRuntimeArtifactObservation(
      sha256: digest,
      byteCount: Int64(descriptor.metadata.st_size),
      device: UInt64(descriptor.metadata.st_dev),
      inode: UInt64(descriptor.metadata.st_ino)
    )
  }

  func readSmallUTF8File(
    installRootURL: URL,
    artifact: NativeRuntimePackageArtifact,
    maximumByteCount: Int
  ) throws -> String {
    guard maximumByteCount > 0 else {
      throw NativeRuntimeDistributionError.unsafeArtifact(artifact.relativePath)
    }
    let descriptor = try openArtifact(
      installRootURL: installRootURL,
      artifact: artifact
    )
    defer { Darwin.close(descriptor.file) }
    guard descriptor.metadata.st_size <= maximumByteCount else {
      throw NativeRuntimeDistributionError.unsafeArtifact(artifact.relativePath)
    }

    var data = Data(count: Int(descriptor.metadata.st_size))
    let count = try data.withUnsafeMutableBytes { bytes -> Int in
      guard let baseAddress = bytes.baseAddress else { return 0 }
      var offset = 0
      while offset < bytes.count {
        let result = Darwin.read(
          descriptor.file,
          baseAddress.advanced(by: offset),
          bytes.count - offset
        )
        if result < 0, errno == EINTR { continue }
        guard result > 0 else {
          throw NativeRuntimeDistributionError.unsafeArtifact(
            artifact.relativePath
          )
        }
        offset += result
      }
      return offset
    }
    guard count == data.count, let value = String(data: data, encoding: .utf8) else {
      throw NativeRuntimeDistributionError.unsafeArtifact(artifact.relativePath)
    }
    return value
  }

  private func openArtifact(
    installRootURL: URL,
    artifact: NativeRuntimePackageArtifact
  ) throws -> (file: Int32, metadata: stat) {
    let components = artifact.relativePath.split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    guard
      !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw NativeRuntimeDistributionError.unsafeArtifact(artifact.relativePath)
    }

    let root = Darwin.open(
      installRootURL.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard root >= 0 else {
      throw NativeRuntimeDistributionError.unsafeArtifact(
        installRootURL.nativeContainersPOSIXPath
      )
    }
    var openedDescriptors = [root]
    var current = root
    var finalMetadata = stat()

    do {
      try requireSecureDirectory(current, path: installRootURL.path)
      for (index, component) in components.enumerated() {
        let isFinal = index == components.count - 1
        let flags =
          O_RDONLY | O_NOFOLLOW | O_CLOEXEC
          | (isFinal ? 0 : O_DIRECTORY)
        let next = Darwin.openat(current, String(component), flags)
        guard next >= 0 else {
          throw NativeRuntimeDistributionError.unsafeArtifact(
            artifact.relativePath
          )
        }
        openedDescriptors.append(next)
        current = next

        var metadata = stat()
        guard Darwin.fstat(current, &metadata) == 0 else {
          throw NativeRuntimeDistributionError.unsafeArtifact(
            artifact.relativePath
          )
        }
        if isFinal {
          finalMetadata = metadata
        } else {
          try requireSecureDirectory(current, path: artifact.relativePath)
        }
      }

      let isExecutable: Bool
      switch artifact.role {
      case .executable, .launchService:
        isExecutable = true
      case .data, .builderArtifactMetadata:
        isExecutable = false
      }
      guard
        finalMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        finalMetadata.st_uid == requiredOwnerUID,
        finalMetadata.st_nlink == 1,
        finalMetadata.st_size > 0,
        finalMetadata.st_size <= artifact.maximumByteCount,
        finalMetadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
        !isExecutable || finalMetadata.st_mode & mode_t(S_IXUSR) != 0
      else {
        throw NativeRuntimeDistributionError.unsafeArtifact(
          artifact.relativePath
        )
      }

      for descriptor in openedDescriptors.dropLast() {
        Darwin.close(descriptor)
      }
      return (current, finalMetadata)
    } catch {
      for descriptor in openedDescriptors {
        Darwin.close(descriptor)
      }
      throw error
    }
  }

  private func requireSecureDirectory(_ descriptor: Int32, path: String) throws {
    var metadata = stat()
    guard
      Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      allowedDirectoryOwnerUIDs.contains(metadata.st_uid),
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw NativeRuntimeDistributionError.unsafeArtifact(path)
    }
  }
}

struct SecurityNativeRuntimeCodeSignatureValidator:
  NativeRuntimeCodeSignatureValidating
{
  func validate(
    codeAt url: URL,
    teamIdentifier: String,
    signingIdentifier: String
  ) throws {
    let requirement =
      "anchor apple generic and identifier \"\(signingIdentifier)\" "
      + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    do {
      try StaticCodeRequirementValidator().validate(
        codeAt: url,
        requirement: requirement
      )
    } catch StaticCodeRequirementValidationError.requirementFailed {
      throw NativeRuntimeDistributionError.artifactSignerMismatch(url.path)
    } catch StaticCodeRequirementValidationError.requirementCreationFailed {
      throw NativeRuntimeDistributionError.artifactSignerMismatch(url.path)
    } catch {
      throw NativeRuntimeDistributionError.artifactSignatureInvalid(url.path)
    }
  }
}

struct NativeRuntimeDistributionVerifier: NativeRuntimeDistributionVerifying {
  private let receiptReader: any NativeRuntimePackageReceiptReading
  private let artifactInspector: any NativeRuntimeArtifactInspecting
  private let signatureValidator: any NativeRuntimeCodeSignatureValidating

  init(
    receiptReader: any NativeRuntimePackageReceiptReading =
      PkgutilNativeRuntimePackageReceiptReader(),
    artifactInspector: any NativeRuntimeArtifactInspecting =
      DescriptorRelativeNativeRuntimeArtifactInspector(),
    signatureValidator: any NativeRuntimeCodeSignatureValidating =
      SecurityNativeRuntimeCodeSignatureValidator()
  ) {
    self.receiptReader = receiptReader
    self.artifactInspector = artifactInspector
    self.signatureValidator = signatureValidator
  }

  func verify(
    _ manifest: NativeRuntimeDistributionManifest
  ) async throws -> NativeRuntimeVerifiedDistribution {
    try validate(manifest)

    guard
      let receipt = try await receiptReader.receipt(
        packageIdentifier: manifest.packageIdentifier
      )
    else {
      throw NativeRuntimeDistributionError.packageReceiptMissing(
        manifest.packageIdentifier
      )
    }
    guard
      receipt.packageIdentifier == manifest.packageIdentifier,
      receipt.version == manifest.packageVersion
    else {
      throw NativeRuntimeDistributionError.packageReceiptMismatch
    }

    var servicePaths: [String: URL] = [:]
    var observedBuilderArtifact: NativeRuntimeBuilderArtifactContract?

    for artifact in manifest.artifacts {
      let url = manifest.installRootURL.appending(
        path: artifact.relativePath,
        directoryHint: .notDirectory
      )
      let before = try artifactInspector.inspect(
        installRootURL: manifest.installRootURL,
        artifact: artifact
      )
      guard before.sha256 == artifact.sha256 else {
        throw NativeRuntimeDistributionError.artifactDigestMismatch(url.path)
      }

      switch artifact.role {
      case .executable(let signingIdentifier):
        try signatureValidator.validate(
          codeAt: url,
          teamIdentifier: manifest.teamIdentifier,
          signingIdentifier: signingIdentifier
        )
      case .launchService(let label, _, let signingIdentifier):
        try signatureValidator.validate(
          codeAt: url,
          teamIdentifier: manifest.teamIdentifier,
          signingIdentifier: signingIdentifier
        )
        servicePaths[label] = url.standardizedFileURL
      case .data:
        break
      case .builderArtifactMetadata:
        let value = try artifactInspector.readSmallUTF8File(
          installRootURL: manifest.installRootURL,
          artifact: artifact,
          maximumByteCount: 4 * 1_024
        )
        guard
          let data = value.data(using: .utf8),
          let observed = try? JSONDecoder().decode(
            NativeRuntimeBuilderArtifactContract.self,
            from: data
          )
        else {
          throw NativeRuntimeDistributionError.builderImageDigestMismatch
        }
        observedBuilderArtifact = observed
      }

      let after = try artifactInspector.inspect(
        installRootURL: manifest.installRootURL,
        artifact: artifact
      )
      guard after == before else {
        throw NativeRuntimeDistributionError.artifactChangedDuringVerification(
          url.path
        )
      }
    }

    guard observedBuilderArtifact == manifest.builderArtifact else {
      throw NativeRuntimeDistributionError.builderImageDigestMismatch
    }

    return NativeRuntimeVerifiedDistribution(
      origin: manifest.origin,
      packageIdentifier: manifest.packageIdentifier,
      version: manifest.packageVersion,
      installRootURL: manifest.installRootURL,
      builderArtifact: manifest.builderArtifact,
      serviceExecutablePaths: servicePaths
    )
  }

  private func validate(
    _ manifest: NativeRuntimeDistributionManifest
  ) throws {
    guard manifest.installRootURL.isFileURL,
      manifest.installRootURL.path.hasPrefix("/"),
      !manifest.packageIdentifier.isEmpty,
      !manifest.packageVersion.isEmpty,
      !manifest.teamIdentifier.isEmpty
    else {
      throw NativeRuntimeDistributionError.invalidManifest("Missing identity fields.")
    }
    if let builderArtifact = manifest.builderArtifact {
      guard
        Self.isSemanticVersion(builderArtifact.shimVersion),
        Self.isRevision(builderArtifact.sourceRevision),
        Self.isDigest(builderArtifact.imageDigest)
      else {
        throw NativeRuntimeDistributionError.invalidManifest(
          "The builder artifact identity is invalid."
        )
      }
    }
    if manifest.origin == .nativeContainers {
      guard
        manifest.teamIdentifier
          == NativeRuntimeDistributionManifest.nativeContainersTeamIdentifier,
        manifest.builderArtifact == .pinned
      else {
        throw NativeRuntimeDistributionError.invalidManifest(
          "The NativeContainers signer or builder release is not pinned."
        )
      }
    }

    var paths = Set<String>()
    var labels = Set<String>()
    var builderDigestArtifacts = 0
    guard !manifest.artifacts.isEmpty else {
      throw NativeRuntimeDistributionError.invalidManifest("No artifacts are listed.")
    }

    for artifact in manifest.artifacts {
      guard
        Self.isSafeRelativePath(artifact.relativePath),
        Self.isSHA256(artifact.sha256),
        artifact.maximumByteCount > 0,
        paths.insert(artifact.relativePath).inserted
      else {
        throw NativeRuntimeDistributionError.invalidManifest(
          "An artifact path or digest is invalid."
        )
      }

      switch artifact.role {
      case .executable(let signingIdentifier):
        guard !signingIdentifier.isEmpty else {
          throw NativeRuntimeDistributionError.invalidManifest(
            "An executable signing identifier is empty."
          )
        }
      case .launchService(let label, let domain, let signingIdentifier):
        guard
          !label.isEmpty,
          !domain.isEmpty,
          !signingIdentifier.isEmpty,
          labels.insert(label).inserted
        else {
          throw NativeRuntimeDistributionError.invalidManifest(
            "A launch service contract is invalid."
          )
        }
      case .data:
        break
      case .builderArtifactMetadata:
        builderDigestArtifacts += 1
      }
    }
    let expectedBuilderMetadataCount = manifest.builderArtifact == nil ? 0 : 1
    guard builderDigestArtifacts == expectedBuilderMetadataCount, !labels.isEmpty else {
      throw NativeRuntimeDistributionError.invalidManifest(
        "The builder metadata count or launch service graph is invalid."
      )
    }
  }

  private static func isSafeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/") else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    let allowed = Set("0123456789abcdef")
    return value.count == 64 && value.allSatisfy(allowed.contains)
  }

  private static func isDigest(_ value: String) -> Bool {
    value.hasPrefix("sha256:")
      && isSHA256(String(value.dropFirst("sha256:".count)))
  }

  private static func isRevision(_ value: String) -> Bool {
    let allowed = Set("0123456789abcdef")
    return value.count == 40 && value.allSatisfy(allowed.contains)
  }

  private static func isSemanticVersion(_ value: String) -> Bool {
    let core = value.split(separator: "-", maxSplits: 1).first ?? ""
    let components = core.split(separator: ".")
    return components.count == 3 && components.allSatisfy { Int($0) != nil }
  }
}
