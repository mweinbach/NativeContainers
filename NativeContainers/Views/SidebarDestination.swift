import SwiftUI

enum SidebarDestination: String, CaseIterable, Hashable, Identifiable {
  case overview
  case containers
  case composeProjects
  case images
  case builds
  case volumes
  case networks
  case linuxMachines
  case kubernetes
  case macOSVirtualMachines
  case settings

  var id: Self { self }

  var workspaceRoute: WorkspaceRoute {
    switch self {
    case .overview: .overview
    case .containers: .containers
    case .composeProjects: .composeProjects
    case .images: .images
    case .builds: .builds
    case .volumes: .volumes
    case .networks: .networks
    case .linuxMachines: .linuxMachines
    case .kubernetes: .kubernetes
    case .macOSVirtualMachines: .macOSVirtualMachines
    case .settings: .settings
    }
  }

  init(workspaceRoute: WorkspaceRoute) {
    switch workspaceRoute.baseRoute {
    case .overview:
      self = .overview
    case .containers:
      self = .containers
    case .composeProjects:
      self = .composeProjects
    case .images:
      self = .images
    case .builds:
      self = .builds
    case .volumes:
      self = .volumes
    case .networks:
      self = .networks
    case .linuxMachines:
      self = .linuxMachines
    case .kubernetes:
      self = .kubernetes
    case .macOSVirtualMachines:
      self = .macOSVirtualMachines
    case .settings:
      self = .settings
    case .container, .composeProject, .image, .volume, .network, .linuxMachine,
      .macOSVirtualMachine:
      preconditionFailure("A base workspace route cannot be a resource route.")
    }
  }

  var title: LocalizedStringResource {
    switch self {
    case .overview: "Overview"
    case .containers: "Containers"
    case .composeProjects: "Compose"
    case .images: "Images"
    case .builds: "Builds"
    case .volumes: "Volumes"
    case .networks: "Networks"
    case .linuxMachines: "Linux Machines"
    case .kubernetes: "Kubernetes"
    case .macOSVirtualMachines: "Virtual Machines"
    case .settings: "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .containers: "shippingbox"
    case .composeProjects: "square.stack.3d.down.right"
    case .images: "square.stack.3d.up"
    case .builds: "hammer"
    case .volumes: "externaldrive"
    case .networks: "network"
    case .linuxMachines: "terminal"
    case .kubernetes: "circles.hexagongrid"
    case .macOSVirtualMachines: "macwindow"
    case .settings: "gearshape"
    }
  }
}
