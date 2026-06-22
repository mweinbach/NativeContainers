# Roadmap

The goal is broad workflow parity, not a pixel-for-pixel clone. Each milestone
must leave a usable, test-backed product slice.

## M0 — Verified native foundation

- [x] Native macOS app and unit-test targets build in Xcode.
- [x] Add and signing-verify the required Virtualization entitlement through Xcode.
- [x] Direct Apple client adapter reports container system health.
- [x] Live inventories for containers, images, volumes, and Linux machines.
- [x] Stable domain models and mockable service protocols.
- [x] Extract inventory, creation, lifecycle, inspection/tooling, terminal,
      attachment, image, volume/network/browser, machine, XPC, and
      owned-resource recovery logic into focused services behind an explicit
      composition root.
- [x] Persistent VM bundle library with schema versioning and atomic writes.
- [x] SwiftUI management shell with useful empty/error/loading states.
- [x] Diagnostics screen records runtime and package versions.

## M1 — Daily container management

- [x] Container start, stop, and delete from the native management UI.
- [x] Validated create-only/create-and-start flow with progress and rollback.
- [x] Five-second graceful stop, force stop, and restart controls.
- [x] Bounded stdout and boot-log inspection.
- [x] Bounded log follow, search, and native file export.
- [x] One-shot CPU, memory, disk, network, block-I/O, and process statistics.
- [x] Two-second live statistics sampling and bounded in-memory history.
- [x] Bounded non-interactive exec console and file copy in/out.
- [x] Interactive PTY terminal with resize, input, and signal forwarding.
- [x] Image pull with byte/item progress.
- [x] Reviewed platform/transport/concurrency selection for standalone pulls.
- [x] Lazy multi-platform image inspect and safe tag/delete flows.
- [x] Reviewed dangling/all-unused prune with mutation-time revalidation.
- [x] Reviewed native image push with digest/platform/transport revalidation.
- [x] Reviewed volume and network create/inspect/delete/prune flows.
- [x] TCP/UDP host-port publishing on Apple’s built-in network and DNS.
- [x] Explicit HTTP/HTTPS open-in-browser for revalidated TCP host publications.
- [x] Reviewed named-volume/network attachment selection and private
      operation-scoped Unix-socket publishing.
- [x] Read-only host-access discovery with an explicit privileged setup-command
      handoff.
- [ ] Signed and notarized privileged helper for optional host-access mutation.
- [x] Registry login/list/logout through Apple’s shared Keychain domain.
- [x] App-wide Command-K resource navigator with deterministic search and exact
      deep links for containers, images, volumes, networks, Linux machines,
      and macOS VMs.

## M2 — Developer workflow and Docker compatibility

- [x] Reviewed Dockerfile/Containerfile build workflow through Apple’s public
      builder API and an isolated signed worker.
- [x] Reviewed shared-builder status, whole-bundle allocation, Stop, explicit
      Force Stop (`KILL`), and stopped-only builder/cache reset.
- [x] Reviewed file-backed BuildKit secrets with one-shot descriptor leases,
      bounded private-pipe transport, and suppressed secret-build diagnostics.
- [x] Private persistent build history with typed outcomes, interrupted-build
      reconciliation guarded by live-launch leases, bounded retention, and no
      retained logs or secret values.
- [x] Stable Build workspace plus independently injectable planning, execution,
      and lifecycle services, with navigation guards, visible cancel,
      TERM-to-KILL, and immediate Force Stop kill points.
- [x] Typed image-store, OCI archive, root-filesystem tar, and root-filesystem
      folder outputs live-verified behind reviewed destination and publication
      services.
- [x] Typed fixed app-owned local cache profile with protocol-v5 isolation,
      cancellation-aware cross-process leases, full-tree-fingerprint-bound
      prepared handoff, bounded stale recovery, atomic promotion, namespace-only reset, and a
      successful two-build live export/import compatibility probe. Cross-builder hit attribution would
      require a destructive builder reset and remains intentionally unclaimed.
- [ ] SSH forwarding and reviewed remote cache profiles.
- [x] Version-pinned Socktainer service with SHA-256 and Developer ID validation,
      HTTP-level readiness, exact-PID TERM-to-KILL/Force Stop recovery, stale
      socket cleanup, and a product-specific Docker context that never becomes
      the active context implicitly.
