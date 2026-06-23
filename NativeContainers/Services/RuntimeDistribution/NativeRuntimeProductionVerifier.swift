import Foundation

protocol NativeRuntimeReleaseContractLoading: Sendable {
  func loadSignedBinaryDigests() throws -> NativeRuntimeSignedBinaryDigestCatalog
}

struct BundledNativeRuntimeReleaseContractLoader:
  NativeRuntimeReleaseContractLoading,
  @unchecked Sendable
{
  static let resourceName = "NativeRuntimeReleaseContract"
  static let resourceExtension = "json"

  private struct ReleaseContract: Decodable {
    let schemaVersion: Int
    let runtimeVersion: String
    let packageIdentifier: String
    let installRoot: String
    let signingTeamIdentifier: String
    let builderShimVersion: String
    let builderShimSourceRevision: String
    let builderImageDigest: String
    let signedBinarySHA256: [String: String]
  }

  private static let signedBinaryPaths = [
    "bin/container",
    "bin/container-apiserver",
    "libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux",
    "libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet",
    "libexec/container/plugins/container-core-images/bin/container-core-images",
    "libexec/container/plugins/machine-apiserver/bin/machine-apiserver",
  ]

  private let bundleURL: URL
  private let contractURL: URL?
  private let signatureValidator: any NativeRuntimeCodeSignatureValidating

  init(
    bundle: Bundle = .main,
    signatureValidator: any NativeRuntimeCodeSignatureValidating =
      SecurityNativeRuntimeCodeSignatureValidator()
  ) {
    bundleURL = bundle.bundleURL
    contractURL = bundle.url(
      forResource: Self.resourceName,
      withExtension: Self.resourceExtension
    )
    self.signatureValidator = signatureValidator
  }

  func loadSignedBinaryDigests() throws
    -> NativeRuntimeSignedBinaryDigestCatalog
  {
    try signatureValidator.validate(
      codeAt: bundleURL,
      teamIdentifier:
        NativeRuntimeDistributionManifest.nativeContainersTeamIdentifier,
      signingIdentifier: "com.nativecontainers.app"
    )
    guard
      let contractURL,
      contractURL.standardizedFileURL.path.hasPrefix(
        bundleURL.standardizedFileURL.path + "/"
      )
    else {
      throw NativeRuntimeDistributionError.invalidManifest(
        "The signed app bundle does not contain the NativeContainers runtime release contract."
      )
    }

    let values: URLResourceValues
    do {
      values = try contractURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
    } catch {
      throw NativeRuntimeDistributionError.invalidManifest(
        "The bundled runtime release contract cannot be inspected."
      )
    }
    guard
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      let byteCount = values.fileSize,
      byteCount > 0,
      byteCount <= 64 * 1_024
    else {
      throw NativeRuntimeDistributionError.invalidManifest(
        "The bundled runtime release contract is not a bounded regular file."
      )
    }

    let data: Data
    do {
      data = try Data(contentsOf: contractURL, options: [.mappedIfSafe])
    } catch {
      throw NativeRuntimeDistributionError.invalidManifest(
        "The bundled runtime release contract cannot be read."
      )
    }
    return try Self.decodeSignedBinaryDigests(data)
  }

  static func decodeSignedBinaryDigests(
    _ data: Data
  ) throws -> NativeRuntimeSignedBinaryDigestCatalog {
    guard
      data.count > 0,
      data.count <= 64 * 1_024,
      let contract = try? JSONDecoder().decode(ReleaseContract.self, from: data),
      contract.schemaVersion == 1,
      contract.runtimeVersion
        == NativeRuntimeProductionContractFactory.nativeRuntimeVersion,
      contract.packageIdentifier
        == NativeRuntimeProductionContractFactory.nativePackageIdentifier,
      contract.installRoot
        == NativeRuntimeProductionContractFactory.nativeInstallRootURL.path,
      contract.signingTeamIdentifier
        == NativeRuntimeDistributionManifest.nativeContainersTeamIdentifier,
      contract.builderShimVersion
        == NativeRuntimeBuilderArtifactContract.pinned.shimVersion,
      contract.builderShimSourceRevision
        == NativeRuntimeBuilderArtifactContract.pinned.sourceRevision,
      contract.builderImageDigest
        == NativeRuntimeBuilderArtifactContract.pinned.imageDigest,
      Set(contract.signedBinarySHA256.keys) == Set(signedBinaryPaths)
    else {
      throw NativeRuntimeDistributionError.invalidManifest(
        "The bundled runtime release contract does not match the pinned release."
      )
    }

    func digest(_ path: String) throws -> String {
      guard let value = contract.signedBinarySHA256[path] else {
        throw NativeRuntimeDistributionError.invalidManifest(
          "The bundled runtime release contract is incomplete."
        )
      }
      return value
    }

    return try NativeRuntimeSignedBinaryDigestCatalog(
      container: digest("bin/container"),
      containerAPIServer: digest("bin/container-apiserver"),
      containerRuntimeLinux: digest(
        "libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux"
      ),
      containerNetworkVMNet: digest(
        "libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet"
      ),
      containerCoreImages: digest(
        "libexec/container/plugins/container-core-images/bin/container-core-images"
      ),
      machineAPIServer: digest(
        "libexec/container/plugins/machine-apiserver/bin/machine-apiserver"
      )
    )
  }
}

struct ProductionActiveNativeRuntimeVerifier: ActiveNativeRuntimeVerifying {
  private let releaseContractLoader: any NativeRuntimeReleaseContractLoading

  init(
    releaseContractLoader: any NativeRuntimeReleaseContractLoading =
      BundledNativeRuntimeReleaseContractLoader()
  ) {
    self.releaseContractLoader = releaseContractLoader
  }

  func verifyActiveNativeRuntime() async throws
    -> NativeRuntimeVerifiedDistribution
  {
    let nativeManifest = NativeRuntimeProductionContractFactory.nativeManifest(
      signedBinaryDigests: try releaseContractLoader.loadSignedBinaryDigests()
    )
    let manifests = [
      NativeRuntimeProductionContractFactory.officialManifest(),
      nativeManifest,
    ]
    let verifier = ActiveNativeRuntimeVerifier(
      nativeManifest: nativeManifest,
      allManifests: manifests,
      distributionVerifier: NativeRuntimeDistributionVerifier(),
      graphSnapshotter: LaunchctlNativeRuntimeGraphSnapshotter(
        manifests: manifests
      )
    )
    return try await verifier.verifyActiveNativeRuntime()
  }
}
