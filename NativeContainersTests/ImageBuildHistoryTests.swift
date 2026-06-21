import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Image build history", .serialized)
struct ImageBuildHistoryTests {
  @Test
  func storeRoundTripsPrivateRecordsAndSupportsRemoval() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)
    let running = makeHistoryRecord(
      launchID: launchID,
      status: .running,
      startedAt: Date(timeIntervalSince1970: 1_000)
    )
    let completed = running.finishing(
      at: Date(timeIntervalSince1970: 1_012),
      status: .succeeded,
      imageDigest: "sha256:built",
      completedTags: running.requestedTags,
      failureKind: nil
    )

    try await store.record(running)
    try await store.record(completed)

    var snapshot = try await store.load()
    #expect(snapshot.records == [completed])
    #expect(snapshot.rejectedRecordCount == 0)
    #expect(
      try permissions(at: fixture.rootURL.deletingLastPathComponent()) == 0o700
    )
    #expect(try permissions(at: fixture.rootURL) == 0o700)
    #expect(try permissions(at: fixture.recordURL(id: completed.id)) == 0o600)

    try await store.remove(id: completed.id)
    snapshot = try await store.load()
    #expect(snapshot.records.isEmpty)

    try await store.record(
      makeHistoryRecord(launchID: launchID, status: .failed)
    )
    try await store.removeAll()
    snapshot = try await store.load()
    #expect(snapshot.records.isEmpty)
  }

  @Test
  @MainActor
  func storeIsolatesCorruptRecords() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)
    let valid = makeHistoryRecord(launchID: launchID, status: .succeeded)
    try await store.record(valid)

    let corruptURL = fixture.recordURL(id: UUID())
    try Data("{not-json".utf8).write(to: corruptURL)
    #expect(Darwin.chmod(corruptURL.path(percentEncoded: false), 0o600) == 0)

    let snapshot = try await store.load()
    #expect(snapshot.records == [valid])
    #expect(snapshot.rejectedRecordCount == 1)

    try await store.remove(id: valid.id)
    let secondCorruptURL = fixture.recordURL(id: UUID())
    try Data("{still-not-json".utf8).write(to: secondCorruptURL)
    #expect(Darwin.chmod(secondCorruptURL.path(percentEncoded: false), 0o600) == 0)
    let model = ImageBuildHistoryModel(service: store)
    await model.refresh()
    #expect(model.records.isEmpty)
    #expect(model.rejectedRecordCount == 1)

    await model.removeAll()
    #expect(model.records.isEmpty)
    #expect(model.rejectedRecordCount == 0)
  }

  @Test
  func storeRetainsRecordsFromANewerSchema() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let store = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: UUID()
    )
    _ = try await store.load()

    let recordID = UUID()
    let recordURL = fixture.recordURL(id: recordID)
    try Data(#"{"schemaVersion":2,"record":{}}"#.utf8).write(to: recordURL)
    #expect(Darwin.chmod(recordURL.path(percentEncoded: false), 0o600) == 0)

    let snapshot = try await store.load()

    #expect(snapshot.records.isEmpty)
    #expect(snapshot.rejectedRecordCount == 1)
    #expect(FileManager.default.fileExists(atPath: recordURL.path(percentEncoded: false)))
  }

  @Test
  func storeDefaultsNewFieldsForExistingSchemaOneRecords() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)
    let record = makeHistoryRecord(launchID: launchID, status: .succeeded)
    try await store.record(record)

    let recordURL = fixture.recordURL(id: record.id)
    let encoded = try Data(contentsOf: recordURL)
    var envelope = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var payload = try #require(envelope["record"] as? [String: Any])
    payload.removeValue(forKey: "retainedImages")
    payload.removeValue(forKey: "outputKind")
    envelope["record"] = payload
    try JSONSerialization.data(withJSONObject: envelope).write(to: recordURL)
    #expect(Darwin.chmod(recordURL.path(percentEncoded: false), 0o600) == 0)

    let snapshot = try await store.load()

    #expect(snapshot.records == [record])
    #expect(snapshot.records.first?.outputKind == .imageStore)
    #expect(snapshot.rejectedRecordCount == 0)
  }

  @Test
  func storeRejectsSpecialFilesWithoutBlockingAndScavengesTemporaryFiles() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)
    _ = try await store.load()

    let fifoURL = fixture.recordURL(id: UUID())
    #expect(Darwin.mkfifo(fifoURL.path(percentEncoded: false), 0o600) == 0)
    let temporaryURL = fixture.rootURL.appending(
      path: ".\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased()).tmp",
      directoryHint: .notDirectory
    )
    try Data("orphaned".utf8).write(to: temporaryURL)
    #expect(Darwin.chmod(temporaryURL.path(percentEncoded: false), 0o600) == 0)

    let snapshot = try await store.load()

    #expect(snapshot.records.isEmpty)
    #expect(snapshot.rejectedRecordCount == 1)
    #expect(!FileManager.default.fileExists(atPath: fifoURL.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path(percentEncoded: false)))
  }

  @Test
  func storeStripsExtendedACLsFromItsDirectoryAndRecords() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)
    let record = makeHistoryRecord(launchID: launchID, status: .succeeded)
    try await store.record(record)
    let recordURL = fixture.recordURL(id: record.id)

    try addACL(
      "everyone allow list,search,readattr,readextattr,readsecurity",
      to: fixture.rootURL
    )
    try addACL("everyone allow read,readattr,readextattr,readsecurity", to: recordURL)
    #expect(try extendedACLEntryCount(at: fixture.rootURL) == 1)
    #expect(try extendedACLEntryCount(at: recordURL) == 1)

    _ = try await store.load()

    #expect(try extendedACLEntryCount(at: fixture.rootURL) == 0)
    #expect(try extendedACLEntryCount(at: recordURL) == 0)
  }

  @Test
  func storeRejectsASymbolicLinkRoot() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let targetURL = fixture.rootURL.deletingLastPathComponent().appending(
      path: "target",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: targetURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let rootPath = fixture.rootURL.path(percentEncoded: false)
    let linkPath = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
    #expect(
      Darwin.symlink(
        targetURL.path(percentEncoded: false),
        linkPath
      ) == 0
    )

    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: UUID())
    await #expect(throws: ImageBuildHistoryStoreError.self) {
      _ = try await store.load()
    }
  }

  @Test
  func storeRemovesItsLeaseOnGracefulRelease() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)

    _ = try await store.load()
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.leaseURL(launchID: launchID).path(percentEncoded: false)
      )
    )

    await store.releaseLaunchLease()

    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.leaseURL(launchID: launchID).path(percentEncoded: false)
      )
    )
  }

  @Test
  func gracefulReleaseDoesNotRecreateARemovedRoot() async throws {
    let fixture = try ImageBuildHistoryFixture()
    let store = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: UUID()
    )
    _ = try await store.load()
    fixture.remove()

    await store.releaseLaunchLease()

    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.rootURL.path(percentEncoded: false)
      )
    )
  }

  @Test
  func storeDoesNotInterruptAnotherLiveLaunch() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let firstLaunch = UUID()
    let record = makeHistoryRecord(
      launchID: firstLaunch,
      status: .running
    )
    let firstStore = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: firstLaunch
    )
    try await firstStore.record(record)

    let observer = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: UUID()
    )
    var snapshot = try await observer.load()
    #expect(snapshot.records.first?.status == .running)

    await firstStore.abandonLaunchLease()
    let recoveryStore = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: UUID(),
      now: { Date(timeIntervalSince1970: 2_000) }
    )
    snapshot = try await recoveryStore.load()
    #expect(snapshot.records.first?.status == .interrupted)
  }

  @Test
  func storeReconcilesRunningRecordsFromAnEarlierLaunch() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let firstLaunch = UUID()
    let secondLaunch = UUID()
    let interruptedAt = Date(timeIntervalSince1970: 2_000)
    let record = makeHistoryRecord(
      launchID: firstLaunch,
      status: .running,
      startedAt: Date(timeIntervalSince1970: 1_900)
    )
    let firstStore = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: firstLaunch
    )
    try await firstStore.record(record)
    await firstStore.abandonLaunchLease()

    let snapshot = try await ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: secondLaunch,
      now: { interruptedAt }
    ).load()

    let reconciled = try #require(snapshot.records.first)
    #expect(reconciled.id == record.id)
    #expect(reconciled.status == .interrupted)
    #expect(reconciled.finishedAt == interruptedAt)
    #expect(reconciled.durationMilliseconds == 100_000)
  }

  @Test
  func retentionBoundsTerminalRecordsWithoutRemovingCurrentWork() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)
    let running = makeHistoryRecord(
      launchID: launchID,
      status: .running,
      startedAt: Date(timeIntervalSince1970: 10_000)
    )
    try await store.record(running)

    for index in 0..<(ImageBuildHistoryStore.maximumTerminalRecordCount + 3) {
      try await store.record(
        makeHistoryRecord(
          launchID: launchID,
          status: .succeeded,
          startedAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
      )
    }

    let snapshot = try await store.load()
    #expect(snapshot.records.filter { $0.status.isTerminal }.count == 200)
    #expect(snapshot.records.contains { $0.id == running.id && $0.status == .running })
    #expect(snapshot.records.count == 201)
  }

  @Test
  func storeFailsClosedWhenCanonicalEntryLimitIsExceeded() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)
    let valid = makeHistoryRecord(launchID: launchID, status: .succeeded)
    try await store.record(valid)

    let malformed = Data(#"{"schemaVersion":1,"record":{}}"#.utf8)
    for _ in 0..<ImageBuildHistoryStore.maximumFilesToScan {
      let url = fixture.recordURL(id: UUID())
      try malformed.write(to: url)
    }

    await #expect(
      throws: ImageBuildHistoryStoreError.tooManyEntries(
        ImageBuildHistoryStore.maximumFilesToScan
      )
    ) {
      _ = try await store.load()
    }
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.recordURL(id: valid.id).path(percentEncoded: false)
      )
    )
  }

  @Test
  @MainActor
  func reviewedBuildPlanLocksTopLevelNavigationUntilDiscarded() async {
    let plan = makeHistoryBuildPlan()
    let appModel = AppModel(
      imageBuildService: TestHistoryImageBuilder(
        plan: plan,
        behavior: .succeed
      )
    )
    appModel.selection = .builds
    let buildModel = appModel.makeImageBuildModel()
    _ = await buildModel.prepare(makeHistoryBuildRequest())

    #expect(appModel.isBuildWorkspaceNavigationLocked)
    appModel.selectSidebarDestination(.images)
    #expect(appModel.selection == .builds)

    await buildModel.discardPlan()
    #expect(!appModel.isBuildWorkspaceNavigationLocked)
    appModel.selectSidebarDestination(.images)
    #expect(appModel.selection == .images)
  }

  @Test
  @MainActor
  func modelRefreshesAndRemovesThroughTheStoragePort() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)
    let record = makeHistoryRecord(launchID: launchID, status: .succeeded)
    try await store.record(record)
    let model = ImageBuildHistoryModel(service: store)

    await model.refresh()
    #expect(model.records == [record])
    #expect(model.errorMessage == nil)

    await model.remove(id: record.id)
    #expect(model.records.isEmpty)
    #expect(model.errorMessage == nil)
  }

  @Test
  @MainActor
  func modelObservesRunningAndTerminalStoreUpdates() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)
    let model = ImageBuildHistoryModel(service: store)
    let observation = Task { await model.observe() }
    defer { observation.cancel() }
    await Task.yield()

    let running = makeHistoryRecord(launchID: launchID, status: .running)
    try await store.record(running)
    try await waitForHistory {
      model.records.first?.status == .running
    }

    try await store.record(
      running.finishing(
        at: running.startedAt.addingTimeInterval(3),
        status: .succeeded,
        imageDigest: "sha256:built",
        completedTags: running.requestedTags,
        failureKind: nil
      )
    )
    try await waitForHistory {
      model.records.first?.status == .succeeded
    }
  }

  @Test
  @MainActor
  func modelCoalescesAnUpdateArrivingDuringALoad() async throws {
    let launchID = UUID()
    let updatedRecord = makeHistoryRecord(
      launchID: launchID,
      status: .succeeded
    )
    let store = DelayedImageBuildHistoryStore(
      initialSnapshot: ImageBuildHistorySnapshot(
        records: [],
        rejectedRecordCount: 0
      )
    )
    let model = ImageBuildHistoryModel(service: store)
    let observation = Task { await model.observe() }
    defer { observation.cancel() }
    await store.waitForLoadCount(1)

    await store.blockNextLoad()
    let manualRefresh = Task { await model.refresh() }
    await store.waitUntilBlockedLoadStarts()
    await store.publish(
      ImageBuildHistorySnapshot(
        records: [updatedRecord],
        rejectedRecordCount: 0
      )
    )
    await Task.yield()
    await store.resumeBlockedLoad()
    await manualRefresh.value

    try await waitForHistory {
      model.records == [updatedRecord]
    }
    #expect(await store.loadCount >= 3)
  }

  @Test
  @MainActor
  func modelPollsForWritesFromAnotherStore() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let writerLaunch = UUID()
    let reader = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: UUID()
    )
    let model = ImageBuildHistoryModel(service: reader)
    let observation = Task { await model.observe() }
    defer { observation.cancel() }
    await Task.yield()

    let record = makeHistoryRecord(
      launchID: writerLaunch,
      status: .succeeded
    )
    let writer = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: writerLaunch
    )
    try await writer.record(record)

    try await waitForHistory {
      model.records == [record]
    }
  }

  @Test
  @MainActor
  func manualRefreshPublishesExternalChangeToOtherVisibleModels() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let reader = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: UUID()
    )
    let firstModel = ImageBuildHistoryModel(service: reader)
    let secondModel = ImageBuildHistoryModel(service: reader)
    let observation = Task { await firstModel.observe() }
    defer { observation.cancel() }
    await Task.yield()

    let writerLaunch = UUID()
    let record = makeHistoryRecord(
      launchID: writerLaunch,
      status: .succeeded
    )
    let writer = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: writerLaunch
    )
    try await writer.record(record)
    await secondModel.refresh()

    try await waitForHistory {
      firstModel.records == [record]
    }
  }

  @Test
  @MainActor
  func modelReconcilesForeignCrashWithoutDirectoryMutation() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let writerLaunch = UUID()
    let writer = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: writerLaunch
    )
    let running = makeHistoryRecord(
      launchID: writerLaunch,
      status: .running
    )
    try await writer.record(running)

    let reader = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: UUID()
    )
    let model = ImageBuildHistoryModel(service: reader)
    let observation = Task { await model.observe() }
    defer { observation.cancel() }
    try await waitForHistory {
      model.records.first?.status == .running
    }

    await writer.abandonLaunchLease()

    try await waitForHistory {
      model.records.first?.status == .interrupted
    }
  }

  @Test
  @MainActor
  func modelKeepsCorruptionWarningAcrossUnchangedPoll() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let store = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: UUID()
    )
    _ = try await store.load()
    let corruptURL = fixture.recordURL(id: UUID())
    try Data("{not-json".utf8).write(to: corruptURL)
    #expect(Darwin.chmod(corruptURL.path(percentEncoded: false), 0o600) == 0)

    let model = ImageBuildHistoryModel(service: store)
    let observation = Task { await model.observe() }
    defer { observation.cancel() }
    try await waitForHistory {
      model.rejectedRecordCount == 1
    }

    try await Task.sleep(for: .milliseconds(1_200))

    #expect(model.rejectedRecordCount == 1)
  }

  @Test
  @MainActor
  func corruptionWarningReachesEveryVisibleModel() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let store = ImageBuildHistoryStore(
      rootURL: fixture.rootURL,
      launchID: UUID()
    )
    _ = try await store.load()
    let firstModel = ImageBuildHistoryModel(service: store)
    let firstObservation = Task { await firstModel.observe() }
    defer { firstObservation.cancel() }
    await Task.yield()

    let corruptURL = fixture.recordURL(id: UUID())
    try Data("{not-json".utf8).write(to: corruptURL)
    #expect(Darwin.chmod(corruptURL.path(percentEncoded: false), 0o600) == 0)

    let secondModel = ImageBuildHistoryModel(service: store)
    let secondObservation = Task { await secondModel.observe() }
    defer { secondObservation.cancel() }

    try await waitForHistory {
      firstModel.rejectedRecordCount == 1
        && secondModel.rejectedRecordCount == 1
    }
  }

  @Test
  func recorderPersistsOnlyReviewedNonsecretMetadata() async throws {
    let fixture = try ImageBuildHistoryFixture()
    defer { fixture.remove() }
    let launchID = UUID()
    let outputDestination = URL(
      filePath: "/tmp/OUTPUT-PATH-SENTINEL/reviewed-image.oci.tar",
      directoryHint: .notDirectory
    )
    let plan = makeHistoryBuildPlan(
      sourceContextDirectory: URL(
        filePath: "/tmp/FULL-PATH-SECRET-SENTINEL/safe-context",
        directoryHint: .isDirectory
      ),
      secrets: [
        ImageBuildSecretReview(
          id: "SECRET-ID-SENTINEL",
          displayPath: "/tmp/SECRET-PATH-SENTINEL/key",
          byteCount: 20
        )
      ],
      buildArguments: ["TOKEN=BUILD-VALUE-SENTINEL"],
      labels: ["secret.label=LABEL-VALUE-SENTINEL"],
      output: ImageBuildOutputPlan(
        reviewID: UUID(),
        kind: .ociArchive,
        destinationURL: outputDestination,
        existingDestinationIdentity: nil
      )
    )
    let base = TestHistoryImageBuilder(
      plan: plan,
      behavior: .succeedOutput(
        .ociArchive(
          destination: outputDestination,
          sha256: String(repeating: "c", count: 64),
          byteCount: 4_096
        )
      )
    )
    let store = ImageBuildHistoryStore(rootURL: fixture.rootURL, launchID: launchID)
    let recorder = RecordingImageBuildService(
      base: base,
      history: store,
      launchID: launchID
    )

    _ = try await recorder.build(
      plan,
      authorization: .none,
      progress: { _ in }
    )

    let snapshot = try await store.load()
    let record = try #require(snapshot.records.first)
    #expect(record.contextDisplayName == "safe-context")
    #expect(record.buildArgumentKeys == ["TOKEN"])
    #expect(record.labelKeys == ["secret.label"])
    #expect(record.secretCount == 1)
    #expect(record.outputKind == .ociArchive)

    let data = try Data(contentsOf: fixture.recordURL(id: record.id))
    let raw = String(decoding: data, as: UTF8.self)
    #expect(!raw.contains("FULL-PATH-SECRET-SENTINEL"))
    #expect(!raw.contains("BUILD-VALUE-SENTINEL"))
    #expect(!raw.contains("LABEL-VALUE-SENTINEL"))
    #expect(!raw.contains("SECRET-ID-SENTINEL"))
    #expect(!raw.contains("SECRET-PATH-SENTINEL"))
    #expect(!raw.contains("OUTPUT-PATH-SENTINEL"))
  }

  @Test
  func recorderWritesRunningThenSucceeded() async throws {
    let plan = makeHistoryBuildPlan()
    let history = CapturingImageBuildHistoryStore()
    let recorder = RecordingImageBuildService(
      base: TestHistoryImageBuilder(plan: plan, behavior: .succeed),
      history: history,
      launchID: UUID()
    )

    let result = try await recorder.build(
      plan,
      authorization: .none,
      progress: { _ in }
    )

    let records = await history.capturedRecords()
    #expect(result.imageDigest == "sha256:built")
    #expect(records.map(\.status) == [.running, .succeeded])
    #expect(records.last?.imageDigest == "sha256:built")
    #expect(records.last?.completedTags == plan.tags.map(\.reference))
  }

  @Test
  func recorderClassifiesPartialCompletionWithoutPersistingMessages() async throws {
    let plan = makeHistoryBuildPlan()
    let history = CapturingImageBuildHistoryStore()
    let expected = ImageBuildPartialCompletionError(
      buildID: plan.id,
      imageDigest: "sha256:partial",
      appliedTags: [plan.tags[0].reference],
      failureMessage: "DO-NOT-PERSIST-MESSAGE"
    )
    let recorder = RecordingImageBuildService(
      base: TestHistoryImageBuilder(plan: plan, behavior: .partial(expected)),
      history: history,
      launchID: UUID()
    )

    await #expect(throws: expected) {
      _ = try await recorder.build(
        plan,
        authorization: .none,
        progress: { _ in }
      )
    }

    let final = try #require(await history.capturedRecords().last)
    #expect(final.status == .partiallySucceeded)
    #expect(final.failureKind == .partialFinalization)
    #expect(final.imageDigest == "sha256:partial")
  }

  @Test
  func recorderPreservesEveryRetainedPartialImport() async throws {
    let plan = makeHistoryBuildPlan()
    let history = CapturingImageBuildHistoryStore()
    let expected = ImageBuildImportPartialCompletionError(
      buildID: plan.id,
      importedImages: [
        ImageBuildImportedImageRecord(
          reference: "recovery:amd64",
          digest: "sha256:amd64"
        ),
        ImageBuildImportedImageRecord(
          reference: "recovery:arm64",
          digest: "sha256:arm64"
        ),
      ],
      failureMessage: "DO-NOT-PERSIST-MESSAGE"
    )
    let recorder = RecordingImageBuildService(
      base: TestHistoryImageBuilder(
        plan: plan,
        behavior: .partialImport(expected)
      ),
      history: history,
      launchID: UUID()
    )

    await #expect(throws: expected) {
      _ = try await recorder.build(
        plan,
        authorization: .none,
        progress: { _ in }
      )
    }

    let final = try #require(await history.capturedRecords().last)
    #expect(final.status == .partiallySucceeded)
    #expect(final.failureKind == .partialImport)
    #expect(
      final.retainedImages == [
        ImageBuildHistoryRetainedImage(
          reference: "recovery:amd64",
          digest: "sha256:amd64"
        ),
        ImageBuildHistoryRetainedImage(
          reference: "recovery:arm64",
          digest: "sha256:arm64"
        ),
      ]
    )
    #expect(final.imageDigest == nil)
  }

  @Test
  func recorderClassifiesSuppressedSecretBuildFailureAsBuilderFailure() async throws {
    let plan = makeHistoryBuildPlan()
    let history = CapturingImageBuildHistoryStore()
    let recorder = RecordingImageBuildService(
      base: TestHistoryImageBuilder(
        plan: plan,
        behavior: .imageBuildFailure(.secretBuildFailed)
      ),
      history: history,
      launchID: UUID()
    )

    await #expect(throws: ImageBuildError.secretBuildFailed) {
      _ = try await recorder.build(
        plan,
        authorization: .none,
        progress: { _ in }
      )
    }

    let failed = try #require(await history.capturedRecords().last)
    #expect(failed.status == .failed)
    #expect(failed.failureKind == .builder)
  }

  @Test
  func recorderClassifiesSecretFailureAndCancellation() async throws {
    let plan = makeHistoryBuildPlan()
    let secretHistory = CapturingImageBuildHistoryStore()
    let secretRecorder = RecordingImageBuildService(
      base: TestHistoryImageBuilder(plan: plan, behavior: .secretFailure),
      history: secretHistory,
      launchID: UUID()
    )

    await #expect(throws: ImageBuildSecretError.reviewMismatch) {
      _ = try await secretRecorder.build(
        plan,
        authorization: .none,
        progress: { _ in }
      )
    }
    let failed = try #require(await secretHistory.capturedRecords().last)
    #expect(failed.status == .failed)
    #expect(failed.failureKind == .secretReview)

    let cancellationHistory = CapturingImageBuildHistoryStore()
    let cancellationRecorder = RecordingImageBuildService(
      base: TestHistoryImageBuilder(plan: plan, behavior: .cancel),
      history: cancellationHistory,
      launchID: UUID()
    )
    await #expect(throws: CancellationError.self) {
      _ = try await cancellationRecorder.build(
        plan,
        authorization: .none,
        progress: { _ in }
      )
    }
    let cancelled = try #require(await cancellationHistory.capturedRecords().last)
    #expect(cancelled.status == .cancelled)
    #expect(cancelled.failureKind == nil)
  }

  @Test
  func historyWriteFailureNeverChangesBuildResult() async throws {
    let plan = makeHistoryBuildPlan()
    let recorder = RecordingImageBuildService(
      base: TestHistoryImageBuilder(plan: plan, behavior: .succeed),
      history: FailingImageBuildHistoryStore(),
      launchID: UUID()
    )

    let result = try await recorder.build(
      plan,
      authorization: .none,
      progress: { _ in }
    )

    #expect(result.imageDigest == "sha256:built")
  }

  @Test
  func terminalWriteFailureRemovesTheKnownStaleRunningRecord() async throws {
    let plan = makeHistoryBuildPlan()
    let attemptID = UUID()
    let history = TerminalRejectingImageBuildHistoryStore()
    let recorder = RecordingImageBuildService(
      base: TestHistoryImageBuilder(plan: plan, behavior: .succeed),
      history: history,
      launchID: UUID(),
      makeIdentifier: { attemptID }
    )

    let result = try await recorder.build(
      plan,
      authorization: .none,
      progress: { _ in }
    )

    #expect(result.imageDigest == "sha256:built")
    #expect(await history.load().records.isEmpty)
    #expect(await history.removedIDs() == [attemptID])
  }

  @Test
  func committedTerminalWriteIsNeverRemovedAfterMaintenanceFailure() async throws {
    let plan = makeHistoryBuildPlan()
    let attemptID = UUID()
    let history = CommittedTerminalImageBuildHistoryStore()
    let recorder = RecordingImageBuildService(
      base: TestHistoryImageBuilder(plan: plan, behavior: .succeed),
      history: history,
      launchID: UUID(),
      makeIdentifier: { attemptID }
    )

    let result = try await recorder.build(
      plan,
      authorization: .none,
      progress: { _ in }
    )

    #expect(result.imageDigest == "sha256:built")
    #expect(await history.load().records.first?.status == .succeeded)
    #expect(await history.removedIDs().isEmpty)
  }
}

