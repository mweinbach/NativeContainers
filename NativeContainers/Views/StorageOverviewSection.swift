import SwiftUI

struct StorageOverviewSection: View {
  @Bindable var model: StorageOverviewModel
  @Bindable var reclamationModel: StorageReclamationModel
  @Bindable var virtualMachineReclamationModel: VirtualMachineStorageReclamationModel
  let containerInventoryRevision: UInt64
  let virtualMachineInventoryRevision: UInt64
  @State private var isShowingReclamation = false
  @State private var isShowingVirtualMachineReclamation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Storage")
            .font(.title2.bold())
          Text("Measured only when requested so inventory refreshes stay fast.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if model.isLoading {
          ProgressView()
            .controlSize(.small)
          Button("Cancel", role: .cancel) {
            model.cancelCurrentOperation()
          }
          .keyboardShortcut(.cancelAction)
        } else {
          Button(model.hasAttempted ? "Measure Again" : "Measure Storage") {
            reclamationModel.invalidateReview()
            virtualMachineReclamationModel.invalidateReview()
            model.startRefresh()
          }
          .buttonStyle(.borderedProminent)
        }
      }

      if model.hasAttempted {
        AppleRuntimeStorageCard(
          model: model,
          onReviewReclamation: {
            reclamationModel.invalidateReview()
            isShowingReclamation = true
            reclamationModel.startPreparing()
          },
          onRetry: {
            reclamationModel.invalidateReview()
            model.startAppleRuntimeRefresh()
          }
        )
        VirtualMachineStorageCard(
          model: model,
          onReviewReclamation: {
            virtualMachineReclamationModel.invalidateReview()
            isShowingVirtualMachineReclamation = true
            virtualMachineReclamationModel.startPreparing()
          },
          onRetry: {
            virtualMachineReclamationModel.invalidateReview()
            model.startVirtualMachineRefresh()
          }
        )
      } else {
        ContentUnavailableView(
          "Storage is not measured yet",
          systemImage: "internaldrive",
          description: Text(
            "Measure Apple runtime categories and the macOS VM library on demand."
          )
        )
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
      }
    }
    .onDisappear {
      model.cancelCurrentOperation()
      reclamationModel.discardReview()
      virtualMachineReclamationModel.discardReview()
    }
    .onChange(of: model.appleRuntimeRevision) {
      reclamationModel.invalidateReview()
    }
    .onChange(of: containerInventoryRevision) {
      reclamationModel.invalidateReview()
    }
    .onChange(of: model.virtualMachineRevision) {
      virtualMachineReclamationModel.invalidateReview()
    }
    .onChange(of: virtualMachineInventoryRevision) {
      virtualMachineReclamationModel.invalidateReview()
    }
    .sheet(
      isPresented: $isShowingReclamation,
      onDismiss: { reclamationModel.discardReview() }
    ) {
      StorageReclamationReviewSheet(model: reclamationModel)
    }
    .sheet(
      isPresented: $isShowingVirtualMachineReclamation,
      onDismiss: { virtualMachineReclamationModel.discardReview() }
    ) {
      VirtualMachineStorageReclamationReviewSheet(
        model: virtualMachineReclamationModel
      )
    }
  }
}

private struct AppleRuntimeStorageCard: View {
  @Bindable var model: StorageOverviewModel
  let onReviewReclamation: () -> Void
  let onRetry: () -> Void

