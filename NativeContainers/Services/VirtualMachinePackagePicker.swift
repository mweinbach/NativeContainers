import AppKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
  static let nativeContainersVirtualMachine = UTType(
    exportedAs: "com.nativecontainers.virtual-machine",
    conformingTo: .package
  )
}

@MainActor
protocol VirtualMachineExportDestinationChoosing {
  func chooseDestination(for machineName: String) async -> URL?
}

@MainActor
struct MacVirtualMachineExportDestinationPicker:
  VirtualMachineExportDestinationChoosing
{
  func chooseDestination(for machineName: String) async -> URL? {
    await withCheckedContinuation { continuation in
      let panel = NSSavePanel()
      panel.title = "Export Virtual Machine"
      panel.prompt = "Export"
      panel.message =
        "Choose a new .\(VirtualMachineLibrary.bundleExtension) package. Existing packages are never replaced."
      panel.allowedContentTypes = [.nativeContainersVirtualMachine]
      panel.allowsOtherFileTypes = false
      panel.treatsFilePackagesAsDirectories = false
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      panel.nameFieldStringValue =
        "\(safeFilename(machineName)).\(VirtualMachineLibrary.bundleExtension)"

      let completion: (NSApplication.ModalResponse) -> Void = { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
      if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        panel.beginSheetModal(for: window, completionHandler: completion)
      } else {
        panel.begin(completionHandler: completion)
      }
    }
  }

  private func safeFilename(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:")
      .union(.controlCharacters)
    let components = name.components(separatedBy: invalid)
    let result =
      components
      .filter { !$0.isEmpty }
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? "Virtual Machine" : result
  }
}
