import Foundation
import Testing
import UserNotifications

@testable import NativeContainers

@MainActor
struct AppNotificationTests {
  @Test
  func systemStatusMappingsCoverEveryKnownCase() {
    #expect(
      SystemUserNotificationCenterClient.authorizationStatus(from: .notDetermined)
        == .notDetermined
    )
    #expect(
      SystemUserNotificationCenterClient.authorizationStatus(from: .denied)
        == .denied
    )
    #expect(
      SystemUserNotificationCenterClient.authorizationStatus(from: .authorized)
        == .authorized
    )
    #expect(
      SystemUserNotificationCenterClient.authorizationStatus(from: .provisional)
        == .provisional
    )
    #expect(
      SystemUserNotificationCenterClient.channelStatus(from: .notSupported)
        == .notSupported
    )
    #expect(
      SystemUserNotificationCenterClient.channelStatus(from: .disabled)
        == .disabled
    )
    #expect(
      SystemUserNotificationCenterClient.channelStatus(from: .enabled)
        == .enabled
    )
  }

  @Test
  func destinationsRoundTripThroughPropertyListSafePayloads() {
    let machineID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let destinations: [AppNotificationDestination] = [
      .builds,
      .macOSVirtualMachine(machineID),
    ]

    for destination in destinations {
      #expect(AppNotificationDestination(payload: destination.payload) == destination)
    }

    #expect(AppNotificationDestination(payload: [:]) == nil)
    #expect(
      AppNotificationDestination(
        payload: ["route": "macOSVirtualMachine", "identifier": "not-a-uuid"]
      ) == nil
    )
    #expect(AppNotificationDestination(payload: ["route": "unknown"]) == nil)
  }

  @Test
  func eventRequestsCarryGenericLocalizedContentAndTypedRoutes() {
    let machineID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let event = AppNotificationEvent.virtualMachineInstallationFailed(
      machineID: machineID,
      machineName: "Development VM"
    )

    let request = UserNotificationService.request(for: event)

    #expect(request.trigger == nil)
    #expect(request.content.sound != nil)
    #expect(request.content.title == "macOS installation failed")
    #expect(request.content.body.contains("Development VM"))
    #expect(request.content.body.contains("needs attention"))
    #expect(request.content.threadIdentifier.contains(machineID.uuidString.lowercased()))
    #expect(
      AppNotificationDestination(
        payload: notificationPayload(from: request.content.userInfo)
      ) == .macOSVirtualMachine(machineID)
    )
  }

  @Test
  func serviceInstallsDelegateRequestsOnlyAlertsAndSoundsAndReturnsAuthoritativeSettings()
    async throws
  {
    let client = RecordingUserNotificationCenterClient(settings: notificationNotDetermined)
    client.settingsAfterAuthorization = notificationAuthorized
    let service = UserNotificationService(center: client)

    let settings = try await service.requestAuthorization()

    #expect(client.installedDelegate != nil)
    #expect(client.authorizationOptions.count == 1)
    #expect(client.authorizationOptions[0].contains(.alert))
    #expect(client.authorizationOptions[0].contains(.sound))
    #expect(!client.authorizationOptions[0].contains(.badge))
    #expect(settings == notificationAuthorized)
  }

  @Test
  func serviceDeliversOnlyWhenTheSystemCurrentlyPermitsIt() async {
    let client = RecordingUserNotificationCenterClient(settings: notificationDenied)
    let service = UserNotificationService(center: client)

    await service.deliver(.imageBuildSucceeded)
    #expect(client.requests.isEmpty)

    client.currentSettings = notificationAuthorized
    await service.deliver(.imageBuildSucceeded)

    #expect(client.requests.count == 1)
    #expect(
      AppNotificationDestination(
        payload: notificationPayload(from: client.requests[0].content.userInfo)
      ) == .builds
    )
  }

  @Test
  func deliveryFailureDoesNotEscapeTheBestEffortServiceBoundary() async {
    let client = RecordingUserNotificationCenterClient(settings: notificationAuthorized)
    client.deliveryError = ExpectedNotificationError()
    let service = UserNotificationService(center: client)

    await service.deliver(.imageBuildFailed)

    #expect(client.requests.count == 1)
  }

  @Test
  func settingsModelRefreshesAndRequestsPermissionFromTheSystemService() async {
    let service = RecordingAppNotificationService(settings: notificationNotDetermined)
    service.authorizationResult = notificationAuthorized
    let model = AppNotificationSettingsModel(service: service)

    await model.refresh()
    #expect(model.settings == notificationNotDetermined)

    await model.requestAuthorization()

    #expect(service.authorizationRequestCount == 1)
    #expect(model.settings == notificationAuthorized)
    #expect(model.errorMessage == nil)
    #expect(!model.isWorking)
  }

  @Test
  func settingsModelReloadsAuthoritativeStateAfterRequestFailure() async {
    let service = RecordingAppNotificationService(settings: notificationNotDetermined)
    service.authorizationError = ExpectedNotificationError()
    let model = AppNotificationSettingsModel(service: service)

    await model.refresh()
    service.currentSettings = notificationDenied
    await model.requestAuthorization()

    #expect(service.authorizationRequestCount == 1)
    #expect(model.settings == notificationDenied)
    #expect(model.errorMessage == "Expected notification failure.")
    #expect(!model.isWorking)
  }

  @Test
  func notificationResponsesRouteToExistingResourcesAndFallBackForMissingOnes() async throws {
    let machine = try notificationMachine()
    let service = RecordingAppNotificationService(settings: notificationAuthorized)
    let model = AppModel(
      notificationService: service,
      initialInventory: notificationEmptyInventory(),
      initialVirtualMachines: [machine]
    )

    #expect(service.authorizationRequestCount == 0)

    await service.simulateResponse(to: .macOSVirtualMachine(machine.id))
    #expect(model.workspaceRoute == .macOSVirtualMachine(machine.id))

    await service.simulateResponse(to: .macOSVirtualMachine(UUID()))
    #expect(model.workspaceRoute == .macOSVirtualMachines)

    await service.simulateResponse(to: .builds)
    #expect(model.workspaceRoute == .builds)
  }
}

