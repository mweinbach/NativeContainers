import Foundation

enum MacVirtualMachineNetworkAttachment:
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

struct MacVirtualMachineNetworkConfiguration: Codable, Equatable, Sendable {
  static let nat = MacVirtualMachineNetworkConfiguration()

  let revision: UInt64
  let attachment: MacVirtualMachineNetworkAttachment

  init(
    revision: UInt64 = 0,
    attachment: MacVirtualMachineNetworkAttachment = .nat
  ) {
    self.revision = revision
    self.attachment = attachment
  }

  func settingAttachment(
    _ attachment: MacVirtualMachineNetworkAttachment
  ) throws -> MacVirtualMachineNetworkConfiguration {
    guard attachment != self.attachment else { return self }
    guard revision < UInt64.max else {
      throw MacVirtualMachineNetworkError.configurationRevisionOverflow
    }
    return MacVirtualMachineNetworkConfiguration(
      revision: revision + 1,
      attachment: attachment
    )
  }
}

struct MacVirtualMachineNetworkSnapshot: Equatable, Sendable {
  let configuration: MacVirtualMachineNetworkConfiguration
}

enum MacVirtualMachineNetworkError: LocalizedError, Equatable, Sendable {
  case unavailable
  case configurationRevisionOverflow
  case savedStateBlocksChanges(UUID)
  case vmnetNetworkCreationFailed(MacVirtualMachineNetworkAttachment, Int)
  case invalidMACAddress(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Network configuration is unavailable on this host."
    case .configurationRevisionOverflow:
      "The network configuration changed too many times to update safely."
    case .savedStateBlocksChanges(let identifier):
      "Discard the saved state for virtual machine \(identifier.uuidString) before changing its network."
    case .vmnetNetworkCreationFailed(let attachment, let status):
      "NativeContainers could not create the \(attachment.displayName) network (vmnet status \(status))."
    case .invalidMACAddress(let address):
      "The virtual machine network address \(address) is invalid."
    }
  }
}

extension MacVirtualMachineNetworkAttachment {
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