private struct ImageBuildHistoryFixture {
  let rootURL: URL

  init() throws {
    let parent = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-ImageBuildHistoryTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    rootURL = parent.appending(path: "history", directoryHint: .isDirectory)
  }

  func recordURL(id: UUID) -> URL {
    rootURL
      .appending(path: id.uuidString.lowercased(), directoryHint: .notDirectory)
      .appendingPathExtension(ImageBuildHistoryStore.recordExtension)
  }

  func leaseURL(launchID: UUID) -> URL {
    rootURL.appending(
      path: ".launch-\(launchID.uuidString.lowercased()).lease",
      directoryHint: .notDirectory
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
  }
}

private enum TestHistoryBuildBehavior: Sendable {
  case succeed
  case succeedOutput(ImageBuildCompletion)
  case partial(ImageBuildPartialCompletionError)
  case partialImport(ImageBuildImportPartialCompletionError)
  case secretFailure
  case imageBuildFailure(ImageBuildError)
  case cancel
}

private actor TestHistoryImageBuilder: ImageBuilding {
  let plan: ImageBuildPlan
  let behavior: TestHistoryBuildBehavior

  init(plan: ImageBuildPlan, behavior: TestHistoryBuildBehavior) {
    self.plan = plan
    self.behavior = behavior
  }

  func prepareBuild(
    _ request: ImageBuildRequest,
    progress: @escaping ImageBuildProgressHandler
  ) -> ImageBuildPlan {
    plan
  }

  func build(
    _ plan: ImageBuildPlan,
    authorization: ImageBuildAuthorization,
    progress: @escaping ImageBuildProgressHandler
  ) throws -> ImageBuildResult {
    switch behavior {
    case .succeed:
      ImageBuildResult(
        buildID: plan.id,
        imageDigest: "sha256:built",
        tags: plan.tags.map(\.reference),
        platforms: plan.platforms,
        durationMilliseconds: 500,
        logTail: "BUILD-LOG-SENTINEL"
      )
    case .succeedOutput(let output):
      ImageBuildResult(
        buildID: plan.id,
        output: output,
        platforms: plan.platforms,
        durationMilliseconds: 500,
        logTail: "BUILD-LOG-SENTINEL"
      )
    case .partial(let error):
      throw error
    case .partialImport(let error):
      throw error
    case .secretFailure:
      throw ImageBuildSecretError.reviewMismatch
    case .imageBuildFailure(let error):
      throw error
    case .cancel:
      throw CancellationError()
    }
  }
}

private actor DelayedImageBuildHistoryStore: ImageBuildHistoryStoring {
  private var snapshot: ImageBuildHistorySnapshot
  private var shouldBlockNextLoad = false
  private var blockedLoadStarted = false
  private var blockedLoadContinuation: CheckedContinuation<Void, Never>?
  private var blockedLoadStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var loadCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var updateContinuation: AsyncStream<Void>.Continuation?
  private(set) var loadCount = 0

  init(initialSnapshot: ImageBuildHistorySnapshot) {
    snapshot = initialSnapshot
  }

  func load() async -> ImageBuildHistorySnapshot {
    loadCount += 1
    let countWaiters = loadCountWaiters
    loadCountWaiters.removeAll()
    for (minimumCount, waiter) in countWaiters {
      if loadCount >= minimumCount {
        waiter.resume()
      } else {
        loadCountWaiters.append((minimumCount, waiter))
      }
    }

    let result = snapshot
    if shouldBlockNextLoad {
      shouldBlockNextLoad = false
      blockedLoadStarted = true
      let startWaiters = blockedLoadStartWaiters
      blockedLoadStartWaiters.removeAll()
      for waiter in startWaiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        blockedLoadContinuation = continuation
      }
      blockedLoadStarted = false
    }
    return result
  }

