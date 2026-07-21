import Compression
import CryptoKit
import Darwin
import Foundation
import Virtualization

struct NativeContainersLinuxImageBuildConfiguration: Sendable {
  static let pinned = Self(
    sourceURL: URL(string: "https://cloud.debian.org/images/cloud/trixie/20260712-2537/debian-13-generic-arm64-20260712-2537.raw")!,
    sourceMetadataURL: URL(string: "https://cloud.debian.org/images/cloud/trixie/20260712-2537/debian-13-generic-arm64-20260712-2537.json")!,
    sourceDigestURL: URL(string: "https://cloud.debian.org/images/cloud/trixie/20260712-2537/SHA512SUMS")!,
    sourceSHA512: "21f7862aca5d05a0ac8c63e64d78520967d881d05152c125b719d008f42ed2ff61e6f02908fda53a5e31a8c6e29d3a1116426e1646b9090f698c59872722d8bb",
    snapshotURL: URL(string: "https://snapshot.debian.org/archive/debian/20260718T000000Z")!,
    securitySnapshotURL: URL(string: "https://snapshot.debian.org/archive/debian-security/20260718T000000Z")!,
    singBoxURL: URL(string: "https://github.com/SagerNet/sing-box/releases/download/v1.13.14/sing-box-1.13.14-linux-arm64-glibc.tar.gz")!,
    singBoxSHA256: "08d37b2bf12145ec44307333490cecca4c917df054cd8e27a210f8d9cdbe0fd9",
    imageID: "debian-13-arm64-v1", imageBuildRevision: "linux-box-image-v1", guestAgentProtocolVersion: 2)
  let sourceURL: URL, sourceMetadataURL: URL, sourceDigestURL: URL, sourceSHA512: String
  let snapshotURL: URL, securitySnapshotURL: URL, singBoxURL: URL, singBoxSHA256: String
  let imageID: String, imageBuildRevision: String, guestAgentProtocolVersion: Int
}

enum NativeContainersLinuxImageBuildPhase: String, CaseIterable, Codable, Sendable {
  case sourceFetchedAndVerified, efiCompatibilityChecked, provisioned, sealed
  case validationCloneChecked, compressed, provenanceWritten
}
protocol NativeContainersLinuxImageBuildFailureInjecting: Sendable { func fail(after phase: NativeContainersLinuxImageBuildPhase) throws }
struct NoNativeContainersLinuxImageBuildFailure: NativeContainersLinuxImageBuildFailureInjecting { func fail(after phase: NativeContainersLinuxImageBuildPhase) throws {} }

struct NativeContainersLinuxImageProvenance: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let sourceURL: URL, sourceMetadataURL: URL, sourceDigestURL: URL, sourceSHA512: String
  let aptSnapshotURL: URL, aptSecuritySnapshotURL: URL, singBoxURL: URL, singBoxSHA256: String
  let guestSourceRevision: String, imageID: String, imageBuildRevision: String
  let guestAgentProtocolVersion: Int, logicalSizeBytes: UInt64, compressedSizeBytes: UInt64
  let compressedSHA256: String, rawSHA512: String, compression: String, chunkSizeBytes: Int
  let packageInventorySHA256: String, sourceInventorySHA256: String, releaseInventorySHA256: String
  let singBoxIdentity: String
  func validate() throws {
    let c = NativeContainersLinuxImageBuildConfiguration.pinned
    guard schemaVersion == 1, imageID == c.imageID, imageBuildRevision == c.imageBuildRevision,
      guestAgentProtocolVersion == c.guestAgentProtocolVersion, logicalSizeBytes >= 8 * 1_073_741_824,
      compressedSizeBytes > 0, chunkSizeBytes == 1 * 1_024 * 1_024,
      rawSHA512.range(of: "^[0-9a-f]{128}$", options: .regularExpression) != nil,
      compressedSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      packageInventorySHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      sourceInventorySHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      releaseInventorySHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      singBoxIdentity == "sing-box-1.13.14", compression == "lzfse"
    else { throw NativeContainersLinuxImageBuilderError.invalidProvenance }
  }
}
struct NativeContainersLinuxImageBuildResult: Equatable, Sendable {
  let candidateURL: URL, compressedURL: URL, provenanceURL: URL, provenance: NativeContainersLinuxImageProvenance
}

struct NativeContainersLinuxImageBuilder: Sendable {
  static let requiredGuestAssets = ["LinuxBoxImage/guest/nativecontainers_agent.py", "LinuxBoxImage/guest/nativecontainers_runtime.py", "LinuxBoxImage/guest/nativecontainers_verify.py"]
  static let requiredSystemdAssets = ["LinuxBoxImage/systemd/nativecontainers-network-authorization.service", "LinuxBoxImage/systemd/nativecontainers_network_authorization.py", "LinuxBoxImage/systemd/nativecontainers-baseline-firewall.nft", "LinuxBoxImage/systemd/nativecontainers-grow-root.service", "LinuxBoxImage/systemd/nativecontainers-sing-box.service", "LinuxBoxImage/systemd/10-nativecontainers.network", "LinuxBoxImage/systemd/10-nativecontainers-authorization.conf", "LinuxBoxImage/systemd/nativecontainers-agent.service", "LinuxBoxImage/systemd/nativecontainers-baseline-firewall.service", "LinuxBoxImage/systemd/nativecontainers_grow_root.py", "LinuxBoxImage/systemd/nativecontainers_lockdown.py"]
  static let requiredGuestTestDirectory = "LinuxBoxImage/tests"
  static let rootCapacityProofMarker = "NATIVECONTAINERS_ROOT_EXPANDED_32G"
  static let chunkSize = 1 * 1_024 * 1_024
  static let aptPackages = ["ca-certificates", "chromium", "cloud-guest-utils", "coreutils", "curl", "dnsutils", "iproute2", "libcap2-bin", "netcat-openbsd", "nftables", "procps", "python3", "util-linux"]
  static let cidataVolumeName = "cidata"
  static let cidataCreationArguments = ["makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata"]
  static let requiredEFICompletionMarker = "NATIVECONTAINERS_UPSTREAM_BOOT_OK"
  static let provisioningCompletionMarker = "NATIVECONTAINERS_PROVISIONING_OK"
  static let efiCompatibilityTimeout: TimeInterval = 300
  static let seedlessReadinessTimeout: TimeInterval = 600
  static let seedlessProtocolTimeout: TimeInterval = 300
  let configuration: NativeContainersLinuxImageBuildConfiguration
  let projectRoot: URL
  let failureInjector: any NativeContainersLinuxImageBuildFailureInjecting
  init(projectRoot: URL, configuration: NativeContainersLinuxImageBuildConfiguration = .pinned, failureInjector: any NativeContainersLinuxImageBuildFailureInjecting = NoNativeContainersLinuxImageBuildFailure()) {
    self.projectRoot = projectRoot.standardizedFileURL; self.configuration = configuration; self.failureInjector = failureInjector
  }

  func requireGuestAssets() throws -> [URL] {
    let guest = Self.requiredGuestAssets.map { projectRoot.appending(path: $0) }
    let systemd = Self.requiredSystemdAssets.map { projectRoot.appending(path: $0) }
    let tests = projectRoot.appending(path: Self.requiredGuestTestDirectory, directoryHint: .isDirectory)
    let required = guest + systemd
    guard required.allSatisfy({ isRegularFile($0) }), isDirectory(tests) else {
      throw NativeContainersLinuxImageBuilderError.guestAssetsMissing(required.filter { !isRegularFile($0) }.map(\.path))
    }
    return required + [tests]
  }

