import SwiftUI

struct ComposeProjectsView: View {
  let model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      if !model.composeTopology.notices.isEmpty {
        ComposeTopologyNoticesBanner(notices: model.composeTopology.notices)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
      }
      if model.composeProjects.isEmpty {
        ContentUnavailableView(
          "No Compose projects",
          systemImage: "square.stack.3d.down.right",
          description: Text(
            "Projects created by Compose appear here when Apple’s inventory includes canonical Compose labels."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HSplitView {
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(model.composeProjects) { project in
                Button {
                  model.navigate(to: .composeProject(project.name))
                } label: {
                  ComposeProjectRow(
                    project: project,
                    isSelected: selectedProjectName == project.name
                  )
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
              }
            }
            .padding(8)
          }
          .frame(minWidth: 330, idealWidth: 390)
          .background(.background.secondary)

          if let project = selectedProject {
            ComposeProjectInspector(project: project, model: model)
              .id(project.id)
              .frame(minWidth: 500)
          } else {
            ContentUnavailableView(
              "Select a project",
              systemImage: "sidebar.right",
              description: Text("Inspect observed services, containers, volumes, and networks.")
            )
            .frame(minWidth: 500)
          }
        }
        .onChange(of: model.composeProjects, initial: true) {
          synchronizeSelection()
        }
      }
    }
    .navigationTitle("Compose Projects")
  }

  private var selectedProjectName: String? {
    guard case .composeProject(let name) = model.workspaceRoute else { return nil }
    return name
  }

  private var selectedProject: ComposeProjectRecord? {
    guard let selectedProjectName else { return nil }
    return model.composeTopology.project(named: selectedProjectName)
  }

  private func synchronizeSelection() {
    guard selectedProject == nil else { return }
    if let name = model.composeProjects.first?.name {
      model.navigate(to: .composeProject(name))
    }
  }
}