  func record(_ record: ImageBuildHistoryRecord) {}
  func remove(id: UUID) {}
  func removeAll() {}

  func updates() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    updateContinuation = continuation
    return stream
  }

  func waitForLoadCount(_ minimumCount: Int) async {
    guard loadCount < minimumCount else { return }
    await withCheckedContinuation { continuation in
      loadCountWaiters.append((minimumCount, continuation))
    }
  }

  func blockNextLoad() {
    shouldBlockNextLoad = true
  }

  func waitUntilBlockedLoadStarts() async {
    guard !blockedLoadStarted else { return }
    await withCheckedContinuation { continuation in
      blockedLoadStartWaiters.append(continuation)
    }
  }

  func publish(_ snapshot: ImageBuildHistorySnapshot) {
    self.snapshot = snapshot
    updateContinuation?.yield()
  }

  func resumeBlockedLoad() {
    blockedLoadContinuation?.resume()
    blockedLoadContinuation = nil
  }
}

private actor CapturingImageBuildHistoryStore: ImageBuildHistoryStoring {
  private var records: [ImageBuildHistoryRecord] = []

  func load() -> ImageBuildHistorySnapshot {
    ImageBuildHistorySnapshot(
      records: records,
      rejectedRecordCount: 0
    )
  }

  func record(_ record: ImageBuildHistoryRecord) {
    records.append(record)
  }

  func remove(id: UUID) {
    records.removeAll { $0.id == id }
  }

  func removeAll() {
    records.removeAll()
  }

  func capturedRecords() -> [ImageBuildHistoryRecord] {
    records
  }

  func updates() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }
}