  func runGuestContractTests() throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-m", "unittest", "discover", "-s", projectRoot.appending(path: Self.requiredGuestTestDirectory).path, "-p", "test_*.py"]
    process.currentDirectoryURL = projectRoot; let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NativeContainersLinuxImageBuilderError.guestContractTestsFailed(process.terminationStatus) }
  }

  /// The complete source-attestable workflow. A caller supplies only an output directory;
  /// the candidate is always downloaded, provisioned, sealed, validated, and compressed here.
  func prepareAndBuild(outputDirectory: URL, guestSourceRevision: String) async throws -> NativeContainersLinuxImageBuildResult {
    try validatePinnedConfiguration(); _ = try requireGuestAssets(); try runGuestContractTests()
    let fm = FileManager.default
    let outputArtifactNames = [
      "nativecontainers-debian-13-arm64-v1.raw",
      "nativecontainers-debian-13-arm64-v1.raw.lzfse",
      "nativecontainers-debian-13-arm64-v1.provenance.json",
    ]
    let outputDirectoryDescriptor = try prepareOutputDirectory(outputDirectory)
    defer { close(outputDirectoryDescriptor) }
    try requireAbsentArtifacts(
      outputArtifactNames,
      directoryDescriptor: outputDirectoryDescriptor
    )
    let workspace = fm.temporaryDirectory.appending(path: "NativeContainersLinuxImageBuilder-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: workspace) }
    do {
      let source = try await fetchAndVerifySource(into: workspace)
      try failureInjector.fail(after: .sourceFetchedAndVerified)
      let upstream = workspace.appending(path: "upstream.raw")
      try cloneOrCopy(source, to: upstream)
      let efiSeed = try makeSeed(in: workspace, userData: minimalEFIUserData())
      _ = try await BuilderVirtualizationRunner.run(raw: upstream, seed: efiSeed, nvramDirectory: workspace.appending(path: "efi"), socket: false, marker: Self.requiredEFICompletionMarker, timeout: Self.efiCompatibilityTimeout)
      try? fm.removeItem(at: efiSeed)
      try failureInjector.fail(after: .efiCompatibilityChecked)
      let candidate = workspace.appending(path: "candidate.raw")
      try cloneOrCopy(source, to: candidate); try sparseGrow(candidate, to: 8 * 1_073_741_824)
      let seed = try makeSeed(in: workspace, userData: provisioningUserData(sourceSHA512: configuration.sourceSHA512, guestSourceRevision: guestSourceRevision))
      let provisioningOutput = try await BuilderVirtualizationRunner.run(raw: candidate, seed: seed, nvramDirectory: workspace.appending(path: "provision-efi"), socket: false, marker: Self.provisioningCompletionMarker, timeout: 1_800)
      let inventory = try inventoryDigests(from: provisioningOutput)
      try? fm.removeItem(at: seed); try failureInjector.fail(after: .provisioned)
      try sealCandidate(candidate); try failureInjector.fail(after: .sealed)
      let validation = workspace.appending(path: "validation.raw")
      try cloneOrCopy(candidate, to: validation)
      try makeOwnerWritable(validation)
      try sparseGrow(validation, to: 32 * 1_073_741_824)
      try await BuilderVirtualizationRunner.validateSeedless(raw: validation, nvramDirectory: workspace.appending(path: "validation-efi"), readinessTimeout: Self.seedlessReadinessTimeout, protocolTimeout: Self.seedlessProtocolTimeout)
      try? fm.removeItem(at: validation); try failureInjector.fail(after: .validationCloneChecked)
      let persistedCandidate = outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.raw")
      try cloneOrCopy(candidate, to: persistedCandidate)
      try sealCandidate(persistedCandidate)
      let compressed = outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.raw.lzfse")
      try compress(candidate, to: compressed)
      try roundTrip(candidate: candidate, compressed: compressed)
      try sealCandidate(compressed)
      try failureInjector.fail(after: .compressed)
      let provenance = NativeContainersLinuxImageProvenance(schemaVersion: 1, sourceURL: configuration.sourceURL, sourceMetadataURL: configuration.sourceMetadataURL, sourceDigestURL: configuration.sourceDigestURL, sourceSHA512: configuration.sourceSHA512, aptSnapshotURL: configuration.snapshotURL, aptSecuritySnapshotURL: configuration.securitySnapshotURL, singBoxURL: configuration.singBoxURL, singBoxSHA256: configuration.singBoxSHA256, guestSourceRevision: guestSourceRevision, imageID: configuration.imageID, imageBuildRevision: configuration.imageBuildRevision, guestAgentProtocolVersion: configuration.guestAgentProtocolVersion, logicalSizeBytes: try fileSize(candidate), compressedSizeBytes: try fileSize(compressed), compressedSHA256: try digest(compressed, algorithm: .sha256), rawSHA512: try digest(candidate, algorithm: .sha512), compression: "lzfse", chunkSizeBytes: Self.chunkSize, packageInventorySHA256: inventory.package, sourceInventorySHA256: inventory.source, releaseInventorySHA256: inventory.release, singBoxIdentity: inventory.singBox)
      try provenance.validate()
      let provenanceURL = outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.provenance.json")
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(provenance).write(to: provenanceURL, options: [.atomic])
      try sealCandidate(provenanceURL)
      try synchronizeOutputDirectory(
        outputDirectory,
        descriptor: outputDirectoryDescriptor
      )
      try failureInjector.fail(after: .provenanceWritten)
      return NativeContainersLinuxImageBuildResult(candidateURL: persistedCandidate, compressedURL: compressed, provenanceURL: provenanceURL, provenance: provenance)
    } catch is CancellationError {
      try? fm.removeItem(at: outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.raw.lzfse"))
      try? fm.removeItem(at: outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.raw"))
      try? fm.removeItem(at: outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.provenance.json"))
      throw NativeContainersLinuxImageBuilderError.cancelled
    } catch {
      try? fm.removeItem(at: outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.raw.lzfse"))
      try? fm.removeItem(at: outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.raw"))
      try? fm.removeItem(at: outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.provenance.json"))
      throw error
    }
  }

  /// Explicit legacy packaging mode. It never represents a completed image build.
  func build(sealedCandidateURL: URL, outputDirectory: URL, guestSourceRevision: String) throws -> NativeContainersLinuxImageBuildResult {
    try validatePinnedConfiguration(); _ = try requireGuestAssets(); try validateCandidate(sealedCandidateURL)
    try sealCandidate(sealedCandidateURL)
    try failureInjector.fail(after: .sourceFetchedAndVerified); try failureInjector.fail(after: .efiCompatibilityChecked); try failureInjector.fail(after: .provisioned); try failureInjector.fail(after: .sealed); try failureInjector.fail(after: .validationCloneChecked)
    let outputDirectoryDescriptor = try prepareOutputDirectory(outputDirectory)
    defer { close(outputDirectoryDescriptor) }
    try requireAbsentArtifacts(
      [
        "nativecontainers-debian-13-arm64-v1.raw.lzfse",
        "nativecontainers-debian-13-arm64-v1.provenance.json",
      ],
      directoryDescriptor: outputDirectoryDescriptor
    )
    let compressed = outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.raw.lzfse")
    try compress(sealedCandidateURL, to: compressed)
    try sealCandidate(compressed)
    let p = NativeContainersLinuxImageProvenance(schemaVersion: 1, sourceURL: configuration.sourceURL, sourceMetadataURL: configuration.sourceMetadataURL, sourceDigestURL: configuration.sourceDigestURL, sourceSHA512: configuration.sourceSHA512, aptSnapshotURL: configuration.snapshotURL, aptSecuritySnapshotURL: configuration.securitySnapshotURL, singBoxURL: configuration.singBoxURL, singBoxSHA256: configuration.singBoxSHA256, guestSourceRevision: guestSourceRevision, imageID: configuration.imageID, imageBuildRevision: configuration.imageBuildRevision, guestAgentProtocolVersion: 1, logicalSizeBytes: try fileSize(sealedCandidateURL), compressedSizeBytes: try fileSize(compressed), compressedSHA256: try digest(compressed, algorithm: .sha256), rawSHA512: try digest(sealedCandidateURL, algorithm: .sha512), compression: "lzfse", chunkSizeBytes: Self.chunkSize, packageInventorySHA256: String(repeating: "0", count: 64), sourceInventorySHA256: String(repeating: "0", count: 64), releaseInventorySHA256: String(repeating: "0", count: 64), singBoxIdentity: "sing-box-1.13.14")
    try p.validate(); let provenanceURL = outputDirectory.appending(path: "nativecontainers-debian-13-arm64-v1.provenance.json")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(p).write(to: provenanceURL, options: [.atomic])
    try sealCandidate(provenanceURL)
    try synchronizeOutputDirectory(
      outputDirectory,
      descriptor: outputDirectoryDescriptor
    )
    return NativeContainersLinuxImageBuildResult(candidateURL: sealedCandidateURL, compressedURL: compressed, provenanceURL: provenanceURL, provenance: p)
  }

  private func fetchAndVerifySource(into directory: URL) async throws -> URL {
    let raw = directory.appending(path: "debian.raw.partial"), metadata = directory.appending(path: "debian.raw.json.partial"), sums = directory.appending(path: "SHA512SUMS.partial")
    try await download(configuration.sourceMetadataURL, to: metadata, maximumBytes: 1 * 1_024 * 1_024)
    try await download(configuration.sourceDigestURL, to: sums, maximumBytes: 16 * 1_024 * 1_024)
    try await download(configuration.sourceURL, to: raw, maximumBytes: 8 * 1_073_741_824)
    guard let metadataObject = try? JSONSerialization.jsonObject(
      with: Data(contentsOf: metadata)
    ),
      let metadataDictionary = metadataObject as? [String: Any],
      metadataDictionary["apiVersion"] as? String == "v1",
      metadataDictionary["kind"] as? String == "List",
      let items = metadataDictionary["items"] as? [[String: Any]],
      items.count == 4
    else {
      throw NativeContainersLinuxImageBuilderError.sourceMetadataInvalid
    }
    let builds = items.filter { $0["kind"] as? String == "Build" }
    guard builds.count == 1,
      builds[0]["apiVersion"] as? String == "cloud.debian.org/v1alpha1",
      let data = builds[0]["data"] as? [String: Any],
      let info = data["info"] as? [String: Any],
      info["arch"] as? String == "arm64",
      info["release"] as? String == "trixie",
      info["release_id"] as? String == "13",
      info["type"] as? String == "official",
      info["vendor"] as? String == "generic",
      info["version"] as? String == "20260712-2537",
      let packages = data["packages"] as? [[String: Any]],
      !packages.isEmpty
    else {
      throw NativeContainersLinuxImageBuilderError.sourceMetadataInvalid
    }
    let fileName = configuration.sourceURL.lastPathComponent
    let expectedRef = "trixie/20260712-2537/\(fileName)"
    let rawUploads = items.filter { item in
      guard item["kind"] as? String == "Upload",
        let data = item["data"] as? [String: Any]
      else { return false }
      return data["provider"] as? String == "cloud.debian.org"
        && data["ref"] as? String == expectedRef
    }
    guard rawUploads.count == 1,
      let rawMetadata = rawUploads[0]["metadata"] as? [String: Any],
      let annotations = rawMetadata["annotations"] as? [String: Any],
      let annotation = annotations["cloud.debian.org/digest"] as? String,
      annotation.hasPrefix("sha512:")
    else {
      throw NativeContainersLinuxImageBuilderError.sourceMetadataInvalid
    }
    var encodedDigest = String(annotation.dropFirst("sha512:".count))
    encodedDigest += String(
      repeating: "=",
      count: (4 - encodedDigest.count % 4) % 4
    )
    guard let metadataDigest = Data(base64Encoded: encodedDigest),
      metadataDigest.map({ String(format: "%02x", $0) }).joined()
        == configuration.sourceSHA512
    else {
      throw NativeContainersLinuxImageBuilderError.sourceMetadataInvalid
    }
    let digestText = try String(contentsOf: sums, encoding: .utf8)
    let digestLine = digestText.split(whereSeparator: \.isNewline).first { line in
      let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard fields.count >= 2 else { return false }
      return fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == fileName
    }
    guard let line = digestLine, let expected = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, expected.lowercased() == configuration.sourceSHA512 else { throw NativeContainersLinuxImageBuilderError.sourceDigestMismatch }
    guard try digest(raw, algorithm: .sha512) == configuration.sourceSHA512 else { throw NativeContainersLinuxImageBuilderError.sourceDigestMismatch }
    return raw
  }

  private func download(
    _ url: URL,
    to destination: URL,
    maximumBytes: Int64
  ) async throws {
    try Task.checkCancellation()
    let curl = URL(fileURLWithPath: "/usr/bin/curl")
    let arguments = [
      "-q",
      "-4",
      "--fail",
      "--location",
      "--silent",
      "--show-error",
      "--retry", "2",
      "--retry-delay", "5",
      "--retry-all-errors",
      "--connect-timeout", "60",
      "--max-time", "1800",
      "--max-filesize", String(maximumBytes),
      "--proto", "=https",
      "--output", destination.path,
      url.absoluteString,
    ]
    do {
      try await runDownloadProcess(
        curl,
        arguments: arguments,
        timeoutNanoseconds: UInt64(3 * 1_800 + 2 * 5 + 10) * 1_000_000_000
      )
      try Task.checkCancellation()
      guard try fileSize(destination) <= UInt64(maximumBytes) else {
        throw NativeContainersLinuxImageBuilderError.downloadFailed(
          url.absoluteString
        )
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: destination.path
      )
      let handle = try FileHandle(forWritingTo: destination)
      try handle.synchronize()
      try handle.close()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw NativeContainersLinuxImageBuilderError.downloadFailed(
        url.absoluteString
      )
    }
  }

  private func makeSeed(in directory: URL, userData: String) throws -> URL {
    let seedDirectory = directory.appending(path: "seed-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: seedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let userDataURL = seedDirectory.appending(path: "user-data")
    let metadataURL = seedDirectory.appending(path: "meta-data")
    try Data(userData.utf8).write(to: userDataURL, options: [.atomic])
    try Data("instance-id: nativecontainers-\(UUID().uuidString.lowercased())\nlocal-hostname: nativecontainers-builder\n".utf8).write(to: metadataURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userDataURL.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    let iso = directory.appending(path: "cidata-\(UUID().uuidString).iso")
    try runProcess(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: Self.cidataCreationArguments + ["-o", iso.path, seedDirectory.path], timeout: 120)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: iso.path)
    try FileManager.default.removeItem(at: seedDirectory); return iso
  }

  private func minimalEFIUserData() -> String {
    """
    #cloud-config
    runcmd:
      - [sh, -c, "for console in /dev/hvc0 /dev/ttyS0; do if [ -c \\"$console\\" ]; then printf '%s\\n' NATIVECONTAINERS_UPSTREAM_BOOT_OK > \\"$console\\"; break; fi; done; sync; /sbin/poweroff"]
    """
  }

  private func provisioningUserData(sourceSHA512: String, guestSourceRevision: String) throws -> String {
    var entries: [(String, String, String)] = []
    for path in Self.requiredGuestAssets {
      let asset = try encodedAsset(path)
      let base = URL(fileURLWithPath: path).lastPathComponent
      entries.append(("/usr/local/libexec/" + base, asset, "0755"))
      entries.append(("/usr/local/share/nativecontainers/guest/" + base, asset, "0755"))
    }
    let deferredSystemdAssets = Set([
      "10-nativecontainers.network",
      "10-nativecontainers-authorization.conf",
    ])
    for path in Self.requiredSystemdAssets {
      let base = URL(fileURLWithPath: path).lastPathComponent
      let asset = try encodedAsset(path)
      let mode = base.hasSuffix(".py") ? "0755" : "0644"
      entries.append(("/usr/local/share/nativecontainers/systemd/" + base, asset, mode))
      guard !deferredSystemdAssets.contains(base) else { continue }
      let destination: String
      if base == "nativecontainers-baseline-firewall.nft" {
        destination = "/usr/lib/nativecontainers/nativecontainers-baseline-firewall.nft"
      } else if base.hasSuffix(".py") {
        destination = "/usr/local/libexec/" + base
      } else {
        destination = "/etc/systemd/system/" + base
      }
      entries.append((destination, asset, mode))
    }
    let fixture = "{\"log\":{\"disabled\":true},\"inbounds\":[],\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}],\"route\":{\"final\":\"direct\"}}"
    entries.append(("/usr/local/share/nativecontainers/sing-box.fixture.json", Data(fixture.utf8).base64EncodedString(), "0600"))
    entries.append(("/usr/lib/nativecontainers/image.json", Data("{\"schema\":1,\"imageID\":\"\(configuration.imageID)\",\"imageBuildRevision\":\"\(configuration.imageBuildRevision)\",\"protocol\":\(configuration.guestAgentProtocolVersion)}\n".utf8).base64EncodedString(), "0644"))
    let guestTestDirectory = projectRoot.appending(path: Self.requiredGuestTestDirectory)
    for test in try FileManager.default.contentsOfDirectory(at: guestTestDirectory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "py" }) {
      entries.append(("/usr/local/share/nativecontainers/tests/" + test.lastPathComponent, try Data(contentsOf: test).base64EncodedString(), "0644"))
    }
    let sealScript = """
    #!/bin/sh
    set -eu
    cloud-init status --wait
    swapoff -a || true
    sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab
    systemctl mask swap.target sleep.target suspend.target hibernate.target hybrid-sleep.target systemd-coredump.socket systemd-coredump@.service kdump-tools.service >/dev/null 2>&1 || true
    systemctl disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service >/dev/null 2>&1 || true
    test "$(sed 1d /proc/swaps | wc -l)" -eq 0
    passwd -S native | awk '$2 == "L" { found=1 } END { exit !found }'
    test "$(getent passwd native | cut -d: -f7)" = /usr/sbin/nologin
    mkdir -p /etc/systemd/journald.conf.d /etc/systemd/system/nativecontainers-agent.service.d /etc/sysctl.d
    printf '%s\\n' '[Journal]' 'Storage=volatile' 'RuntimeMaxUse=32M' > /etc/systemd/journald.conf.d/nativecontainers-volatile.conf
    printf '%s\\n' '[Service]' 'LimitCORE=0' 'StandardOutput=null' 'StandardError=null' > /etc/systemd/system/nativecontainers-agent.service.d/limits.conf
    printf '%s\\n' 'kernel.core_pattern=|/bin/false' 'fs.suid_dumpable=0' > /etc/sysctl.d/99-nativecontainers-no-coredump.conf
    printf '%s\\n' '* hard core 0' '* soft core 0' > /etc/security/limits.d/nativecontainers.conf
    cloud-init clean --logs --seed || true
    apt-get clean
    rm -f /etc/ssh/ssh_host_* /var/lib/systemd/random-seed
    rm -rf /var/lib/cloud/* /var/log/cloud-init* /var/lib/dhcp/* /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/log/journal/* /run/systemd/journal/* /var/lib/systemd/coredump/*
    rm -f /etc/machine-id
    touch /etc/machine-id
    chmod 0444 /etc/machine-id
    touch /etc/cloud/cloud-init.disabled
    test ! -s /etc/machine-id
    test -f /etc/cloud/cloud-init.disabled
    pkgDigest=$(sha256sum /usr/share/nativecontainers/package-inventory.txt | cut -d' ' -f1)
    sourceDigest=$(sha256sum /usr/share/nativecontainers/source-inventory.txt | cut -d' ' -f1)
    releaseDigest=$(sha256sum /usr/share/nativecontainers/release-inventory.txt | cut -d' ' -f1)
    systemctl disable nativecontainers-image-seal.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/nativecontainers-image-seal.service /usr/local/libexec/nativecontainers_seal_image.sh
    systemctl daemon-reload
    for console in /dev/hvc0 /dev/ttyS0; do
      if [ -c "$console" ]; then
        printf '%s packageInventorySHA256=%s sourceInventorySHA256=%s releaseInventorySHA256=%s singBoxIdentity=sing-box-1.13.14\\n' \(Self.provisioningCompletionMarker) "$pkgDigest" "$sourceDigest" "$releaseDigest" > "$console"
        break
      fi
    done
    sync
    /sbin/poweroff
    """
    let sealUnit = """
    [Unit]
    Description=NativeContainers image sealing completion
    After=cloud-final.service
    [Service]
    Type=oneshot
    ExecStart=/usr/local/libexec/nativecontainers_seal_image.sh
    StandardOutput=null
    StandardError=null
    [Install]
    WantedBy=multi-user.target
    """
    entries.append(("/usr/local/libexec/nativecontainers_seal_image.sh", Data(sealScript.utf8).base64EncodedString(), "0755"))
    entries.append(("/etc/systemd/system/nativecontainers-image-seal.service", Data(sealUnit.utf8).base64EncodedString(), "0644"))
    let packages = Self.aptPackages.joined(separator: " ")
    let identityCommand = """
    set -eu
    nativeGroup="$(getent group native || true)"
    if [ -n "$nativeGroup" ]; then
      test "$(printf '%s\\n' "$nativeGroup" | cut -d: -f3)" = 1000
    fi
    gid1000Group="$(getent group 1000 || true)"
    if [ -n "$gid1000Group" ]; then
      gid1000Name="$(printf '%s\\n' "$gid1000Group" | cut -d: -f1)"
      if [ "$gid1000Name" != native ]; then
        test -z "$nativeGroup"
        groupmod -n native "$gid1000Name"
      fi
    elif [ -z "$nativeGroup" ]; then
      groupadd --gid 1000 native
    fi
    test "$(getent group native | cut -d: -f3)" = 1000
    priorHome=
    nativePasswd="$(getent passwd native || true)"
    if [ -n "$nativePasswd" ]; then
      test "$(printf '%s\\n' "$nativePasswd" | cut -d: -f3)" = 1000
      priorHome="$(printf '%s\\n' "$nativePasswd" | cut -d: -f6)"
    else
      uid1000Passwd="$(getent passwd 1000 || true)"
      if [ -n "$uid1000Passwd" ]; then
        uid1000Name="$(printf '%s\\n' "$uid1000Passwd" | cut -d: -f1)"
        priorHome="$(printf '%s\\n' "$uid1000Passwd" | cut -d: -f6)"
        test "$uid1000Name" != native
        usermod -l native "$uid1000Name"
      else
        useradd --uid 1000 --gid 1000 --home-dir /workspace --no-create-home --shell /usr/sbin/nologin native
      fi
    fi
    if [ -n "$priorHome" ] && [ "$priorHome" != / ] && [ "$priorHome" != /workspace ]; then
      test ! -L "$priorHome"
      if [ -e "$priorHome" ]; then
        test -d "$priorHome"
        chown root:root "$priorHome"
        chmod 0700 "$priorHome"
      fi
    fi
    usermod --gid 1000 --groups "" --home /workspace --shell /usr/sbin/nologin native
    passwd -l native >/dev/null
    test "$(getent passwd native | cut -d: -f3)" = 1000
    test "$(getent passwd native | cut -d: -f4)" = 1000
    test "$(getent passwd native | cut -d: -f6)" = /workspace
    test "$(getent passwd native | cut -d: -f7)" = /usr/sbin/nologin
    test "$(id -G native)" = 1000
    passwd -S native | awk '$2 == "L" { found=1 } END { exit !found }'
    install -d -o 1000 -g 1000 -m 0700 /workspace
    test "$(stat -c '%u:%g:%a' /workspace)" = 1000:1000:700
    """
    let stages: [(String, String)] = [
      (
        "bootstrap-layout",
        "install -d -m 0755 /usr/local/libexec /usr/local/share/nativecontainers /usr/share/nativecontainers /usr/lib/nativecontainers"
      ),
      (
        "apt-snapshot-packages",
        "set -eu; install -d -m 0755 /usr/local/lib/nativecontainers /usr/local/share/nativecontainers /usr/lib/nativecontainers /etc/systemd/network /etc/systemd/system/systemd-networkd.service.d; rm -f /etc/apt/sources.list; rm -rf /etc/apt/sources.list.d/*; printf '%s\\n' 'deb [check-valid-until=no] \(configuration.snapshotURL.absoluteString) trixie main' 'deb [check-valid-until=no] \(configuration.snapshotURL.absoluteString) trixie-updates main' 'deb [check-valid-until=no] \(configuration.securitySnapshotURL.absoluteString) trixie-security main' > /etc/apt/sources.list.d/nativecontainers.list; printf '%s\\n' 'Acquire::Check-Valid-Until false;' > /etc/apt/apt.conf.d/99-nativecontainers-snapshot; apt-get update; apt-get install -y --no-install-recommends \\\n    \(packages)"
      ),
      (
        "sing-box-fetch-verify-install",
        "set -eu; tmp=\"$(mktemp)\"; curl --fail --silent --show-error --location --proto '=https' --tlsv1.3 --output \"$tmp\" \(configuration.singBoxURL.absoluteString); printf '%s  %s\\n' \(configuration.singBoxSHA256) \"$tmp\" | sha256sum --check --status; mkdir -p /tmp/nativecontainers-sing-box; tar -xzf \"$tmp\" -C /tmp/nativecontainers-sing-box --strip-components=1; install -m 0755 /tmp/nativecontainers-sing-box/sing-box /usr/local/bin/sing-box; rm -rf \"$tmp\" /tmp/nativecontainers-sing-box; /usr/local/bin/sing-box check -c /usr/local/share/nativecontainers/sing-box.fixture.json"
      ),
      (
        "sing-box-version-record",
        "set -eu; /usr/local/bin/sing-box version | grep -F '1.13.14' > /usr/share/nativecontainers/sing-box.identity"
      ),
      (
        "guest-user-systemd-inventory",
        "\(identityCommand)\ninstall -m 0644 /usr/local/share/nativecontainers/systemd/10-nativecontainers.network /etc/systemd/network/10-nativecontainers.network; install -m 0644 /usr/local/share/nativecontainers/systemd/10-nativecontainers-authorization.conf /etc/systemd/system/systemd-networkd.service.d/10-nativecontainers-authorization.conf; systemctl daemon-reload; systemctl enable nativecontainers-grow-root.service nativecontainers-agent.service nativecontainers-baseline-firewall.service; systemctl disable nativecontainers-network-authorization.service nativecontainers-sing-box.service systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service >/dev/null 2>&1 || true; systemctl disable NetworkManager.service networking.service >/dev/null 2>&1 || true; systemctl start nativecontainers-grow-root.service; systemctl daemon-reload"
      ),
      (
        "apt-release-inventories",
        "set -eu; find /etc/apt -maxdepth 3 -type f -print0 | xargs -0 sha256sum | LC_ALL=C sort > /usr/share/nativecontainers/source-inventory.txt; find /var/lib/apt/lists -type f \\( -name '*InRelease' -o -name '*Release' \\) -print0 | xargs -0 -r sha256sum | LC_ALL=C sort > /usr/share/nativecontainers/release-inventory.txt; test -s /usr/share/nativecontainers/release-inventory.txt"
      ),
      (
        "guest-tests-systemd-verify-inventory-digests",
        "set -eu; python3 -m unittest discover -s /usr/local/share/nativecontainers/tests -p 'test_*.py'; systemd-analyze verify /etc/systemd/system/nativecontainers-*.service > /usr/share/nativecontainers/systemd-graph.txt; sha256sum /usr/share/nativecontainers/package-inventory.txt /usr/share/nativecontainers/source-inventory.txt /usr/share/nativecontainers/release-inventory.txt | LC_ALL=C sort > /usr/share/nativecontainers/inventory-digests.txt"
      ),
      (
        "seal-service-enable-start",
        "set -eu; systemctl daemon-reload; systemctl enable nativecontainers-image-seal.service; systemctl start --no-block nativecontainers-image-seal.service"
      ),
    ]
    let provisioningScript = """
    #!/bin/sh
    set -eu
    provision_failure() {
      status=$?
      trap - EXIT
      if [ "$status" -ne 0 ]; then
        sync || true
        /sbin/poweroff || true
      fi
      exit "$status"
    }
    trap provision_failure EXIT
    run_stage() {
      stage="$1"
      semantic_command="$2"
      exec 3>/dev/hvc0
      printf '%s\\n' "NATIVECONTAINERS_PROVISION_STAGE_BEGIN stage=$stage" >&3
      if sh -c "$semantic_command" >/dev/null 2>&3; then
        status=0
      else
        status=$?
      fi
      if [ "$status" -ne 0 ]; then
        printf '%s\\n' "NATIVECONTAINERS_PROVISION_STAGE_FAILED stage=$stage exit=$status" >&3
      fi
      exec 3>&-
      return "$status"
    }
    \(stages.map { "run_stage \(Self.shellQuote($0.0)) \(Self.shellQuote($0.1))" }.joined(separator: "\n"))
    """
    entries.append(("/usr/local/libexec/nativecontainers_provision_image.sh", Data(provisioningScript.utf8).base64EncodedString(), "0755"))
    let files = entries.map { "  - path: \($0.0)\n    permissions: '\($0.2)'\n    encoding: b64\n    content: \($0.1)" }.joined(separator: "\n")
    return """
    #cloud-config
    users: []
    disable_root: true
    ssh_pwauth: false
    package_update: false
    write_files:
    \(files)
    runcmd:
      - ["/usr/local/libexec/nativecontainers_provision_image.sh"]
    """
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }

  private func encodedAsset(_ relative: String) throws -> String { Data(try Data(contentsOf: projectRoot.appending(path: relative))).base64EncodedString() }
  private typealias InventoryDigests = (package: String, source: String, release: String, singBox: String)
  private func inventoryDigests(from text: String) throws -> InventoryDigests {
    guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains(Self.provisioningCompletionMarker) && $0.contains("packageInventorySHA256=") }) else {
      throw NativeContainersLinuxImageBuilderError.provisioningEvidenceMissing
    }
    var values: [String: String] = [:]
    for field in line.split(separator: " ") {
      let parts = field.split(separator: "=", maxSplits: 1)
      if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
    }
    guard let package = values["packageInventorySHA256"], let source = values["sourceInventorySHA256"],
      let release = values["releaseInventorySHA256"], let singBox = values["singBoxIdentity"] else {
      throw NativeContainersLinuxImageBuilderError.provisioningEvidenceMissing
    }
    return (package, source, release, singBox)
  }
  private func sealCandidate(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw NativeContainersLinuxImageBuilderError.ioFailure(String(cString: strerror(errno)))
    }
    defer { close(descriptor) }
    var identity = stat()
    guard fstat(descriptor, &identity) == 0,
      (identity.st_mode & S_IFMT) == S_IFREG,
      identity.st_uid == geteuid(),
      fchmod(descriptor, 0o400) == 0,
      fsync(descriptor) == 0,
      fstat(descriptor, &identity) == 0,
      mode_t(identity.st_mode & 0o7777) == 0o400
    else {
      throw NativeContainersLinuxImageBuilderError.ioFailure(String(cString: strerror(errno)))
    }
    try synchronizeParentDirectory(of: url)
  }
  private func makeOwnerWritable(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw NativeContainersLinuxImageBuilderError.ioFailure(String(cString: strerror(errno)))
    }
    defer { close(descriptor) }
    var identity = stat()
    guard fstat(descriptor, &identity) == 0,
      (identity.st_mode & S_IFMT) == S_IFREG,
      identity.st_uid == geteuid(),
      fchmod(descriptor, 0o600) == 0,
      fstat(descriptor, &identity) == 0,
      mode_t(identity.st_mode & 0o7777) == 0o600
    else {
      throw NativeContainersLinuxImageBuilderError.ioFailure(String(cString: strerror(errno)))
    }
  }
  private func prepareOutputDirectory(_ url: URL) throws -> Int32 {
    var before = stat()
    if lstat(url.path, &before) == 0 {
      guard (before.st_mode & S_IFMT) == S_IFDIR else {
        throw NativeContainersLinuxImageBuilderError.privateOutputDirectoryRequired
      }
    } else {
      guard errno == ENOENT else {
        throw NativeContainersLinuxImageBuilderError.ioFailure(String(cString: strerror(errno)))
      }
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw NativeContainersLinuxImageBuilderError.ioFailure(String(cString: strerror(errno)))
    }
    var identity = stat()
    guard fstat(descriptor, &identity) == 0,
      (identity.st_mode & S_IFMT) == S_IFDIR,
      identity.st_uid == geteuid(),
      mode_t(identity.st_mode & 0o7777) == 0o700
    else {
      close(descriptor)
      throw NativeContainersLinuxImageBuilderError.privateOutputDirectoryRequired
    }
    return descriptor
  }
  private func requireAbsentArtifacts(
    _ names: [String],
    directoryDescriptor: Int32
  ) throws {
    for name in names {
      var identity = stat()
      let result = name.withCString {
        fstatat(directoryDescriptor, $0, &identity, AT_SYMLINK_NOFOLLOW)
      }
      guard result != 0, errno == ENOENT else {
        throw NativeContainersLinuxImageBuilderError.outputExists
      }
    }
  }
  private func synchronizeOutputDirectory(
    _ url: URL,
    descriptor: Int32
  ) throws {
    var pathIdentity = stat()
    var descriptorIdentity = stat()
    guard lstat(url.path, &pathIdentity) == 0,
      fstat(descriptor, &descriptorIdentity) == 0,
      pathIdentity.st_dev == descriptorIdentity.st_dev,
      pathIdentity.st_ino == descriptorIdentity.st_ino,
      fsync(descriptor) == 0
    else {
      throw NativeContainersLinuxImageBuilderError.ioFailure(String(cString: strerror(errno)))
    }
  }
  private func synchronizeParentDirectory(of url: URL) throws {
    let descriptor = open(
      url.deletingLastPathComponent().path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw NativeContainersLinuxImageBuilderError.ioFailure(String(cString: strerror(errno)))
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw NativeContainersLinuxImageBuilderError.ioFailure(String(cString: strerror(errno)))
    }
  }
  private func validatePinnedConfiguration() throws { let p = NativeContainersLinuxImageBuildConfiguration.pinned; guard configuration.sourceURL == p.sourceURL, configuration.sourceMetadataURL == p.sourceMetadataURL, configuration.sourceDigestURL == p.sourceDigestURL, configuration.sourceSHA512 == p.sourceSHA512, configuration.snapshotURL == p.snapshotURL, configuration.securitySnapshotURL == p.securitySnapshotURL, configuration.singBoxURL == p.singBoxURL, configuration.singBoxSHA256 == p.singBoxSHA256, configuration.imageID == p.imageID else { throw NativeContainersLinuxImageBuilderError.sourceIdentityMismatch } }
  private func validateCandidate(_ url: URL) throws { guard isRegularFile(url), try fileSize(url) >= 8 * 1_073_741_824 else { throw NativeContainersLinuxImageBuilderError.invalidCandidate } }
  private func sparseGrow(_ url: URL, to size: UInt64) throws { let h = try FileHandle(forWritingTo: url); defer { try? h.close() }; try h.truncate(atOffset: size); try h.synchronize() }
  private func cloneOrCopy(_ source: URL, to destination: URL) throws { if copyfile(source.path, destination.path, nil, UInt32(COPYFILE_CLONE | COPYFILE_ALL)) != 0 { try FileManager.default.copyItem(at: source, to: destination) } }

  private func compress(_ source: URL, to destination: URL) throws {
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw NativeContainersLinuxImageBuilderError.outputExists }
    let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination); defer { try? input.close(); try? output.close() }
    let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1); defer { scratch.deallocate() }
    var stream = compression_stream(dst_ptr: scratch, dst_size: 0, src_ptr: UnsafePointer(scratch), src_size: 0, state: nil)
    guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else { throw NativeContainersLinuxImageBuilderError.compressionFailed }
    defer { compression_stream_destroy(&stream) }; var out = [UInt8](repeating: 0, count: Self.chunkSize)
    while let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty {
      try data.withUnsafeBytes { raw in
        stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!; stream.src_size = raw.count
        repeat {
          let produced = try out.withUnsafeMutableBytes { dst -> Int in
            stream.dst_ptr = dst.bindMemory(to: UInt8.self).baseAddress!; stream.dst_size = dst.count
            let status = compression_stream_process(&stream, 0)
            if status == COMPRESSION_STATUS_ERROR { throw NativeContainersLinuxImageBuilderError.compressionFailed }
            return dst.count - stream.dst_size
          }
          if produced > 0 { try output.write(contentsOf: Data(out[0..<produced])) }
        } while stream.src_size > 0
      }
    }
    var done = false
    while !done {
      stream.src_ptr = UnsafePointer(scratch); stream.src_size = 0
      let produced = try out.withUnsafeMutableBytes { dst -> Int in
        stream.dst_ptr = dst.bindMemory(to: UInt8.self).baseAddress!; stream.dst_size = dst.count
        let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
        done = status == COMPRESSION_STATUS_END
        if status == COMPRESSION_STATUS_ERROR { throw NativeContainersLinuxImageBuilderError.compressionFailed }
        return dst.count - stream.dst_size
      }
      if produced > 0 { try output.write(contentsOf: Data(out[0..<produced])) }
    }
    try output.synchronize()
  }

  private func roundTrip(candidate: URL, compressed: URL) throws {
    guard try fileSize(compressed) < 2 * 1_073_741_824 else {
      throw NativeContainersLinuxImageBuilderError.compressedTooLarge
    }
    let expectedSize = try fileSize(candidate)
    guard expectedSize <= 64 * 1_073_741_824 else {
      throw NativeContainersLinuxImageBuilderError.decompressedTooLarge
    }
    let outputURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-roundtrip-\(UUID().uuidString).raw")
    defer { try? FileManager.default.removeItem(at: outputURL) }
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let input = try FileHandle(forReadingFrom: compressed)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? input.close(); try? output.close() }
    let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    defer { scratch.deallocate() }
    var stream = compression_stream(
      dst_ptr: scratch,
      dst_size: 0,
      src_ptr: UnsafePointer(scratch),
      src_size: 0,
      state: nil)
    guard compression_stream_init(
      &stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK
    else {
      throw NativeContainersLinuxImageBuilderError.compressionFailed
    }
    defer { compression_stream_destroy(&stream) }
    var outputBuffer = [UInt8](repeating: 0, count: Self.chunkSize)
    var ended = false
    var logicalOffset: UInt64 = 0

    func process(_ flags: Int32) throws -> (produced: Int, status: compression_status) {
      let result = outputBuffer.withUnsafeMutableBytes { destination
        -> (produced: Int, status: compression_status) in
        stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
        stream.dst_size = destination.count
        let status = compression_stream_process(&stream, flags)
        return (destination.count - stream.dst_size, status)
      }
      guard result.status != COMPRESSION_STATUS_ERROR else {
        throw NativeContainersLinuxImageBuilderError.compressionFailed
      }
      if result.produced > 0 {
        guard logicalOffset <= expectedSize,
          UInt64(result.produced) <= expectedSize - logicalOffset
        else {
          throw NativeContainersLinuxImageBuilderError.decompressedTooLarge
        }
        let chunk = Data(outputBuffer[0..<result.produced])
        if chunk.allSatisfy({ $0 == 0 }) {
          try output.seek(toOffset: logicalOffset + UInt64(result.produced))
        } else {
          if output.offsetInFile != logicalOffset {
            try output.seek(toOffset: logicalOffset)
          }
          try output.write(contentsOf: chunk)
        }
        logicalOffset += UInt64(result.produced)
      }
      return result
    }

    while !ended, let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty {
      try data.withUnsafeBytes { source in
        stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
        stream.src_size = source.count
        var produced = 0
        repeat {
          let sourceBytesBefore = stream.src_size
          let result = try process(0)
          produced = result.produced
          if result.status == COMPRESSION_STATUS_END {
            guard stream.src_size == 0 else {
              throw NativeContainersLinuxImageBuilderError.trailingCompressedData
            }
            ended = true
            break
          }
          if result.produced == 0, stream.src_size == sourceBytesBefore {
            guard stream.src_size == 0 else {
              throw NativeContainersLinuxImageBuilderError.compressionFailed
            }
            break
          }
        } while stream.src_size > 0 || produced == outputBuffer.count
      }
    }

    if !ended {
      stream.src_ptr = UnsafePointer(scratch)
      stream.src_size = 0
      repeat {
        let result = try process(Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
        if result.status == COMPRESSION_STATUS_END {
          ended = true
          break
        }
        guard result.produced > 0 else {
          throw NativeContainersLinuxImageBuilderError.compressionFailed
        }
      } while !ended
    }

    if ended, let trailing = try input.read(upToCount: 1), !trailing.isEmpty {
      throw NativeContainersLinuxImageBuilderError.trailingCompressedData
    }
    guard ended, logicalOffset == expectedSize else {
      throw NativeContainersLinuxImageBuilderError.roundTripMismatch
    }
    try output.truncate(atOffset: expectedSize)
    try output.synchronize()
    guard try fileSize(outputURL) == expectedSize,
      try digest(outputURL, algorithm: .sha512) == digest(candidate, algorithm: .sha512)
    else {
      throw NativeContainersLinuxImageBuilderError.roundTripMismatch
    }
  }

  private func digest(_ url: URL, algorithm: DigestAlgorithm) throws -> String { let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }; var a = SHA256(), b = SHA512(); while let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty { switch algorithm { case .sha256: a.update(data: data); case .sha512: b.update(data: data) } }; switch algorithm { case .sha256: return a.finalize().map { String(format: "%02x", $0) }.joined(); case .sha512: return b.finalize().map { String(format: "%02x", $0) }.joined() } }
  private func fileSize(_ url: URL) throws -> UInt64 { let values = try url.resourceValues(forKeys: [.fileSizeKey]); guard let size = values.fileSize, size >= 0 else { throw NativeContainersLinuxImageBuilderError.invalidCandidate }; return UInt64(size) }
  private func isRegularFile(_ url: URL) -> Bool { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue }
  private func isDirectory(_ url: URL) -> Bool { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue }

  private enum DigestAlgorithm { case sha256, sha512 }
  private func runDownloadProcess(
    _ executable: URL,
    arguments: [String],
    timeoutNanoseconds: UInt64
  ) async throws {
    let state = BuilderDownloadProcessState(executable: executable, arguments: arguments)
    try await withTaskCancellationHandler(operation: {
      try Task.checkCancellation()
      try state.start()
      try await withThrowingTaskGroup(of: Int32.self) { group in
        group.addTask {
          try await state.waitForExit()
        }
        group.addTask {
          try await Task.sleep(for: .nanoseconds(Int64(timeoutNanoseconds)))
          throw BuilderDownloadTimeout()
        }
        do {
          guard let status = try await group.next() else {
            throw BuilderDownloadTimeout()
          }
          group.cancelAll()
          try? await group.waitForAll()
          try Task.checkCancellation()
          guard status == 0 else {
            throw NativeContainersLinuxImageBuilderError.commandFailed(
              executable.path,
              status
            )
          }
        } catch {
          let cancelled = Task.isCancelled || error is CancellationError
          state.requestTermination()
          group.cancelAll()
          try? await group.waitForAll()
          if cancelled {
            throw CancellationError()
          }
          if error is BuilderDownloadTimeout {
            throw NativeContainersLinuxImageBuilderError.commandFailed(
              executable.path,
              state.terminationStatus ?? -1
            )
          }
          throw error
        }
      }
    }, onCancel: {
      state.requestTermination()
    })
  }

  private func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval) throws {
    let process = Process(); process.executableURL = executable; process.arguments = arguments; process.standardInput = FileHandle.nullDevice; let output = Pipe(); process.standardOutput = output; process.standardError = output
    try process.run(); let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }; DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer); process.waitUntilExit(); timer.cancel(); guard process.terminationStatus == 0 else { throw NativeContainersLinuxImageBuilderError.commandFailed(executable.path, process.terminationStatus) }
  }
}
private struct BuilderDownloadTimeout: Error {}

