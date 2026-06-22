import Foundation

struct MacGuestOperatingSystemIdentity: Codable, Equatable, Sendable {
  let buildVersion: String
  let majorVersion: Int
  let minorVersion: Int
  let patchVersion: Int

  init(
    buildVersion: String,
    majorVersion: Int,
    minorVersion: Int,
    patchVersion: Int
  ) {
    self.buildVersion = buildVersion
    self.majorVersion = majorVersion
    self.minorVersion = minorVersion
    self.patchVersion = patchVersion
  }

  init(buildVersion: String, operatingSystemVersion: OperatingSystemVersion) {
    self.init(
      buildVersion: buildVersion,
      majorVersion: operatingSystemVersion.majorVersion,
      minorVersion: operatingSystemVersion.minorVersion,
      patchVersion: operatingSystemVersion.patchVersion
    )
  }

  var supportsGuestProvisioning: Bool {
    majorVersion >= 27
  }

  var versionDescription: String {
    "\(majorVersion).\(minorVersion).\(patchVersion)"
  }
}

enum MacVirtualMachineFirstBootState: String, Codable, Equatable, Sendable {
  case pending
  case launching
  case started
}

struct MacPlatformPreparationResult: Equatable, Sendable {
  let operatingSystem: MacGuestOperatingSystemIdentity
  let minimumCPUCount: Int
  let minimumMemoryBytes: UInt64

  init(
    operatingSystem: MacGuestOperatingSystemIdentity,
    minimumCPUCount: Int = 1,
    minimumMemoryBytes: UInt64 = VirtualMachineResources.bytesPerGiB
  ) {
    self.operatingSystem = operatingSystem
    self.minimumCPUCount = minimumCPUCount
    self.minimumMemoryBytes = minimumMemoryBytes
  }
}

struct MacGuestProvisioningRequest: Equatable, Sendable {
  let fullName: String
  let username: String
  let password: String
  let logsInAutomatically: Bool
  let enablesRemoteLogin: Bool

  init(
    fullName: String,
    username: String,
    password: String,
    logsInAutomatically: Bool,
    enablesRemoteLogin: Bool
  ) throws {
    let normalizedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedFullName.isEmpty else {
      throw MacGuestProvisioningError.emptyFullName
    }

    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedUsername.isEmpty else {
      throw MacGuestProvisioningError.emptyUsername
    }
    guard !password.isEmpty else {
      throw MacGuestProvisioningError.emptyPassword
    }

    self.fullName = normalizedFullName
    self.username = normalizedUsername
    self.password = password
    self.logsInAutomatically = logsInAutomatically
    self.enablesRemoteLogin = enablesRemoteLogin
  }
}

enum MacGuestProvisioningError: LocalizedError, Equatable, Sendable {
  case emptyFullName
  case emptyUsername
  case emptyPassword
  case passwordsDoNotMatch
  case hostUnsupported
  case guestVersionUnknown
  case guestUnsupported(String)
  case firstBootUnavailable
  case savedStateConflict

  var errorDescription: String? {
    switch self {
    case .emptyFullName:
      "Enter the account holder’s full name."
    case .emptyUsername:
      "Enter a username for the guest account."
    case .emptyPassword:
      "Enter a password for the guest account."
    case .passwordsDoNotMatch:
      "The guest account passwords do not match."
    case .hostUnsupported:
      "Automated macOS guest setup requires macOS 27 or later on the host."
    case .guestVersionUnknown:
      "Automated guest setup is unavailable because this virtual machine’s macOS version is unknown."
    case .guestUnsupported(let version):
      "Automated guest setup requires macOS 27 or later; this guest is macOS \(version)."
    case .firstBootUnavailable:
      "Automated guest setup is only available before this virtual machine’s first boot."
    case .savedStateConflict:
      "Automated guest setup cannot be used while resuming a saved virtual machine state."
    }
  }
}
