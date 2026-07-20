import Foundation

enum VirtualMachineNetworkAttachment:
  String,
  Codable,
  CaseIterable,
  Equatable,
  Hashable,
  Sendable
{
  case nat
  case shared
  case hostOnly

  var usesCustomVmnetNetwork: Bool {
    self != .nat
  }
}

struct VirtualMachineNetworkConfiguration: Codable, Equatable, Sendable {
  static let nat = VirtualMachineNetworkConfiguration()

  let revision: UInt64
  let attachment: VirtualMachineNetworkAttachment

  init(
    revision: UInt64 = 0,
    attachment: VirtualMachineNetworkAttachment = .nat
  ) {
    self.revision = revision
    self.attachment = attachment
  }

  func settingAttachment(
    _ attachment: VirtualMachineNetworkAttachment
  ) throws -> VirtualMachineNetworkConfiguration {
    guard attachment != self.attachment else { return self }
    guard revision < UInt64.max else {
      throw VirtualMachineNetworkError.configurationRevisionOverflow
    }
    return VirtualMachineNetworkConfiguration(
      revision: revision + 1,
      attachment: attachment
    )
  }
}

struct VirtualMachineNetworkSnapshot: Equatable, Sendable {
  let configuration: VirtualMachineNetworkConfiguration
}

enum VirtualMachineNetworkError: LocalizedError, Equatable, Sendable {
  case unavailable
  case configurationRevisionOverflow
  case savedStateBlocksChanges(UUID)
  case managedConfigurationLocked(UUID)
  case vmnetNetworkCreationFailed(VirtualMachineNetworkAttachment, Int)
  case invalidMACAddress(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Network configuration is unavailable on this host."
    case .configurationRevisionOverflow:
      "The network configuration changed too many times to update safely."
    case .savedStateBlocksChanges(let identifier):
      "Discard the saved state for virtual machine \(identifier.uuidString) before changing its network."
    case .managedConfigurationLocked(let identifier):
      "Residential Linux box \(identifier.uuidString) always uses automatic NAT networking."
    case .vmnetNetworkCreationFailed(let attachment, let status):
      "NativeContainers could not create the \(attachment.displayName) network (vmnet status \(status))."
    case .invalidMACAddress(let address):
      "The virtual machine network address \(address) is invalid."
    }
  }
}

extension VirtualMachineNetworkAttachment {
  fileprivate var displayName: String {
    switch self {
    case .nat:
      "automatic NAT"
    case .shared:
      "shared VM"
    case .hostOnly:
      "host-only"
    }
  }
}

typealias MacVirtualMachineNetworkAttachment = VirtualMachineNetworkAttachment
typealias LinuxVirtualMachineNetworkAttachment = VirtualMachineNetworkAttachment
typealias MacVirtualMachineNetworkConfiguration = VirtualMachineNetworkConfiguration
typealias LinuxVirtualMachineNetworkConfiguration = VirtualMachineNetworkConfiguration
typealias MacVirtualMachineNetworkSnapshot = VirtualMachineNetworkSnapshot
typealias LinuxVirtualMachineNetworkSnapshot = VirtualMachineNetworkSnapshot
typealias MacVirtualMachineNetworkError = VirtualMachineNetworkError
typealias LinuxVirtualMachineNetworkError = VirtualMachineNetworkError
