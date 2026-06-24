import Darwin
import Foundation
import Security
@preconcurrency import Virtualization

struct WindowsPlatformArtifactURLs: Sendable {
  static let directoryName = "WindowsPlatform"
  static let efiVariableStoreFilename = "NVRAM"
  static let machineIdentifierFilename = "MachineIdentifier"
  static let installationMediaFilename = "Installation.iso"
  static let setupConfigurationMediaFilename = "SetupConfig.img"
  static let guestAgentSecretFilename = "GuestAgentSecret"

  let directory: URL

  var efiVariableStore: URL {
    directory.appending(path: Self.efiVariableStoreFilename)
  }

  var machineIdentifier: URL {
    directory.appending(path: Self.machineIdentifierFilename)
  }

  var installationMedia: URL {
    directory.appending(path: Self.installationMediaFilename)
  }

  var setupConfigurationMedia: URL {
    directory.appending(path: Self.setupConfigurationMediaFilename)
  }

  var guestAgentSecret: URL {
    directory.appending(path: Self.guestAgentSecretFilename)
  }

  var all: [URL] {
    [
      efiVariableStore,
      machineIdentifier,
      installationMedia,
      setupConfigurationMedia,
      guestAgentSecret,
    ]
  }

  static var efiVariableStoreManifestPath: String {
    "\(directoryName)/\(efiVariableStoreFilename)"
  }

  static var machineIdentifierManifestPath: String {
    "\(directoryName)/\(machineIdentifierFilename)"
  }

  static var installationMediaManifestPath: String {
    "\(directoryName)/\(installationMediaFilename)"
  }

  static var setupConfigurationMediaManifestPath: String {
    "\(directoryName)/\(setupConfigurationMediaFilename)"
  }

  static var guestAgentSecretManifestPath: String {
    "\(directoryName)/\(guestAgentSecretFilename)"
  }
}

protocol WindowsPlatformArtifactPreparing: Sendable {
  func prepare(
    installationMediaURL: URL,
    destination: WindowsPlatformArtifactURLs,
    securityMode: WindowsVirtualMachineSecurityMode
  ) async throws -> WindowsPlatformPreparationResult
}

protocol WindowsPlatformIdentityCreating: Sendable {
  func create(
    at destination: WindowsPlatformArtifactURLs,
    securityMode: WindowsVirtualMachineSecurityMode
  ) throws -> String
}

protocol WindowsSetupConfigurationMediaWriting: Sendable {
  func write(
    installationMediaURL: URL,
    installationMediaByteCount: UInt64,
    to destinationURL: URL,
    guestAgentSecret: Data
  ) async throws
}

struct WindowsPlatformArtifactPreparer: WindowsPlatformArtifactPreparing {
  private let mediaCopier: any WindowsInstallationMediaCopying
  private let mediaInspector: any WindowsInstallationMediaInspecting
  private let setupMediaWriter: any WindowsSetupConfigurationMediaWriting
  private let identityService: any WindowsPlatformIdentityCreating

  init(
    mediaCopier: any WindowsInstallationMediaCopying =
      FileWindowsInstallationMediaCopier(),
    mediaInspector: any WindowsInstallationMediaInspecting =
      DiskutilWindowsInstallationMediaInspector(),
    setupMediaWriter: any WindowsSetupConfigurationMediaWriting =
      DiskutilWindowsSetupConfigurationMediaWriter(),
    identityService: any WindowsPlatformIdentityCreating =
      AppleWindowsPlatformIdentityService()
  ) {
    self.mediaCopier = mediaCopier
    self.mediaInspector = mediaInspector
    self.setupMediaWriter = setupMediaWriter
    self.identityService = identityService
  }

  func prepare(
    installationMediaURL: URL,
    destination: WindowsPlatformArtifactURLs,
    securityMode: WindowsVirtualMachineSecurityMode
  ) async throws -> WindowsPlatformPreparationResult {
    let copy = try await mediaCopier.copy(
      from: installationMediaURL,
      to: destination.installationMedia
    )
    try Task.checkCancellation()
    let media = try await mediaInspector.inspect(
      installationMediaURL: destination.installationMedia,
      sourceFilename: installationMediaURL.lastPathComponent,
      copy: copy
    )
    try Task.checkCancellation()
    let macAddress = try identityService.create(
      at: destination,
      securityMode: securityMode
    )
    try Task.checkCancellation()
    let guestAgentSecret = try Data(contentsOf: destination.guestAgentSecret)
    try await setupMediaWriter.write(
      installationMediaURL: destination.installationMedia,
      installationMediaByteCount: copy.byteCount,
      to: destination.setupConfigurationMedia,
      guestAgentSecret: guestAgentSecret
    )
    try Task.checkCancellation()
    return WindowsPlatformPreparationResult(
      macAddress: macAddress,
      installationMedia: media
    )
  }
}

