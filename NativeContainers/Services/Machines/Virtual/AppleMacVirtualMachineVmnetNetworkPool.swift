import CoreFoundation
import Foundation
import vmnet

#if arch(arm64)
  @MainActor
  final class AppleVirtualMachineVmnetNetworkPool {
    private final class OwnedNetwork {
      let reference: vmnet_network_ref

      init(reference: vmnet_network_ref) {
        self.reference = reference
      }

      deinit {
        releaseVmnetObject(reference)
      }
    }

    private var networks: [VirtualMachineNetworkAttachment: OwnedNetwork] = [:]

    func network(
      for attachment: VirtualMachineNetworkAttachment
    ) throws -> vmnet_network_ref {
      precondition(attachment.usesCustomVmnetNetwork)

      if let existing = networks[attachment] {
        return existing.reference
      }

      let mode: vmnet_mode_t
      switch attachment {
      case .nat:
        preconditionFailure("NAT does not use a custom vmnet network")
      case .shared:
        mode = .VMNET_SHARED_MODE
      case .hostOnly:
        mode = .VMNET_HOST_MODE
      }

      var status = vmnet_return_t.VMNET_FAILURE
      guard let configuration = vmnet_network_configuration_create(mode, &status) else {
        throw VirtualMachineNetworkError.vmnetNetworkCreationFailed(
          attachment,
          Int(status.rawValue)
        )
      }
      defer { releaseVmnetObject(configuration) }

      guard let network = vmnet_network_create(configuration, &status) else {
        throw VirtualMachineNetworkError.vmnetNetworkCreationFailed(
          attachment,
          Int(status.rawValue)
        )
      }

      let ownedNetwork = OwnedNetwork(reference: network)
      networks[attachment] = ownedNetwork
      return ownedNetwork.reference
    }
  }

  typealias AppleMacVirtualMachineVmnetNetworkPool =
    AppleVirtualMachineVmnetNetworkPool

  private func releaseVmnetObject(_ object: OpaquePointer) {
    Unmanaged<CFTypeRef>
      .fromOpaque(UnsafeRawPointer(object))
      .release()
  }
#endif