private final class BuilderDownloadProcessState: @unchecked Sendable {
  private static let terminationGraceNanoseconds: UInt64 = 250_000_000
  private let process: Process
  private let lock = NSLock()
  private var ownedProcessIdentifier: Int32?
  private var terminationRequested = false
  private var escalationDeadline: UInt64?
  private var escalated = false
  private var reapedStatusValue: Int32?
  private var waiter: CheckedContinuation<Int32, Error>?

  init(executable: URL, arguments: [String]) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    self.process = process
  }

  var terminationStatus: Int32? {
    lock.lock()
    defer { lock.unlock() }
    return reapedStatusValue
  }

  func start() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !terminationRequested else {
      throw CancellationError()
    }
    try process.run()
    ownedProcessIdentifier = process.processIdentifier
    DispatchQueue.global(qos: .utility).async { [weak self] in
      self?.monitorAndReap()
    }
  }

  func waitForExit() async throws -> Int32 {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Int32, Error>) in
        install(waiter: continuation)
      }
    }, onCancel: {
      requestTermination()
    })
  }

  func requestTermination() {
    lock.lock()
    defer { lock.unlock() }
    guard reapedStatusValue == nil, !terminationRequested else {
      return
    }
    terminationRequested = true
    escalationDeadline = DispatchTime.now().uptimeNanoseconds
      + Self.terminationGraceNanoseconds
    if ownedProcessIdentifier != nil, process.isRunning {
      process.terminate()
    }
  }

  private func install(waiter: CheckedContinuation<Int32, Error>) {
    var status: Int32?
    lock.lock()
    if let reapedStatusValue {
      status = reapedStatusValue
    } else {
      self.waiter = waiter
    }
    lock.unlock()
    if let status {
      waiter.resume(returning: status)
    }
  }

  private func monitorAndReap() {
    while true {
      lock.lock()
      let running = process.isRunning
      var shouldEscalate = false
      if terminationRequested,
        !escalated,
        let escalationDeadline,
        DispatchTime.now().uptimeNanoseconds >= escalationDeadline
      {
        escalated = true
        shouldEscalate = true
        if let processIdentifier = ownedProcessIdentifier,
          processIdentifier > 0,
          running,
          process.processIdentifier == processIdentifier
        {
          _ = Darwin.kill(processIdentifier, SIGKILL)
        }
      }
      lock.unlock()
      if !running {
        break
      }
      if !shouldEscalate {
        usleep(10_000)
      }
    }
    process.waitUntilExit()
    recordReaped(status: process.terminationStatus)
  }

  private func recordReaped(status: Int32) {
    var waiter: CheckedContinuation<Int32, Error>?
    lock.lock()
    guard reapedStatusValue == nil else {
      lock.unlock()
      return
    }
    reapedStatusValue = status
    waiter = self.waiter
    self.waiter = nil
    lock.unlock()
    waiter?.resume(returning: status)
  }
}



