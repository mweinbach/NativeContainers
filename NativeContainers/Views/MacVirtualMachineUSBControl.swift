import SwiftUI

struct MacVirtualMachineUSBControl: View {
  let machineName: String
  let model: MacVirtualMachineUSBModel

  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 5) {
        Label("USB", systemImage: "cable.connector")
        if model.snapshot.hasAttachedDevices {
          Text(attachedCount, format: .number)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.tint, in: Capsule())
            .foregroundStyle(.white)
        }
      }
    }
    .buttonStyle(.borderless)
    .help("Attach a physical USB accessory to the virtual machine.")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      MacVirtualMachineUSBPanel(
        machineName: machineName,
        model: model
      )
    }
  }

  private var attachedCount: Int {
    model.snapshot.devices.lazy.filter {
      $0.state == .attached || $0.state == .detaching
    }.count
  }
}

private struct MacVirtualMachineUSBPanel: View {
  let machineName: String
  let model: MacVirtualMachineUSBModel

  var body: some View {
    MacVirtualMachineUSBPanelContent(
      machineName: machineName,
      snapshot: model.snapshot,
      canAttachDevices: model.canAttachDevices,
      isDiscovering: model.isDiscovering,
      workingDeviceID: model.workingDeviceID,
      errorMessage: model.errorMessage,
      discover: { Task { await model.discover() } },
      attach: { deviceID in
        Task { await model.attach(deviceID: deviceID) }
      },
      detach: { deviceID in
        Task { await model.detach(deviceID: deviceID) }
      },
      clearError: model.clearError
    )
    .task {
      model.observe()
    }
  }
}

private struct MacVirtualMachineUSBPanelContent: View {
  let machineName: String
  let snapshot: MacVirtualMachineUSBSnapshot
  let canAttachDevices: Bool
  let isDiscovering: Bool
  let workingDeviceID: UInt64?
  let errorMessage: String?
  let discover: () -> Void
  let attach: (UInt64) -> Void
  let detach: (UInt64) -> Void
  let clearError: () -> Void

  @State private var pendingAttachment: MacVirtualMachineUSBDeviceDescriptor?
  @State private var isConfirmingAttachment = false

  var body: some View {
    VStack(spacing: 0) {
      MacVirtualMachineUSBPanelHeader(
        machineName: machineName,
        attachedDeviceCount: attachedDeviceCount
      )
      Divider()
      MacVirtualMachineUSBDiscoveryContent(
        snapshot: snapshot,
        canAttachDevices: canAttachDevices,
        isDiscovering: isDiscovering,
        workingDeviceID: workingDeviceID,
        discover: discover,
        confirmAttachment: { descriptor in
          pendingAttachment = descriptor
          isConfirmingAttachment = true
        },
        detach: detach
      )
      if snapshot.discoveryStatus == .ready, !snapshot.devices.isEmpty {
        MacVirtualMachineUSBSafetyNote()
      }
      if let errorMessage {
        MacVirtualMachineUSBErrorBanner(
          message: errorMessage,
          dismiss: clearError
        )
      }
    }
    .frame(
      minWidth: 420,
      idealWidth: 420,
      minHeight: 360,
      idealHeight: 420
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .confirmationDialog(
      "Attach USB accessory?",
      isPresented: $isConfirmingAttachment,
      presenting: pendingAttachment
    ) { descriptor in
      Button("Attach to \(machineName)") {
        attach(descriptor.id)
      }
    } message: { descriptor in
      Text(
        "The host releases USB device \(descriptor.vendorProductIdentifier) while it is attached to the virtual machine."
      )
    }
  }

  private var attachedDeviceCount: Int {
    snapshot.devices.lazy.filter {
      $0.state == .attached || $0.state == .detaching
    }.count
  }
}

private struct MacVirtualMachineUSBPanelHeader: View {
  let machineName: String
  let attachedDeviceCount: Int

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "cable.connector")
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("USB Accessories")
          .font(.headline)
        Text(machineName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if attachedDeviceCount > 0 {
        Text("\(attachedDeviceCount) attached")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
  }
}

private struct MacVirtualMachineUSBDiscoveryContent: View {
  let snapshot: MacVirtualMachineUSBSnapshot
  let canAttachDevices: Bool
  let isDiscovering: Bool
  let workingDeviceID: UInt64?
  let discover: () -> Void
  let confirmAttachment: (MacVirtualMachineUSBDeviceDescriptor) -> Void
  let detach: (UInt64) -> Void

