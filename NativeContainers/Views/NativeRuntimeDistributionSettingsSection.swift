import SwiftUI

struct NativeRuntimeDistributionSettingsSection: View {
  @State private var model: NativeRuntimeDistributionModel
  @State private var pendingAction: PendingAction?

  init(appModel: AppModel) {
    _model = State(
      initialValue: appModel.makeNativeRuntimeDistributionModel()
    )
  }

  var body: some View {
    Section("Container runtime distribution") {
      if let status = model.status {
        NativeRuntimeGraphStatusView(graph: status.graph)
        NativeRuntimeDistributionAvailabilityView(
          title: "Apple official",
          availability: status.appleOfficial
        )
        NativeRuntimeDistributionAvailabilityView(
          title: "NativeContainers",
          availability: status.nativeContainers
        )
        NativeRuntimeMigrationStatusView(migration: status.migration)
      } else {
        HStack {
          ProgressView().controlSize(.small)
          Text("Inspecting installed runtime distributions…")
        }
      }

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .textSelection(.enabled)
        Button("Dismiss Error") {
          model.clearError()
        }
      }

      HStack {
        Button("Use Apple Runtime") {
          pendingAction = .activateApple
        }
        .disabled(!canActivateApple)

        Button("Use NativeContainers Runtime") {
          pendingAction = .activateNative
        }
        .disabled(!canActivateNative)

        if model.isWorking {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Changing container runtime")
        }

        Spacer()

        Button("Refresh Status", systemImage: "arrow.clockwise") {
          Task { await model.refresh() }
        }
        .disabled(model.isWorking)
      }

      Button("Clone Apple Data and Use NativeContainers", systemImage: "doc.on.doc") {
        pendingAction = .cloneAndActivateNative
      }
      .disabled(!canCloneAndActivate)

      Text(
        "Runtime changes stop the active container service graph. NativeContainers never installs or elevates the runtime package and never modifies or deletes Apple’s source data."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Text(
        "Install the separately notarized NativeContainers runtime package manually before selecting it. A development app with a placeholder release contract keeps NativeContainers actions unavailable while Apple’s verified runtime remains usable."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .task {
      if model.status == nil {
        await model.refresh()
      }
    }
    .confirmationDialog(
      pendingAction?.title ?? "Change container runtime?",
      isPresented: Binding(
        get: { pendingAction != nil },
        set: { if !$0 { pendingAction = nil } }
      )
    ) {
      if let pendingAction {
        Button(role: .destructive) {
          self.pendingAction = nil
          Task {
            switch pendingAction {
            case .activateApple:
              await model.activateAppleRuntime()
            case .activateNative:
              await model.activateNativeRuntime()
            case .cloneAndActivateNative:
              await model.cloneAppleDataAndActivateNativeRuntime()
            }
          }
        } label: {
          Text(pendingAction.confirmationButton)
        }
      }
      Button("Cancel", role: .cancel) {
        pendingAction = nil
      }
    } message: {
      Text(pendingAction?.message ?? "")
    }
  }

  private var canActivateApple: Bool {
    guard let status = model.status else { return false }
    return !model.isWorking
      && status.graph.isSafe
      && status.graph.activeOrigin != .appleOfficial
      && status.appleOfficial.isVerified
  }

  private var canActivateNative: Bool {
    guard let status = model.status else { return false }
    return !model.isWorking
      && status.graph.isSafe
      && status.graph.activeOrigin != .nativeContainers
      && status.appleOfficial.isVerified
      && status.nativeContainers.isVerified
  }

  private var canCloneAndActivate: Bool {
    guard let status = model.status else { return false }
    return !model.isWorking
      && status.graph == .active(.appleOfficial)
      && status.appleOfficial.isVerified
      && status.nativeContainers.isVerified
  }

  private enum PendingAction: Identifiable {
    case activateApple
    case activateNative
    case cloneAndActivateNative

    var id: Self { self }

    var title: LocalizedStringKey {
      switch self {
      case .activateApple:
        "Switch to Apple’s runtime?"
      case .activateNative:
        "Switch to the NativeContainers runtime?"
      case .cloneAndActivateNative:
        "Clone Apple runtime data and switch?"
      }
    }

    var confirmationButton: LocalizedStringKey {
      switch self {
      case .activateApple:
        "Stop Current Runtime and Use Apple"
      case .activateNative:
        "Stop Apple Runtime and Use NativeContainers"
      case .cloneAndActivateNative:
        "Stop, Clone, and Use NativeContainers"
      }
    }

    var message: LocalizedStringKey {
      switch self {
      case .activateApple:
        "The current verified runtime will stop before Apple’s unchanged installation starts. NativeContainers data is retained."
      case .activateNative:
        "Apple’s runtime will stop before the manually installed NativeContainers runtime starts. This action does not copy Apple data."
      case .cloneAndActivateNative:
        "Apple’s runtime will stop, persistent data will be cloned into an exclusive NativeContainers root, and the NativeContainers runtime will start. Apple’s source remains unchanged. If cloning or activation fails, the verified Apple runtime is restarted."
      }
    }
  }
}

private struct NativeRuntimeGraphStatusView: View {
  let graph: NativeRuntimeManagedGraphStatus

  var body: some View {
    LabeledContent("Active runtime") {
      switch graph {
      case .inactive:
        Text("Stopped")
          .foregroundStyle(.secondary)
      case .active(.appleOfficial):
        Text("Apple official")
          .foregroundStyle(.green)
      case .active(.nativeContainers):
        Text("NativeContainers")
          .foregroundStyle(.green)
      case .unsafe(let reason):
        Text("Unsafe or unknown: \(reason)")
          .foregroundStyle(.red)
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }
    }
  }
}

private struct NativeRuntimeDistributionAvailabilityView: View {
  let title: LocalizedStringResource
  let availability: NativeRuntimeDistributionAvailability

  var body: some View {
    LabeledContent {
      switch availability {
      case .verified(let version):
        Label("Verified \(version)", systemImage: "checkmark.seal.fill")
          .foregroundStyle(.green)
      case .unavailable(let reason):
        VStack(alignment: .trailing, spacing: 2) {
          Label("Unavailable", systemImage: "xmark.octagon.fill")
            .foregroundStyle(.orange)
          Text(reason)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
        }
      }
    } label: {
      Text(title)
    }
  }
}

private struct NativeRuntimeMigrationStatusView: View {
  let migration: NativeRuntimeMigrationCompletionState

  var body: some View {
    LabeledContent("Apple data clone") {
      switch migration {
      case .notCompleted:
        Text("Not cloned")
          .foregroundStyle(.secondary)
      case .completed(let fingerprint):
        Text("Completed (\(String(fingerprint.prefix(12))))")
          .foregroundStyle(.green)
      case .unavailable(let reason):
        Text("Unavailable: \(reason)")
          .foregroundStyle(.orange)
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }
    }
  }
}
