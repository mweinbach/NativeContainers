import SwiftUI

enum SidebarDestination: String, CaseIterable, Hashable, Identifiable {
  case overview
  case containers
  case images
  case builds
  case volumes
  case linuxMachines
  case macOSVirtualMachines
  case settings

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .overview: "Overview"
    case .containers: "Containers"
    case .images: "Images"
    case .builds: "Builds"
    case .volumes: "Volumes"
    case .linuxMachines: "Linux Machines"
    case .macOSVirtualMachines: "macOS VMs"
    case .settings: "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .containers: "shippingbox"
    case .images: "square.stack.3d.up"
    case .builds: "hammer"
    case .volumes: "externaldrive"
    case .linuxMachines: "terminal"
    case .macOSVirtualMachines: "macwindow"
    case .settings: "gearshape"
    }
  }
}