private actor TerminalRejectingImageBuildHistoryStore: ImageBuildHistoryStoring {
  private var records: [UUID: ImageBuildHistoryRecord] = [:]
  private var removals: [UUID] = []

  func load() -> ImageBuildHistorySnapshot {
    ImageBuildHistorySnapshot(
      records: Array(records.values),
      rejectedRecordCount: 0
    )
  }

  func record(_ record: ImageBuildHistoryRecord) throws {
    if record.status.isTerminal {
      throw TestImageBuildHistoryError.rejected
    }
    records[record.id] = record
  }

  func remove(id: UUID) {
    records.removeValue(forKey: id)
    removals.append(id)
  }

  func removeAll() {
    records.removeAll()
  }

  func updates() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }

  func removedIDs() -> [UUID] {
    removals
  }
}

private actor CommittedTerminalImageBuildHistoryStore: ImageBuildHistoryStoring {
  private var records: [UUID: ImageBuildHistoryRecord] = [:]
  private var removals: [UUID] = []

  func load() -> ImageBuildHistorySnapshot {
    ImageBuildHistorySnapshot(
      records: Array(records.values),
      rejectedRecordCount: 0
    )
  }

  func record(_ record: ImageBuildHistoryRecord) throws {
    records[record.id] = record
    if record.status.isTerminal {
      throw ImageBuildHistoryStoreError.maintenanceAfterCommit
    }
  }

  func remove(id: UUID) {
    records.removeValue(forKey: id)
    removals.append(id)
  }

  func removeAll() {
    records.removeAll()
  }

  func updates() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }

  func removedIDs() -> [UUID] {
    removals
  }
}

