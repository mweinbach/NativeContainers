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

struct DiskutilWindowsSetupConfigurationMediaWriter:
  WindowsSetupConfigurationMediaWriting
{
  static let imageSize = "16MiB"
  static let volumeName = "NCTSETUP"
  static let answerFilename = "Autounattend.xml"
  static let integrationDirectoryName = "NativeContainers"
  static let guestAgentSecretFilename = "GuestAgentSecret.bin"

  private let executor: any HostCommandExecuting
  private let mounter: any DiskImageMounting

  init(
    executor: any HostCommandExecuting = FoundationHostCommandExecutor(),
    mounter: (any DiskImageMounting)? = nil
  ) {
    self.executor = executor
    self.mounter = mounter ?? DiskutilDiskImageMounter(executor: executor)
  }

  func write(
    to destinationURL: URL,
    guestAgentSecret: Data
  ) async throws {
    guard guestAgentSecret.count == 32 else {
      throw WindowsPlatformArtifactError.invalidGuestAgentSecret
    }
    let result = try await executor.execute(
      executableURL: DiskutilDiskImageMounter.executableURL,
      arguments: [
        "image", "create", "blank", "--format", "RAW", "--size",
        Self.imageSize, "--volumeName", Self.volumeName, "--fs", "MS-DOS",
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
    let image = try await mounter.attach(destinationURL, readOnly: false)
    do {
      let answerURL = image.mountURL.appending(path: Self.answerFilename)
      try Data(Self.answerFile.utf8).write(to: answerURL, options: [.atomic])
      let integrationDirectory = image.mountURL.appending(
        path: Self.integrationDirectoryName,
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: integrationDirectory,
        withIntermediateDirectories: false
      )
      try guestAgentSecret.write(
        to: integrationDirectory.appending(path: Self.guestAgentSecretFilename),
        options: [.atomic]
      )
      try await mounter.detach(image)
    } catch {
      try? await mounter.detach(image)
      throw error
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destinationURL.path
    )
    completed = true
  }

  func write(to destinationURL: URL) async throws {
    try await write(
      to: destinationURL,
      guestAgentSecret: Data(repeating: 0, count: 32)
    )
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
  case missingArtifact(String)

  var errorDescription: String? {
    switch self {
    case .setupMediaCreationFailed(let diagnostic):
      "The Windows setup configuration image could not be created: \(diagnostic)"
    case .unableToCreateGuestAgentSecret(let status):
      "The Windows guest-agent secret could not be generated (Security status \(status))."
    case .invalidGuestAgentSecret:
      "The Windows guest-agent secret must contain exactly 32 bytes."
    case .missingArtifact(let filename):
      "Windows platform preparation did not create \(filename)."
    }
  }
}
