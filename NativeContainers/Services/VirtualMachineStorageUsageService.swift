import Darwin
import Foundation

protocol VirtualMachineStorageInventoryLoading: Sendable {
  func loadVirtualMachineStorageInventory() async throws
    -> VirtualMachineStorageInventory
}

protocol VirtualMachineLibraryStorageMeasuring: Sendable {
  func measureStorage(
    in inventory: VirtualMachineStorageInventory
  ) throws -> VirtualMachineLibraryStorageMeasurement
}

protocol VirtualMachineStorageUsageLoading: Sendable {
  func loadVirtualMachineStorageUsage() async throws
    -> VirtualMachineStorageSummary
}

struct VirtualMachineBundleStorageMeasurement: Equatable, Sendable {
  let logicalBytes: UInt64
  let allocatedBytes: UInt64
  let diskLogicalBytes: UInt64
  let diskAllocatedBytes: UInt64
  let savedStateAllocatedBytes: UInt64
  let regularFileCount: Int
  let entryCount: Int
  let hardLinkCount: Int
  let nonRegularEntryCount: Int
  let missingEntryCount: Int
  let overflowed: Bool
}

struct VirtualMachineLibraryStorageMeasurement: Equatable, Sendable {
  let library: VirtualMachineBundleStorageMeasurement
  let machines: [UUID: VirtualMachineBundleStorageMeasurement]
}

enum VirtualMachineStorageMeasurementError:
  LocalizedError,
  Equatable,
  Sendable
{
  case missingRoot(String)
  case unsafeRoot(String)
  case unreadableDirectory(String)
  case tooDeep
  case tooManyEntries
  case invalidMetadata(String)
  case byteCountOverflow

  var errorDescription: String? {
    switch self {
    case .missingRoot(let path):
      "The storage root is missing: \(path)"
    case .unsafeRoot(let path):
      "The storage root is not a safe directory: \(path)"
    case .unreadableDirectory(let path):
      "The storage directory cannot be read: \(path)"
    case .tooDeep:
      "The storage tree exceeds the supported directory depth."
    case .tooManyEntries:
      "The storage tree contains too many entries to measure safely."
    case .invalidMetadata(let path):
      "The storage entry has invalid filesystem metadata: \(path)"
    case .byteCountOverflow:
      "The storage byte count exceeds the supported range."
    }
  }
}

