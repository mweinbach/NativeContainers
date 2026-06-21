import Foundation

enum WorkspaceRoute: Hashable, Sendable {
  case overview
  case containers
  case container(String)
  case images
  case image(String)
  case builds
  case volumes
  case volume(String)
  case networks
  case network(String)
  case linuxMachines
  case linuxMachine(String)
  case macOSVirtualMachines
  case macOSVirtualMachine(UUID)
  case settings

  var baseRoute: WorkspaceRoute {
    switch self {
    case .overview:
      .overview
    case .containers, .container:
      .containers
    case .images, .image:
      .images
    case .builds:
      .builds
    case .volumes, .volume:
      .volumes
    case .networks, .network:
      .networks
    case .linuxMachines, .linuxMachine:
      .linuxMachines
    case .macOSVirtualMachines, .macOSVirtualMachine:
      .macOSVirtualMachines
    case .settings:
      .settings
    }
  }

  var isResourceRoute: Bool {
    switch self {
    case .container, .image, .volume, .network, .linuxMachine, .macOSVirtualMachine:
      true
    case .overview, .containers, .images, .builds, .volumes, .networks,
      .linuxMachines, .macOSVirtualMachines, .settings:
      false
    }
  }

  var stableIdentifier: String {
    switch self {
    case .overview:
      "overview"
    case .containers:
      "containers"
    case .container(let id):
      "container:\(id)"
    case .images:
      "images"
    case .image(let reference):
      "image:\(reference)"
    case .builds:
      "builds"
    case .volumes:
      "volumes"
    case .volume(let id):
      "volume:\(id)"
    case .networks:
      "networks"
    case .network(let id):
      "network:\(id)"
    case .linuxMachines:
      "linux-machines"
    case .linuxMachine(let id):
      "linux-machine:\(id)"
    case .macOSVirtualMachines:
      "macos-virtual-machines"
    case .macOSVirtualMachine(let id):
      "macos-virtual-machine:\(id.uuidString.lowercased())"
    case .settings:
      "settings"
    }
  }
}

enum WorkspaceResourceKind: Int, CaseIterable, Sendable {
  case container
  case image
  case volume
  case network
  case linuxMachine
  case macOSVirtualMachine

  var title: LocalizedStringResource {
    switch self {
    case .container:
      "Container"
    case .image:
      "Image"
    case .volume:
      "Volume"
    case .network:
      "Network"
    case .linuxMachine:
      "Linux Machine"
    case .macOSVirtualMachine:
      "macOS VM"
    }
  }

  var systemImage: String {
    switch self {
    case .container:
      "shippingbox"
    case .image:
      "square.stack.3d.up"
    case .volume:
      "externaldrive"
    case .network:
      "network"
    case .linuxMachine:
      "terminal"
    case .macOSVirtualMachine:
      "macwindow"
    }
  }

  var searchTerms: [String] {
    switch self {
    case .container:
      ["container"]
    case .image:
      ["image", "oci"]
    case .volume:
      ["volume", "storage"]
    case .network:
      ["network", "subnet"]
    case .linuxMachine:
      ["linux", "machine", "vm"]
    case .macOSVirtualMachine:
      ["macos", "mac", "virtual machine", "vm"]
    }
  }
}

struct WorkspaceResourceEntry: Identifiable, Equatable, Sendable {
  let route: WorkspaceRoute
  let kind: WorkspaceResourceKind
  let title: String
  let subtitle: String
  let searchTerms: [String]

  var id: WorkspaceRoute { route }
}

struct WorkspaceResourceSnapshot: Equatable, Sendable {
  let containers: [ContainerRecord]
  let images: [ImageRecord]
  let volumes: [VolumeRecord]
  let networks: [NetworkRecord]
  let linuxMachines: [LinuxMachineRecord]
  let macOSVirtualMachines: [VirtualMachineManifest]

  init(
    containers: [ContainerRecord] = [],
    images: [ImageRecord] = [],
    volumes: [VolumeRecord] = [],
    networks: [NetworkRecord] = [],
    linuxMachines: [LinuxMachineRecord] = [],
    macOSVirtualMachines: [VirtualMachineManifest] = []
  ) {
    self.containers = containers
    self.images = images
    self.volumes = volumes
    self.networks = networks
    self.linuxMachines = linuxMachines
    self.macOSVirtualMachines = macOSVirtualMachines
  }
}