private struct FailingImageBuildHistoryStore: ImageBuildHistoryStoring {
  func load() async throws -> ImageBuildHistorySnapshot {
    throw TestImageBuildHistoryError.rejected
  }

  func record(_ record: ImageBuildHistoryRecord) async throws {
    throw TestImageBuildHistoryError.rejected
  }

  func remove(id: UUID) async throws {
    throw TestImageBuildHistoryError.rejected
  }

  func removeAll() async throws {
    throw TestImageBuildHistoryError.rejected
  }

  func updates() async -> AsyncStream<Void> {
    AsyncStream { _ in }
  }
}

private enum TestImageBuildHistoryError: Error {
  case rejected
}

private func makeHistoryRecord(
  id: UUID = UUID(),
  buildID: UUID = UUID(),
  launchID: UUID,
  status: ImageBuildHistoryStatus,
  startedAt: Date = Date(timeIntervalSince1970: 1_000)
) -> ImageBuildHistoryRecord {
  ImageBuildHistoryRecord(
    id: id,
    buildID: buildID,
    launchID: launchID,
    contextDisplayName: "sample-context",
    contextFingerprint: String(repeating: "c", count: 64),
    dockerfileSHA256: String(repeating: "d", count: 64),
    outputKind: .imageStore,
    requestedTags: ["sample:latest"],
    completedTags: status == .succeeded ? ["sample:latest"] : [],
    platforms: [.current],
    buildArgumentKeys: ["CONFIGURATION"],
    labelKeys: ["org.example.owner"],
    targetStage: "runtime",
    startedAt: startedAt,
    finishedAt: status.isTerminal ? startedAt.addingTimeInterval(1) : nil,
    durationMilliseconds: status.isTerminal ? 1_000 : nil,
    status: status,
    imageDigest: status == .succeeded ? "sha256:built" : nil,
    retainedImages: [],
    failureKind: status == .failed ? .unknown : nil,
    secretCount: 0,
    noCache: false,
    pullLatest: true
  )
}