- [x] Source-pinned Socktainer 1.0.0 Compose conformance manifest with explicit
      route requirements, semantic gaps, and a visible policy block.
- [x] Isolated live-wire Compose fixture with canonical Apple-inventory proof,
      bounded clients, noncancellable teardown, and Apple-native force cleanup.
- [x] Pin, provenance-verify, and privately install the official Docker Compose
      5.1.4 Darwin arm64 client without modifying Docker CLI plugin paths.
- [x] Implement a reviewed Compose desired-state parser and review coordinator
      with private source pinning, stable full/active canonical renders,
      redacted typed planning, and explicit lifecycle intent.
- [x] Implement an exact-ID Compose mutation coordinator, opaque prepared-plan
      store, private canonical execution workspace, crash-safe operation journal,
      explicit TERM-to-KILL policy, and manual-only recovery records for the
      reviewed executable subset.
- [x] Replace loose Compose resource-name arrays with ordered identity-bound
      container/network/volume/orphan actions; split execution into focused
      action, command, and postcondition services; enable exact-count native Up
      plus exact reviewed orphan/network/named-volume Down.
- [x] Add journal schema v3 opaque step membership/order checks, manual-only v2
      recovery compatibility, and a doubly gated real Up/Stop/Start/Down lifecycle
      probe with detached exact-identity cleanup.
- [x] Add a deterministic external-resource execution overlay, immutable stable
      metadata paths, supported-key allowlist, attachment proofs, and contiguous
      replica-prefix guard; enable create-missing Up while keeping recreation
      blocked on Socktainer 1.0.0.
- [x] Read-only automatic project detection and objective per-project status
      from canonical Compose labels in Apple inventory.
- [x] SSH agent forwarding and safe host-directory sharing.
- [x] Native menu-bar quick controls backed by the shared app inventory and
      exact container lifecycle services, including explicit Force Stop.
      Insertion is policy-disabled on macOS 27 and later until the verified
      SwiftUI app-graph invalidation regression is fixed and revalidated.
- [x] Native completion notifications for image builds, restore-image
      preparation, and macOS installation, with system-owned permission state
      and typed workspace routing from notification responses.
- [x] Typed container-shell discovery that prefers the container `SHELL` and
      shell init process, then probes bounded common-shell fallbacks before
      reporting that the image has no supported interactive shell.
- [x] Detachable terminal windows, tabs, saved shell presets, and session
      restoration.

## M3 — Linux machines

- [x] Create, first-boot provision, start, stop, force-stop, and perform
      revalidated stopped-only deletion of Apple container machines.
- [x] Create-time and persistent CPU, memory, and reviewed
      none/read-only/read-write home-mount configuration, with exact-identity
      revalidation, reply reconciliation, and next-start/restart guidance.
- [ ] Disk, kernel, Rosetta, and nested-virtualization configuration after a
      verified runtime upgrade; pinned Apple 1.0 machine config does not expose
      these controls.
- [x] Native login-shell terminal and bounded shell-command runner with
      stopped-machine auto-start, mapped-user execution, and explicit KILL.
- [ ] Persistent machine snapshots/backups where the Apple runtime supports it.
- [x] Transactional general-purpose GUI Linux VM bundle foundation through
      Virtualization.framework: durable EFI/NVRAM and machine identity, copied
      ISO media, stable MAC identity, secure artifact resolution, and a
      validated Virtio GUI/audio/input/NAT/SPICE configuration.
- [x] Generation-pinned GUI Linux runtime ownership, start/pause/resume,
      graceful stop with a 30-second automatic force-stop watchdog, explicit
      Force Stop, native console, installer-media ejection, and creation UI.
- [x] Persistent GUI Linux VirtioFS shared folders through security-scoped
      bookmarks, stopped-only lease-backed editing, one stable
      `nativecontainers` mount tag, and exact in-guest mount guidance.

## M4 — macOS VMs

- [x] Discover latest supported restore image and validate selected local IPSWs.
- [x] Download/import through one cache authority with resumable progress,
      immutable promotion, cross-process leases held through manifest commit,
      and launch recovery against a fresh VM-reference set.
- [x] Store new IPSWs in private, backup-excluded Application Support and
      journal exact legacy Caches-reference migration without deleting the old
      copy or exposing store mechanics to SwiftUI.
