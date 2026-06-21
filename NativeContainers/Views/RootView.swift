import SwiftUI

struct RootView: View {
  let model: AppModel

  var body: some View {
    @Bindable var model = model

    NavigationSplitView {
      SidebarView(
        selection: Binding(
          get: { model.selection },
          set: model.selectSidebarDestination
        ),
        lockedDestination: model.isBuildWorkspaceNavigationLocked ? .builds : nil
      )
    } detail: {
      DestinationView(model: model, destination: model.selection)
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await model.refresh() }
        }
        .disabled(model.isRefreshing)
        .help("Refresh container and virtual machine state")
      }
    }
    .task {
      await model.loadIfNeeded()
    }
    .alert(
      "NativeContainers Error",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { isPresented in
          if !isPresented { model.clearError() }
        }
      )
    ) {
      Button("OK") { model.clearError() }
    } message: {
      Text(model.errorMessage ?? "An unknown error occurred.")
    }
  }
}

struct DestinationView: View {
  let model: AppModel
  let destination: SidebarDestination

  var body: some View {
    VStack(spacing: 0) {
      switch destination {
      case .overview:
        OverviewView(model: model)
      case .containers:
        ContainersView(model: model)
      case .images:
        ImagesView(model: model)
      case .builds:
        ImageBuildsView(appModel: model)
      case .volumes:
        VolumesView(model: model)
      case .networks:
        NetworksView(model: model)
      case .linuxMachines:
        LinuxMachinesView(model: model)
      case .macOSVirtualMachines:
        VirtualMachinesView(model: model)
      case .settings:
        SettingsView(model: model)
      }
    }
  }
}

#Preview("Running resources") {
  RootView(model: .preview)
    .frame(width: 1180, height: 760)
}

#Preview("Empty library") {
  RootView(model: .previewEmpty)
    .frame(width: 980, height: 680)
}