  var body: some View {
    StorageCard(title: "Apple runtime", systemImage: "shippingbox.and.arrow.backward") {
      if let usage = model.appleRuntimeUsage {
        HStack {
          if model.isAppleRuntimeSnapshotStale {
            Label("Remeasure after recent changes", systemImage: "arrow.clockwise.circle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          Spacer()
          Button("Review Reclamation…", action: onReviewReclamation)
            .disabled(model.isLoading || model.isAppleRuntimeSnapshotStale)
        }

        HStack(spacing: 22) {
          StorageMetric(
            title: "Allocated",
            bytes: usage.totalAllocatedBytes,
            detail: "sum of reported categories"
          )
          StorageMetric(
            title: "Reclaimable",
            bytes: usage.totalReclaimableBytes,
            detail: "runtime estimate"
          )
          Spacer()
          MeasurementTimestamp(date: usage.capturedAt)
        }

        Divider()

        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
          GridRow {
            Text("Category")
            Text("Active")
            Text("Allocated")
            Text("Reclaimable")
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

          AppleRuntimeStorageRow(name: "Images", usage: usage.images)
          AppleRuntimeStorageRow(name: "Containers", usage: usage.containers)
          AppleRuntimeStorageRow(name: "Local volumes", usage: usage.volumes)
        }
      } else if model.isLoadingAppleRuntime {
        StorageLoadingView(label: "Measuring Apple runtime storage…")
      }

      if let message = model.appleRuntimeErrorMessage {
        StorageLaneErrorView(message: message, retry: onRetry)
          .disabled(model.isLoading)
      }

      Text(
        "Reclaimable is Apple’s point-in-time classification, not a deletion authorization."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct AppleRuntimeStorageRow: View {
  let name: String
  let usage: StorageResourceUsage

  var body: some View {
    GridRow {
      Text(name)
        .fontWeight(.medium)
      Text("\(usage.activeCount) of \(usage.totalCount)")
        .monospacedDigit()
      StorageBytesText(bytes: usage.allocatedBytes)
      StorageBytesText(bytes: usage.reclaimableBytes)
    }
  }
}

private struct VirtualMachineStorageCard: View {
  @Bindable var model: StorageOverviewModel
  let onReviewReclamation: () -> Void
  let onRetry: () -> Void

  var body: some View {
    StorageCard(title: "macOS VM library", systemImage: "macwindow.on.rectangle") {
      if let usage = model.virtualMachineUsage {
        HStack {
          if model.isVirtualMachineSnapshotStale {
            Label(
              "Remeasure after recent changes",
              systemImage: "arrow.clockwise.circle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          }
          Spacer()
          Button("Review VM Reclamation…", action: onReviewReclamation)
            .disabled(
              model.isLoading || model.isVirtualMachineSnapshotStale
            )
        }

        HStack(spacing: 22) {
          StorageMetric(
            title: "Allocated",
            bytes: usage.totalAllocatedBytes,
            detail: "\(usage.discoveredMachineCount) managed VMs"
          )
          StorageMetric(
            title: "Logical",
            bytes: usage.totalLogicalBytes,
            detail: "regular-file sizes"
          )
          StorageMetric(
            title: "Provisioned disks",
            bytes: usage.totalProvisionedDiskBytes,
            detail: "configured capacity"
          )
          Spacer()
          MeasurementTimestamp(date: usage.capturedAt)
        }

        Divider()

        if usage.machines.isEmpty {
          Text("No managed macOS VM bundles were found.")
            .foregroundStyle(.secondary)
        } else {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
            GridRow {
              Text("Virtual machine")
              Text("Disk capacity")
              Text("Bundle logical")
              Text("Bundle allocated")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(usage.machines) { machine in
              GridRow {
                HStack(spacing: 6) {
                  Text(machine.name)
                    .fontWeight(.medium)
                  if machine.isApproximate {
                    Image(systemName: "approximately")
                      .foregroundStyle(.secondary)
                      .accessibilityLabel("Approximate measurement")
                  }
                }
                StorageBytesText(bytes: machine.provisionedDiskBytes)
                StorageBytesText(bytes: machine.bundleLogicalBytes)
                StorageBytesText(bytes: machine.bundleAllocatedBytes)
              }
            }
          }
        }

        if usage.unattributedAllocatedBytes > 0
          || usage.totalSavedStateAllocatedBytes > 0
          || !usage.issues.isEmpty
        {
          Divider()
          VStack(alignment: .leading, spacing: 6) {
            if usage.totalSavedStateAllocatedBytes > 0 {
              StorageDetailLine(
                label: "Saved states",
                bytes: usage.totalSavedStateAllocatedBytes
              )
            }
            if usage.unattributedAllocatedBytes > 0 {
              StorageDetailLine(
                label: "Library items outside managed bundles",
                bytes: usage.unattributedAllocatedBytes
              )
            }
            ForEach(usage.issues) { issue in
              Label(
                "\(issue.name): \(issue.message)",
                systemImage: "exclamationmark.triangle"
              )
              .font(.caption)
              .foregroundStyle(.orange)
            }
          }
        }

        if usage.hasApproximateMeasurements {
          Label(
            "Some values are approximate because files changed, were linked, or could not be classified during the scan.",
            systemImage: "approximately"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      } else if model.isLoadingVirtualMachines {
        StorageLoadingView(label: "Measuring the macOS VM library…")
      }

      if let message = model.virtualMachineErrorMessage {
        StorageLaneErrorView(message: message, retry: onRetry)
          .disabled(model.isLoading)
      }

      Text(
        "Allocated bytes are filesystem-reported and can count APFS shared extents in more than one bundle."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct StorageCard<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(.separator.opacity(0.55), lineWidth: 1)
    }
  }
}

private struct StorageMetric: View {
  let title: String
  let bytes: UInt64
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      StorageBytesText(bytes: bytes)
        .font(.title3.bold().monospacedDigit())
      Text(detail)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
}

private struct StorageBytesText: View {
  let bytes: UInt64

  var body: some View {
    Text(StorageByteFormatter.string(from: bytes))
      .monospacedDigit()
      .accessibilityLabel("\(bytes.formatted()) bytes")
  }
}

private struct StorageDetailLine: View {
  let label: String
  let bytes: UInt64

  var body: some View {
    HStack {
      Text(label)
      Spacer()
      StorageBytesText(bytes: bytes)
    }
    .font(.caption)
  }
}

private struct MeasurementTimestamp: View {
  let date: Date

  var body: some View {
    Text("Measured \(date, format: .relative(presentation: .named))")
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

private struct StorageLoadingView: View {
  let label: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text(label)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
  }
}

private struct StorageLaneErrorView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Spacer()
      Button("Retry", action: retry)
        .controlSize(.small)
    }
    .font(.caption)
    .padding(10)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct PreviewStorageUsageService: StorageUsageLoading {
  static var appleRuntimeUsage: AppleRuntimeStorageUsage {
    AppleRuntimeStorageUsage(
      capturedAt: .now,
      images: StorageResourceUsage(
        totalCount: 8,
        activeCount: 3,
        allocatedBytes: 2_400_000_000,
        reclaimableBytes: 610_000_000
      ),
      containers: StorageResourceUsage(
        totalCount: 4,
        activeCount: 2,
        allocatedBytes: 880_000_000,
        reclaimableBytes: 220_000_000
      ),
      volumes: StorageResourceUsage(
        totalCount: 2,
        activeCount: 2,
        allocatedBytes: 320_000_000,
        reclaimableBytes: 0
      )
    )
  }

  static var virtualMachineUsage: VirtualMachineStorageSummary {
    let machineID = UUID()
    return VirtualMachineStorageSummary(
      capturedAt: .now,
      discoveredMachineCount: 1,
      libraryLogicalBytes: 80_000_000_000,
      libraryAllocatedBytes: 18_400_000_000,
      libraryEntryCount: 18,
      libraryHardLinkCount: 0,
      libraryNonRegularEntryCount: 0,
      libraryMissingEntryCount: 0,
      libraryOverflowed: false,
      machines: [
        VirtualMachineStorageUsage(
          machineID: machineID,
          name: "Sequoia Lab",
          installState: .stopped,
          provisionedDiskBytes: 80_000_000_000,
          diskLogicalBytes: 80_000_000_000,
          diskAllocatedBytes: 17_900_000_000,
          bundleLogicalBytes: 80_000_000_000,
          bundleAllocatedBytes: 18_400_000_000,
          savedStateAllocatedBytes: 420_000_000,
          regularFileCount: 9,
          hardLinkCount: 0,
          nonRegularEntryCount: 0,
          missingEntryCount: 0,
          overflowed: false
        )
      ],
      issues: []
    )
  }

  func loadAppleRuntimeStorageUsage() async throws -> AppleRuntimeStorageUsage {
    Self.appleRuntimeUsage
  }

  func loadVirtualMachineStorageUsage() async throws -> VirtualMachineStorageSummary {
    Self.virtualMachineUsage
  }
}

private struct StorageOverviewLoadedPreview: View {
  @State private var model = StorageOverviewModel(
    service: PreviewStorageUsageService(),
    appleRuntimeUsage: PreviewStorageUsageService.appleRuntimeUsage,
    virtualMachineUsage: PreviewStorageUsageService.virtualMachineUsage
  )
  @State private var reclamationModel = StorageReclamationModel(
    service: UnavailableStorageReclamationService(),
    currentSource: {
      StorageReclamationSource(
        appleRuntimeCapturedAt: PreviewStorageUsageService.appleRuntimeUsage.capturedAt,
        appleRuntimeRevision: 1,
        inventoryRevision: 1,
        images: PreviewStorageUsageService.appleRuntimeUsage.images,
        containers: PreviewStorageUsageService.appleRuntimeUsage.containers,
        volumes: PreviewStorageUsageService.appleRuntimeUsage.volumes
      )
    }
  )
  @State private var virtualMachineReclamationModel =
    VirtualMachineStorageReclamationModel(
      service: UnavailableVirtualMachineStorageReclamationService(),
      currentSource: {
        VirtualMachineStorageReclamationSource(
          capturedAt: PreviewStorageUsageService.virtualMachineUsage.capturedAt,
          measurementRevision: 1,
          libraryRevision: 1,
          measuredSavedStateMachineIDs: Set(
            PreviewStorageUsageService.virtualMachineUsage.machines
              .filter { $0.savedStateAllocatedBytes > 0 }
              .map(\.machineID)
          )
        )
      }
    )

  var body: some View {
    ScrollView {
      StorageOverviewSection(
        model: model,
        reclamationModel: reclamationModel,
        virtualMachineReclamationModel: virtualMachineReclamationModel,
        containerInventoryRevision: 1,
        virtualMachineInventoryRevision: 1
      )
      .padding(28)
    }
  }
}

#Preview("Storage – Loaded") {
  StorageOverviewLoadedPreview()
    .frame(width: 1_080, height: 760)
}