  var body: some View {
    switch snapshot.discoveryStatus {
    case .notStarted:
      ContentUnavailableView {
        Label("Find USB Accessories", systemImage: "cable.connector.horizontal")
      } description: {
        Text("NativeContainers asks macOS for access only when you choose Discover.")
      } actions: {
        Button("Discover…", action: discover)
          .buttonStyle(.borderedProminent)
      }
    case .discovering:
      VStack(spacing: 12) {
        ProgressView()
        Text("Waiting for USB access…")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .ready where snapshot.devices.isEmpty:
      ContentUnavailableView(
        "No USB Accessories",
        systemImage: "cable.connector.slash",
        description: Text("Connect a USB device to this Mac and it will appear here.")
      )
    case .ready:
      MacVirtualMachineUSBDeviceList(
        devices: snapshot.devices,
        canAttachDevices: canAttachDevices,
        workingDeviceID: workingDeviceID,
        confirmAttachment: confirmAttachment,
        detach: detach
      )
    case .unavailable(let reason):
      ContentUnavailableView(
        "USB Passthrough Unavailable",
        systemImage: "cable.connector.slash",
        description: Text(reason)
      )
    case .failed(let reason):
      ContentUnavailableView {
        Label("USB Discovery Failed", systemImage: "exclamationmark.triangle")
      } description: {
        Text(reason)
      } actions: {
        Button("Try Again", action: discover)
          .disabled(isDiscovering)
      }
    }
  }
}

private struct MacVirtualMachineUSBDeviceList: View {
  let devices: [MacVirtualMachineUSBDeviceSnapshot]
  let canAttachDevices: Bool
  let workingDeviceID: UInt64?
  let confirmAttachment: (MacVirtualMachineUSBDeviceDescriptor) -> Void
  let detach: (UInt64) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(devices) { device in
          VStack(spacing: 0) {
            MacVirtualMachineUSBDeviceRow(
              device: device,
              canAttachDevices: canAttachDevices,
              isWorking: workingDeviceID == device.id,
              confirmAttachment: confirmAttachment,
              detach: detach
            )
            Divider()
          }
        }
      }
      .padding(.horizontal, 12)
    }
  }
}

private struct MacVirtualMachineUSBDeviceRow: View {
  let device: MacVirtualMachineUSBDeviceSnapshot
  let canAttachDevices: Bool
  let isWorking: Bool
  let confirmAttachment: (MacVirtualMachineUSBDeviceDescriptor) -> Void
  let detach: (UInt64) -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: device.state == .attached ? "cable.connector" : "externaldrive")
        .foregroundStyle(device.state == .attached ? Color.green : Color.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("USB Device \(device.descriptor.vendorProductIdentifier)")
          .font(.body)
        Text(deviceClassLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      MacVirtualMachineUSBDeviceAction(
        state: device.state,
        canAttachDevices: canAttachDevices,
        isWorking: isWorking,
        attach: { confirmAttachment(device.descriptor) },
        detach: { detach(device.id) }
      )
    }
    .padding(.vertical, 4)
  }

  private var deviceClassLabel: LocalizedStringResource {
    switch device.descriptor.deviceClass {
    case 0x01:
      "Audio device"
    case 0x02:
      "Communications device"
    case 0x03:
      "Human interface device"
    case 0x08:
      "Mass storage device"
    case 0x09:
      "USB hub"
    case 0x0E:
      "Video device"
    case 0xEF:
      "Composite device"
    default:
      "USB accessory"
    }
  }
}

private struct MacVirtualMachineUSBDeviceAction: View {
  let state: MacVirtualMachineUSBDeviceState
  let canAttachDevices: Bool
  let isWorking: Bool
  let attach: () -> Void
  let detach: () -> Void

  var body: some View {
    HStack {
      switch state {
      case .available:
        Button("Attach…", action: attach)
          .disabled(!canAttachDevices || isWorking)
          .help(
            canAttachDevices
              ? "Attach this USB accessory to the guest."
              : "Start or pause the virtual machine before attaching USB accessories."
          )
      case .attaching:
        ProgressView()
          .controlSize(.small)
        Text("Attaching")
          .foregroundStyle(.secondary)
      case .attached:
        Button("Detach", action: detach)
          .disabled(isWorking)
      case .detaching:
        ProgressView()
          .controlSize(.small)
        Text("Detaching")
          .foregroundStyle(.secondary)
      case .inUseByAnotherVirtualMachine:
        Text("In use")
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct MacVirtualMachineUSBSafetyNote: View {
  var body: some View {
    Divider()
    Label(
      "Detach USB accessories before suspending. Stopping the VM releases them automatically.",
      systemImage: "info.circle"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
  }
}

private struct MacVirtualMachineUSBErrorBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    Divider()
    HStack(spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Spacer()
      Button("Dismiss", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .font(.caption)
    .padding(12)
  }
}

#Preview("USB devices ready") {
  MacVirtualMachineUSBPanelContent(
    machineName: "macOS Development",
    snapshot: MacVirtualMachineUSBSnapshot(
      machineID: UUID(),
      target: MacVirtualMachineRuntimeTarget(
        machineID: UUID(),
        generation: UUID()
      ),
      discoveryStatus: .ready,
      devices: [
        MacVirtualMachineUSBDeviceSnapshot(
          descriptor: MacVirtualMachineUSBDeviceDescriptor(
            id: 1,
            vendorID: 0x05AC,
            productID: 0x12A8,
            deviceClass: 0xEF
          ),
          state: .attached
        ),
        MacVirtualMachineUSBDeviceSnapshot(
          descriptor: MacVirtualMachineUSBDeviceDescriptor(
            id: 2,
            vendorID: 0x0781,
            productID: 0x558A,
            deviceClass: 0x08
          ),
          state: .available
        ),
      ]
    ),
    canAttachDevices: true,
    isDiscovering: false,
    workingDeviceID: nil,
    errorMessage: nil,
    discover: {},
    attach: { _ in },
    detach: { _ in },
    clearError: {}
  )
  .padding()
}

#Preview("USB unavailable") {
  MacVirtualMachineUSBPanelContent(
    machineName: "macOS Development",
    snapshot: MacVirtualMachineUSBSnapshot(
      machineID: UUID(),
      discoveryStatus: .unavailable(
        "Accessory Access is unavailable in this signed build."
      )
    ),
    canAttachDevices: false,
    isDiscovering: false,
    workingDeviceID: nil,
    errorMessage: nil,
    discover: {},
    attach: { _ in },
    detach: { _ in },
    clearError: {}
  )
  .padding()
}