struct AppleWindowsPlatformIdentityService: WindowsPlatformIdentityCreating {
  func create(
    at destination: WindowsPlatformArtifactURLs,
    securityMode: WindowsVirtualMachineSecurityMode
  ) throws -> String {
    try VZGenericMachineIdentifier().dataRepresentation.write(
      to: destination.machineIdentifier,
      options: [.atomic]
    )
    let variableStore = try VZEFIVariableStore(
      creatingVariableStoreAt: destination.efiVariableStore
    )
    if securityMode.usesSecureBoot {
      guard #available(macOS 27.0, *) else {
        throw WindowsVirtualMachineError.secureBootRequiresMacOS27
      }
      try variableStore.enrollDefaultSecureBootSignatures()
      try variableStore.enableSecureBootUsingDefaultPlatformKey()
      guard try variableStore.isSecureBootEnabled else {
        throw WindowsVirtualMachineError.invalidConfiguration(
          "Secure Boot did not remain enabled in the EFI variable store"
        )
      }
    }

    var secret = Data(count: 32)
    let status = secret.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw WindowsPlatformArtifactError.unableToCreateGuestAgentSecret(status)
    }
    try secret.write(to: destination.guestAgentSecret, options: [.atomic])

    for artifact in [
      destination.machineIdentifier,
      destination.efiVariableStore,
      destination.guestAgentSecret,
    ] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: artifact.path
      )
    }
    return VZMACAddress.randomLocallyAdministered().string
  }
}

protocol WindowsBootableInstallationMediaPopulating: Sendable {
  func populate(
    from sourceVolumeURL: URL,
    to destinationVolumeURL: URL,
    guestAgentSecret: Data
  ) async throws
}

protocol WindowsWIMImageSplitting: Sendable {
  func split(sourceURL: URL, destinationURL: URL) async throws
}

struct WIMLibWindowsWIMImageSplitter: WindowsWIMImageSplitting {
  static let maximumPartSizeMiB = 3_800

  private let executor: any HostCommandExecuting
  private let requestedExecutableURL: URL?

  init(
    executor: any HostCommandExecuting = FoundationHostCommandExecutor(),
    executableURL: URL? = nil
  ) {
    self.executor = executor
    requestedExecutableURL = executableURL
  }

  func split(sourceURL: URL, destinationURL: URL) async throws {
    let executableURL = try resolveExecutableURL()
    let result = try await executor.execute(
      executableURL: executableURL,
      arguments: [
        "split",
        sourceURL.path(percentEncoded: false),
        destinationURL.path(percentEncoded: false),
        String(Self.maximumPartSizeMiB),
      ],
      environment: nil,
      timeout: .seconds(7_200)
    )
    guard result.exitCode == 0 else {
      throw WindowsPlatformArtifactError.wimSplitFailed(
        Self.diagnostic(from: result)
      )
    }
  }

  private func resolveExecutableURL() throws -> URL {
    let candidates: [URL]
    if let requestedExecutableURL {
      candidates = [requestedExecutableURL]
    } else {
      var discovered: [URL] = []
      if let bundled = Bundle.main.url(
        forResource: "wimlib-imagex",
        withExtension: nil,
        subdirectory: "WindowsTools"
      ) {
        discovered.append(bundled)
      }
      discovered.append(URL(filePath: "/opt/homebrew/bin/wimlib-imagex"))
      discovered.append(URL(filePath: "/usr/local/bin/wimlib-imagex"))
      candidates = discovered
    }

    for candidate in candidates {
      let resolved = candidate.resolvingSymlinksInPath()
      let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
      guard values?.isRegularFile == true,
        FileManager.default.isExecutableFile(atPath: resolved.path)
      else {
        continue
      }
      return resolved
    }
    throw WindowsPlatformArtifactError.wimlibUnavailable
  }

  private static func diagnostic(from result: HostCommandResult) -> String {
    String(
      [result.standardError, result.standardOutput]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .suffix(2_000)
    )
  }
}

