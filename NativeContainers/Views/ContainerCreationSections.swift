import AppKit
import SwiftUI

struct ContainerIdentitySection: View {
  @Binding var name: String
  @Binding var imageReference: String
  @Binding var architecture: ContainerArchitecture

  var body: some View {
    Section("Container") {
      TextField("Name", text: $name, prompt: Text("my-container"))
      TextField("Image", text: $imageReference, prompt: Text("alpine:latest"))
      Picker("Architecture", selection: $architecture) {
        Text("Apple silicon (arm64)").tag(ContainerArchitecture.arm64)
        Text("Intel with Rosetta (amd64)").tag(ContainerArchitecture.amd64)
      }
    }
  }
}

struct ContainerResourcesSection: View {
  @Binding var cpuCount: Int
  @Binding var memoryMiB: Int
  let maximumSuggestedCPUCount: Int

  var body: some View {
    Section("Resources") {
      Stepper(value: $cpuCount, in: 1...maximumSuggestedCPUCount) {
        LabeledContent("CPUs", value: cpuCount.formatted())
      }
      Picker("Memory", selection: $memoryMiB) {
        ForEach(ContainerCreationDraft.memoryOptions, id: \.self) { option in
          Text(memoryLabel(option)).tag(option)
        }
      }
    }
  }

  private func memoryLabel(_ value: Int) -> String {
    Int64(value * Int(ContainerCreationRequest.bytesPerMiB)).formatted(
      .byteCount(style: .memory)
    )
  }
}

struct ContainerProcessSection: View {
  @Binding var workingDirectory: String
  @Binding var argumentsText: String
  @Binding var environmentText: String

  var body: some View {
    Section("Process") {
      TextField(
        "Working directory",
        text: $workingDirectory,
        prompt: Text("Use image default")
      )
      LabeledContent("Arguments") {
        ContainerMultilineEditor(
          text: $argumentsText,
          prompt: "One argument per line; leave empty for image defaults",
          minimumHeight: 64
        )
      }
      LabeledContent("Environment") {
        ContainerMultilineEditor(
          text: $environmentText,
          prompt: "One KEY=value entry per line",
          minimumHeight: 76
        )
      }
    }
  }
}

private struct ContainerMultilineEditor: View {
  @Binding var text: String
  let prompt: LocalizedStringKey
  let minimumHeight: CGFloat

  var body: some View {
    TextEditor(text: $text)
      .font(.body.monospaced())
      .frame(minHeight: minimumHeight)
      .overlay(alignment: .topLeading) {
        if text.isEmpty {
          Text(prompt)
            .foregroundStyle(.tertiary)
            .allowsHitTesting(false)
            .padding(.horizontal, 5)
            .padding(.vertical, 7)
        }
      }
  }
}

struct ContainerPortPublicationsSection: View {
  @Binding var ports: [ContainerPortDraft]

  var body: some View {
    Section("Published ports") {
      if ports.isEmpty {
        Text("No host ports published")
          .foregroundStyle(.secondary)
      }
      ForEach($ports) { $port in
        ContainerPortDraftRow(port: $port) {
          ports.removeAll { $0.id == port.id }
        }
      }
      Button("Add Port", systemImage: "plus") {
        ports.append(ContainerPortDraft())
      }
    }
  }
}

struct ContainerPortDraftRow: View {
  @Binding var port: ContainerPortDraft
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      TextField("Host address", text: $port.hostAddress)
        .frame(minWidth: 125)
      TextField("Host", value: $port.hostPort, format: .number)
        .frame(width: 74)
      Image(systemName: "arrow.right")
        .foregroundStyle(.tertiary)
      TextField("Guest", value: $port.containerPort, format: .number)
        .frame(width: 74)
      Picker("Protocol", selection: $port.transportProtocol) {
        ForEach(ContainerTransportProtocol.allCases) { transport in
          Text(transport.rawValue.uppercased()).tag(transport)
        }
      }
      .labelsHidden()
      .frame(width: 76)
      Button("Remove Port", systemImage: "minus.circle", action: onDelete)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
    }
  }
}

