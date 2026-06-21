import AppKit
import SwiftUI

struct ComposeProjectManagementView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: ComposeProjectWorkspaceModel
  @State private var reviewTask: Task<Void, Never>?
  @State private var executionTask: Task<Void, Never>?
  @State private var confirmExecution = false
  @State private var recoveryToDiscard: ComposeOperationRecoverySnapshot?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if !model.pendingRecoveries.isEmpty {
            recoverySection
          }
          sourceSection
          intentSection
          if let errorMessage = model.errorMessage {
            errorBanner(errorMessage)
          }
          if let plan = model.plan {
            reviewSection(plan)
          } else {
            reviewPlaceholder
          }
          if let result = model.executionResult {
            executionResultSection(result)
          }
        }
        .padding(24)
      }
      Divider()
      footer
    }
    .background(.background)
    .frame(minWidth: 720, minHeight: 660)
    .task {
      await model.loadRecoveries()
    }
    .alert("Execute reviewed Compose operation?", isPresented: $confirmExecution) {
      Button("Cancel", role: .cancel) {}
      Button("Execute", role: .destructive) {
        executionTask = Task {
          await model.execute()
          executionTask = nil
        }
      }
    } message: {
      Text(
        "The source, Compose binary, controlled environment, and Apple inventory will be revalidated before mutation. Cancellation may leave a manual recovery record."
      )
    }
    .alert(
      "Discard reviewed recovery record?",
      isPresented: Binding(
        get: { recoveryToDiscard != nil },
        set: { if !$0 { recoveryToDiscard = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) {
        recoveryToDiscard = nil
      }
      Button("Discard Record", role: .destructive) {
        guard let operationID = recoveryToDiscard?.operationID else { return }
        recoveryToDiscard = nil
        Task {
          await model.discardRecoveryAfterReview(operationID: operationID)
        }
      }
    } message: {
      Text(
        "Only discard this record after manually reconciling the listed operation against current Apple container inventory. Discarding never resumes or rolls back work."
      )
    }
    .onDisappear {
      reviewTask?.cancel()
      executionTask?.cancel()
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.title)
        .foregroundStyle(.indigo)
      VStack(alignment: .leading, spacing: 3) {
        Text("Review Compose Project")
          .font(.title2.bold())
        Text("Render a stable desired state before any lifecycle work is authorized.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Close") {
        reviewTask?.cancel()
        executionTask?.cancel()
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
    }
    .padding(20)
  }

  private var sourceSection: some View {
    GroupBox("Project source") {
      HStack(spacing: 14) {
        Image(
          systemName: model.selectedDirectoryURL == nil
            ? "folder.badge.questionmark" : "folder.fill"
        )
        .font(.title2)
        .foregroundStyle(model.selectedDirectoryURL == nil ? Color.secondary : Color.indigo)
        .frame(width: 32)
        VStack(alignment: .leading, spacing: 3) {
          Text(model.sourceDisplayName)
            .font(.headline)
            .lineLimit(1)
          Text(
            model.selectedDirectoryURL?.path(percentEncoded: false)
              ?? "Choose a private folder containing exactly one compose.yaml, compose.yml, docker-compose.yaml, or docker-compose.yml."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
        }
        Spacer()
        Button("Choose Folder…", action: chooseFolder)
          .disabled(model.isReviewing || model.isExecuting)
      }
      .padding(10)
    }
  }

  private var intentSection: some View {
    GroupBox("Review intent") {
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
        GridRow {
          Text("Project name")
            .foregroundStyle(.secondary)
          TextField("lowercase-project-name", text: $model.projectName)
            .textFieldStyle(.roundedBorder)
        }
        GridRow {
          Text("Action")
            .foregroundStyle(.secondary)
          Picker("Action", selection: $model.action) {
            ForEach(ComposeProjectLifecycleAction.allCases) { action in
              Text(action.rawValue.capitalized).tag(action)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }
        GridRow {
          Text("Active profiles")
            .foregroundStyle(.secondary)
          TextField("Optional, comma or space separated", text: $model.profilesText)
            .textFieldStyle(.roundedBorder)
        }
        if model.action == .up {
          GridRow {
            Text("Pull policy")
              .foregroundStyle(.secondary)
            Picker("Pull policy", selection: $model.pullPolicy) {
              ForEach(ComposeProjectPullPolicy.allCases) { policy in
                Text(policy.rawValue.capitalized).tag(policy)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
          }
        }
      }
      .padding(10)

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        if model.action == .down {
          Toggle("Include reviewed true orphans (review only)", isOn: $model.removeOrphans)
          Toggle("Include managed named volumes (review only)", isOn: $model.removeVolumes)
        }
        if model.action == .stop || model.action == .down {
          Toggle(
            "Automatically send KILL after the graceful stop timeout",
            isOn: $model.killStuckContainers
          )
        }
        Text(
          "Fresh Up, exact-count native Up, exact-ID Start and Stop, plus reviewed declared/orphan/network/volume Down actions are executable when review has no blockers. Create-missing and recreation remain blocked. External resources are always lookup-only."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(10)
    }
  }

  private var recoverySection: some View {
    GroupBox("Manual recovery required") {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          "NativeContainers never auto-resumes an interrupted Compose mutation. Reconcile each operation against current inventory, then explicitly discard its record."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        ForEach(model.pendingRecoveries) { recovery in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
              .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
              Text("\(recovery.projectName) · \(recovery.action.rawValue.capitalized)")
                .font(.headline)
              Text(
                "Phase: \(recovery.phase.rawValue) · Steps \(recovery.completedStepTokens.count)/\(recovery.plannedStepTokens.count) · Journal v\(recovery.schemaVersion)"
              )
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              Text(recovery.operationID.uuidString.lowercased())
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            }
            Spacer()
            Button("Reviewed…") {
              recoveryToDiscard = recovery
            }
          }
          .padding(10)
          .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
      }
      .padding(10)
    }
  }

  private var reviewPlaceholder: some View {
    Label {
      VStack(alignment: .leading, spacing: 3) {
        Text("Ready for review")
          .font(.headline)
        Text(
          "The pinned Compose client will render the full and active models twice. Environment values are never retained in the review."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: "checklist")
        .font(.title2)
        .foregroundStyle(.indigo)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }

  private func reviewSection(_ plan: ComposeProjectPlan) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Reviewed desired state", systemImage: "checkmark.seal.fill")
          .font(.title3.bold())
          .foregroundStyle(.green)
        Spacer()
        Text("Compose \(plan.composeReleaseVersion)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      GroupBox {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
          reviewRow("Declared services", plan.desiredState.declaredServiceNames.count.formatted())
          reviewRow("Active services", plan.desiredState.activeServices.count.formatted())
          reviewRow("Container actions", plan.containerActions.count.formatted())
          reviewRow("Volume actions", plan.volumeActions.count.formatted())
          reviewRow("Network actions", plan.networkActions.count.formatted())
          reviewRow("True orphans", plan.orphanContainerIDs.count.formatted())
          reviewRow("Source SHA-256", String(plan.source.fileIdentity.sha256.prefix(12)))
          reviewRow("Full model SHA-256", String(plan.fullConfigurationSHA256.prefix(12)))
          reviewRow("Active model SHA-256", String(plan.activeConfigurationSHA256.prefix(12)))
        }
        .padding(10)
      }

      if !plan.desiredState.activeServices.isEmpty {
        GroupBox("Active services") {
          VStack(spacing: 0) {
            ForEach(plan.desiredState.activeServices) { service in
              HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                  .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                  Text(service.name)
                    .font(.headline)
                  Text(service.imageReference)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                Text("\(service.replicaCount)×")
                  .font(.callout.monospacedDigit())
                if service.publishedPortCount > 0 {
                  Label(service.publishedPortCount.formatted(), systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .padding(.vertical, 9)
              if service.id != plan.desiredState.activeServices.last?.id {
                Divider()
              }
            }
          }
          .padding(.horizontal, 10)
        }
      }

      issuesSection(plan)
    }
  }

  private func executionResultSection(_ result: ComposeProjectExecutionResult) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 3) {
        Text("Compose \(result.action.rawValue.capitalized) confirmed")
          .font(.headline)
        Text(
          "Apple inventory now reports \(result.remainingContainerCount) project container(s), \(result.remainingVolumeCount) volume(s), and \(result.remainingNetworkCount) network(s)."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: "checkmark.circle.fill")
        .font(.title2)
        .foregroundStyle(.green)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  private func issuesSection(_ plan: ComposeProjectPlan) -> some View {
    GroupBox("Review findings") {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(plan.issues) { issue in
          HStack(alignment: .top, spacing: 10) {
            Image(
              systemName:
                issue.severity == .blocker
                ? "lock.trianglebadge.exclamationmark.fill"
                : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(issue.severity == .blocker ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
              Text(issue.subject)
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
              Text(issue.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }
        }
      }
      .padding(10)
    }
  }

  private func reviewRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.monospaced())
        .textSelection(.enabled)
    }
  }

  private func errorBanner(_ message: String) -> some View {
    Label {
      Text(message)
        .textSelection(.enabled)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
    }
    .foregroundStyle(.red)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  private var footer: some View {
    HStack {
      Label(
        "Execution revalidates the reviewed source and identities; pending journals require manual reconciliation.",
        systemImage: "checkmark.shield.fill"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Spacer()

      if model.isExecuting {
        ProgressView()
          .controlSize(.small)
        Button("Cancel Execution", role: .destructive) {
          executionTask?.cancel()
        }
      } else if model.isReviewing {
        ProgressView()
          .controlSize(.small)
        Button("Cancel Review") {
          reviewTask?.cancel()
        }
      } else {
        if model.plan != nil {
          Button("Execute Reviewed \(model.action.rawValue.capitalized)") {
            confirmExecution = true
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(!model.canExecute)
        }
        Button("Review Desired State") {
          reviewTask = Task {
            await model.review()
            reviewTask = nil
          }
        }
        .buttonStyle(.bordered)
        .disabled(!model.canReview)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.title = "Choose Compose Project Folder"
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    if panel.runModal() == .OK, let url = panel.url {
      model.selectDirectory(url)
    }
  }
}

#Preview("Compose project review") {
  ComposeProjectManagementView(
    model: ComposeProjectWorkspaceModel(
      service: UnavailableComposeProjectLifecycleService()
    )
  )
}
