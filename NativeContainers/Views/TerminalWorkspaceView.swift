import SwiftUI

struct TerminalWorkspaceWindow: View {
  @SceneStorage("terminal.workspace.snapshot.v1")
  private var encodedSnapshot: Data?

  @State private var model: TerminalWorkspaceModel
  @State private var isManagingPresets = false
  @State private var pendingTabClosure: UUID?

  private let appModel: AppModel

  init(request: TerminalWindowRequest, appModel: AppModel) {
    self.appModel = appModel
    _model = State(
      initialValue: appModel.makeTerminalWorkspaceModel(request: request)
    )
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        TerminalWorkspaceTabStrip(
          tabs: model.tabs,
          selectedTabID: model.selectedTabID,
          onSelect: selectTab,
          onClose: { pendingTabClosure = $0 }
        )
        Divider()
        TerminalWorkspaceContent(model: model)
        if let errorMessage = model.errorMessage {
          TerminalWorkspaceErrorBanner(
            message: errorMessage,
            onDismiss: model.clearError
          )
        }
      }
      .navigationTitle("Terminal — \(model.windowRequest.target.id)")
      .toolbar {
        terminalToolbar
      }
    }
    .frame(minWidth: 820, minHeight: 560)
    .task {
      let isRestoringSavedTabs = encodedSnapshot != nil
      await model.restore(from: encodedSnapshot)
      persistSnapshot()
      if !isRestoringSavedTabs {
        await model.startSelectedTabIfNeeded()
        await appModel.refresh()
      }
    }
    .onChange(of: model.snapshot) {
      persistSnapshot()
    }
    .onDisappear {
      Task {
        await model.closeAll()
        await appModel.refresh()
      }
    }
    .sheet(isPresented: $isManagingPresets) {
      TerminalPresetManagerView(model: model)
    }
    .confirmationDialog(
      "Close terminal tab?",
      isPresented: Binding(
        get: { pendingTabClosure != nil },
        set: { if !$0 { pendingTabClosure = nil } }
      )
    ) {
      Button("Close Tab", role: .destructive) {
        guard let id = pendingTabClosure else { return }
        pendingTabClosure = nil
        Task {
          await model.closeTab(id: id)
          await model.startSelectedTabIfNeeded()
          await appModel.refresh()
        }
      }
      Button("Keep Open", role: .cancel) {
        pendingTabClosure = nil
      }
    } message: {
      Text("The shell receives hangup and is force-stopped if it does not exit promptly.")
    }
  }

  @ToolbarContentBuilder
  private var terminalToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if model.supportsPresets {
        Menu("New Tab", systemImage: "plus") {
          Button("Preferred Shell") {
            addTab()
          }
          ForEach(model.presets) { preset in
            Button(preset.name) {
              addTab(presetID: preset.id)
            }
          }
          Divider()
          Button("Manage Presets…", systemImage: "slider.horizontal.3") {
            isManagingPresets = true
          }
        }
        .keyboardShortcut("t", modifiers: .command)
      } else {
        Button("New Tab", systemImage: "plus") {
          addTab()
        }
        .keyboardShortcut("t", modifiers: .command)
      }

      Button("Close Tab", systemImage: "xmark") {
        pendingTabClosure = model.selectedTab?.id
      }
      .disabled(model.selectedTab == nil)

      if let terminal = model.selectedTab?.terminal, terminal.isRunning {
        Button("Interrupt", systemImage: "stop.circle") {
          terminal.enqueueInput(Data([0x03]))
        }
        .help("Send Control-C to the foreground terminal process")

        Menu("Session", systemImage: "ellipsis.circle") {
          Button("Send End of File") {
            terminal.enqueueInput(Data([0x04]))
          }
          Button("Send Hangup") {
            Task { await terminal.sendSignal(.hangup) }
          }
          Divider()
          Button("Terminate Process", role: .destructive) {
            Task { await terminal.sendSignal(.terminate) }
          }
          Button("Kill Process", role: .destructive) {
            Task { await terminal.sendSignal(.kill) }
          }
        }
      } else if let tab = model.selectedTab, !tab.terminal.isConnecting {
        Button("Start New Shell", systemImage: "arrow.clockwise") {
          Task { await tab.terminal.connect(request: tab.request) }
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  private func persistSnapshot() {
    guard let snapshot = model.encodeSnapshot() else { return }
    encodedSnapshot = snapshot
  }

  private func selectTab(_ id: UUID) {
    model.selectedTabID = id
    Task {
      await model.startSelectedTabIfNeeded()
      await appModel.refresh()
    }
  }

  private func addTab(presetID: UUID? = nil) {
    model.addTab(presetID: presetID)
    Task {
      await model.startSelectedTabIfNeeded()
      await appModel.refresh()
    }
  }
}

private struct TerminalWorkspaceTabStrip: View {
  let tabs: [TerminalWorkspaceTabModel]
  let selectedTabID: UUID?
  let onSelect: (UUID) -> Void
  let onClose: (UUID) -> Void

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(tabs) { tab in
          TerminalWorkspaceTabButton(
            title: tab.title,
            isSelected: selectedTabID == tab.id,
            onSelect: { onSelect(tab.id) },
            onClose: { onClose(tab.id) }
          )
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
    }
    .scrollIndicators(.hidden)
    .background(.bar)
  }
}

private struct TerminalWorkspaceTabButton: View {
  let title: String
  let isSelected: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: 5) {
      Button(action: onSelect) {
        Label(title, systemImage: "terminal")
          .lineLimit(1)
      }
      .buttonStyle(.plain)

      Button("Close \(title)", systemImage: "xmark", action: onClose)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(
      isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(isSelected ? Color.accentColor.opacity(0.45) : .clear)
    }
  }
}

#Preview("Tabbed terminal workspace") {
  TerminalWorkspaceWindow(
    request: TerminalWindowRequest(
      target: .container(
        ContainerTerminalTargetIdentity(container: AppModel.preview.containers[0])
      )
    ),
    appModel: .preview
  )
}
