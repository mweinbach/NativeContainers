import AppKit
import SwiftUI

@MainActor
final class MenuBarQuickControlsController: NSObject {
  private let model: AppModel
  private let preferences: UserDefaults
  private let popover = NSPopover()
  private var statusItem: NSStatusItem?
  private var openMainWindow: ((WorkspaceRoute) -> Void)?
  private var openSettings: (() -> Void)?
  private var hasStarted = false
  private var isSynchronizingVisibility = false

  init(
    model: AppModel,
    preferences: UserDefaults = .standard
  ) {
    self.model = model
    self.preferences = preferences
    super.init()

    popover.behavior = .transient
    popover.animates = true
    popover.contentSize = NSSize(width: 360, height: 560)
  }

  var isVisible: Bool { statusItem != nil }

  func start(
    openMainWindow: @escaping (WorkspaceRoute) -> Void,
    openSettings: @escaping () -> Void
  ) {
    self.openMainWindow = openMainWindow
    self.openSettings = openSettings

    guard !hasStarted else { return }
    hasStarted = true
    synchronizeVisibility()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(userDefaultsDidChange),
      name: UserDefaults.didChangeNotification,
      object: preferences
    )
  }

  func stop() {
    NotificationCenter.default.removeObserver(
      self,
      name: UserDefaults.didChangeNotification,
      object: preferences
    )
    hasStarted = false
    setVisible(false)
  }

  @objc private func userDefaultsDidChange() {
    synchronizeVisibility()
  }

  @objc private func togglePopover() {
    guard let button = statusItem?.button else { return }

    if popover.isShown {
      popover.performClose(nil)
      return
    }

    popover.contentViewController = NSHostingController(rootView: contentView())
    popover.show(
      relativeTo: button.bounds,
      of: button,
      preferredEdge: .minY
    )
  }

  private func synchronizeVisibility() {
    guard !isSynchronizingVisibility else { return }
    isSynchronizingVisibility = true
    defer { isSynchronizingVisibility = false }

    let storedValue =
      preferences.object(
        forKey: AppPreferenceKey.menuBarExtraInserted
      ) as? Bool
    setVisible(storedValue ?? true)
  }

  private func setVisible(_ isVisible: Bool) {
    guard isVisible else {
      if let statusItem {
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
      }
      return
    }

    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let button = item.button else {
      NSStatusBar.system.removeStatusItem(item)
      return
    }

    let image = NSImage(
      systemSymbolName: "shippingbox.fill",
      accessibilityDescription: "NativeContainers"
    )
    image?.isTemplate = true
    button.image = image
    button.toolTip = "NativeContainers"
    button.target = self
    button.action = #selector(togglePopover)
    statusItem = item
  }

  private func contentView() -> MenuBarQuickControlsView {
    MenuBarQuickControlsView(
      model: model,
      openMainWindow: { [weak self] route in
        self?.openMainWindow?(route)
      },
      openSettings: { [weak self] in
        self?.openSettings?()
      }
    )
  }
}

struct MenuBarQuickControlsInstaller: View {
  let model: AppModel
  let controller: MenuBarQuickControlsController

  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .task {
        guard AppExecutionContext.current.allowsMenuBarControls else { return }
        controller.start(
          openMainWindow: { route in
            _ = model.navigate(to: route)
            openWindow(id: "main")
          },
          openSettings: {
            openSettings()
          }
        )
      }
  }
}