private final class BuilderSerialCapture: @unchecked Sendable {
  private var bytes = Data()
  private let lock = NSLock()
  func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    let maximumBytes = 8 * 1_024 * 1_024
    bytes.append(data)
    if bytes.count > maximumBytes {
      bytes.removeFirst(bytes.count - maximumBytes)
    }
  }
  func contains(_ marker: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return bytes.range(of: Data(marker.utf8)) != nil
  }
}

private final class BuilderPipeManager: @unchecked Sendable {
  private let condition = NSCondition()
  private let capture: BuilderSerialCapture
  private let pipe: Pipe
  private var readabilityHandlerActive = true
  private var isWriteClosed = false
  private var isReadClosed = false
  private var inFlightCallbackCount = 0

  init(pipe: Pipe, capture: BuilderSerialCapture) {
    self.pipe = pipe
    self.capture = capture
  }

  func setupReadabilityHandler() {
    let condition = self.condition
    let capture = self.capture
    let pipe = self.pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      guard let self = self else { return }
      condition.lock()
      guard self.readabilityHandlerActive else {
        condition.unlock()
        return
      }
      self.inFlightCallbackCount += 1
      condition.unlock()

      let data = try? handle.read(upToCount: 64 * 1024)

      condition.lock()
      if let data = data, !data.isEmpty {
        capture.append(data)
      }
      self.inFlightCallbackCount -= 1
      if self.inFlightCallbackCount == 0 {
        condition.broadcast()
      }
      condition.unlock()
    }
  }

  func stopReadabilityHandler() {
    condition.lock()
    defer { condition.unlock() }
    guard readabilityHandlerActive else { return }
    readabilityHandlerActive = false
    pipe.fileHandleForReading.readabilityHandler = nil
  }

  func closeWriteEnd() {
    condition.lock()
    defer { condition.unlock() }
    guard !isWriteClosed else { return }
    isWriteClosed = true
    try? pipe.fileHandleForWriting.close()
  }

  func drainPipe(strictByteBound: Bool, vmStopped: Bool) {
    stopReadabilityHandler()
    guard vmStopped else { return }

    condition.lock()
    while inFlightCallbackCount > 0 {
      condition.wait()
    }

    let maxBytes = strictByteBound ? (1 * 1024 * 1024) : (8 * 1024 * 1024)
    var bytesRead = 0
    while bytesRead < maxBytes {
      condition.unlock()
      let data = try? pipe.fileHandleForReading.read(upToCount: min(64 * 1024, maxBytes - bytesRead))
      condition.lock()

      guard let validData = data, !validData.isEmpty else {
        break
      }
      self.capture.append(validData)
      bytesRead += validData.count
    }
    condition.unlock()
  }

  func cleanup(vmStopped: Bool) {
    guard vmStopped else { return }
    stopReadabilityHandler()
    closeWriteEnd()
    drainPipe(strictByteBound: true, vmStopped: vmStopped)
    condition.lock()
    defer { condition.unlock() }
    guard !isReadClosed else { return }
    isReadClosed = true
    try? pipe.fileHandleForReading.close()
  }
}
private final class RunnerState: @unchecked Sendable {
  private let lock = NSLock()
  private var _started = false
  private var _stopped = false
  private var _stopError: (any Error)?
  private var _hostStopError: (any Error)?