private func makeHistoryBuildRequest() -> ImageBuildRequest {
  ImageBuildRequest(
    contextDirectory: URL(
      filePath: "/tmp/nativecontainers-source",
      directoryHint: .isDirectory
    ),
    dockerfile: nil,
    secrets: [],
    tags: ["registry.example/nativecontainers/app:latest"],
    platforms: [.current],
    buildArguments: [],
    labels: [],
    targetStage: "",
    noCache: false,
    pullLatest: true,
    builderCPUCount: nil,
    builderMemoryMiB: nil
  )
}

private func makeHistoryBuildPlan(
  sourceContextDirectory: URL = URL(
    filePath: "/tmp/nativecontainers-source",
    directoryHint: .isDirectory
  ),
  secrets: [ImageBuildSecretReview] = [],
  buildArguments: [String] = ["CONFIGURATION=release"],
  labels: [String] = ["org.example.owner=nativecontainers"],
  output: ImageBuildOutputPlan = .imageStore
) -> ImageBuildPlan {
  let id = UUID()
  let stagedRoot = URL(
    filePath: "/tmp/nativecontainers-history-tests/\(id.uuidString.lowercased())/context",
    directoryHint: .isDirectory
  )
  return ImageBuildPlan(
    id: id,
    sourceContextDirectory: sourceContextDirectory,
    stagedContextDirectory: stagedRoot,
    stagedDockerfile: stagedRoot.appending(path: "Dockerfile", directoryHint: .notDirectory),
    dockerfileSHA256: String(repeating: "a", count: 64),
    stagedDockerignore: nil,
    dockerignoreSHA256: nil,
    contextFingerprint: String(repeating: "b", count: 64),
    secretReviewID: secrets.isEmpty ? nil : id,
    secrets: secrets,
    tags: [
      ContainerBuildTagExpectation(
        reference: "registry.example/nativecontainers/app:latest",
        existingDigest: nil
      )
    ],
    platforms: [.current],
    buildArguments: buildArguments,
    labels: labels,
    targetStage: "runtime",
    noCache: false,
    pullLatest: true,
    builderCPUCount: nil,
    builderMemoryMiB: nil,
    output: output,
    generatedAt: Date(timeIntervalSince1970: 1_000)
  )
}

@MainActor
private func waitForHistory(
  _ condition: @MainActor () -> Bool
) async throws {
  for _ in 0..<200 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(condition())
}

private func addACL(_ rule: String, to url: URL) throws {
  let process = Process()
  process.executableURL = URL(filePath: "/bin/chmod")
  process.arguments = ["+a", rule, url.path(percentEncoded: false)]
  try process.run()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
}

private func extendedACLEntryCount(at url: URL) throws -> Int {
  errno = 0
  guard
    let acl = Darwin.acl_get_file(
      url.path(percentEncoded: false),
      ACL_TYPE_EXTENDED
    )
  else {
    if errno == ENOENT { return 0 }
    throw TestImageBuildHistoryError.rejected
  }
  defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }

  var count = 0
  var entry: acl_entry_t?
  var selector = Int32(ACL_FIRST_ENTRY.rawValue)
  while Darwin.acl_get_entry(acl, selector, &entry) == 0 {
    count += 1
    selector = Int32(ACL_NEXT_ENTRY.rawValue)
  }
  return count
}

private func permissions(at url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(
    atPath: url.path(percentEncoded: false)
  )
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