- [x] Create bundle, disk, auxiliary storage, hardware model, and identifier.
- [ ] Live-verify macOS installation against a local IPSW. The entitlement and
      service/UI path, progress, supported cancellation, operation leases,
      interruption recovery, and deterministic cleanup tests are implemented.
- [x] Automated macOS 27 first-boot account provisioning through a typed guest
      OS identity, fail-closed first-boot transaction, transient secret form,
      and focused Virtualization start-options adapter. Live guest verification
      remains gated by a newly restored macOS 27 VM.
- [x] Start, pause, resume, request stop, and explicit force stop through an
      app-scoped, generation-safe runtime service. Live guest verification still
      requires an installed macOS VM.
- [x] Transactional same-host save/restore with configuration fingerprints,
      single-use restore consumption, and queued Force Stop. Live verification
      remains gated by an installed guest.
- [x] Native console with automatic display reconfiguration and system-key
      capture controls.
- [x] Persistent, security-scoped VirtioFS shared directories with stopped-only
      editing, saved-state invalidation, read-only/read-write access, and a
      selected-VM configuration inspector. Live guest mount verification remains
      gated by an installed guest.
- [x] Host audio output through a focused Virtio sound-device factory and the
      Mac's current output device, with saved-state topology invalidation.
- [x] Explicit per-VM microphone input through the Mac's current input device,
      with user-initiated permission, stopped-only edits, and saved-state
      fingerprinting; clones and portable packages start disconnected.
- [x] Per-VM automatic NAT, app-shared, and host-only networking through a
      manifest-backed service, app-owned vmnet pool, and focused VZ device
      factory. Custom modes are stopped-only, saved-state-free, and reset to NAT
      in portable packages.
- [ ] Complete macOS host integration where public APIs and distributable
      entitlements support the guest.
  - [x] Physical USB discovery, exact-generation attach/detach orchestration,
        disconnect handling, suspend exclusion, and native controls using the
        macOS 27 AccessoryAccess and Virtualization APIs.
  - [ ] Enable and signing-verify
        `com.apple.developer.accessory-access.usb`, then live-verify capture
        against disposable physical hardware. The installed Xcode MCP
        capability action does not yet recognize this macOS 27 entitlement, so
        the live composition currently detects its absence and fails closed.
  - [ ] Add macOS guest clipboard integration only if Apple publishes a
        supported channel. The current SPICE clipboard API is Linux-specific.
  - [ ] Add physical bridging only if the restricted entitlement becomes
        distributable for this target.
- [x] Stopped-only same-host clone service with APFS copy-on-write when
      available, a fresh `VZMacMachineIdentifier`, runtime/library leases,
      sparse fallback, write-level cancellation, cold-boot saved-state
      scrubbing, atomic publication, cancellation cleanup, hard-exit recovery,
      and a native review sheet.
- [x] Portable `.nativevm` export/import with a shared bundle-preparation
      service, identity-preserving restore, explicit import-as-copy identity
      regeneration, stopped/runtime leases, host-state scrubbing, collision
      rejection, write-level cancellation, atomic publication, and partial
      recovery.
- [x] Safe disk-space reclamation.
  - [x] Reviewed Apple-runtime container, image, and volume reclamation with
        exact identities, bounded clients, non-force stopped-container delete,
        cancellation checkpoints, and partial-result reconciliation.
  - [x] Reviewed VM saved-state and exact allowlisted interrupted-residue
        reclamation with runtime/library locks, filesystem identity seals,
        atomic retirement, cancellation checkpoints, and partial results.
  - [x] Opt-in reviewed restore-image reclamation with shared cache leases,
        fresh manifest-reference checks, exact filesystem seals, aged-partial
        policy, atomic retirement, and crash-tombstone recovery.
  - [x] Stopped-only sparse compaction through an explicit RAW-to-ASIF
        migration; raw truncation remains prohibited.
  - [x] Stopped-only standalone ASIF rewrite through the shared journaled
        replacement coordinator, committing only a measured allocation reduction.

## M5 — Optimization and polish

- [x] Launch-on-login through `SMAppService.mainApp`, with approval and
      unavailable states surfaced rather than inferred.
