import SwiftUI

struct ResourceQuickOpenView: View {
  let navigation: WorkspaceNavigationModel
  let lockedRoute: WorkspaceRoute?
  let onOpen: (WorkspaceRoute) -> Void

  @State private var isSearchPresented = true

  var body: some View {
    @Bindable var navigation = navigation

    NavigationStack {
      ResourceQuickOpenContent(
        entries: navigation.results,
        query: navigation.query,
        lockedRoute: lockedRoute,
        onOpen: onOpen
      )
      .navigationTitle("Quick Open")
      .searchable(
        text: $navigation.query,
        isPresented: $isSearchPresented,
        placement: .toolbar,
        prompt: "Containers, images, networks, volumes, and VMs"
      )
      .onSubmit(of: .search) {
        guard
          let entry = navigation.results.first(where: {
            navigation.canNavigate(to: $0.route, lockedTo: lockedRoute)
          })
        else { return }
        onOpen(entry.route)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            navigation.dismissQuickOpen()
          }
          .keyboardShortcut(.cancelAction)
        }
      }
    }
    .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 520)
  }
}

private struct ResourceQuickOpenContent: View {
  let entries: [WorkspaceResourceEntry]
  let query: String
  let lockedRoute: WorkspaceRoute?
  let onOpen: (WorkspaceRoute) -> Void

  var body: some View {
    VStack(spacing: 0) {
      if lockedRoute != nil {
        ResourceQuickOpenLockBanner()
      }

      if entries.isEmpty {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          ContentUnavailableView(
            "No resources",
            systemImage: "magnifyingglass",
            description: Text("Create or pull a resource, then use Quick Open to jump to it.")
          )
        } else {
          ContentUnavailableView.search(text: query)
        }
      } else {
        ResourceQuickOpenResultsList(
          entries: entries,
          lockedRoute: lockedRoute,
          onOpen: onOpen
        )
      }
    }
  }
}

private struct ResourceQuickOpenLockBanner: View {
  var body: some View {
    Label(
      "Finish or cancel the active build operation before leaving Builds.",
      systemImage: "lock.fill"
    )
    .font(.callout)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.orange.opacity(0.08))
  }
}

private struct ResourceQuickOpenResultsList: View {
  let entries: [WorkspaceResourceEntry]
  let lockedRoute: WorkspaceRoute?
  let onOpen: (WorkspaceRoute) -> Void

  var body: some View {
    List(entries) { entry in
      Button {
        onOpen(entry.route)
      } label: {
        ResourceQuickOpenRow(
          title: entry.title,
          subtitle: entry.subtitle,
          kind: entry.kind
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(lockedRoute != nil && entry.route.baseRoute != lockedRoute?.baseRoute)
      .accessibilityHint("Opens this resource in its management view")
    }
  }
}

private struct ResourceQuickOpenRow: View {
  let title: String
  let subtitle: String
  let kind: WorkspaceResourceKind

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: kind.systemImage)
        .font(.title3)
        .foregroundStyle(.tint)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 16)

      Text(kind.title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 5)
  }
}

#Preview("Quick Open") {
  let model = AppModel.preview
  ResourceQuickOpenView(
    navigation: model.workspaceNavigation,
    lockedRoute: nil,
    onOpen: { _ in }
  )
}