  var started: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _started
  }

  var stopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _stopped
  }

  var stopError: (any Error)? {
    lock.lock()
    defer { lock.unlock() }
    return _stopError
  }

  var hostStopError: (any Error)? {
    lock.lock()
    defer { lock.unlock() }
    return _hostStopError
  }

  func recordStart() {
    lock.lock()
    defer { lock.unlock() }
    _started = true
  }

  func recordStop() {
    lock.lock()
    defer { lock.unlock() }
    _stopped = true
  }

  func recordStopWithError(_ error: any Error) {
    lock.lock()
    defer { lock.unlock() }
    _stopped = true
    _stopError = error
  }

  func recordHostStopError(_ error: any Error) {
    lock.lock()
    defer { lock.unlock() }
    _hostStopError = error
  }
}

@MainActor
private final class BuilderVirtualizationRunner: NSObject, VZVirtualMachineDelegate {
  @MainActor
  fileprivate static var activeRunners = Set<BuilderVirtualizationRunner>()


  private let capture = BuilderSerialCapture()
  let state = RunnerState()
  var pipeManager: BuilderPipeManager?
  private var vm: VZVirtualMachine?
  fileprivate var deferPipeCleanup = false

  nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    state.recordStop()
    Task { @MainActor in
      self.cleanupPipe()
    }
  }

  nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
    state.recordStopWithError(error)
    Task { @MainActor in
      self.cleanupPipe()
    }
  }

  fileprivate func releaseAfterFailedStop() {
    pipeManager?.stopReadabilityHandler()
    pipeManager?.closeWriteEnd()
    pipeManager = nil
    vm = nil
    Self.activeRunners.remove(self)
  }
  fileprivate func cleanupPipe() {
    guard !deferPipeCleanup else { return }
    let vmStopped = !self.state.started || self.state.stopped
    if let manager = self.pipeManager {
      manager.cleanup(vmStopped: vmStopped)
    }
    if vmStopped {
      self.pipeManager = nil
      self.vm = nil
      Self.activeRunners.remove(self)
    }
  }

  static func run(raw: URL, seed: URL, nvramDirectory: URL, socket: Bool, marker: String, timeout: TimeInterval) async throws -> String {
    let runner = BuilderVirtualizationRunner(); let fm = FileManager.default
    Self.activeRunners.insert(runner)
    defer { runner.cleanupPipe() }
    try fm.createDirectory(at: nvramDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let platform = VZGenericPlatformConfiguration(); platform.machineIdentifier = VZGenericMachineIdentifier()
    let boot = VZEFIBootLoader(); boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: nvramDirectory.appending(path: "efivars.nvram"))
    let root = try VZDiskImageStorageDeviceAttachment(url: raw, readOnly: false); let seedAttachment = try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)
    let config = VZVirtualMachineConfiguration(); config.platform = platform; config.bootLoader = boot; config.cpuCount = 2; config.memorySize = 2 * 1_073_741_824
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: root), VZVirtioBlockDeviceConfiguration(attachment: seedAttachment)]
    let network = VZVirtioNetworkDeviceConfiguration(); network.attachment = VZNATNetworkDeviceAttachment()
    config.networkDevices = [network]; config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]; config.consoleDevices = [makeSerial(runner)]
    if socket { config.socketDevices = [VZVirtioSocketDeviceConfiguration()] }; try config.validate()
    let vm = VZVirtualMachine(configuration: config); vm.delegate = runner; runner.vm = vm; try await start(vm); runner.state.recordStart()
    defer {
      if vm.state == .stopped || runner.state.stopped {
        vm.delegate = nil
        runner.vm = nil
      }
    }
    var fallbackAttempted = false
    var diagnosticEmitted = false
    var deadlineExpired = false
    do {
      let clock = ContinuousClock()
      let startInstant = clock.now
      let deadline = startInstant.advanced(by: .seconds(timeout))
      while clock.now < deadline {
        try Task.checkCancellation()
        if runner.capture.contains(marker) || vm.state == .stopped || runner.state.stopped { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      if !runner.capture.contains(marker) && vm.state != .stopped && !runner.state.stopped && clock.now >= deadline {
        try Task.checkCancellation()
        deadlineExpired = true
      }
      if runner.capture.contains(marker) {
        while clock.now < deadline {
          try Task.checkCancellation()
          if vm.state == .stopped || runner.state.stopped { break }
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        if vm.state != .stopped && !runner.state.stopped && clock.now >= deadline {
          try Task.checkCancellation()
          deadlineExpired = true
        }
      }
      let guestStopped = (vm.state == .stopped || runner.state.stopped)
      let confirmed: Bool
      if guestStopped {
        confirmed = true
      } else {
        fallbackAttempted = true
        confirmed = await Self.waitTerminal(vm, runner: runner)
      }
      guard confirmed else {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: marker, vmState: vm.state, deadlineExpired: deadlineExpired)
          diagnosticEmitted = true
        }
        throw NativeContainersLinuxImageBuilderError.ioFailure("Stop confirmation failed")
      }
      runner.pipeManager?.closeWriteEnd()
      runner.pipeManager?.drainPipe(strictByteBound: false, vmStopped: true)
      let containsMarker = runner.capture.contains(marker)
      if let stopError = runner.state.stopError ?? runner.state.hostStopError {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: marker, vmState: vm.state, deadlineExpired: deadlineExpired)
          diagnosticEmitted = true
        }
        throw NativeContainersLinuxImageBuilderError.ioFailure(Self.formatStopError(stopError))
      }
      guard containsMarker else {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: marker, vmState: vm.state, deadlineExpired: deadlineExpired)
          diagnosticEmitted = true
        }
        throw NativeContainersLinuxImageBuilderError.bootMarkerMissing(marker)
      }
      return runner.capture.text()
    } catch {
      if !fallbackAttempted {
        fallbackAttempted = true
        let confirmed = await Self.waitTerminal(vm, runner: runner)
        if confirmed {
          runner.pipeManager?.closeWriteEnd()
          runner.pipeManager?.drainPipe(strictByteBound: true, vmStopped: true)
        }
        if !confirmed {
          if !diagnosticEmitted {
            runner.reportDiagnostic(marker: marker, vmState: vm.state, deadlineExpired: deadlineExpired)
            diagnosticEmitted = true
          }
          throw NativeContainersLinuxImageBuilderError.ioFailure("Stop confirmation failed")
        }
      }
      if let stopError = runner.state.stopError ?? runner.state.hostStopError {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: marker, vmState: vm.state, deadlineExpired: deadlineExpired)
          diagnosticEmitted = true
        }
        throw NativeContainersLinuxImageBuilderError.ioFailure(Self.formatStopError(stopError))
      }
      if !runner.capture.contains(marker) {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: marker, vmState: vm.state, deadlineExpired: deadlineExpired)
          diagnosticEmitted = true
        }
      }
      throw error
    }
  }

  static func validateSeedless(raw: URL, nvramDirectory: URL, readinessTimeout: TimeInterval, protocolTimeout: TimeInterval) async throws {
    var lastSeedlessStep = "connect"
    var lastSeedlessError: (category: String, code: Int)?
    var lastSeedlessVMStateBefore = Self.formatVMState(.stopped)
    var lastSeedlessVMStateAfter = Self.formatVMState(.stopped)
    let runner = BuilderVirtualizationRunner(); let fm = FileManager.default
    Self.activeRunners.insert(runner)
    defer {
      runner.deferPipeCleanup = false
      runner.cleanupPipe()
    }
    try fm.createDirectory(at: nvramDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let platform = VZGenericPlatformConfiguration(); platform.machineIdentifier = VZGenericMachineIdentifier()
    let boot = VZEFIBootLoader(); boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: nvramDirectory.appending(path: "efivars.nvram"))
    let root = try VZDiskImageStorageDeviceAttachment(url: raw, readOnly: false)
    guard try raw.resourceValues(forKeys: [.fileSizeKey]).fileSize == 32 * 1_073_741_824 else { throw NativeContainersLinuxImageBuilderError.validationFailed("validation clone is not 32 GiB") }
    let config = VZVirtualMachineConfiguration(); config.platform = platform; config.bootLoader = boot; config.cpuCount = 2; config.memorySize = 2 * 1_073_741_824
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: root)]
    let network = VZVirtioNetworkDeviceConfiguration(); network.attachment = VZNATNetworkDeviceAttachment()
    config.networkDevices = [network]; config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]; config.consoleDevices = [makeSerial(runner)]; config.socketDevices = [VZVirtioSocketDeviceConfiguration()]; try config.validate()
    let vm = VZVirtualMachine(configuration: config); vm.delegate = runner; runner.vm = vm; try await start(vm); runner.state.recordStart()
    defer {
      if vm.state == .stopped || runner.state.stopped {
        vm.delegate = nil
        runner.vm = nil
      }
    }
    var terminalHandled = false
    var diagnosticEmitted = false
    do {
      let clock = ContinuousClock()
      let readinessDeadline = clock.now.advanced(by: .seconds(readinessTimeout))
      let protocolDuration = protocolTimeout
      var protocolDeadline: ContinuousClock.Instant?
      func requireProtocolTime() throws {
        if let protocolDeadline, clock.now >= protocolDeadline {
          throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
        }
      }
      guard vm.state == .running && !runner.state.stopped else {
        throw NativeContainersLinuxImageBuilderError.validationFailed("seedless validation VM is not running before guest agent connection")
      }
      guard let device = vm.socketDevices.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
        throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
      }
      var status: [String: Any]?
      while status == nil {
        let deadline = protocolDeadline ?? readinessDeadline
        guard clock.now < deadline else { break }
        try Task.checkCancellation()
        do {
          lastSeedlessStep = "connect"
          lastSeedlessVMStateBefore = Self.formatVMState(vm.state)
          let ownedConnection = try await Self.connect(device: device, deadline: deadline)
          if protocolDeadline == nil, clock.now >= readinessDeadline {
            ownedConnection.close()
            throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
          }
          if protocolDeadline == nil {
            protocolDeadline = clock.now.advanced(by: .seconds(protocolDuration))
          }
          defer { ownedConnection.close() }
          let descriptor = ownedConnection.fileDescriptor
          try BuilderGuestProtocol.configureDescriptor(descriptor)
          var challengeBytes = [UInt8](repeating: 0, count: 32)
          var random = SystemRandomNumberGenerator()
          for index in challengeBytes.indices {
            challengeBytes[index] = UInt8.random(in: .min ... .max, using: &random)
          }
          let challenge = Data(challengeBytes).base64EncodedString()
          lastSeedlessStep = "hello-exchange"
          try requireProtocolTime()
          let helloRequest = try BuilderGuestProtocol.helloRequest(challenge: challenge)
          let helloPayload = try await Self.exchange(
            ownedConnection,
            descriptor: descriptor,
            request: helloRequest.data,
            deadline: protocolDeadline!
          )
          try requireProtocolTime()
          lastSeedlessStep = "hello-decode"
          let hello = try BuilderGuestProtocol.decodeResponse(
            helloPayload,
            requestID: helloRequest.id
          )
          lastSeedlessStep = "hello-validation"
          guard let helloData = hello["data"] as? [String: Any],
            helloData["protocol"] as? Int == NativeContainersLinuxImageBuildConfiguration.pinned.guestAgentProtocolVersion,
            helloData["imageID"] as? String
              == NativeContainersLinuxImageBuildConfiguration.pinned.imageID,
            helloData["imageBuildRevision"] as? String
              == NativeContainersLinuxImageBuildConfiguration.pinned.imageBuildRevision,
            helloData["challenge"] as? String == challenge,
            let bootID = helloData["bootID"] as? String,
            UUID(uuidString: bootID)?.uuidString.lowercased() == bootID
          else {
            throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
          }
          lastSeedlessStep = "status-exchange"
          try requireProtocolTime()
          let statusRequest = try BuilderGuestProtocol.statusRequest()
          let statusPayload = try await Self.exchange(
            ownedConnection,
            descriptor: descriptor,
            request: statusRequest.data,
            deadline: protocolDeadline!
          )
          try requireProtocolTime()
          lastSeedlessStep = "status-decode"
          let response = try BuilderGuestProtocol.decodeResponse(
            statusPayload,
            requestID: statusRequest.id
          )
          try requireProtocolTime()
          lastSeedlessStep = "status-data-extraction"
          guard let statusData = response["data"] as? [String: Any] else {
            throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
          }
          runner.deferPipeCleanup = true
          lastSeedlessStep = "shutdown-exchange"
          try requireProtocolTime()
          let shutdownRequest = try BuilderGuestProtocol.shutdownRequest()
          let shutdownPayload = try await Self.exchange(
            ownedConnection,
            descriptor: descriptor,
            request: shutdownRequest.data,
            deadline: protocolDeadline!
          )
          try requireProtocolTime()
          lastSeedlessStep = "shutdown-decode"
          let shutdownResponse = try BuilderGuestProtocol.decodeResponse(
            shutdownPayload,
            requestID: shutdownRequest.id
          )
          lastSeedlessStep = "shutdown-validation"
          guard let shutdownData = shutdownResponse["data"] as? [String: Any],
            shutdownData["accepted"] as? Bool == true
          else {
            throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
          }
          terminalHandled = true
          let cleanStopConfirmed = await Self.waitForCleanStop(vm, runner: runner)
          if !cleanStopConfirmed {
            let hostStopConfirmed = await Self.waitTerminal(vm, runner: runner)
            if hostStopConfirmed {
              runner.pipeManager?.closeWriteEnd()
              runner.pipeManager?.drainPipe(strictByteBound: true, vmStopped: true)
            }
            else {
              runner.releaseAfterFailedStop()
            }
            runner.deferPipeCleanup = false
            runner.cleanupPipe()
            throw NativeContainersLinuxImageBuilderError.validationFailed("guest shutdown was not cleanly observed")
          }
          runner.pipeManager?.closeWriteEnd()
          runner.pipeManager?.drainPipe(strictByteBound: false, vmStopped: true)
          runner.deferPipeCleanup = false
          runner.cleanupPipe()
          status = statusData
          break
        } catch {
          lastSeedlessVMStateAfter = Self.formatVMState(vm.state)
          if error is CancellationError {
            throw error
          }
          if terminalHandled {
            throw error
          }
          lastSeedlessError = Self.seedlessErrorDiagnostic(error)
          let retryDeadline = protocolDeadline ?? readinessDeadline
          if clock.now < retryDeadline {
            try await Task.sleep(nanoseconds: 500_000_000)
          }
        }
      }
      guard let status else {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: NativeContainersLinuxImageBuilder.rootCapacityProofMarker, vmState: vm.state)
          diagnosticEmitted = true
        }
        let errorDetail = lastSeedlessError.map { "error=\($0.category):\($0.code)" } ?? "error=none"
        throw NativeContainersLinuxImageBuilderError.validationFailed(
          "seedless hello/status unavailable step=\(lastSeedlessStep) \(errorDetail) vmBefore=\(lastSeedlessVMStateBefore) vmAfter=\(lastSeedlessVMStateAfter)"
        )
      }
      guard runner.capture.contains(NativeContainersLinuxImageBuilder.rootCapacityProofMarker) else {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: NativeContainersLinuxImageBuilder.rootCapacityProofMarker, vmState: vm.state)
          diagnosticEmitted = true
        }
        throw NativeContainersLinuxImageBuilderError.validationFailed("root filesystem did not prove 32 GiB expansion after clean guest shutdown")
      }
      guard status["state"] as? String == "awaitingConfiguration",
        status["baselineActive"] as? Bool == true,
        status["authorizationActive"] as? Bool == false,
        status["networkdActive"] as? Bool == false,
        status["singBoxActive"] as? Bool == false
      else {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: NativeContainersLinuxImageBuilder.rootCapacityProofMarker, vmState: vm.state)
          diagnosticEmitted = true
        }
        throw NativeContainersLinuxImageBuilderError.validationFailed(Self.formatSeedlessBaseline(status))
      }
      if let stopError = runner.state.stopError ?? runner.state.hostStopError {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: NativeContainersLinuxImageBuilder.rootCapacityProofMarker, vmState: vm.state)
          diagnosticEmitted = true
        }
        throw NativeContainersLinuxImageBuilderError.ioFailure(Self.formatStopError(stopError))
      }

    } catch {
      if !terminalHandled {
        terminalHandled = true
        let confirmed = await Self.waitTerminal(vm, runner: runner)
        if confirmed {
          runner.pipeManager?.closeWriteEnd()
          runner.pipeManager?.drainPipe(strictByteBound: true, vmStopped: true)
        }
        else {
          runner.releaseAfterFailedStop()
        }
        if !confirmed, runner.state.stopError == nil, runner.state.hostStopError == nil {
          if !diagnosticEmitted {
            runner.reportDiagnostic(marker: NativeContainersLinuxImageBuilder.rootCapacityProofMarker, vmState: vm.state)
            diagnosticEmitted = true
          }
          throw NativeContainersLinuxImageBuilderError.ioFailure("Stop confirmation failed")
        }
      }
      let stopError = runner.state.stopError ?? runner.state.hostStopError
      if let stopError = stopError {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: NativeContainersLinuxImageBuilder.rootCapacityProofMarker, vmState: vm.state)
          diagnosticEmitted = true
        }
        throw NativeContainersLinuxImageBuilderError.ioFailure(Self.formatStopError(stopError))
      }
      if !runner.capture.contains(NativeContainersLinuxImageBuilder.rootCapacityProofMarker) {
        if !diagnosticEmitted {
          runner.reportDiagnostic(marker: NativeContainersLinuxImageBuilder.rootCapacityProofMarker, vmState: vm.state)
          diagnosticEmitted = true
        }
      }
      throw error
    }
  }

  private static func connect(
    device: VZVirtioSocketDevice,
    deadline: ContinuousClock.Instant
  ) async throws -> BuilderSocketConnectionHolder {
    let state = BuilderSocketConnectState()
    let timeoutTask = Task.detached(priority: nil) { [state] in
      let remaining = ContinuousClock.now.duration(to: deadline)
      guard remaining > .zero else {
        state.timeout()
        return
      }
      do {
        try await Task.sleep(for: remaining)
        state.timeout()
      } catch {
      }
    }
    let result: Result<BuilderSocketConnectionHolder, Error> = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Result<BuilderSocketConnectionHolder, Error>, Never>) in
        state.install(continuation)
        state.start(device: device)
      }
    } onCancel: {
      state.cancel()
    }
    timeoutTask.cancel()
    _ = await timeoutTask.result
    if Task.isCancelled {
      if case .success(let connection) = result {
        connection.close()
      }
      throw CancellationError()
    }
    guard ContinuousClock.now < deadline else {
      if case .success(let connection) = result {
        connection.close()
      }
      throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
    }
    return try result.get()
  }

  private static func exchange(
    _ ownedConnection: BuilderSocketConnectionHolder,
    descriptor: Int32,
    request: Data,
    deadline: ContinuousClock.Instant
  ) async throws -> Data {
    let exchangeTask = Task.detached(priority: nil) {
      try BuilderGuestProtocol.exchange(descriptor, request: request, deadline: deadline)
    }
    let timeoutTask = Task.detached(priority: nil) {
      let remaining = ContinuousClock.now.duration(to: deadline)
      guard remaining > .zero else {
        BuilderGuestProtocol.interrupt(descriptor)
        return
      }
      do {
        try await Task.sleep(for: remaining)
        BuilderGuestProtocol.interrupt(descriptor)
      } catch {
      }
    }
    let result = await withTaskCancellationHandler {
      await exchangeTask.result
    } onCancel: {
      BuilderGuestProtocol.interrupt(descriptor)
    }
    timeoutTask.cancel()
    _ = await timeoutTask.result
    do {
      if Task.isCancelled {
        throw CancellationError()
      }
      guard ContinuousClock.now < deadline else {
        throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
      }
      return try result.get()
    } catch {
      ownedConnection.close()
      throw error
    }
  }


  private static func makeSerial(_ runner: BuilderVirtualizationRunner) -> VZVirtioConsoleDeviceConfiguration {
    let pipe = Pipe()
    let manager = BuilderPipeManager(pipe: pipe, capture: runner.capture)
    runner.pipeManager = manager
    manager.setupReadabilityHandler()
    let attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: pipe.fileHandleForWriting)
    let port = VZVirtioConsolePortConfiguration()
    port.name = "builder-serial"
    port.isConsole = true
    port.attachment = attachment
    let console = VZVirtioConsoleDeviceConfiguration()
    console.ports[0] = port
    return console
  }

  private static func start(_ vm: VZVirtualMachine) async throws { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in vm.start { result in continuation.resume(with: result) } } }
  private static func waitForCleanStop(_ vm: VZVirtualMachine, runner: BuilderVirtualizationRunner) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while clock.now < deadline {
      if runner.state.stopError != nil || runner.state.hostStopError != nil {
        return false
      }
      if vm.state == .stopped || runner.state.stopped {
        return true
      }
      _ = await Task.detached {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }.value
    }
    return (vm.state == .stopped || runner.state.stopped)
      && runner.state.stopError == nil
      && runner.state.hostStopError == nil
  }
  @discardableResult
  private static func waitTerminal(_ vm: VZVirtualMachine, runner: BuilderVirtualizationRunner) async -> Bool {
    if vm.state != .stopped {
      vm.stop { [weak runner] error in
        Task { @MainActor [weak runner] in
          if let error = error {
            runner?.state.recordHostStopError(error)
          } else {
            runner?.state.recordStop()
          }
          runner?.cleanupPipe()
        }
      }
    }
    let clock = ContinuousClock()
    let start = clock.now
    let deadline = start.advanced(by: .seconds(30))
    while clock.now < deadline {
      if runner.state.hostStopError != nil {
        return false
      }
      if vm.state == .stopped || runner.state.stopped {
        return true
      }
      _ = await Task.detached {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }.value
    }
    return vm.state == .stopped || runner.state.stopped
  }
  private static func formatVMState(_ state: VZVirtualMachine.State) -> String {
    switch state {
    case .stopped: return "stopped"
    case .running: return "running"
    case .starting: return "starting"
    case .pausing: return "pausing"
    case .paused: return "paused"
    case .resuming: return "resuming"
    case .stopping: return "stopping"
    case .error: return "error"
    case .saving: return "saving"
    case .restoring: return "restoring"
    @unknown default: return "unknown"
    }
  }

  private static func formatStopError(_ error: (any Error)?) -> String {
    guard let error = error else { return "None" }
    let nsError = error as NSError
    return "Error(domain: \(nsError.domain), code: \(nsError.code))"
  }
  private static func seedlessErrorDiagnostic(_ error: any Error) -> (category: String, code: Int) {
    let nsError = error as NSError
    let category: String
    switch nsError.domain {
    case "VZErrorDomain": category = "vz"
    case NSPOSIXErrorDomain: category = "posix"
    case NSCocoaErrorDomain: category = "cocoa"
    default: category = "other"
    }
    return (category: category, code: nsError.code)
  }

  private static func formatSeedlessBaseline(_ status: [String: Any]) -> String {
    let state = formatSeedlessStringField(status["state"])
    let baselineActive = formatSeedlessBooleanField(status["baselineActive"])
    let authorizationActive = formatSeedlessBooleanField(status["authorizationActive"])
    let networkdActive = formatSeedlessBooleanField(status["networkdActive"])
    let singBoxActive = formatSeedlessBooleanField(status["singBoxActive"])
    return "seedless hello/status baseline state=\(state) baselineActive=\(baselineActive) authorizationActive=\(authorizationActive) networkdActive=\(networkdActive) singBoxActive=\(singBoxActive)"
  }

  private static func formatSeedlessStringField(_ value: Any?) -> String {
    guard let value else { return "missing" }
    guard let value = value as? String else { return "invalid" }
    switch value {
    case "awaitingConfiguration", "authorizing", "healthy", "verifying", "ready", "quiescing", "quiesced", "failed":
      return value
    default:
      return "invalid"
    }
  }

  private static func formatSeedlessBooleanField(_ value: Any?) -> String {
    guard let value else { return "missing" }
    guard let value = value as? Bool else { return "invalid" }
    return value ? "true" : "false"
  }

  private static func escapeTail(_ string: String, maxCharacters: Int) -> String {
    var parts: [String] = []
    var currentLength = 0
    for char in string.reversed() {
      let escaped: String
      switch char {
      case "\\": escaped = "\\\\"
      case "\n": escaped = "\\n"
      case "\r": escaped = "\\r"
      case "\t": escaped = "\\t"
      case "\"": escaped = "\\\""
      default:
        if let ascii = char.asciiValue, ascii >= 32, ascii < 127 {
          escaped = String(char)
        } else {
          var temp = ""
          for scalar in char.unicodeScalars {
            temp.append(String(format: "\\u{%04X}", scalar.value))
          }
          escaped = temp
        }
      }
      if currentLength + escaped.count > maxCharacters {
        break
      }
      parts.append(escaped)
      currentLength += escaped.count
    }
    return parts.reversed().joined()
  }

  private func reportDiagnostic(marker: String, vmState: VZVirtualMachine.State, deadlineExpired: Bool = false) {
    let reason: String
    if deadlineExpired {
      reason = "timeout"
    } else if let _ = self.state.stopError {
      reason = "error"
    } else if self.state.stopped || vmState == .stopped {
      reason = "stopped"
    } else {
      reason = "timeout"
    }
    let rawText = self.capture.text()
    let escapedTail = Self.escapeTail(rawText, maxCharacters: 64 * 1024)
    let diagnostic = """
--- VM Virtualization Runner Diagnostic ---
Marker: \(marker)
Failure Reason: \(reason)
Observed VM Terminal State: \(Self.formatVMState(vmState))
Delegate Stop Error: \(Self.formatStopError(self.state.stopError))
Escaped Serial Tail:
\(escapedTail)
------------------------------------------\n
"""
    if let data = diagnostic.data(using: .utf8) {
      FileHandle.standardError.write(data)
    }
  }
}
private final class BuilderSocketConnectState: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var continuation: CheckedContinuation<Result<BuilderSocketConnectionHolder, Error>, Never>?
  private var result: Result<BuilderSocketConnectionHolder, Error>?

  func install(
    _ continuation: CheckedContinuation<Result<BuilderSocketConnectionHolder, Error>, Never>
  ) {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(returning: result)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  @MainActor
  func start(device: VZVirtioSocketDevice) {
    lock.lock()
    guard result == nil else {
      lock.unlock()
      return
    }
    device.connect(toPort: 4050) { [self] result in
      switch result {
      case .success(let connection):
        resolve(connection: connection)
      case .failure(let error):
        resolve(error: error)
      }
    }
    lock.unlock()
  }

  private func resolve(connection: VZVirtioSocketConnection) {
    lock.lock()
    guard result == nil else {
      lock.unlock()
      connection.close()
      return
    }
    let result: Result<BuilderSocketConnectionHolder, Error> = .success(
      BuilderSocketConnectionHolder(connection))
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: result)
  }

  private func resolve(error: Error) {
    lock.lock()
    guard result == nil else {
      lock.unlock()
      return
    }
    let result: Result<BuilderSocketConnectionHolder, Error> = .failure(error)
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: result)
  }

  func cancel() {
    resolve(error: CancellationError())
  }

  func timeout() {
    resolve(error: NativeContainersLinuxImageBuilderError.guestAgentUnavailable)
  }
}