struct FileVirtualMachineLibraryStorageMeasurer:
  VirtualMachineLibraryStorageMeasuring
{
  private static let allocationBlockBytes: UInt64 = 512
  private static let maximumDepth = 256
  private static let maximumEntryCount = 1_000_000

  func measureStorage(
    in inventory: VirtualMachineStorageInventory
  ) throws -> VirtualMachineLibraryStorageMeasurement {
    try Task.checkCancellation()
    let rootPath =
      inventory.rootURL.standardizedFileURL.path(percentEncoded: false)
    let rootDescriptor = rootPath.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard rootDescriptor >= 0 else {
      if errno == ENOENT {
        throw VirtualMachineStorageMeasurementError.missingRoot(rootPath)
      }
      throw VirtualMachineStorageMeasurementError.unsafeRoot(rootPath)
    }
    defer { Darwin.close(rootDescriptor) }

    var rootMetadata = stat()
    guard Darwin.fstat(rootDescriptor, &rootMetadata) == 0,
      Self.fileType(rootMetadata.st_mode) == mode_t(S_IFDIR)
    else {
      throw VirtualMachineStorageMeasurementError.unsafeRoot(rootPath)
    }

    var state = AggregateScanState(
      rootDevice: rootMetadata.st_dev,
      inventory: inventory
    )
    try state.record(
      metadata: rootMetadata,
      relativePath: ".",
      displayPath: rootPath
    )
    try scanDirectory(
      descriptor: rootDescriptor,
      relativePath: "",
      displayPath: rootPath,
      depth: 0,
      state: &state
    )
    return state.measurement
  }

  private func scanDirectory(
    descriptor: Int32,
    relativePath: String,
    displayPath: String,
    depth: Int,
    state: inout AggregateScanState
  ) throws {
    try Task.checkCancellation()
    guard depth <= Self.maximumDepth else {
      throw VirtualMachineStorageMeasurementError.tooDeep
    }

    let names = try directoryNames(
      descriptor: descriptor,
      displayPath: displayPath
    )
    for name in names {
      try Task.checkCancellation()
      state.visitedEntryCount += 1
      guard state.visitedEntryCount <= Self.maximumEntryCount else {
        throw VirtualMachineStorageMeasurementError.tooManyEntries
      }

      let childRelativePath =
        relativePath.isEmpty ? name : "\(relativePath)/\(name)"
      let childDisplayPath = "\(displayPath)/\(name)"
      var metadata = stat()
      let status = name.withCString {
        Darwin.fstatat(
          descriptor,
          $0,
          &metadata,
          AT_SYMLINK_NOFOLLOW
        )
      }
      guard status == 0 else {
        state.markMissing(relativePath: childRelativePath)
        continue
      }

      do {
        try state.record(
          metadata: metadata,
          relativePath: childRelativePath,
          displayPath: childDisplayPath
        )
      } catch VirtualMachineStorageMeasurementError.invalidMetadata {
        state.markUnsafe(relativePath: childRelativePath)
        continue
      }

      guard Self.fileType(metadata.st_mode) == mode_t(S_IFDIR) else {
        continue
      }
      guard metadata.st_dev == state.rootDevice else {
        state.markUnsafe(relativePath: childRelativePath)
        continue
      }

      let childDescriptor = name.withCString {
        Darwin.openat(
          descriptor,
          $0,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
      }
      guard childDescriptor >= 0 else {
        state.markMissing(relativePath: childRelativePath)
        continue
      }

      var openedMetadata = stat()
      let unchanged =
        Darwin.fstat(childDescriptor, &openedMetadata) == 0
        && openedMetadata.st_dev == metadata.st_dev
        && openedMetadata.st_ino == metadata.st_ino
        && Self.fileType(openedMetadata.st_mode) == mode_t(S_IFDIR)
      guard unchanged else {
        Darwin.close(childDescriptor)
        state.markMissing(relativePath: childRelativePath)
        continue
      }

      do {
        try scanDirectory(
          descriptor: childDescriptor,
          relativePath: childRelativePath,
          displayPath: childDisplayPath,
          depth: depth + 1,
          state: &state
        )
        Darwin.close(childDescriptor)
      } catch {
        Darwin.close(childDescriptor)
        throw error
      }
    }
  }

  private func directoryNames(
    descriptor: Int32,
    displayPath: String
  ) throws -> [String] {
    let duplicateDescriptor = Darwin.dup(descriptor)
    guard duplicateDescriptor >= 0,
      let directory = Darwin.fdopendir(duplicateDescriptor)
    else {
      if duplicateDescriptor >= 0 {
        Darwin.close(duplicateDescriptor)
      }
      throw VirtualMachineStorageMeasurementError.unreadableDirectory(
        displayPath
      )
    }
    defer { Darwin.closedir(directory) }

    var names: [String] = []
    errno = 0
    while let entry = Darwin.readdir(directory) {
      try Task.checkCancellation()
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(
          to: CChar.self,
          capacity: Int(MAXNAMLEN) + 1
        ) {
          String(cString: $0)
        }
      }
      guard name != ".", name != ".." else { continue }
      guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
        throw VirtualMachineStorageMeasurementError.invalidMetadata(
          displayPath
        )
      }
      names.append(name)
    }
    guard errno == 0 else {
      throw VirtualMachineStorageMeasurementError.unreadableDirectory(
        displayPath
      )
    }
    return names.sorted {
      $0.utf8.lexicographicallyPrecedes($1.utf8)
    }
  }

  fileprivate static func fileType(_ mode: mode_t) -> mode_t {
    mode & mode_t(S_IFMT)
  }

  fileprivate struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
  }

  private struct TargetDescriptor {
    let machineID: UUID
    let diskImagePath: String
  }

  private struct AggregateScanState {
    let rootDevice: dev_t
    let targetsByBundleName: [String: TargetDescriptor]
    var library = ScanState(diskImagePath: nil)
    var machines: [UUID: ScanState]
    var visitedEntryCount = 0

    init(
      rootDevice: dev_t,
      inventory: VirtualMachineStorageInventory
    ) {
      self.rootDevice = rootDevice
      targetsByBundleName = Dictionary(
        uniqueKeysWithValues: inventory.targets.map {
          (
            $0.bundleURL.lastPathComponent,
            TargetDescriptor(
              machineID: $0.manifest.id,
              diskImagePath: $0.manifest.diskImagePath
            )
          )
        }
      )
      machines = Dictionary(
        uniqueKeysWithValues: inventory.targets.map {
          (
            $0.manifest.id,
            ScanState(diskImagePath: $0.manifest.diskImagePath)
          )
        }
      )
    }

    mutating func record(
      metadata: stat,
      relativePath: String,
      displayPath: String
    ) throws {
      try library.record(
        metadata: metadata,
        relativePath: relativePath,
        displayPath: displayPath
      )
      guard let target = target(for: relativePath),
        var machine = machines[target.descriptor.machineID]
      else {
        return
      }
      try machine.record(
        metadata: metadata,
        relativePath: target.relativePath,
        displayPath: displayPath
      )
      machines[target.descriptor.machineID] = machine
    }

    mutating func markMissing(relativePath: String) {
      library.missingEntryCount += 1
      guard let target = target(for: relativePath),
        var machine = machines[target.descriptor.machineID]
      else {
        return
      }
      machine.missingEntryCount += 1
      machines[target.descriptor.machineID] = machine
    }

    mutating func markUnsafe(relativePath: String) {
      library.nonRegularEntryCount += 1
      guard let target = target(for: relativePath),
        var machine = machines[target.descriptor.machineID]
      else {
        return
      }
      machine.nonRegularEntryCount += 1
      machines[target.descriptor.machineID] = machine
    }

    var measurement: VirtualMachineLibraryStorageMeasurement {
      VirtualMachineLibraryStorageMeasurement(
        library: library.measurement,
        machines: machines.mapValues(\.measurement)
      )
    }

    private func target(
      for relativePath: String
    ) -> (descriptor: TargetDescriptor, relativePath: String)? {
      guard relativePath != "." else { return nil }
      let components = relativePath.split(
        separator: "/",
        omittingEmptySubsequences: false
      )
      guard let first = components.first,
        let descriptor = targetsByBundleName[String(first)]
      else {
        return nil
      }
      let nestedPath =
        components.count == 1
        ? "."
        : components.dropFirst().joined(separator: "/")
      return (descriptor, nestedPath)
    }
  }

  private struct ScanState {
    let diskImagePath: String?
    var logicalBytes: UInt64 = 0
    var allocatedBytes: UInt64 = 0
    var diskLogicalBytes: UInt64 = 0
    var diskAllocatedBytes: UInt64 = 0
    var savedStateAllocatedBytes: UInt64 = 0
    var regularFileCount = 0
    var entryCount = 0
    var hardLinkCount = 0
    var nonRegularEntryCount = 0
    var missingEntryCount = 0
    var overflowed = false
    var seenIdentities =
      Set<FileVirtualMachineLibraryStorageMeasurer.FileIdentity>()
    var seenHardLinkedFiles =
      Set<FileVirtualMachineLibraryStorageMeasurer.FileIdentity>()

    mutating func record(
      metadata: stat,
      relativePath: String,
      displayPath: String
    ) throws {
      guard metadata.st_size >= 0, metadata.st_blocks >= 0 else {
        throw VirtualMachineStorageMeasurementError.invalidMetadata(
          displayPath
        )
      }
      entryCount += 1

      let identity =
        FileVirtualMachineLibraryStorageMeasurer.FileIdentity(
          device: UInt64(metadata.st_dev),
          inode: UInt64(metadata.st_ino)
        )
      let allocated = try checkedProduct(
        UInt64(metadata.st_blocks),
        FileVirtualMachineLibraryStorageMeasurer.allocationBlockBytes
      )
      let type = FileVirtualMachineLibraryStorageMeasurer.fileType(
        metadata.st_mode
      )
      let isRegularFile = type == mode_t(S_IFREG)

      if isRegularFile {
        regularFileCount += 1
        if metadata.st_nlink > 1,
          seenHardLinkedFiles.insert(identity).inserted
        {
          hardLinkCount += 1
        }
        if relativePath == diskImagePath {
          diskLogicalBytes = UInt64(metadata.st_size)
          diskAllocatedBytes = allocated
        }
      } else if type != mode_t(S_IFDIR) {
        nonRegularEntryCount += 1
      }

      guard seenIdentities.insert(identity).inserted else {
        return
      }
      if isRegularFile {
        logicalBytes = try checkedSum(
          logicalBytes,
          UInt64(metadata.st_size)
        )
      }
      allocatedBytes = try checkedSum(allocatedBytes, allocated)
      if isSavedState(relativePath) {
        savedStateAllocatedBytes = try checkedSum(
          savedStateAllocatedBytes,
          allocated
        )
      }
    }

    var measurement: VirtualMachineBundleStorageMeasurement {
      VirtualMachineBundleStorageMeasurement(
        logicalBytes: logicalBytes,
        allocatedBytes: allocatedBytes,
        diskLogicalBytes: diskLogicalBytes,
        diskAllocatedBytes: diskAllocatedBytes,
        savedStateAllocatedBytes: savedStateAllocatedBytes,
        regularFileCount: regularFileCount,
        entryCount: entryCount,
        hardLinkCount: hardLinkCount,
        nonRegularEntryCount: nonRegularEntryCount,
        missingEntryCount: missingEntryCount,
        overflowed: overflowed
      )
    }

    private func isSavedState(_ relativePath: String) -> Bool {
      relativePath == MacVirtualMachineSavedStateStore.directoryName
        || relativePath.hasPrefix(
          "\(MacVirtualMachineSavedStateStore.directoryName)/"
        )
    }

    private mutating func checkedSum(
      _ lhs: UInt64,
      _ rhs: UInt64
    ) throws -> UInt64 {
      let (sum, overflow) = lhs.addingReportingOverflow(rhs)
      guard !overflow else {
        overflowed = true
        throw VirtualMachineStorageMeasurementError.byteCountOverflow
      }
      return sum
    }

    private mutating func checkedProduct(
      _ lhs: UInt64,
      _ rhs: UInt64
    ) throws -> UInt64 {
      let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
      guard !overflow else {
        overflowed = true
        throw VirtualMachineStorageMeasurementError.byteCountOverflow
      }
      return product
    }
  }
}

