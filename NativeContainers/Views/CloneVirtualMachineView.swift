import SwiftUI

struct CloneVirtualMachineView: View {
  let machine: VirtualMachineManifest
  let model: AppModel

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var isCloning = false
  @State private var isCancelling = false
  @State private var errorMessage: String?
  @State private var cloneTask: Task<Void, Never>?

  init(machine: VirtualMachineManifest, model: AppModel) {
    self.machine = machine
    self.model = model
    _name = State(initialValue: "\(machine.name) Copy")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 14) {
        Image(systemName: "square.on.square")
          .font(.largeTitle)
          .foregroundStyle(machine.guest == .macOS ? Color.indigo : Color.mint)
        VStack(alignment: .leading, spacing: 3) {
          switch machine.guest {
          case .macOS:
            Text("Clone macOS VM")
              .font(.title2.bold())
          case .linux:
            Text("Clone Linux VM")
              .font(.title2.bold())
          case .windows:
            Text("Clone Windows VM")
              .font(.title2.bold())
          }
          Text("Create a separate, bootable copy of \(machine.name)")
            .foregroundStyle(.secondary)
        }
      }

      Form {
        TextField("Name", text: $name)
      }

      VStack(alignment: .leading, spacing: 8) {
        Label(
          "Uses APFS copy-on-write cloning when available.",
          systemImage: "internaldrive"
        )
        Label(
          "The clone starts from a cold boot; suspended session data is not copied.",
          systemImage: "snowflake"
        )
        switch machine.guest {
        case .macOS:
          Label(
            "Virtualization may require iCloud reauthentication for cloned hardware.",
            systemImage: "person.crop.circle.badge.exclamationmark"
          )
        case .linux:
          Label(
            "The clone receives fresh platform and network identities.",
            systemImage: "network"
          )
        case .windows:
          Label(
            "The clone receives fresh platform, network, and guest-agent identities. Windows activation and the guest computer identity are not reset.",
            systemImage: "network"
          )
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }

      HStack {
        if isCloning {
          ProgressView()
            .controlSize(.small)
          Text(isCancelling ? "Cancelling and cleaning up…" : "Cloning \(machine.name)…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          guard let cloneTask else {
            dismiss()
            return
          }
          isCancelling = true
          cloneTask.cancel()
        } label: {
          Text(isCancelling ? "Cancelling…" : "Cancel")
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isCancelling)
        Button("Clone") {
          clone()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(
          isCloning || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
    .padding(24)
    .frame(width: 540)
    .interactiveDismissDisabled(isCloning)
    .onDisappear {
      cloneTask?.cancel()
    }
  }

  private func clone() {
    isCloning = true
    errorMessage = nil
    cloneTask = Task {
      do {
        try await model.cloneVirtualMachine(id: machine.id, name: name)
        cloneTask = nil
        dismiss()
      } catch is CancellationError {
        cloneTask = nil
        isCloning = false
        isCancelling = false
        dismiss()
      } catch {
        cloneTask = nil
        errorMessage = error.localizedDescription
        isCloning = false
        isCancelling = false
      }
    }
  }
}

#Preview("Clone VM") {
  let model = AppModel.previewVirtualMachines
  if let machine = model.virtualMachines.first {
    CloneVirtualMachineView(machine: machine, model: model)
  }
}