private final class BuilderSocketConnectionHolder: @unchecked Sendable {
  private let connection: VZVirtioSocketConnection
  private let lock = NSLock()
  private var closed = false

  init(_ connection: VZVirtioSocketConnection) {
    self.connection = connection
  }

  @MainActor
  var fileDescriptor: Int32 {
    connection.fileDescriptor
  }

  @MainActor
  func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    lock.unlock()
    connection.close()
  }
}


private enum BuilderGuestProtocol {
  struct Request: Sendable {
    let id: String
    let data: Data
  }

  static func helloRequest(challenge: String) throws -> Request {
    try makeRequest(operation: "hello", payload: ["challenge": challenge])
  }

  static func statusRequest() throws -> Request {
    try makeRequest(operation: "status", payload: [:])
  }
  static func shutdownRequest() throws -> Request {
    try makeRequest(operation: "shutdown", payload: [:])
  }

  static func configureDescriptor(_ descriptor: Int32) throws {
    let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
    guard descriptorFlags >= 0,
      Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
    else {
      throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
    }
    let statusFlags = Darwin.fcntl(descriptor, F_GETFL)
    guard statusFlags >= 0,
      Darwin.fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0
    else {
      throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
    }
  }
  static func interrupt(_ descriptor: Int32) {
    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
  }

