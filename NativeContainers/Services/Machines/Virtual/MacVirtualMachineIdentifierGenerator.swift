import Foundation
@preconcurrency import Virtualization

protocol MacVirtualMachineIdentifierValidating: Sendable {
  func isValidIdentifierData(_ data: Data) -> Bool
}

protocol MacVirtualMachineIdentifierGenerating: MacVirtualMachineIdentifierValidating {
  func makeIdentifierData() throws -> Data
}

struct AppleMacVirtualMachineIdentifierGenerator: MacVirtualMachineIdentifierGenerating {
  func makeIdentifierData() throws -> Data {
    #if arch(arm64)
      VZMacMachineIdentifier().dataRepresentation
    #else
      throw MacPlatformArtifactError.requiresAppleSilicon
    #endif
  }

  func isValidIdentifierData(_ data: Data) -> Bool {
    #if arch(arm64)
      VZMacMachineIdentifier(dataRepresentation: data) != nil
    #else
      false
    #endif
  }
}