private struct ComposeProjectRow: View {
  let project: ComposeProjectRecord
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "square.stack.3d.down.right.fill")
        .font(.title2)
        .foregroundStyle(.indigo)
        .frame(width: 30)

      VStack(alignment: .leading, spacing: 5) {
        Text(project.name)
          .font(.headline)
          .lineLimit(1)
        HStack(spacing: 8) {
          Text("\(project.runningContainerCount)/\(project.containerCount) running")
          Text("·")
          Text("\(project.serviceCount) services")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        HStack(spacing: 10) {
          Label(project.volumes.count.formatted(), systemImage: "externaldrive")
          Label(project.networks.count.formatted(), systemImage: "network")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
      }

      Spacer(minLength: 10)
      ComposeProjectRuntimeBadge(project: project)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(
      isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
  }
}

private struct ComposeProjectInspector: View {
  let project: ComposeProjectRecord
  let model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header
        ComposeProjectProvenanceBanner()

        if !project.services.isEmpty {
          ComposeServicesSection(project: project, model: model)
        }

        if !project.unclassifiedContainers.isEmpty {
          ComposeUngroupedContainersSection(project: project, model: model)
        }

        if !project.volumes.isEmpty || !project.networks.isEmpty {
          ComposeProjectResourcesSection(project: project, model: model)
        }

        if project.metadata != .empty {
          ComposeProjectMetadataSection(metadata: project.metadata)
        }
      }
      .padding(24)
    }
    .background(.background)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "square.stack.3d.down.right.fill")
        .font(.largeTitle)
        .foregroundStyle(.indigo)

      VStack(alignment: .leading, spacing: 6) {
        Text(project.name)
          .font(.title.bold())
          .textSelection(.enabled)
        HStack(spacing: 10) {
          ComposeProjectRuntimeBadge(project: project)
          Text(
            "\(project.runningContainerCount) of \(project.containerCount) containers running"
          )
          .foregroundStyle(.secondary)
        }
        .font(.subheadline)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 4) {
        Text(project.serviceCount.formatted())
          .font(.title2.bold().monospacedDigit())
        Text(project.serviceCount == 1 ? "service" : "services")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct ComposeProjectProvenanceBanner: View {
  var body: some View {
    Label {
      Text(
        "Read-only topology derived from canonical Compose labels in one Apple runtime inventory refresh. Manage lifecycle on each underlying resource."
      )
    } icon: {
      Image(systemName: "info.circle.fill")
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct ComposeTopologyNoticesBanner: View {
  let notices: [ComposeTopologyNotice]

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(notices) { notice in
          VStack(alignment: .leading, spacing: 2) {
            Text("\(resourceTitle(notice.resourceKind)) · \(notice.resourceID)")
              .font(.caption.weight(.semibold))
              .textSelection(.enabled)
            Text(detail(notice))
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
      .padding(.top, 8)
    } label: {
      Label {
        Text(
          "\(notices.count) topology evidence \(notices.count == 1 ? "notice was" : "notices were") recorded for incomplete or invalid labels, excluded special resources, or cross-project consumers."
        )
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
    }
    .font(.callout)
    .foregroundStyle(.orange)
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
  }

  private func resourceTitle(_ kind: ComposeTopologyResourceKind) -> String {
    switch kind {
    case .container: "Container"
    case .volume: "Volume"
    case .network: "Network"
    }
  }

  private func detail(_ notice: ComposeTopologyNotice) -> String {
    switch notice.kind {
    case .invalidProjectName:
      "Invalid project label: \(notice.projectLabel.isEmpty ? "<empty>" : notice.projectLabel)"
    case .invalidLogicalName:
      "Invalid value “\(notice.observedValue ?? "")” for \(notice.expectedLabelKey ?? "canonical logical-name label")."
    case .invalidOptionalLabel:
      "Invalid optional value “\(notice.observedValue ?? "")” for \(notice.expectedLabelKey ?? "Compose label")."
    case .missingResourceLabel:
      "Missing \(notice.expectedLabelKey ?? "required canonical label")."
    case .anonymousVolume:
      "Anonymous volumes are not canonical named Compose project resources."
    case .builtinNetwork:
      "Apple’s built-in network is not a Compose project resource."
    case .consumerProjectMismatch:
      "Also referenced by canonical project(s): \(notice.relatedProjectNames.formatted())."
    }
  }
}

struct ComposeMembershipBanner: View {
  let projectName: String
  let memberName: String?
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 10) {
        Image(systemName: "square.stack.3d.down.right.fill")
          .foregroundStyle(.indigo)
        VStack(alignment: .leading, spacing: 2) {
          Text("Compose project")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack(spacing: 6) {
            Text(projectName)
              .font(.callout.weight(.semibold))
            if let memberName {
              Text("·")
                .foregroundStyle(.tertiary)
              Text(memberName)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
        Spacer()
        Text("Open project")
          .font(.callout)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
      }
      .padding(12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityHint("Opens the observed Compose project")
  }
}

private struct ComposeServicesSection: View {
  let project: ComposeProjectRecord
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Services")
        .font(.title2.bold())

      VStack(spacing: 12) {
        ForEach(project.services) { service in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                  .font(.headline)
                  .textSelection(.enabled)
                if !service.imageReferences.isEmpty {
                  Text(service.imageReferences.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
              Spacer()
              Text("\(service.runningContainerCount)/\(service.containerCount) running")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Divider()

            ForEach(service.instances) { instance in
              ComposeContainerLink(
                instance: instance,
                onOpen: { model.navigate(to: .container(instance.id)) }
              )
            }
          }
          .padding(14)
          .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
      }
    }
  }
}

private struct ComposeUngroupedContainersSection: View {
  let project: ComposeProjectRecord
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Excluded container evidence")
          .font(.title3.bold())
        Text(
          "These containers have the project label but no valid canonical service label. They do not affect project counts or observed state."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      VStack(spacing: 0) {
        ForEach(project.unclassifiedContainers) { instance in
          ComposeContainerLink(
            instance: instance,
            onOpen: { model.navigate(to: .container(instance.id)) }
          )
          if instance.id != project.unclassifiedContainers.last?.id {
            Divider()
          }
        }
      }
      .padding(.horizontal, 14)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
  }
}

private struct ComposeContainerLink: View {
  let instance: ComposeContainerInstance
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 10) {
        RuntimeStatusIndicator(state: instance.container.state)
        VStack(alignment: .leading, spacing: 2) {
          Text(instance.id)
            .font(.body.weight(.medium))
          Text(instance.container.imageReference)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if let replicaNumber = instance.replicaNumber {
          Text("Replica \(replicaNumber)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if instance.isOneOff {
          Text("One-off")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.12), in: Capsule())
        }
        RuntimeStateBadge(state: instance.container.state)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.vertical, 9)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens this container")
  }
}

private struct ComposeProjectResourcesSection: View {
  let project: ComposeProjectRecord
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Resources with canonical labels")
        .font(.title2.bold())

      VStack(spacing: 0) {
        ForEach(project.volumes) { observation in
          ComposeResourceLink(
            title: observation.logicalName,
            detail: volumeDetail(observation),
            systemImage: "externaldrive.fill",
            tint: .orange,
            onOpen: { model.navigate(to: .volume(observation.id)) }
          )
          if observation.id != project.volumes.last?.id || !project.networks.isEmpty {
            Divider()
          }
        }

        ForEach(project.networks) { observation in
          ComposeResourceLink(
            title: observation.logicalName,
            detail: networkDetail(observation),
            systemImage: "network",
            tint: .teal,
            onOpen: { model.navigate(to: .network(observation.id)) }
          )
          if observation.id != project.networks.last?.id {
            Divider()
          }
        }
      }
      .padding(.horizontal, 14)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private func volumeDetail(_ observation: ComposeVolumeObservation) -> String {
    let volume = observation.volume
    if observation.logicalName == volume.name {
      return "\(volume.driver) · \(volume.format)"
    }
    return "Runtime \(volume.name) · \(volume.driver) · \(volume.format)"
  }

  private func networkDetail(_ observation: ComposeNetworkObservation) -> String {
    let network = observation.network
    if observation.logicalName == network.name {
      return network.assignedIPv4Subnet
    }
    return "Runtime \(network.name) · \(network.assignedIPv4Subnet)"
  }
}

private struct ComposeResourceLink: View {
  let title: String
  let detail: String
  let systemImage: String
  let tint: Color
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .foregroundStyle(tint)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.body.weight(.medium))
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens this resource")
  }
}

private struct ComposeProjectMetadataSection: View {
  let metadata: ComposeProjectMetadata

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Observed metadata")
        .font(.title2.bold())

      if metadata.hasConflictingSourceMetadata {
        Label(
          "Conflicting source metadata was observed across service containers.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.orange)
      }

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
        if !metadata.composeVersions.isEmpty {
          metadataRow("Compose version", values: metadata.composeVersions)
        }
        if !metadata.workingDirectories.isEmpty {
          metadataRow("Working directory", values: metadata.workingDirectories)
        }
        if !metadata.configFileValues.isEmpty {
          metadataRow("Config files", values: metadata.configFileValues)
        }
      }
      .font(.callout)
    }
  }

  private func metadataRow(_ title: LocalizedStringResource, values: [String]) -> some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
      Text(values.formatted())
        .font(.callout.monospaced())
        .textSelection(.enabled)
    }
  }
}