  static func exchange(
    _ descriptor: Int32,
    request: Data,
    deadline: ContinuousClock.Instant
  ) throws -> Data {
    try writeFrame(descriptor, request, deadline: deadline)
    return try readFrame(descriptor, deadline: deadline)
  }

  @MainActor
  static func decodeResponse(_ data: Data, requestID: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let schemaVersion = value["schemaVersion"] as? NSNumber,
      String(cString: schemaVersion.objCType) != "c",
      schemaVersion.doubleValue.rounded() == schemaVersion.doubleValue,
      schemaVersion.intValue == NativeContainersLinuxImageBuildConfiguration.pinned.guestAgentProtocolVersion,
      value["requestID"] as? String == requestID,
      value["ok"] as? Bool == true
    else {
      throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
    }
    return value
  }

  private static func makeRequest(
    operation: String,
    payload: [String: Any]
  ) throws -> Request {
    let id = UUID().uuidString.lowercased()
    let object: [String: Any] = [
      "schemaVersion": NativeContainersLinuxImageBuildConfiguration.pinned.guestAgentProtocolVersion,
      "requestID": id,
      "operation": operation,
      "timeoutSeconds": 30,
      "payload": payload,
    ]
    return Request(
      id: id,
      data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
  }

  private static func writeFrame(
    _ descriptor: Int32,
    _ data: Data,
    deadline: ContinuousClock.Instant
  ) throws {
    guard data.count <= 1_048_576 else {
      throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
    }
    var length = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &length) {
      try writeAll(descriptor, $0, deadline: deadline)
    }
    try data.withUnsafeBytes {
      try writeAll(descriptor, $0, deadline: deadline)
    }
  }