@MainActor
private final class RecordingUserNotificationCenterClient: UserNotificationCenterClient {
  var currentSettings: AppNotificationSettingsSnapshot
  var settingsAfterAuthorization: AppNotificationSettingsSnapshot?
  var authorizationError: (any Error)?
  var deliveryError: (any Error)?

  private(set) var installedDelegate: (any UNUserNotificationCenterDelegate)?
  private(set) var authorizationOptions: [UNAuthorizationOptions] = []
  private(set) var requests: [UNNotificationRequest] = []

  init(settings: AppNotificationSettingsSnapshot) {
    currentSettings = settings
  }

  func install(delegate: any UNUserNotificationCenterDelegate) {
    installedDelegate = delegate
  }

  func settings() async -> AppNotificationSettingsSnapshot {
    currentSettings
  }

  func requestAuthorization(options: UNAuthorizationOptions) async throws {
    authorizationOptions.append(options)
    if let authorizationError {
      throw authorizationError
    }
    if let settingsAfterAuthorization {
      currentSettings = settingsAfterAuthorization
    }
  }

  func add(_ request: UNNotificationRequest) async throws {
    requests.append(request)
    if let deliveryError {
      throw deliveryError
    }
  }
}

private struct ExpectedNotificationError: LocalizedError {
  var errorDescription: String? {
    "Expected notification failure."
  }
}

private let notificationNotDetermined = AppNotificationSettingsSnapshot(
  authorization: .notDetermined,
  alerts: .disabled,
  sounds: .disabled
)

private let notificationAuthorized = AppNotificationSettingsSnapshot(
  authorization: .authorized,
  alerts: .enabled,
  sounds: .enabled
)

private let notificationDenied = AppNotificationSettingsSnapshot(
  authorization: .denied,
  alerts: .disabled,
  sounds: .disabled
)

private func notificationPayload(
  from userInfo: [AnyHashable: Any]
) -> [String: String] {
  userInfo.reduce(into: [String: String]()) { result, entry in
    guard let key = entry.key as? String, let value = entry.value as? String else {
      return
    }
    result[key] = value
  }
}

private func notificationEmptyInventory() -> ContainerInventory {
  ContainerInventory(
    system: ContainerSystemInfo(
      version: "1.0.0",
      build: "release",
      commit: "abc123",
      applicationRoot: URL(filePath: "/tmp/nativecontainers-notification-tests"),
      installRoot: URL(filePath: "/usr/local")
    ),
    containers: [],
    images: [],
    volumes: [],
    networks: [],
    machines: []
  )
}

private func notificationMachine() throws -> VirtualMachineManifest {
  try VirtualMachineManifest(
    name: "Notification Test",
    guest: .macOS,
    installState: .readyToInstall,
    resources: VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
  )
}
