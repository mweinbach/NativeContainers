import SwiftUI

struct VirtualMachineNameSection: View {
  let naming: VirtualMachineNameModel
  let refreshToken: Date
  let editMessage: LocalizedStringResource?

  var body: some View {
    @Bindable var naming = naming

    GroupBox {
      VStack(alignment: .leading, spacing: 0) {
        if let editMessage {
          VirtualMachineConfigurationEditLockBanner(
            message: editMessage,
            discardSavedState: nil
          )
          .padding(.vertical, 8)
          Divider()
        }

        HStack(spacing: 12) {
          Label("Name", systemImage: "tag")
          TextField("Virtual machine name", text: $naming.name)
            .textFieldStyle(.roundedBorder)
            .disabled(!canEdit)
            .onSubmit {
              guard canEdit, naming.canSave else { return }
              Task { await naming.save() }
            }
        }
        .padding(.vertical, 10)

        if naming.hasChanges && !naming.hasValidName {
          Text("Enter a virtual machine name.")
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.bottom, 10)
        }

        Divider()
        HStack(spacing: 12) {
          Text(
            "Renaming changes the label shown by NativeContainers without changing the guest’s platform identity."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Spacer(minLength: 12)
          Button("Revert", action: naming.resetChanges)
            .disabled(!canEdit || !naming.hasChanges)
          Button("Rename") {
            Task { await naming.save() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canEdit || !naming.canSave)
        }
        .padding(.vertical, 10)
      }
      .padding(.horizontal, 4)
    } label: {
      HStack {
        Label("General", systemImage: "slider.horizontal.3")
          .font(.headline)
        Spacer()
        if naming.isLoading || naming.isWorking {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
    .task(id: refreshToken) {
      await naming.reload()
    }
  }

  private var canEdit: Bool {
    editMessage == nil
      && naming.isLoaded
      && !naming.isLoading
      && !naming.isWorking
  }
}

#Preview("Virtual machine name") {
  VirtualMachineNameSection(
    naming: VirtualMachineNameModel(
      machineID: UUID(),
      initialName: "Development",
      service: PreviewVirtualMachineNameService()
    ),
    refreshToken: .distantPast,
    editMessage: nil
  )
  .padding(24)
  .frame(width: 680)
}

private actor PreviewVirtualMachineNameService: VirtualMachineNameManaging {
  private var name = "Development"

  func currentName(id: UUID) -> String {
    name
  }

  func rename(_ name: String, for machineID: UUID) -> String {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return self.name
  }
}
