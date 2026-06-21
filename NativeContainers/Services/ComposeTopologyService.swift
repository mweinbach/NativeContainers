import Foundation

protocol ComposeTopologyDeriving: Sendable {
  func derive(from inventory: ContainerInventory) -> ComposeTopologySnapshot
}

struct ComposeTopologyService: ComposeTopologyDeriving {
  func derive(from inventory: ContainerInventory) -> ComposeTopologySnapshot {
    var accumulators: [String: ProjectAccumulator] = [:]

    for container in inventory.containers {
      guard let projectName = labelValue(ComposeLabelKey.project, in: container.labels) else {
        continue
      }

      let instance = ComposeContainerInstance(
        container: container,
        replicaNumber: replicaNumber(in: container.labels),
        isOneOff: oneOffValue(in: container.labels)
      )
      var project = accumulators[projectName, default: ProjectAccumulator()]
      project.collectMetadata(from: container.labels)

      if let serviceName = labelValue(ComposeLabelKey.service, in: container.labels) {
        project.instancesByService[serviceName, default: []].append(instance)
      } else {
        project.ungroupedContainers.append(instance)
      }
      accumulators[projectName] = project
    }

    for volume in inventory.volumes {
      guard let projectName = labelValue(ComposeLabelKey.project, in: volume.labels) else {
        continue
      }
      var project = accumulators[projectName, default: ProjectAccumulator()]
      project.volumes.append(volume)
      project.collectMetadata(from: volume.labels)
      accumulators[projectName] = project
    }

    for network in inventory.networks {
      guard let projectName = labelValue(ComposeLabelKey.project, in: network.labels) else {
        continue
      }
      var project = accumulators[projectName, default: ProjectAccumulator()]
      project.networks.append(network)
      project.collectMetadata(from: network.labels)
      accumulators[projectName] = project
    }

    let projects = accumulators.map { name, accumulator in
      project(name: name, from: accumulator)
    }
    .sorted { composeStringOrder($0.name, $1.name) }

    return snapshot(from: projects)
  }

  private func project(
    name: String,
    from accumulator: ProjectAccumulator
  ) -> ComposeProjectRecord {
    let services = accumulator.instancesByService.map { name, instances in
      ComposeServiceRecord(
        name: name,
        instances: instances.sorted(by: instanceOrder)
      )
    }
    .sorted { composeStringOrder($0.name, $1.name) }

    return ComposeProjectRecord(
      name: name,
      services: services,
      ungroupedContainers: accumulator.ungroupedContainers.sorted(by: instanceOrder),
      volumes: accumulator.volumes.sorted(by: volumeOrder),
      networks: accumulator.networks.sorted(by: networkOrder),
      metadata: ComposeProjectMetadata(
        workingDirectories: accumulator.workingDirectories.sorted(by: composeStringOrder),
        configFileValues: accumulator.configFileValues.sorted(by: composeStringOrder),
        composeVersions: accumulator.composeVersions.sorted(by: composeStringOrder)
      )
    )
  }

  private func snapshot(from projects: [ComposeProjectRecord]) -> ComposeTopologySnapshot {
    var projectNameByContainerID: [String: String] = [:]
    var serviceNameByContainerID: [String: String] = [:]
    var projectNameByVolumeID: [String: String] = [:]
    var projectNameByNetworkID: [String: String] = [:]

    for project in projects {
      for service in project.services {
        for instance in service.instances {
          projectNameByContainerID[instance.id] = project.name
          serviceNameByContainerID[instance.id] = service.name
        }
      }
      for instance in project.ungroupedContainers {
        projectNameByContainerID[instance.id] = project.name
      }
      for volume in project.volumes {
        projectNameByVolumeID[volume.id] = project.name
      }
      for network in project.networks {
        projectNameByNetworkID[network.id] = project.name
      }
    }

    return ComposeTopologySnapshot(
      projects: projects,
      projectNameByContainerID: projectNameByContainerID,
      serviceNameByContainerID: serviceNameByContainerID,
      projectNameByVolumeID: projectNameByVolumeID,
      projectNameByNetworkID: projectNameByNetworkID
    )
  }

  private func labelValue(_ key: String, in labels: [String: String]) -> String? {
    guard let value = labels[key], !value.isEmpty else { return nil }
    return value
  }

  private func replicaNumber(in labels: [String: String]) -> Int? {
    guard
      let value = labelValue(ComposeLabelKey.containerNumber, in: labels),
      let number = Int(value),
      number > 0
    else {
      return nil
    }
    return number
  }

  private func oneOffValue(in labels: [String: String]) -> Bool {
    guard let value = labelValue(ComposeLabelKey.oneOff, in: labels) else { return false }
    return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame
  }

  private func instanceOrder(
    _ lhs: ComposeContainerInstance,
    _ rhs: ComposeContainerInstance
  ) -> Bool {
    switch (lhs.replicaNumber, rhs.replicaNumber) {
    case (let lhsNumber?, let rhsNumber?) where lhsNumber != rhsNumber:
      return lhsNumber < rhsNumber
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      return composeStringOrder(lhs.id, rhs.id)
    }
  }

  private func volumeOrder(_ lhs: VolumeRecord, _ rhs: VolumeRecord) -> Bool {
    if lhs.name != rhs.name {
      return composeStringOrder(lhs.name, rhs.name)
    }
    return composeStringOrder(lhs.id, rhs.id)
  }

  private func networkOrder(_ lhs: NetworkRecord, _ rhs: NetworkRecord) -> Bool {
    if lhs.name != rhs.name {
      return composeStringOrder(lhs.name, rhs.name)
    }
    return composeStringOrder(lhs.id, rhs.id)
  }
}

private struct ProjectAccumulator {
  var instancesByService: [String: [ComposeContainerInstance]] = [:]
  var ungroupedContainers: [ComposeContainerInstance] = []
  var volumes: [VolumeRecord] = []
  var networks: [NetworkRecord] = []
  var workingDirectories: Set<String> = []
  var configFileValues: Set<String> = []
  var composeVersions: Set<String> = []

  mutating func collectMetadata(from labels: [String: String]) {
    insertLabel(ComposeLabelKey.workingDirectory, from: labels, into: &workingDirectories)
    insertLabel(ComposeLabelKey.configFiles, from: labels, into: &configFileValues)
    insertLabel(ComposeLabelKey.version, from: labels, into: &composeVersions)
  }

  private func insertLabel(
    _ key: String,
    from labels: [String: String],
    into values: inout Set<String>
  ) {
    guard let value = labels[key], !value.isEmpty else { return }
    values.insert(value)
  }
}