struct ContainerStorageSection: View {
  @Binding var mounts: [ContainerVolumeMountDraft]
  let volumes: [VolumeRecord]

  var body: some View {
    Section("Named volumes") {
      if volumes.isEmpty {
        Text("Create a named volume before attaching persistent storage.")
          .foregroundStyle(.secondary)
      } else if mounts.isEmpty {
        Text("No named volumes attached")
          .foregroundStyle(.secondary)
      }

      ForEach($mounts) { $mount in
        ContainerVolumeMountRow(
          mount: $mount,
          volumes: volumes
        ) {
          mounts.removeAll { $0.id == mount.id }
        }
      }

      Button("Attach Volume", systemImage: "externaldrive.badge.plus") {
        addVolume()
      }
      .disabled(nextVolumeName == nil)
    }
  }

  private var nextVolumeName: String? {
    volumes.first { volume in
      !volume.isAnonymous
        && volume.usedByContainerIDs.isEmpty
        && !mounts.contains(where: { $0.volumeName == volume.name })
    }?.name
  }

  private func addVolume() {
    guard let nextVolumeName else { return }
    mounts.append(ContainerVolumeMountDraft(volumeName: nextVolumeName))
  }
}

private struct ContainerVolumeMountRow: View {
  @Binding var mount: ContainerVolumeMountDraft
  let volumes: [VolumeRecord]
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Picker("Volume", selection: $mount.volumeName) {
          ForEach(volumes) { volume in
            Text(volumeLabel(volume)).tag(volume.name)
              .disabled(volume.isAnonymous || !volume.usedByContainerIDs.isEmpty)
          }
        }
        LabeledContent("Container path") {
          TextField(
            "Container path",
            text: $mount.containerPath,
            prompt: Text("/data")
          )
          .labelsHidden()
          .font(.body.monospaced())
        }
        Button("Remove Volume", systemImage: "minus.circle", action: onDelete)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
      }
      Toggle("Mount read-only", isOn: $mount.isReadOnly)
        .toggleStyle(.checkbox)
    }
  }

  private func volumeLabel(_ volume: VolumeRecord) -> String {
    if volume.isAnonymous {
      return "\(volume.name) — anonymous"
    }
    if !volume.usedByContainerIDs.isEmpty {
      return "\(volume.name) — attached to \(volume.usedByContainerIDs.formatted())"
    }
    return volume.name
  }
}

struct ContainerNetworksSection: View {
  @Binding var attachments: [ContainerNetworkAttachmentDraft]
  let networks: [NetworkRecord]

