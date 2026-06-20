import SwiftUI

struct RegistrySettingsSection: View {
  @State private var model: RegistrySettingsModel
  @State private var isShowingLogin = false
  @State private var registryPendingLogout: RegistryCredentialRecord?

  init(appModel: AppModel) {
    _model = State(initialValue: appModel.makeRegistrySettingsModel())
  }

  var body: some View {
    Section {
      if model.isLoading, model.registries.isEmpty {
        ProgressView("Reading Apple container credentials…")
      } else if model.registries.isEmpty {
        ContentUnavailableView(
          "No registry logins",
          systemImage: "key.horizontal",
          description: Text("Add credentials for Docker Hub, GHCR, or a private OCI registry.")
        )
      } else {
        ForEach(model.registries) { registry in
          HStack(spacing: 12) {
            Image(systemName: "key.horizontal.fill")
              .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
              Text(registry.hostname)
                .font(.headline)
                .textSelection(.enabled)
              Text(registry.username)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Spacer()
            Text(registry.modifiedAt, format: .relative(presentation: .named))
              .font(.caption)
              .foregroundStyle(.tertiary)
            Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right") {
              registryPendingLogout = registry
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove credentials for \(registry.hostname)")
          }
        }
      }

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      Text(
        "Credentials are shared with Apple’s container CLI through its com.apple.container.registry Keychain domain. Stored passwords are never listed or loaded into the settings model; a new secret remains in secure input only long enough to validate and save it. Transport is chosen again for each transfer because Apple’s Keychain entry does not store a scheme."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } header: {
      HStack {
        Text("Registry credentials")
        Spacer()
        Button("Log In", systemImage: "plus") {
          model.resetLogin()
          isShowingLogin = true
        }
        .disabled(model.isLoading || model.isWorking)
      }
    }
    .task {
      await model.load()
    }
    .sheet(isPresented: $isShowingLogin) {
      RegistryLoginView(model: model)
    }
    .confirmationDialog(
      "Log out from registry?",
      isPresented: Binding(
        get: { registryPendingLogout != nil },
        set: { if !$0 { registryPendingLogout = nil } }
      ),
      presenting: registryPendingLogout
    ) { registry in
      Button("Log Out from \(registry.hostname)", role: .destructive) {
        Task {
          _ = await model.logout(registry)
          registryPendingLogout = nil
        }
      }
      Button("Cancel", role: .cancel) {
        registryPendingLogout = nil
      }
    } message: { registry in
      Text("This removes \(registry.username)’s credential from Apple container’s Keychain domain.")
    }
  }
}

private struct RegistryLoginView: View {
  @Environment(\.dismiss) private var dismiss
  let model: RegistrySettingsModel
  @State private var server = ""
  @State private var username = ""
  @State private var password = ""
  @State private var transport = RegistryTransport.automatic
  @State private var isConfirmingSensitiveLogin = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Registry") {
          TextField("Server", text: $server, prompt: Text("ghcr.io"))
            .textContentType(.URL)
          TextField("Username", text: $username)
            .textContentType(.username)
          SecureField("Password or access token", text: $password)
            .textContentType(.password)
            .privacySensitive()
          Picker("Transport", selection: $transport) {
            ForEach(RegistryTransport.allCases) { transport in
              Text(transport.title).tag(transport)
            }
          }
        }

        Section("Security") {
          switch transport {
          case .automatic:
            Text(
              "Automatic uses HTTPS for public registries and HTTP for localhost, private IPv4 ranges, and Apple’s internal container DNS domain. The resolved transport is shown for confirmation before credentials are sent."
            )
          case .https:
            Text("Require encrypted HTTPS.")
          case .http:
            Label(
              "HTTP sends registry credentials without transport encryption and requires an extra confirmation.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
          }
        }
        .font(.caption)

        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }

        if model.isWorking {
          Section { ProgressView("Validating registry credentials…") }
        }
      }
      .formStyle(.grouped)
      .disabled(model.isWorking)
      .navigationTitle("Registry Login")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            password = ""
            model.resetLogin()
            dismiss()
          }
          .disabled(model.isWorking)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Log In") {
            prepareLogin()
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || password.isEmpty
          )
        }
      }
    }
    .frame(minWidth: 560, minHeight: 480)
    .interactiveDismissDisabled(model.isWorking)
    .confirmationDialog(
      loginConfirmationTitle,
      isPresented: $isConfirmingSensitiveLogin,
      presenting: model.loginPlan
    ) { plan in
      Button(loginConfirmationButton(plan), role: .destructive) {
        submitLogin(
          allowingInsecureTransport: plan.requiresInsecureConfirmation,
          replacingDifferentUsername: plan.replacesDifferentUsername
        )
      }
      Button("Cancel", role: .cancel) {
        model.resetLogin()
      }
    } message: { plan in
      Text(loginConfirmationMessage(plan))
    }
  }

  private func prepareLogin() {
    Task {
      guard
        let plan = await model.prepareLogin(
          server: server,
          username: username,
          transport: transport
        )
      else { return }
      if plan.requiresInsecureConfirmation || plan.replacesDifferentUsername {
        isConfirmingSensitiveLogin = true
      } else {
        submitLogin(
          allowingInsecureTransport: false,
          replacingDifferentUsername: false
        )
      }
    }
  }

  private func submitLogin(
    allowingInsecureTransport: Bool,
    replacingDifferentUsername: Bool
  ) {
    let passwordToSubmit = password
    password = ""
    Task {
      if await model.login(
        password: passwordToSubmit,
        allowingInsecureTransport: allowingInsecureTransport,
        replacingDifferentUsername: replacingDifferentUsername
      ) {
        dismiss()
      }
    }
  }

  private var loginConfirmationTitle: String {
    guard let plan = model.loginPlan else { return "Confirm registry login" }
    if plan.requiresInsecureConfirmation, plan.replacesDifferentUsername {
      return "Replace login over HTTP?"
    }
    if plan.requiresInsecureConfirmation { return "Send credentials over HTTP?" }
    return "Replace stored registry login?"
  }

  private func loginConfirmationButton(_ plan: RegistryLoginPlan) -> String {
    if plan.replacesDifferentUsername {
      return "Replace Login for \(plan.hostname)"
    }
    return "Use HTTP for \(plan.hostname)"
  }

  private func loginConfirmationMessage(_ plan: RegistryLoginPlan) -> String {
    var messages: [String] = []
    if plan.replacesDifferentUsername, let existingUsername = plan.existingUsername {
      messages.append(
        "This replaces \(existingUsername)’s stored credential with \(plan.username)’s credential."
      )
    }
    if plan.requiresInsecureConfirmation {
      messages.append(
        "\(plan.hostname) resolved to plain-text HTTP. Anyone able to observe that network can read this credential."
      )
    }
    return messages.joined(separator: " ")
  }
}
