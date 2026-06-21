import Foundation

protocol ComposeTopologyDeriving: Sendable {
  func derive(from inventory: ContainerInventory) -> ComposeTopologySnapshot
}

struct ComposeTopologyService: ComposeTopologyDeriving {
  func derive(from inventory: ContainerInventory) -> ComposeTopologySnapshot {
    var accumulators: [String: ProjectAccumulator] = [:]
    var notices: [ComposeTopologyNotice] = []

    for container in inventory.containers {
      guard let projectName = container.labels[ComposeLabelKey.project] else {
        continue
      }
      guard isValidProjectName(projectName) else {
        notices.append(
          invalidProjectNotice(
            resourceKind: .container,
            resourceID: container.id,
            projectLabel: projectName
          )
        )
        continue
      }

      let replicaNumberLabel = replicaNumber(in: container.labels)
      let oneOffLabel = oneOffValue(in: container.labels)
      let instance = ComposeContainerInstance(
        container: container,
        replicaNumberLabel: replicaNumberLabel,
        oneOffLabel: oneOffLabel
      )
      if case .invalid(let rawValue) = replicaNumberLabel {
        notices.append(
          invalidOptionalLabelNotice(
            resourceID: container.id,
            projectLabel: projectName,
            expectedLabelKey: ComposeLabelKey.containerNumber,
            rawValue: rawValue
          )
        )
      }
      if case .invalid(let rawValue) = oneOffLabel {
        notices.append(
          invalidOptionalLabelNotice(
            resourceID: container.id,
            projectLabel: projectName,
            expectedLabelKey: ComposeLabelKey.oneOff,
            rawValue: rawValue
          )
        )
      }
      var project = accumulators[projectName, default: ProjectAccumulator()]

      if let serviceName = labelValue(ComposeLabelKey.service, in: container.labels),
        isValidLogicalName(serviceName)
      {
        project.collectContainerMetadata(from: container.labels)
        project.instancesByService[serviceName, default: []].append(instance)
      } else {
        if let serviceName = container.labels[ComposeLabelKey.service] {
          notices.append(
            invalidLogicalNameNotice(
              resourceKind: .container,
              resourceID: container.id,
              projectLabel: projectName,
              expectedLabelKey: ComposeLabelKey.service,
              rawValue: serviceName
            )
          )
        } else {
          notices.append(
            missingResourceLabelNotice(
              resourceKind: .container,
              resourceID: container.id,
              projectLabel: projectName,
              expectedLabelKey: ComposeLabelKey.service
            )
          )
        }
        project.unclassifiedContainers.append(instance)
      }
      accumulators[projectName] = project
    }

    for volume in inventory.volumes {
      guard let projectName = volume.labels[ComposeLabelKey.project] else {
        continue
      }
      guard isValidProjectName(projectName) else {
        notices.append(
          invalidProjectNotice(
            resourceKind: .volume,
            resourceID: volume.id,
            projectLabel: projectName
          )
        )
        continue
      }
      guard let logicalName = volume.labels[ComposeLabelKey.volume] else {
        notices.append(
          missingResourceLabelNotice(
            resourceKind: .volume,
            resourceID: volume.id,
            projectLabel: projectName,
            expectedLabelKey: ComposeLabelKey.volume
          )
        )
        continue
      }
      guard isValidLogicalName(logicalName) else {
        notices.append(
          invalidLogicalNameNotice(
            resourceKind: .volume,
            resourceID: volume.id,
            projectLabel: projectName,
            expectedLabelKey: ComposeLabelKey.volume,
            rawValue: logicalName
          )
        )
        continue
      }
      guard !volume.isAnonymous else {
        notices.append(
          ComposeTopologyNotice(
            kind: .anonymousVolume,
            resourceKind: .volume,
            resourceID: volume.id,
            projectLabel: projectName,
            expectedLabelKey: nil
          )
        )
        continue
      }
      var project = accumulators[projectName, default: ProjectAccumulator()]
      project.volumes.append(
        ComposeVolumeObservation(logicalName: logicalName, volume: volume)
      )
      project.collectVersion(from: volume.labels)
      accumulators[projectName] = project
    }

    for network in inventory.networks {
      guard let projectName = network.labels[ComposeLabelKey.project] else {
        continue
      }
      guard isValidProjectName(projectName) else {
        notices.append(
          invalidProjectNotice(
            resourceKind: .network,
            resourceID: network.id,
            projectLabel: projectName
          )
        )
        continue
      }
      guard let logicalName = network.labels[ComposeLabelKey.network] else {
        notices.append(
          missingResourceLabelNotice(
            resourceKind: .network,
            resourceID: network.id,
            projectLabel: projectName,
            expectedLabelKey: ComposeLabelKey.network
          )
        )
        continue
      }
      guard isValidLogicalName(logicalName) else {
        notices.append(
          invalidLogicalNameNotice(
            resourceKind: .network,
            resourceID: network.id,
            projectLabel: projectName,
            expectedLabelKey: ComposeLabelKey.network,
            rawValue: logicalName
          )
        )
        continue
      }
      guard !network.isBuiltin else {
        notices.append(
          ComposeTopologyNotice(
            kind: .builtinNetwork,
            resourceKind: .network,
            resourceID: network.id,
            projectLabel: projectName,
            expectedLabelKey: nil
          )
        )
        continue
      }
      var project = accumulators[projectName, default: ProjectAccumulator()]
      project.networks.append(
        ComposeNetworkObservation(logicalName: logicalName, network: network)
      )
      project.collectVersion(from: network.labels)
      accumulators[projectName] = project
    }

    let projects: [ComposeProjectRecord] = accumulators.compactMap { element in
      let (name, accumulator) = element
      guard accumulator.hasCanonicalResources else { return nil }
      return project(name: name, from: accumulator)
    }
    .sorted { composeStringOrder($0.name, $1.name) }

    notices.append(contentsOf: consumerConflictNotices(in: projects))

    return snapshot(
      from: projects,
      notices: notices.sorted(by: noticeOrder)
    )
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
      unclassifiedContainers: accumulator.unclassifiedContainers.sorted(by: instanceOrder),
      volumes: accumulator.volumes.sorted(by: volumeOrder),
      networks: accumulator.networks.sorted(by: networkOrder),
      metadata: ComposeProjectMetadata(
        workingDirectories: accumulator.workingDirectories.sorted(by: composeStringOrder),
        configFileValues: accumulator.configFileValues.sorted(by: composeStringOrder),
        composeVersions: accumulator.composeVersions.sorted(by: composeStringOrder)
      )
    )
  }

  private func snapshot(
    from projects: [ComposeProjectRecord],
    notices: [ComposeTopologyNotice]
  ) -> ComposeTopologySnapshot {
    var containerAssociationsByID: [String: ComposeContainerAssociation] = [:]
    var volumeAssociationsByID: [String: ComposeResourceAssociation] = [:]
    var networkAssociationsByID: [String: ComposeResourceAssociation] = [:]

    for project in projects {
      for service in project.services {
        for instance in service.instances {
          containerAssociationsByID[instance.id] = ComposeContainerAssociation(
            projectName: project.name,
            serviceName: service.name,
            replicaNumber: instance.replicaNumberLabel,
            oneOff: instance.oneOffLabel
          )
        }
      }
      for observation in project.volumes {
        volumeAssociationsByID[observation.id] = ComposeResourceAssociation(
          projectName: project.name,
          logicalName: observation.logicalName
        )
      }
      for observation in project.networks {
        networkAssociationsByID[observation.id] = ComposeResourceAssociation(
          projectName: project.name,
          logicalName: observation.logicalName
        )
      }
    }

    return ComposeTopologySnapshot(
      projects: projects,
      notices: notices,
      containerAssociationsByID: containerAssociationsByID,
      volumeAssociationsByID: volumeAssociationsByID,
      networkAssociationsByID: networkAssociationsByID
    )
  }

  private func labelValue(_ key: String, in labels: [String: String]) -> String? {
    guard let value = labels[key], !value.isEmpty else { return nil }
    return value
  }

  private func isValidProjectName(_ value: String) -> Bool {
    guard let first = value.utf8.first, isLowercaseASCIILetter(first) || isASCIIDigit(first) else {
      return false
    }
    return value.utf8.allSatisfy { character in
      isLowercaseASCIILetter(character)
        || isASCIIDigit(character)
        || character == 45
        || character == 95
    }
  }

  private func isValidLogicalName(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy { character in
        isLowercaseASCIILetter(character)
          || (character >= 65 && character <= 90)
          || isASCIIDigit(character)
          || character == 45
          || character == 46
          || character == 95
      }
  }

  private func isLowercaseASCIILetter(_ character: UInt8) -> Bool {
    character >= 97 && character <= 122
  }

  private func isASCIIDigit(_ character: UInt8) -> Bool {
    character >= 48 && character <= 57
  }

  private func invalidProjectNotice(
    resourceKind: ComposeTopologyResourceKind,
    resourceID: String,
    projectLabel: String
  ) -> ComposeTopologyNotice {
    ComposeTopologyNotice(
      kind: .invalidProjectName,
      resourceKind: resourceKind,
      resourceID: resourceID,
      projectLabel: projectLabel,
      expectedLabelKey: nil
    )
  }

  private func missingResourceLabelNotice(
    resourceKind: ComposeTopologyResourceKind,
    resourceID: String,
    projectLabel: String,
    expectedLabelKey: String
  ) -> ComposeTopologyNotice {
    ComposeTopologyNotice(
      kind: .missingResourceLabel,
      resourceKind: resourceKind,
      resourceID: resourceID,
      projectLabel: projectLabel,
      expectedLabelKey: expectedLabelKey
    )
  }

  private func invalidLogicalNameNotice(
    resourceKind: ComposeTopologyResourceKind,
    resourceID: String,
    projectLabel: String,
    expectedLabelKey: String,
    rawValue: String
  ) -> ComposeTopologyNotice {
    ComposeTopologyNotice(
      kind: .invalidLogicalName,
      resourceKind: resourceKind,
      resourceID: resourceID,
      projectLabel: projectLabel,
      expectedLabelKey: expectedLabelKey,
      observedValue: rawValue
    )
  }

  private func invalidOptionalLabelNotice(
    resourceID: String,
    projectLabel: String,
    expectedLabelKey: String,
    rawValue: String
  ) -> ComposeTopologyNotice {
    ComposeTopologyNotice(
      kind: .invalidOptionalLabel,
      resourceKind: .container,
      resourceID: resourceID,
      projectLabel: projectLabel,
      expectedLabelKey: expectedLabelKey,
      observedValue: rawValue
    )
  }

  private func replicaNumber(in labels: [String: String]) -> ObservedOptionalLabel<Int> {
    guard let value = labels[ComposeLabelKey.containerNumber] else { return .absent }
    guard let number = Int(value), number > 0 else { return .invalid(rawValue: value) }
    return .valid(number)
  }

  private func oneOffValue(in labels: [String: String]) -> ObservedOptionalLabel<Bool> {
    guard let value = labels[ComposeLabelKey.oneOff] else { return .absent }
    if value == "1" || value.caseInsensitiveCompare("true") == .orderedSame {
      return .valid(true)
    }
    if value == "0" || value.caseInsensitiveCompare("false") == .orderedSame {
      return .valid(false)
    }
    return .invalid(rawValue: value)
  }

  private func consumerConflictNotices(
    in projects: [ComposeProjectRecord]
  ) -> [ComposeTopologyNotice] {
    let containerProjects = Dictionary(
      uniqueKeysWithValues: projects.flatMap { project in
        project.containers.map { ($0.id, project.name) }
      }
    )
    var notices: [ComposeTopologyNotice] = []

    for project in projects {
      for observation in project.volumes {
        let conflictingProjects = Set(
          observation.volume.usedByContainerIDs.compactMap { containerProjects[$0] }
            .filter { $0 != project.name }
        ).sorted(by: composeStringOrder)
        if !conflictingProjects.isEmpty {
          notices.append(
            ComposeTopologyNotice(
              kind: .consumerProjectMismatch,
              resourceKind: .volume,
              resourceID: observation.id,
              projectLabel: project.name,
              expectedLabelKey: nil,
              relatedProjectNames: conflictingProjects
            )
          )
        }
      }

      for observation in project.networks {
        let conflictingProjects = Set(
          observation.network.usedByContainerIDs.compactMap { containerProjects[$0] }
            .filter { $0 != project.name }
        ).sorted(by: composeStringOrder)
        if !conflictingProjects.isEmpty {
          notices.append(
            ComposeTopologyNotice(
              kind: .consumerProjectMismatch,
              resourceKind: .network,
              resourceID: observation.id,
              projectLabel: project.name,
              expectedLabelKey: nil,
              relatedProjectNames: conflictingProjects
            )
          )
        }
      }
    }
    return notices
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

  private func volumeOrder(
    _ lhs: ComposeVolumeObservation,
    _ rhs: ComposeVolumeObservation
  ) -> Bool {
    if lhs.logicalName != rhs.logicalName {
      return composeStringOrder(lhs.logicalName, rhs.logicalName)
    }
    return composeStringOrder(lhs.id, rhs.id)
  }

  private func networkOrder(
    _ lhs: ComposeNetworkObservation,
    _ rhs: ComposeNetworkObservation
  ) -> Bool {
    if lhs.logicalName != rhs.logicalName {
      return composeStringOrder(lhs.logicalName, rhs.logicalName)
    }
    return composeStringOrder(lhs.id, rhs.id)
  }

  private func noticeOrder(_ lhs: ComposeTopologyNotice, _ rhs: ComposeTopologyNotice) -> Bool {
    if lhs.resourceKind != rhs.resourceKind {
      return lhs.resourceKind.rawValue < rhs.resourceKind.rawValue
    }
    if lhs.resourceID != rhs.resourceID {
      return composeStringOrder(lhs.resourceID, rhs.resourceID)
    }
    return composeStringOrder(lhs.id, rhs.id)
  }
}

private struct ProjectAccumulator {
  var instancesByService: [String: [ComposeContainerInstance]] = [:]
  var unclassifiedContainers: [ComposeContainerInstance] = []
  var volumes: [ComposeVolumeObservation] = []
  var networks: [ComposeNetworkObservation] = []
  var workingDirectories: Set<String> = []
  var configFileValues: Set<String> = []
  var composeVersions: Set<String> = []

  var hasCanonicalResources: Bool {
    !instancesByService.isEmpty || !volumes.isEmpty || !networks.isEmpty
  }

  mutating func collectContainerMetadata(from labels: [String: String]) {
    insertLabel(ComposeLabelKey.workingDirectory, from: labels, into: &workingDirectories)
    insertLabel(ComposeLabelKey.configFiles, from: labels, into: &configFileValues)
    collectVersion(from: labels)
  }

  mutating func collectVersion(from labels: [String: String]) {
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