  var body: some View {
    Section("Networks") {
      if networks.isEmpty {
        Text("No container networks are currently available.")
          .foregroundStyle(.secondary)
      }
      ForEach($attachments) { $attachment in
        let index = attachments.firstIndex { $0.id == attachment.id } ?? 0
        ContainerNetworkAttachmentRow(
          attachment: $attachment,
          networks: networks,
          isPrimary: index == 0,
          canMoveUp: index > 0,
          canMoveDown: index + 1 < attachments.count,
          canDelete: attachments.count > 1,
          onMoveUp: { move(id: attachment.id, offset: -1) },
          onMoveDown: { move(id: attachment.id, offset: 1) },
          onDelete: { attachments.removeAll { $0.id == attachment.id } }
        )
      }
      Button("Attach Network", systemImage: "network.badge.shield.half.filled") {
        addNetwork()
      }
      .disabled(nextNetworkID == nil)
      Text(
        "The primary network supplies the container hostname, DNS gateway, and published-port interface."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var nextNetworkID: String? {
    networks.first {
      network in !attachments.contains(where: { $0.networkID == network.id })
    }?.id
  }

  private func addNetwork() {
    guard let nextNetworkID else { return }
    attachments.append(ContainerNetworkAttachmentDraft(networkID: nextNetworkID))
  }

  private func move(id: UUID, offset: Int) {
    guard let source = attachments.firstIndex(where: { $0.id == id }) else { return }
    let destination = source + offset
    guard attachments.indices.contains(destination) else { return }
    attachments.swapAt(source, destination)
  }
}

private struct ContainerNetworkAttachmentRow: View {
  @Binding var attachment: ContainerNetworkAttachmentDraft
  let networks: [NetworkRecord]
  let isPrimary: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let canDelete: Bool
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack {
      if isPrimary {
        Text("Primary")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 54, alignment: .leading)
      } else {
        Text("Attached")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(width: 54, alignment: .leading)
      }
      Picker("Network", selection: $attachment.networkID) {
        ForEach(networks) { network in
          Text(networkLabel(network)).tag(network.id)
        }
      }
      Button("Move Up", systemImage: "chevron.up", action: onMoveUp)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(!canMoveUp)
      Button("Move Down", systemImage: "chevron.down", action: onMoveDown)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(!canMoveDown)
      Button("Remove Network", systemImage: "minus.circle", action: onDelete)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .disabled(!canDelete)
    }
  }

  private func networkLabel(_ network: NetworkRecord) -> String {
    network.isBuiltin ? "\(network.name) — built in" : network.name
  }
}

struct ContainerSocketPublicationsSection: View {
  @Binding var sockets: [ContainerSocketPublicationDraft]
  let socketRootPath: String?

  var body: some View {
    Section("Published Unix sockets") {
      if sockets.isEmpty {
        Text("No container sockets published to the Mac")
          .foregroundStyle(.secondary)
      }
      ForEach($sockets) { $socket in
        ContainerSocketPublicationRow(socket: $socket) {
          sockets.removeAll { $0.id == socket.id }
        }
      }
      Button("Publish Socket", systemImage: "plus") {
        sockets.append(ContainerSocketPublicationDraft())
      }
      Text(socketLocationDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  private var socketLocationDescription: String {
    guard let socketRootPath, !socketRootPath.isEmpty else {
      return "Host sockets use a private app-owned operation directory."
    }
    return
      "Host sockets appear under \(socketRootPath)/<operation-id>/ and are revalidated before every start."
  }
}

private struct ContainerSocketPublicationRow: View {
  @Binding var socket: ContainerSocketPublicationDraft
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Host socket name")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField(
          "Host socket name",
          text: $socket.hostSocketName,
          prompt: Text("service.sock")
        )
        .labelsHidden()
        .font(.body.monospaced())
      }
      Image(systemName: "arrow.left")
        .foregroundStyle(.tertiary)
        .padding(.bottom, 5)
      VStack(alignment: .leading, spacing: 4) {
        Text("Container socket path")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField(
          "Container socket path",
          text: $socket.containerPath,
          prompt: Text("/run/service.sock")
        )
        .labelsHidden()
        .font(.body.monospaced())
      }
      Button("Remove Socket", systemImage: "minus.circle", action: onDelete)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .padding(.bottom, 5)
    }
  }
}

struct ContainerHostAccessSection: View {
  @Binding var isRequired: Bool
  @Binding var selectedConfigurationID: String?
  let catalog: ContainerHostAccessCatalog?