struct VirtualMachineStorageUsageService:
  VirtualMachineStorageUsageLoading
{
  private let inventory: any VirtualMachineStorageInventoryLoading
  private let measurer: any VirtualMachineLibraryStorageMeasuring
  private let now: @Sendable () -> Date

  init(
    inventory: any VirtualMachineStorageInventoryLoading,
    measurer: any VirtualMachineLibraryStorageMeasuring =
      FileVirtualMachineLibraryStorageMeasurer(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.inventory = inventory
    self.measurer = measurer
    self.now = now
  }

  func loadVirtualMachineStorageUsage() async throws
    -> VirtualMachineStorageSummary
  {
    try Task.checkCancellation()
    let storageInventory =
      try await inventory.loadVirtualMachineStorageInventory()
    let measurer = self.measurer
    let capturedAt = now()

    let measurementTask = Task.detached(priority: .utility) {
      let measurement = try measurer.measureStorage(in: storageInventory)
      var machines: [VirtualMachineStorageUsage] = []
      var issues: [VirtualMachineStorageIssue] = []

      for target in storageInventory.targets {
        try Task.checkCancellation()
        guard let usage = measurement.machines[target.manifest.id] else {
          issues.append(
            VirtualMachineStorageIssue(
              machineID: target.manifest.id,
              name: target.manifest.name,
              message: "The VM bundle disappeared during storage measurement."
            )
          )
          continue
        }
        machines.append(
          VirtualMachineStorageUsage(
            machineID: target.manifest.id,
            name: target.manifest.name,
            installState: target.manifest.installState,
            provisionedDiskBytes: target.manifest.resources.diskBytes,
            diskLogicalBytes: usage.diskLogicalBytes,
            diskAllocatedBytes: usage.diskAllocatedBytes,
            bundleLogicalBytes: usage.logicalBytes,
            bundleAllocatedBytes: usage.allocatedBytes,
            savedStateAllocatedBytes: usage.savedStateAllocatedBytes,
            regularFileCount: usage.regularFileCount,
            hardLinkCount: usage.hardLinkCount,
            nonRegularEntryCount: usage.nonRegularEntryCount,
            missingEntryCount: usage.missingEntryCount,
            overflowed: usage.overflowed
          )
        )
      }

      return VirtualMachineStorageSummary(
        capturedAt: capturedAt,
        discoveredMachineCount: storageInventory.targets.count,
        libraryLogicalBytes: measurement.library.logicalBytes,
        libraryAllocatedBytes: measurement.library.allocatedBytes,
        libraryEntryCount: measurement.library.entryCount,
        libraryHardLinkCount: measurement.library.hardLinkCount,
        libraryNonRegularEntryCount:
          measurement.library.nonRegularEntryCount,
        libraryMissingEntryCount: measurement.library.missingEntryCount,
        libraryOverflowed: measurement.library.overflowed,
        machines: machines.sorted {
          $0.name.localizedStandardCompare($1.name) == .orderedAscending
        },
        issues: issues
      )
    }
    return try await withTaskCancellationHandler {
      try await measurementTask.value
    } onCancel: {
      measurementTask.cancel()
    }
  }
}

struct UnavailableVirtualMachineStorageUsageService:
  VirtualMachineStorageUsageLoading
{
  func loadVirtualMachineStorageUsage() async throws
    -> VirtualMachineStorageSummary
  {
    throw StorageUsageError.unavailable
  }
}