struct ComposeProjectRuntimeBadge: View {
  let project: ComposeProjectRecord

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(tint.opacity(0.12), in: Capsule())
  }

  private var title: LocalizedStringResource {
    switch project.observedState {
    case .noContainers: "No containers"
    case .allRunning: "All running"
    case .partiallyRunning: "Partially running"
    case .noneRunning: "None running"
    case .transitioning: "Transitioning"
    case .unknown: "Unknown"
    }
  }

  private var systemImage: String {
    switch project.observedState {
    case .allRunning: "play.circle.fill"
    case .partiallyRunning: "circle.lefthalf.filled"
    case .transitioning: "clock.arrow.circlepath"
    case .noneRunning: "stop.circle.fill"
    case .noContainers: "shippingbox"
    case .unknown: "questionmark.circle.fill"
    }
  }

  private var tint: Color {
    switch project.observedState {
    case .allRunning: .green
    case .partiallyRunning, .transitioning: .orange
    case .noneRunning: .secondary
    case .noContainers: .blue
    case .unknown: .secondary
    }
  }
}

struct ComposeProjectsOverviewSection: View {
  let projects: [ComposeProjectRecord]
  let onOpen: (WorkspaceRoute) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Compose projects")
          .font(.title2.bold())
        Spacer()
        Button("Open all") {
          onOpen(.composeProjects)
        }
        .buttonStyle(.link)
      }

      VStack(spacing: 0) {
        ForEach(Array(projects.prefix(4))) { project in
          Button {
            onOpen(.composeProject(project.name))
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "square.stack.3d.down.right.fill")
                .foregroundStyle(.indigo)
                .frame(width: 26)
              VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                  .font(.headline)
                Text(
                  "\(project.runningContainerCount)/\(project.containerCount) containers running · \(project.serviceCount) services"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              Spacer()
              ComposeProjectRuntimeBadge(project: project)
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)

          if project.id != projects.prefix(4).last?.id {
            Divider()
          }
        }
      }
      .background(.background, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(.separator.opacity(0.55), lineWidth: 1)
      }
    }
  }
}

#Preview("Compose Projects") {
  NavigationStack {
    ComposeProjectsView(model: .preview)
  }
  .frame(width: 1_080, height: 720)
}