  private static func readFrame(
    _ descriptor: Int32,
    deadline: ContinuousClock.Instant
  ) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 4)
    try readAll(descriptor, &bytes, deadline: deadline)
    let length = bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    guard length > 0, length <= 1_048_576 else {
      throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
    }
    var data = Data(count: Int(length))
    try data.withUnsafeMutableBytes {
      try readAll(descriptor, $0, deadline: deadline)
    }
    return data
  }

  private static func wait(
    _ descriptor: Int32,
    events: Int16,
    deadline: ContinuousClock.Instant
  ) throws {
    while true {
      let timeout = try pollTimeoutMilliseconds(until: deadline)
      var state = pollfd(fd: descriptor, events: events, revents: 0)
      let result = Darwin.poll(&state, 1, timeout)
      if result > 0 {
        guard ContinuousClock.now < deadline else {
          throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
        }
        return
      }
      if result == 0 {
        throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
      }
      if errno != EINTR {
        throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
      }
    }
  }

  private static func pollTimeoutMilliseconds(
    until deadline: ContinuousClock.Instant
  ) throws -> Int32 {
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
    }
    let components = remaining.components
    let seconds = Swift.max(Int64(0), Swift.min(Int64(30), components.seconds))
    let milliseconds = Swift.min(
      Int64(30_000),
      seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    )
    return Int32(milliseconds)
  }

  private static func writeAll(
    _ descriptor: Int32,
    _ bytes: UnsafeRawBufferPointer,
    deadline: ContinuousClock.Instant
  ) throws {
    var offset = 0
    while offset < bytes.count {
      try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
      let result = Darwin.write(
        descriptor,
        bytes.baseAddress!.advanced(by: offset),
        bytes.count - offset
      )
      if result < 0 {
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
      }
      guard result > 0 else {
        throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
      }
      offset += result
    }
  }

  private static func readAll(
    _ descriptor: Int32,
    _ bytes: UnsafeMutableRawBufferPointer,
    deadline: ContinuousClock.Instant
  ) throws {
    var offset = 0
    while offset < bytes.count {
      try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
      let result = Darwin.read(
        descriptor,
        bytes.baseAddress!.advanced(by: offset),
        bytes.count - offset
      )
      if result == 0 {
        throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
      }
      if result < 0 {
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        throw NativeContainersLinuxImageBuilderError.guestAgentUnavailable
      }
      offset += result
    }
  }

  private static func readAll(
    _ descriptor: Int32,
    _ bytes: inout [UInt8],
    deadline: ContinuousClock.Instant
  ) throws {
    try bytes.withUnsafeMutableBytes {
      try readAll(descriptor, $0, deadline: deadline)
    }
  }
}

enum NativeContainersLinuxImageBuilderError: LocalizedError, Equatable, Sendable {
  case guestAssetsMissing([String]), guestContractTestsFailed(Int32), sourceIdentityMismatch, invalidCandidate, outputExists, privateOutputDirectoryRequired, compressionFailed, invalidProvenance, sourceMetadataInvalid, sourceDigestMismatch, downloadFailed(String), commandFailed(String, Int32), ioFailure(String), bootMarkerMissing(String), guestAgentUnavailable, validationFailed(String), roundTripMismatch, compressedTooLarge, decompressedTooLarge, trailingCompressedData, provisioningEvidenceMissing, cancelled
  var errorDescription: String? { switch self {
    case .guestAssetsMissing(let paths): "Required guest image assets are missing: \(paths.joined(separator: ", "))"
    case .guestContractTestsFailed(let status): "Guest contract tests failed with status \(status)."
    case .sourceIdentityMismatch: "The prepared-image source is not the pinned Debian or sing-box source."
    case .invalidCandidate: "The sealed candidate is not a regular sparse image of at least 8 GiB."
    case .outputExists: "The prepared-image output already exists."
    case .privateOutputDirectoryRequired: "The prepared-image output directory must be a current-user-owned mode-0700 directory."
    case .compressionFailed: "The sealed candidate could not be LZFSE compressed."
    case .invalidProvenance: "The prepared-image provenance did not satisfy the release contract."
    case .sourceMetadataInvalid: "The pinned Debian source metadata is not a JSON object."
    case .sourceDigestMismatch: "The downloaded Debian source did not match SHA512SUMS and the pinned SHA-512."
    case .downloadFailed(let url): "The pinned image source could not be downloaded: \(url)"
    case .commandFailed(let command, let status): "Command failed (\(status)): \(command)"
    case .ioFailure(let message): "Image builder I/O failed: \(message)"
    case .bootMarkerMissing(let marker): "Virtualization boot did not emit marker \(marker)."
    case .guestAgentUnavailable: "The seedless validation guest agent was unavailable."
    case .validationFailed(let message): "Seedless validation failed: \(message)"
    case .roundTripMismatch: "LZFSE sparse round-trip did not reproduce the sealed candidate."
    case .compressedTooLarge: "The compressed release asset exceeds the two-GiB limit."
    case .decompressedTooLarge: "The decompressed image exceeded the bounded output limit."
    case .trailingCompressedData: "The compressed release asset contains trailing data."
    case .provisioningEvidenceMissing: "The guest did not emit complete inventory provenance."
    case .cancelled: "The prepared-image build was cancelled."
  } }
}