  var body: some View {
    Section("Mac host access") {
      if let catalog, !catalog.configurations.isEmpty {
        Toggle("Require a configured host alias", isOn: $isRequired)
        if isRequired {
          Picker("Host alias", selection: $selectedConfigurationID) {
            Text("Select an alias").tag(nil as String?)
            ForEach(catalog.configurations) { configuration in
              Text("\(configuration.domain) → \(configuration.redirectIPv4Address)")
                .tag(configuration.id as String?)
            }
          }
        }
        Label(
          "Configured on disk; active packet-filter state requires administrator access to verify.",
          systemImage: "checkmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        Text("No safe host alias is configured on disk.")
          .foregroundStyle(.secondary)
        Text(ContainerHostAccessCatalog.setupCommand)
          .font(.caption.monospaced())
          .textSelection(.enabled)
        Button("Copy Privileged Setup Command", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            ContainerHostAccessCatalog.setupCommand,
            forType: .string
          )
        }
      }

      if let warnings = catalog?.warnings {
        ForEach(warnings, id: \.self) { warning in
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      Text(
        "Apple notes that localhost aliases disable Private Relay and their packet-filter redirect may need repair after a Mac restart. NativeContainers never runs the privileged command automatically."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .onChange(of: isRequired) {
      guard isRequired, selectedConfigurationID == nil else { return }
      selectedConfigurationID = catalog?.configurations.first?.id
    }
  }
}

struct ContainerLifecycleSection: View {
  @Binding var startAfterCreation: Bool
  @Binding var useInitProcess: Bool
  @Binding var forwardSSHAgent: Bool
  @Binding var readOnlyRootFilesystem: Bool
  @Binding var removeWhenStopped: Bool

  var body: some View {
    Section("Lifecycle") {
      Toggle("Start after creation", isOn: $startAfterCreation)
      Toggle("Use a minimal init process", isOn: $useInitProcess)
      Toggle("Forward SSH agent", isOn: $forwardSSHAgent)
      Toggle("Read-only root filesystem", isOn: $readOnlyRootFilesystem)
      Toggle("Remove automatically when stopped", isOn: $removeWhenStopped)
    }
  }
}

@MainActor
private struct ContainerAttachmentsPreview: View {
  let volumes: [VolumeRecord]
  let networks: [NetworkRecord]
  let environment: ContainerAttachmentEnvironment

  @State private var mounts: [ContainerVolumeMountDraft]
  @State private var networkAttachments: [ContainerNetworkAttachmentDraft]
  @State private var sockets: [ContainerSocketPublicationDraft]
  @State private var requiresHostAccess = true
  @State private var selectedHostAccessID: String?

  init() {
    let model = AppModel.preview
    let hostAccess = try! ContainerHostAccessConfiguration(
      domain: "host.container.internal",
      redirectIPv4Address: "203.0.113.113"
    )
    volumes = model.volumes
    networks = model.networks
    environment = ContainerAttachmentEnvironment(
      publishedSocketRootPath: "/private/tmp/nativecontainers-501",
      hostAccess: ContainerHostAccessCatalog(
        configurations: [hostAccess],
        warnings: []
      )
    )
    _mounts = State(
      initialValue: [
        ContainerVolumeMountDraft(
          volumeName: "workspace",
          containerPath: "/workspace"
        )
      ]
    )
    _networkAttachments = State(
      initialValue: model.networks.map {
        ContainerNetworkAttachmentDraft(networkID: $0.id)
      }
    )
    _sockets = State(
      initialValue: [
        ContainerSocketPublicationDraft(
          hostSocketName: "api.sock",
          containerPath: "/run/api.sock"
        )
      ]
    )
    _selectedHostAccessID = State(initialValue: hostAccess.id)
  }

  var body: some View {
    Form {
      ContainerStorageSection(mounts: $mounts, volumes: volumes)
      ContainerNetworksSection(
        attachments: $networkAttachments,
        networks: networks
      )
      ContainerSocketPublicationsSection(
        sockets: $sockets,
        socketRootPath: environment.publishedSocketRootPath
      )
      ContainerHostAccessSection(
        isRequired: $requiresHostAccess,
        selectedConfigurationID: $selectedHostAccessID,
        catalog: environment.hostAccess
      )
    }
    .formStyle(.grouped)
    .frame(width: 700, height: 900)
  }
}

#Preview("Container attachments") {
  ContainerAttachmentsPreview()
}
