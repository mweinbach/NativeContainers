import SwiftUI

struct MacGuestProvisioningCallout: View {
  let operatingSystem: MacGuestOperatingSystemIdentity
  let configure: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "person.crop.circle.badge.plus")
        .font(.title3)
        .foregroundStyle(.tint)

      VStack(alignment: .leading, spacing: 2) {
        Text("Automate First-Boot Setup")
          .font(.subheadline.weight(.semibold))
        Text(
          "Create the first macOS \(operatingSystem.versionDescription) account before this VM boots."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      Button("Set Up & Start…", action: configure)
        .buttonStyle(.bordered)
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 10)
  }
}

struct MacGuestProvisioningView: View {
  let machineName: String
  let operatingSystem: MacGuestOperatingSystemIdentity
  let runtimeModel: MacVirtualMachineRuntimeModel
  @Bindable var model: MacGuestProvisioningFormModel

  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case fullName
    case username
    case password
    case passwordConfirmation
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Guest Account") {
          TextField("Full Name", text: $model.fullName)
            .textContentType(.name)
            .focused($focusedField, equals: .fullName)

          TextField("Username", text: $model.username)
            .textContentType(.username)
            .focused($focusedField, equals: .username)

          SecureField("Password", text: $model.password)
            .textContentType(.newPassword)
            .focused($focusedField, equals: .password)

          SecureField("Confirm Password", text: $model.passwordConfirmation)
            .textContentType(.newPassword)
            .focused($focusedField, equals: .passwordConfirmation)
        }

        Section("First Boot") {
          Toggle(
            "Log in automatically",
            isOn: $model.logsInAutomatically
          )
          Toggle(
            "Enable Remote Login (SSH)",
            isOn: $model.enablesRemoteLogin
          )
        }

        Section {
          LabeledContent("Virtual Machine", value: machineName)
          LabeledContent(
            "Guest",
            value: "macOS \(operatingSystem.versionDescription) (\(operatingSystem.buildVersion))"
          )
        } footer: {
          Text(
            "Credentials are passed directly to Apple’s Virtualization framework for this first start. NativeContainers does not write the password to disk."
          )
        }

        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Set Up \(machineName)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            model.clearSecrets()
            dismiss()
          }
          .disabled(model.isSubmitting)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Set Up & Start") {
            Task {
              if await model.submit(using: runtimeModel) {
                dismiss()
              }
            }
          }
          .disabled(!model.canSubmit)
        }
      }
    }
    .frame(
      minWidth: 520,
      idealWidth: 520,
      maxWidth: 520,
      minHeight: 520
    )
    .interactiveDismissDisabled(model.isSubmitting)
    .onAppear {
      focusedField = .fullName
    }
    .onDisappear {
      model.clearSecrets()
    }
  }
}

#Preview {
  MacGuestProvisioningView(
    machineName: "Developer VM",
    operatingSystem: MacGuestOperatingSystemIdentity(
      buildVersion: "27A123",
      majorVersion: 27,
      minorVersion: 0,
      patchVersion: 0
    ),
    runtimeModel: MacVirtualMachineRuntimeModel(
      machineID: UUID(),
      service: UnavailableMacVirtualMachineRuntimeService()
    ),
    model: MacGuestProvisioningFormModel()
  )
}
