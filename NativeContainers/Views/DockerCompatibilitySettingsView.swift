import SwiftUI

struct DockerCompatibilitySettingsSection: View {
  @State private var model: DockerCompatibilityModel
  @State private var isConfirmingRepair = false
  @State private var isConfirmingForceStop = false
  @State private var isConfirmingStaleSocketRemoval = false

  init(appModel: AppModel) {
    _model = State(initialValue: appModel.makeDockerCompatibilityModel())
  }

  var body: some View {
    Section {
      if let snapshot = model.snapshot {
        LabeledContent("Pinned bridge") {
          Text("Socktainer \(snapshot.release.version)")
            .textSelection(.enabled)
        }
        LabeledContent("Installation") {
          statusLabel(
            installationTitle(snapshot.installation),
            systemImage: installationSymbol(snapshot.installation),
            color: installationColor(snapshot.installation)
          )
        }
        LabeledContent("Apple runtime") {
          statusLabel(
            appleRuntimeTitle(snapshot.appleContainer),
            systemImage: appleRuntimeSymbol(snapshot.appleContainer),
            color: appleRuntimeColor(snapshot.appleContainer)
          )
        }
        LabeledContent("Bridge") {
          statusLabel(
            runtimeTitle(snapshot.runtime),
            systemImage: runtimeSymbol(snapshot.runtime),
            color: runtimeColor(snapshot.runtime)
          )
        }
        actionRow(snapshot)
        LabeledContent("Socket") {
          Text(snapshot.socketURL.path(percentEncoded: false))
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        LabeledContent("Docker context") {
          statusLabel(
            contextTitle(snapshot.dockerContext.state),
            systemImage: contextSymbol(snapshot.dockerContext.state),
            color: contextColor(snapshot.dockerContext.state)
          )
        }
        if let activeContext = snapshot.dockerContext.activeContext {
          LabeledContent("Active context", value: activeContext)
        }

        if case .invalid(let reason) = snapshot.installation {
          warningLabel(reason)
        }
        if case .failed(let reason) = snapshot.runtime {
          warningLabel(reason)
        }
        if case .failed(let reason) = snapshot.dockerContext.state {
          warningLabel(reason)
        }
        if !snapshot.dockerContext.environmentOverrides.isEmpty {
          warningLabel(
            "Shell overrides can bypass nativecontainers: "
              + snapshot.dockerContext.environmentOverrides.joined(separator: ", ")
          )
        }

        Text("Use docker --context nativecontainers …; setup never changes the active context.")
          .font(.caption.monospaced())
          .textSelection(.enabled)

        Text(
          "Compatibility is optional and partial: Socktainer exposes part of Docker Engine API v1.51. Compose behavior remains experimental and is not represented as native Apple runtime support."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        ProgressView("Inspecting Docker compatibility…")
      }

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    } header: {
      HStack {
        Text("Docker compatibility")
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await model.load() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(model.isRefreshing || model.isWorking)
        .help("Refresh Docker compatibility status")
      }
    }
    .task {
      await model.load()
    }
    .confirmationDialog(
      "Repair nativecontainers context?",
      isPresented: $isConfirmingRepair
    ) {
      Button("Repair Context") {
        Task { await model.createOrRepairContext() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This updates only the nativecontainers context endpoint. It does not select that context or modify the active Docker context."
      )
    }
    .confirmationDialog(
      "Force stop Socktainer?",
      isPresented: $isConfirmingForceStop
    ) {
      Button("Force Stop", role: .destructive) {
        Task { await model.forceStop() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This sends SIGKILL only to the exact process launched by NativeContainers, then confirms exit and removes only its captured socket inode."
      )
    }
    .confirmationDialog(
      "Remove stale Socktainer socket?",
      isPresented: $isConfirmingStaleSocketRemoval
    ) {
      Button("Remove Stale Socket", role: .destructive) {
        Task { await model.removeStaleSocket() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "NativeContainers checks three times that no process is listening and that the socket inode has not changed. A live external bridge is never killed or unlinked."
      )
    }
  }

  @ViewBuilder
  private func actionRow(_ snapshot: DockerCompatibilitySnapshot) -> some View {
    HStack {
      if !isInstalled(snapshot.installation) {
        Button("Install Pinned Bridge", systemImage: "arrow.down.circle") {
          Task { await model.install() }
        }
        .disabled(model.isWorking || isRuntimeBusy(snapshot.runtime))
      }

      switch snapshot.runtime {
      case .running:
        Button("Stop", systemImage: "stop.fill") {
          Task { await model.stop() }
        }
        .disabled(model.isWorking)

        Button("Force Stop", systemImage: "bolt.fill", role: .destructive) {
          isConfirmingForceStop = true
        }
        .disabled(model.isWorking)
      case .starting, .stopping:
        ProgressView()
          .controlSize(.small)
      case .blockedByForeignSocket:
        Button("Remove Stale Socket", systemImage: "trash", role: .destructive) {
          isConfirmingStaleSocketRemoval = true
        }
        .disabled(model.isWorking)
      case .stopped, .failed:
        Button("Start", systemImage: "play.fill") {
          Task { await model.start() }
        }
        .disabled(model.isWorking || !canStart(snapshot))
      }

      Spacer()

      switch snapshot.dockerContext.state {
      case .missing:
        Button("Create Context", systemImage: "plus.circle") {
          Task { await model.createOrRepairContext() }
        }
        .disabled(model.isWorking)
      case .drifted:
        Button("Repair Context", systemImage: "wrench.and.screwdriver") {
          isConfirmingRepair = true
        }
        .disabled(model.isWorking)
      case .ready, .dockerUnavailable, .failed:
        EmptyView()
      }
    }
  }

  private func statusLabel(
    _ title: String,
    systemImage: String,
    color: Color
  ) -> some View {
    Label(title, systemImage: systemImage)
      .foregroundStyle(color)
      .textSelection(.enabled)
  }

  private func warningLabel(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(.caption)
      .foregroundStyle(.orange)
      .textSelection(.enabled)
  }

  private func isInstalled(_ state: SocktainerInstallationState) -> Bool {
    if case .ready = state { return true }
    return false
  }

  private func isRuntimeBusy(_ state: SocktainerRuntimeState) -> Bool {
    switch state {
    case .starting, .running, .stopping:
      true
    case .stopped, .blockedByForeignSocket, .failed:
      false
    }
  }

  private func canStart(_ snapshot: DockerCompatibilitySnapshot) -> Bool {
    guard case .ready = snapshot.installation,
      case .compatible = snapshot.appleContainer
    else { return false }
    switch snapshot.runtime {
    case .stopped, .failed:
      return true
    case .starting, .running, .stopping, .blockedByForeignSocket:
      return false
    }
  }

  private func installationTitle(_ state: SocktainerInstallationState) -> String {
    switch state {
    case .notInstalled: "Not installed"
    case .ready(let version): "Verified \(version)"
    case .invalid: "Invalid — reinstall required"
    }
  }

  private func installationSymbol(_ state: SocktainerInstallationState) -> String {
    switch state {
    case .ready: "checkmark.circle.fill"
    case .notInstalled: "arrow.down.circle"
    case .invalid: "xmark.octagon.fill"
    }
  }

  private func installationColor(_ state: SocktainerInstallationState) -> Color {
    switch state {
    case .ready: .green
    case .notInstalled: .secondary
    case .invalid: .red
    }
  }

  private func appleRuntimeTitle(_ state: AppleContainerCompatibilityState) -> String {
    switch state {
    case .compatible(let version): "API server \(version)"
    case .unavailable: "Unavailable"
    case .incompatible(let found, let required): "\(found); requires \(required)"
    }
  }

  private func appleRuntimeSymbol(_ state: AppleContainerCompatibilityState) -> String {
    switch state {
    case .compatible: "checkmark.circle.fill"
    case .unavailable: "questionmark.circle"
    case .incompatible: "xmark.octagon.fill"
    }
  }

  private func appleRuntimeColor(_ state: AppleContainerCompatibilityState) -> Color {
    switch state {
    case .compatible: .green
    case .unavailable: .secondary
    case .incompatible: .red
    }
  }

  private func runtimeTitle(_ state: SocktainerRuntimeState) -> String {
    switch state {
    case .stopped: "Stopped"
    case .starting: "Starting…"
    case .running(let processID): "Running — PID \(processID)"
    case .stopping: "Stopping…"
    case .blockedByForeignSocket: "External or stale socket"
    case .failed: "Failed"
    }
  }

  private func runtimeSymbol(_ state: SocktainerRuntimeState) -> String {
    switch state {
    case .running: "checkmark.circle.fill"
    case .starting, .stopping: "clock"
    case .stopped: "stop.circle"
    case .blockedByForeignSocket: "lock.trianglebadge.exclamationmark"
    case .failed: "xmark.octagon.fill"
    }
  }

  private func runtimeColor(_ state: SocktainerRuntimeState) -> Color {
    switch state {
    case .running: .green
    case .starting, .stopping: .blue
    case .stopped: .secondary
    case .blockedByForeignSocket: .orange
    case .failed: .red
    }
  }

  private func contextTitle(_ state: DockerContextSnapshot.State) -> String {
    switch state {
    case .dockerUnavailable: "Docker CLI not found"
    case .missing: "Not configured"
    case .ready: "nativecontainers ready"
    case .drifted: "Endpoint drifted"
    case .failed: "Inspection failed"
    }
  }

  private func contextSymbol(_ state: DockerContextSnapshot.State) -> String {
    switch state {
    case .ready: "checkmark.circle.fill"
    case .missing: "plus.circle"
    case .dockerUnavailable: "questionmark.circle"
    case .drifted: "wrench.and.screwdriver"
    case .failed: "xmark.octagon.fill"
    }
  }

  private func contextColor(_ state: DockerContextSnapshot.State) -> Color {
    switch state {
    case .ready: .green
    case .missing, .dockerUnavailable: .secondary
    case .drifted: .orange
    case .failed: .red
    }
  }
}
