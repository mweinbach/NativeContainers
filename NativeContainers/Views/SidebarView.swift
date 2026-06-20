import SwiftUI

struct SidebarView: View {
  @Binding var selection: SidebarDestination

  var body: some View {
    List(selection: $selection) {
      Section("Workspace") {
        SidebarRow(destination: .overview)
        SidebarRow(destination: .containers)
        SidebarRow(destination: .images)
        SidebarRow(destination: .volumes)
      }

      Section("Virtual Machines") {
        SidebarRow(destination: .linuxMachines)
        SidebarRow(destination: .macOSVirtualMachines)
      }

      Section {
        SidebarRow(destination: .settings)
      }
    }
    .navigationTitle("NativeContainers")
    .listStyle(.sidebar)
  }
}

struct SidebarRow: View {
  let destination: SidebarDestination

  var body: some View {
    Label(destination.title, systemImage: destination.systemImage)
      .tag(destination)
  }
}