struct WindowsBootableInstallationMediaPopulator:
  WindowsBootableInstallationMediaPopulating,
  @unchecked Sendable
{
  static let copyChunkSize = 4 * 1_024 * 1_024
  static let maximumFAT32FileSize: UInt64 = 4_294_967_295

  private let fileManager: FileManager
  private let splitter: any WindowsWIMImageSplitting

  init(
    fileManager: FileManager = .default,
    splitter: any WindowsWIMImageSplitting = WIMLibWindowsWIMImageSplitter()
  ) {
    self.fileManager = fileManager
    self.splitter = splitter
  }

  func populate(
    from sourceVolumeURL: URL,
    to destinationVolumeURL: URL,
    guestAgentSecret: Data
  ) async throws {
    guard guestAgentSecret.count == 32 else {
      throw WindowsPlatformArtifactError.invalidGuestAgentSecret
    }

    let keys: [URLResourceKey] = [
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .fileSizeKey,
    ]
    var enumerationError: (any Error)?
    guard
      let enumerator = fileManager.enumerator(
        at: sourceVolumeURL,
        includingPropertiesForKeys: keys,
        options: [],
        errorHandler: { _, error in
          enumerationError = error
          return false
        }
      )
    else {
      throw WindowsPlatformArtifactError.installationMediaCopyFailed(
        sourceVolumeURL.lastPathComponent
      )
    }

    var installImage: (source: URL, destination: URL)?
    while let sourceURL = enumerator.nextObject() as? URL {
      try Task.checkCancellation()
      let components = try relativeComponents(
        of: sourceURL,
        in: sourceVolumeURL
      )
      let relativePath = components.joined(separator: "/")
      let values = try sourceURL.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        throw WindowsPlatformArtifactError.unsupportedInstallationMediaEntry(
          relativePath
        )
      }

      let destinationURL = components.reduce(destinationVolumeURL) {
        $0.appending(path: $1)
      }
      if values.isDirectory == true {
        try createDirectoryIfNeeded(at: destinationURL)
        continue
      }
      guard values.isRegularFile == true else {
        throw WindowsPlatformArtifactError.unsupportedInstallationMediaEntry(
          relativePath
        )
      }

      if components.map({ $0.lowercased() }) == ["sources", "install.wim"] {
        guard installImage == nil else {
          throw WindowsPlatformArtifactError.duplicateInstallImage
        }
        installImage = (
          source: sourceURL,
          destination:
            destinationURL
            .deletingLastPathComponent()
            .appending(path: "install.swm")
        )
        continue
      }

      let byteCount = UInt64(values.fileSize ?? 0)
      guard byteCount <= Self.maximumFAT32FileSize else {
        throw WindowsPlatformArtifactError.installationMediaFileTooLarge(
          relativePath
        )
      }
      try copyRegularFile(
        from: sourceURL,
        to: destinationURL,
        relativePath: relativePath
      )
    }
    if let enumerationError {
      throw WindowsPlatformArtifactError.installationMediaCopyFailed(
        enumerationError.localizedDescription
      )
    }

    guard let installImage else {
      throw WindowsPlatformArtifactError.missingInstallImage
    }
    try await splitter.split(
      sourceURL: installImage.source,
      destinationURL: installImage.destination
    )
    try validateSplitInstallImages(in: installImage.destination.deletingLastPathComponent())
    try writeConfigurationFiles(
      to: destinationVolumeURL,
      guestAgentSecret: guestAgentSecret
    )
  }

  private func relativeComponents(of childURL: URL, in rootURL: URL) throws
    -> [String]
  {
    let rootComponents = rootURL.standardizedFileURL.pathComponents
    let childComponents = childURL.standardizedFileURL.pathComponents
    guard childComponents.count > rootComponents.count,
      childComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    else {
      throw WindowsPlatformArtifactError.unsupportedInstallationMediaEntry(
        childURL.lastPathComponent
      )
    }
    return Array(childComponents.dropFirst(rootComponents.count))
  }

  private func createDirectoryIfNeeded(at url: URL) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw WindowsPlatformArtifactError.installationMediaCopyFailed(
          url.lastPathComponent
        )
      }
      return
    }
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: false
    )
  }

  private func copyRegularFile(
    from sourceURL: URL,
    to destinationURL: URL,
    relativePath: String
  ) throws {
    let sourceDescriptor = Darwin.open(
      sourceURL.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard sourceDescriptor >= 0 else {
      throw WindowsPlatformArtifactError.installationMediaCopyFailed(relativePath)
    }
    let input = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
    defer { try? input.close() }

    var sourceMetadata = stat()
    guard Darwin.fstat(sourceDescriptor, &sourceMetadata) == 0,
      sourceMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else {
      throw WindowsPlatformArtifactError.unsupportedInstallationMediaEntry(
        relativePath
      )
    }

    let destinationDescriptor = Darwin.open(
      destinationURL.path(percentEncoded: false),
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard destinationDescriptor >= 0 else {
      throw WindowsPlatformArtifactError.installationMediaCopyFailed(relativePath)
    }
    let output = FileHandle(
      fileDescriptor: destinationDescriptor,
      closeOnDealloc: true
    )
    defer { try? output.close() }

    do {
      while true {
        try Task.checkCancellation()
        guard
          let data = try input.read(upToCount: Self.copyChunkSize),
          !data.isEmpty
        else {
          break
        }
        try output.write(contentsOf: data)
      }
      try output.synchronize()
    } catch {
      try? fileManager.removeItem(at: destinationURL)
      throw error
    }
  }

  private func validateSplitInstallImages(in sourcesURL: URL) throws {
    let children = try fileManager.contentsOfDirectory(
      at: sourcesURL,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: []
    )
    let splitImages = children.filter {
      let name = $0.lastPathComponent.lowercased()
      return name == "install.swm"
        || (name.hasPrefix("install") && name.hasSuffix(".swm"))
    }
    guard splitImages.contains(where: { $0.lastPathComponent.lowercased() == "install.swm" })
    else {
      throw WindowsPlatformArtifactError.missingSplitInstallImage
    }
    for image in splitImages {
      let values = try image.resourceValues(forKeys: [
        .isRegularFileKey,
        .fileSizeKey,
      ])
      guard values.isRegularFile == true,
        let fileSize = values.fileSize,
        fileSize > 0,
        UInt64(fileSize) <= Self.maximumFAT32FileSize
      else {
        throw WindowsPlatformArtifactError.invalidSplitInstallImage(
          image.lastPathComponent
        )
      }
    }
  }

  private func writeConfigurationFiles(
    to destinationVolumeURL: URL,
    guestAgentSecret: Data
  ) throws {
    let answerURL = destinationVolumeURL.appending(
      path: DiskutilWindowsSetupConfigurationMediaWriter.answerFilename
    )
    try Data(DiskutilWindowsSetupConfigurationMediaWriter.answerFile.utf8).write(
      to: answerURL,
      options: [.atomic]
    )
    let integrationDirectory = destinationVolumeURL.appending(
      path: DiskutilWindowsSetupConfigurationMediaWriter.integrationDirectoryName,
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(
      at: integrationDirectory,
      withIntermediateDirectories: true
    )
    try guestAgentSecret.write(
      to: integrationDirectory.appending(
        path: DiskutilWindowsSetupConfigurationMediaWriter.guestAgentSecretFilename
      ),
      options: [.atomic]
    )
  }
}

struct DiskutilWindowsSetupConfigurationMediaWriter:
  WindowsSetupConfigurationMediaWriting
{
  static let imageHeadroomBytes: UInt64 = 512 * 1_024 * 1_024
  static let bytesPerMiB: UInt64 = 1_024 * 1_024
  static let volumeName = "NCTSETUP"
  static let answerFilename = "Autounattend.xml"
  static let integrationDirectoryName = "NativeContainers"
  static let guestAgentSecretFilename = "GuestAgentSecret.bin"

  private let executor: any HostCommandExecuting
  private let mounter: any DiskImageMounting
  private let populator: any WindowsBootableInstallationMediaPopulating

  init(
    executor: any HostCommandExecuting = FoundationHostCommandExecutor(),
    mounter: (any DiskImageMounting)? = nil,
    populator: (any WindowsBootableInstallationMediaPopulating)? = nil
  ) {
    self.executor = executor
    self.mounter = mounter ?? DiskutilDiskImageMounter(executor: executor)
    self.populator =
      populator
      ?? WindowsBootableInstallationMediaPopulator(
        splitter: WIMLibWindowsWIMImageSplitter(executor: executor)
      )
  }

  func write(
    installationMediaURL: URL,
    installationMediaByteCount: UInt64,
    to destinationURL: URL,
    guestAgentSecret: Data
  ) async throws {
    guard guestAgentSecret.count == 32 else {
      throw WindowsPlatformArtifactError.invalidGuestAgentSecret
    }
    let imageSize = try Self.imageSize(
      installationMediaByteCount: installationMediaByteCount
    )
    let result = try await executor.execute(
      executableURL: DiskutilDiskImageMounter.executableURL,
      arguments: [
        "image", "create", "blank", "--format", "RAW", "--size",
        imageSize, "--volumeName", Self.volumeName, "--fs", "MS-DOS",
        destinationURL.path(percentEncoded: false),
      ],
      environment: nil,
      timeout: .seconds(120)
    )
    guard result.exitCode == 0 else {
      throw WindowsPlatformArtifactError.setupMediaCreationFailed(
        diagnostic(from: result)
      )
    }

    var completed = false
    defer {
      if !completed {
        try? FileManager.default.removeItem(at: destinationURL)
      }
    }
    let sourceImage = try await mounter.attach(
      installationMediaURL,
      readOnly: true
    )
    var destinationImage: MountedDiskImage?
    do {
      let image = try await mounter.attach(destinationURL, readOnly: false)
      destinationImage = image
      try await populator.populate(
        from: sourceImage.mountURL,
        to: image.mountURL,
        guestAgentSecret: guestAgentSecret
      )
      try await mounter.detach(image)
      destinationImage = nil
      try await mounter.detach(sourceImage)
    } catch {
      if let destinationImage {
        try? await mounter.detach(destinationImage)
      }
      try? await mounter.detach(sourceImage)
      throw error
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destinationURL.path
    )
    completed = true
  }

  static func imageSize(installationMediaByteCount: UInt64) throws -> String {
    let (requiredBytes, overflow) = installationMediaByteCount.addingReportingOverflow(
      imageHeadroomBytes
    )
    guard !overflow, requiredBytes > 0 else {
      throw WindowsPlatformArtifactError.invalidInstallationMediaSize
    }
    let roundedMiB =
      requiredBytes / bytesPerMiB
      + (requiredBytes.isMultiple(of: bytesPerMiB) ? 0 : 1)
    return "\(roundedMiB)MiB"
  }

  private func diagnostic(from result: HostCommandResult) -> String {
    String(
      [result.standardError, result.standardOutput]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .suffix(2_000)
    )
  }

  static let answerFile = """
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>1</Order>
              <Description>Permit installation without a virtual TPM</Description>
              <Path>reg.exe add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
    </unattend>
    """
}

enum WindowsPlatformArtifactError: LocalizedError, Equatable {
  case setupMediaCreationFailed(String)
  case unableToCreateGuestAgentSecret(OSStatus)
  case invalidGuestAgentSecret
  case invalidInstallationMediaSize
  case unsupportedInstallationMediaEntry(String)
  case installationMediaCopyFailed(String)
  case installationMediaFileTooLarge(String)
  case duplicateInstallImage
  case missingInstallImage
  case wimlibUnavailable
  case wimSplitFailed(String)
  case missingSplitInstallImage
  case invalidSplitInstallImage(String)
  case missingArtifact(String)

  var errorDescription: String? {
    switch self {
    case .setupMediaCreationFailed(let diagnostic):
      "The Windows setup configuration image could not be created: \(diagnostic)"
    case .unableToCreateGuestAgentSecret(let status):
      "The Windows guest-agent secret could not be generated (Security status \(status))."
    case .invalidGuestAgentSecret:
      "The Windows guest-agent secret must contain exactly 32 bytes."
    case .invalidInstallationMediaSize:
      "The Windows installation media size is invalid."
    case .unsupportedInstallationMediaEntry(let path):
      "The Windows installation media contains an unsupported entry: \(path)."
    case .installationMediaCopyFailed(let path):
      "The Windows installation media could not be copied into the boot image: \(path)."
    case .installationMediaFileTooLarge(let path):
      "The Windows installation media contains a FAT32-incompatible file: \(path)."
    case .duplicateInstallImage:
      "The Windows installation media contains more than one sources/install.wim."
    case .missingInstallImage:
      "The Windows installation media is missing sources/install.wim."
    case .wimlibUnavailable:
      "Creating bootable Windows media requires wimlib-imagex in the app bundle or at /opt/homebrew/bin or /usr/local/bin."
    case .wimSplitFailed(let diagnostic):
      "The Windows install image could not be split for FAT32 media: \(diagnostic)"
    case .missingSplitInstallImage:
      "The bootable Windows media is missing sources/install.swm."
    case .invalidSplitInstallImage(let filename):
      "The bootable Windows media contains an invalid split image: \(filename)."
    case .missingArtifact(let filename):
      "Windows platform preparation did not create \(filename)."
    }
  }
}
