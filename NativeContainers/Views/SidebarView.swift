import SwiftUI

struct SidebarView: View {
  @Binding var selection: SidebarDestination
  var lockedDestination: SidebarDestination?

  var body: some View {
    List(selection: $selection) {
      Section("Workspace") {
        row(.overview)
        row(.containers)
        row(.composeProjects)
        row(.images)
        row(.builds)
        row(.volumes)
        row(.networks)
      }

      Section("Virtual Machines") {
        row(.linuxMachines)
        row(.macOSVirtualMachines)
      }

      Section("Orchestration") {
        row(.kubernetes)
      }

      Section {
        row(.settings)
      }
    }
    .navigationTitle("NativeContainers")
    .listStyle(.sidebar)
  }

  private func row(_ destination: SidebarDestination) -> some View {
    SidebarRow(destination: destination)
      .disabled(
        lockedDestination != nil && lockedDestination != destination
      )
  }
}

struct SidebarRow: View {
  let destination: SidebarDestination

  var body: some View {
    Label(destination.title, systemImage: destination.systemImage)
      .tag(destination)
  }
}