- [x] Demand-started optional integrations: Docker compatibility and Compose
      share one thread-safe lazy module, while launch-critical inventory and VM
      recovery remain eager.
- [x] Low-Power-Mode and serious/critical-thermal-aware CPU defaults for newly
      opened container, persistent-machine, and GUI-VM creation flows, sampled
      through an injectable Foundation adapter without changing existing work.
- [ ] Idle suspension after an authoritative guest-activity signal is available;
      app, window, or console inactivity alone is not treated as guest idleness.
- [x] On-demand Apple runtime and macOS VM library storage accounting with
      category-level reclaimable estimates, sparse logical-versus-allocated
      bytes, hidden-partial attribution, and cancellable scans outside ordinary
      inventory refresh.
- [x] Measured standalone-ASIF rewrite reclamation without a compaction guarantee.
- [x] Bounded stopped-only macOS disk snapshots through bundle-local
      DiskImageKit overlay stacks, with transactional manifest commits,
      restore-to-prune semantics, saved-state invalidation, and native controls.
- [x] Native sidebar/toolbar command groups, Command-1 through Command-9
      plus Command-0 Kubernetes navigation, Voice Control input labels, and automatic
      source-language String Catalog extraction.
- [x] Single-node K3s control plane in a dedicated persistent Apple machine,
      with exact machine identity, pinned installer and release verification,
      secret encryption, crash-resumable setup, native lifecycle/status UI, and
      explicit ephemeral kubeconfig export.
  - [x] Bounded, read-only workloads/pods/services inventory with guest-side
        field projection, duplicate-safe stable identity, native search, and no
        kubeconfig export or Kubernetes secret material in the browser model.
  - [x] Explicit-container Pod log snapshots with API-UID revalidation,
        timestamped 2,000-line/512-KiB bounds, cached search, stale-response
        rejection, and user-initiated export.
  - [x] Explicit-container Pod terminals with exact cluster-machine and Pod API
        identity, allowlisted shell discovery, Apple process-XPC PTY transport,
        native terminal windows, and no arbitrary preset injection.
  - [x] Live-provision the gated Alpine machine, verify API reachability and a
        real Deployment, Service, and disposable pod, verify the app-owned
        inventory path, survive a stop/start, then delete the exact machine,
        namespace, and temporary credentials.
- [ ] Reviewed non-English translations and full VoiceOver/Full Keyboard
      Access QA across every management workflow.
- [ ] Distribution, updater, migration, and crash diagnostics.
  - [x] Arm64-only versioned archive with hardened runtime on the app and
        embedded build worker, constrained entitlements, exact layout checks,
        and a repeatable local validator.
  - [ ] Developer ID Application signing, notarization submission, accepted
        ticket stapling, and strict Gatekeeper validation.
  - [ ] Signed updater with rollback and version-policy tests.
  - [ ] User-data migration and rollback strategy.
  - [x] Privacy-reviewed local MetricKit capture for crash, hang, CPU,
        disk-write, and daily metric payloads, with bounded private retention,
        explicit JSON export/deletion, hosted-process suppression, and matching
        app/build-worker dSYM enforcement in the archive gate.
- [ ] Complete performance benchmark coverage.
  - [x] User-initiated local baselines for warm Apple inventory, private
        temporary-file write/read I/O, and Network.framework localhost TCP,
        with warmups, median/P95 reporting, bounded cancellation, and no
        container or VM mutation.
  - [ ] Cold container/VM startup, guest and bind-mount I/O, real image-build,
        external-network, and idle-resource lanes behind explicit live gates.

## Public-API constraint log

Potential parity gaps are tracked rather than hidden:

- Apple’s container stack is OCI/Docker-image and Dockerfile compatible but has
  no Docker Engine API. Docker CLI/Compose requires a separate bridge.
- Physical bridged networking and some low-level VM controls require restricted
  entitlements. NAT remains the portable default; public vmnet shared and
  host-only logical networks provide advanced same-process modes without
  claiming physical bridging.
- GPU acceleration, host integration, snapshots, and dynamic device changes
  differ between Linux and macOS guests and across host OS versions.
- Exact shared-loopback networking, arbitrary Linux GPU passthrough, portable
  macOS saved-state files, and complete guest-memory reclamation are not
  available through current public APIs.
