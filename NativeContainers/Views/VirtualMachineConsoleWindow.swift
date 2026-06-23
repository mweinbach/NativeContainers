import SwiftUI

struct VirtualMachineConsoleWindow: View {
  @Environment(\.dismissWindow) private var dismissWindow

  let request: VirtualMachineConsoleWindowRequest
  let appModel: AppModel

  var body: some View {
    if let machine = appModel.virtualMachine(matching: request) {
      NavigationStack {
        VirtualMachineConsoleRuntimeContent(
          machine: machine,
          appModel: appModel
        )
        .navigationTitle(machine.name)
      }
    } else {
      ContentUnavailableView {
        Label("Virtual Machine Unavailable", systemImage: "display")
      } description: {
        Text(
          "This virtual machine was removed or no longer matches the restored window."
        )
      } actions: {
        Button("Close Window", systemImage: "xmark") {
          dismissWindow(
            id: VirtualMachineConsoleWindowRequest.windowGroupID,
            value: request
          )
        }
      }
      .frame(minWidth: 640, minHeight: 420)
    }
  }
}

private struct VirtualMachineConsoleRuntimeContent: View {
  let machine: VirtualMachineManifest
  let appModel: AppModel

  var body: some View {
    switch machine.guest {
    case .macOS:
      MacVirtualMachineRuntimeView(
        machine: machine,
        model: appModel.makeMacVirtualMachineRuntimeModel(for: machine),
        usb: appModel.makeMacVirtualMachineUSBModel(for: machine)
      )
    case .linux:
      LinuxVirtualMachineRuntimeView(
        machine: machine,
        model: appModel.makeLinuxVirtualMachineRuntimeModel(for: machine)
      )
    case .windows:
      LinuxVirtualMachineRuntimeView(
        machine: machine,
        model: appModel.makeLinuxVirtualMachineRuntimeModel(for: machine)
      )
    }
  }
}

#Preview("macOS virtual machine window") {
  let model = AppModel.previewVirtualMachines
  let machine = model.virtualMachines[0]
  VirtualMachineConsoleWindow(
    request: VirtualMachineConsoleWindowRequest(machine: machine),
    appModel: model
  )
}
