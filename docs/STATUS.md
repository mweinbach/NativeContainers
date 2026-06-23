# Current status

Updated: 2026-06-23.

## Verified

- Xcode project generated and open as scheme `NativeContainers` on `My Mac`.
- Exact `apple/container` 1.0.0 package resolves and compiles.
- Build-for-testing and the normal app build succeed; refreshed source
  diagnostics and the Issue Navigator report no warnings or errors.
- A clean Release archive for version 0.1.0 (1) succeeds through Xcode on
  `Any Mac (arm64)`. It contains one arm64 app and one arm64 embedded build
  worker, both strictly signed by team `6UHAW5UAT4` with hardened runtime. The
  archive validator confirms that the app carries only microphone input and
  virtualization while the worker carries no app capability.
- The current full app-hosted Xcode run contains 1,269 test results: all
  1,231 deterministic results passed, with 38 destructive or external-service
  integrations skipped behind explicit live gates and no failures or unrun
  tests. Existing opt-in tests cover Apple runtime
  provisioning, reviewed host-directory and SSH-agent attachments, interactive
  PTY, stopped-filesystem export, GUI Linux VZ boot/control, image behavior,
  Compose lifecycle, and disposable local-registry paths; none run against
  public services by default.
- The most recent isolated window-level app verification launched through Xcode as PID 48034.
  LLDB confirmed its visible main window was titled `Overview`, and Xcode
  stopped that exact process. No app or build-worker process remained.
- A native menu-bar control plane shares the app-scoped `AppModel`, inventory,
  lifecycle services, routing, and error state instead of introducing a second
  poller. It reports runtime and machine counts, exposes bounded container
  Start/Stop/Restart/Force Stop actions, and deep-links into the unique main
  window. An app-scoped AppKit `NSStatusItem` and `NSPopover` host the existing
  SwiftUI quick-controls view, avoiding the macOS 27 `MenuBarExtra` app-graph
  loop without disabling the feature. App Behavior settings persist menu-bar
  visibility across the deployment range and route launch at login through an
  injectable `SMAppService.mainApp` adapter with explicit approval, unavailable,
  and failure reconciliation states. Persistent system scenes are suppressed
  in hosted tests and Preview agents; constructing the app performs no AppKit
  status-bar work before the main scene exists.
- The app target is automatically Apple Development signed with
  `com.apple.security.virtualization` and the microphone-specific
  `com.apple.security.device.audio-input`; `ENABLE_APP_SANDBOX` remains `NO` as
  required by the checked-in project specification and the app's private
  `/private/tmp` socket workspace. Shared and host-only VM networking use public
  vmnet objects and add no entitlement; the restricted physical-bridge
  entitlement remains absent. The macOS 27 Accessory Access entitlement also
  remains absent because the current Xcode MCP capability action does not
  recognize it; physical USB composition detects that signed-build fact and
  fails closed. An app-hosted availability probe reports the Virtualization
  capability as available.
- The SwiftUI overview, split container inspector, Linux-machine list,
  Linux-machine creation and persistent-configuration forms, machine command
  runner, macOS VM list,
  restore-image preparation sheet, macOS installation sheet, VM clone sheet,
  portable VM export/import sheets, and generation-keyed macOS runtime console
  render successfully in Xcode Preview
  in light mode. The app-wide Quick Open sheet, actionable Overview, and
  initial-selection paths for Volumes and Networks also render successfully.
  Menu-bar quick controls and App Behavior settings render successfully in both
  light and dark appearance. The macOS VM network section renders automatic NAT
  in light appearance, shared vmnet in dark appearance, and the host-only
  saved-state lock/discard path without clipping its mode controls. The physical
  USB popover renders ready and entitlement-unavailable states without clipping.
  The Performance Baselines settings section also renders its measured and
  per-lane failure states without clipping.
- A typed workspace navigator now unifies sidebar state, exact resource
  selection, Overview links, and Command-K search. Its pure catalog derives
  stable entries from live inventory, ranks exact/prefix/word/substring matches,
  indexes localized kind names, and stores no secondary index. An authoritative
  refresh reconciles a removed resource back to its safe category, while a
  transient service failure preserves the pending exact route through recovery.
  Reviewed or active builds refuse every route away from Builds, including
  Quick Open. Navigation owns one unique main window rather than leaking app-wide
  route and sheet state across multiple scenes.
- A live Xcode snippet called `AppleContainerService.loadInventory()` against
  the installed XPC services and returned the 1.0.0 server plus live container,
  image, volume, network, and machine counts.
- A live app-hosted Xcode smoke created, inspected, inventoried, and deleted a
  unique 64 MiB sparse ext4 volume and host-only network through the reviewed
  adapter. Follow-up CLI inventory confirmed no probe resources remained.
- VM draft creation uses a staging directory, atomic manifest write, sparse disk
  allocation, and final rename; tests verify reload and cleanup.
- The macOS VM preparation sheet discovers Apple’s latest supported IPSW,
  accepts a local IPSW, reports compatibility requirements, and drives a
  resumable cache download with bounded progress. HTTP 206 ranges are validated,
  HTTP 200 responses safely restart stale partials, cancellation preserves the
  partial file, and completion atomically promotes it.
- Local restore-image validation now uses `VZMacOSRestoreImage.image(from:)`.
  Hardware model data, a fresh machine identifier, and matching auxiliary
  storage are created in a staging directory, validated as a set, atomically
  promoted into the VM bundle, and then committed to the manifest. Tests prove
  both successful reload and rollback on partial failure.
- Local IPSWs are now copied into the app-owned restore-image cache while their
  security scope is active. The import streams bounded chunks, reports progress,
  removes partial copies on cancellation, discards a promoted cache copy if
  platform preparation fails, and persists only the durable cache URL needed by
  a later installation. Pending markers and a private advisory lock make launch
  cleanup crash-durable without deleting an import still owned by this or
  another app process; referenced promoted images survive recovery.
- macOS installation is split into focused bundle-resolution, persistence,
  configuration, engine, orchestration, observable-model, and SwiftUI view
  services. Bundle resolution rejects absolute, escaping, symbolic, missing,
  or special artifacts before Virtualization.framework sees them. Each install
  owns an operation-ID lease; stale completion cannot commit, app relaunch marks
  an orphaned lease interrupted, and only a successful matching operation moves
  the manifest to `stopped`. A cross-process advisory lock prevents competing
  recovery from removing a live installation workspace. Discard atomically
  renames the bundle to a hidden tombstone before recursive cleanup, and launch
  recovery retries a leftover tombstone without exposing a half-deleted VM.
- The Apple installation adapter rebuilds and validates the persisted Mac
  platform, RAW disk, display, input, entropy, memory-balloon, and NAT devices on
  the main VM queue. Installation mutates an operation-scoped sparse disk and
  auxiliary-storage copy, atomically adopts that directory only after success,
  and discards it on cancellation, failure, or relaunch recovery so the prepared
  media remains retryable. Cancellation uses only
  `VZMacOSInstaller.progress.cancel()` after installation has started and then
  awaits the installer result; the app never pauses or force-stops an installing
  VM. Deterministic tests cover preflight failure, monotonic progress,
  cancellation, failure, durable-state errors, stale leases, interruption
  recovery, cross-process ownership, path traversal, symlinks, transactional
  discard, and cache cleanup. A failed startup recovery is retried by Refresh
  instead of remaining latched until restart.
- Installed macOS VM runtime is split into reusable resolution/configuration,
  per-bundle ownership, Apple engine, lifecycle coordinator, observable model,
  and SwiftUI console services. The durable manifest remains provisioning truth;
  running and paused states are ephemeral. A short global mutation lock acquires
  a generation-tagged per-VM advisory lease and informational owner sidecar, so
  another process cannot start or discard the same writable disk while unrelated
  VM work remains available. Runtime startup does not require the cached IPSW.
- Start, pause, resume, graceful shutdown, and explicitly confirmed destructive
  stop are wired through `VZVirtualMachine`. Graceful shutdown remains stopping
  until the delegate confirms exit, keeps Force Stop visible, and arms a
  generation-pinned 30-second service watchdog that reuses the same destructive
  stop path if the guest hangs. Failed force stop retains the session and lease;
  stale generations cannot stop replacement sessions; duplicate terminal
  callbacks finalize once; and caller cancellation cannot release an accepted
  start. The native console uses automatic display reconfiguration, opt-in
  Mac-shortcut capture, SDK 27's adaptor, and detaches stale views. Deterministic
  ownership/service/model tests pass, while real VM launch still requires an
  installed local macOS guest.
- Newly restored macOS 27 guests now expose an optional native first-boot setup
  sheet. Restore preparation persists the exact guest version/build, while a
  focused policy, transaction service, and Virtualization adapter validate and
  submit VZMacGuestProvisioningOptions only on an unclaimed cold boot. Passwords
  remain transient UI/runtime values and are never written to the VM manifest.
  Failed starts restore eligibility; ambiguous crash state fails closed. The
  service, policy, rollback, model, and light/dark preview paths are verified;
  successful in-guest account creation still requires a disposable macOS 27 VM.
- Same-host suspend/resume is implemented behind focused runtime, saved-state
  callback, and transactional filesystem services. The live configuration uses
  a deterministic per-VM MAC and records save/restore capability independently
  from cold-boot support. Checkpoints are configuration-fingerprinted,
  lease-borrowed, crash-recovered, and single-use on restore; Start Fresh and
  live Resume atomically invalidate them before storage advances. The UI exposes
  Suspend, Resume, confirmed Start Fresh/Discard Saved State, incompatible-state
  diagnostics, and a generation-pinned Force Stop that queues while save/restore
  callbacks are outstanding. Deterministic store/service/runtime/model tests are
  implemented; a real save/restore still requires an installed macOS guest.
- macOS VM configuration now includes a focused Virtio audio factory with host
  output through `VZHostAudioOutputStreamSink` and explicit per-VM microphone
  input through `VZHostAudioInputStreamSource`. Microphone input is disconnected
  by default. Connect is a user action that checks AVFoundation authorization
  before persistence; denial never acquires VM ownership or changes hardware.
  The audio service reuses the stopped-only runtime lease and rejects saved-state
  conflicts. Topology version 3 still distinguishes the earlier no-audio layout,
  while post-default audio revisions remain fingerprinted so toggling input off
  cannot make an older checkpoint valid again. Clones and portable packages
  deliberately clear this host-local opt-in, so every copied or imported VM
  requires a fresh Connect action.
- macOS VM networking is split into a revisioned manifest value, a lease-aware
  persistence service, one app-owned vmnet pool, a focused Virtualization device
  factory, a stable observable model, and a snapshot/action-only SwiftUI section.
  Automatic NAT remains the portable and suspend-capable default. Shared mode
  joins participating VMs with the host and external networks; host-only joins
  participating VMs with the host without external access. Both custom modes
  use public same-process vmnet objects, are recreated after app relaunch, and
  deliberately disable suspend. Edits require a stopped VM with no checkpoint,
  advance the saved-state fingerprint revision, persist across same-host clones,
  and reset to NAT during portable export/import preparation. Focused tests also
  create real shared and host-only vmnet attachments without adding a target
  entitlement. Physical bridging remains unavailable because Xcode rejects its
  restricted entitlement for this target.
- Physical USB passthrough now has a complete macOS 27 service lane:
  AccessoryAccess discovery, immutable descriptor mapping, one XHCI controller
  per VM, exact-generation attach/detach orchestration, physical-disconnect
  reconciliation, a stable observable model, and a native runtime popover.
  Discovery is explicit and host authorization is never persisted. Attachment
  ownership is projected across VMs, a late attach is unwound after generation
  replacement, stopping releases controller state, and suspend fails before
  pausing while a device remains attached. The new controller topology advances
  the saved-state configuration version. Deterministic descriptor, service,
  runtime, model, and app-composition tests pass, and ready/unavailable previews
  render without clipping. This is implementation evidence, not product
  availability.
- Product USB activation remains blocked and fail-closed. Apple's documented
  `com.apple.developer.accessory-access.usb` capability is distinct from the
  existing sandbox USB-device entitlement. Xcode MCP's capability action does
  not yet recognize the macOS 27 key, and the freshly signed product does not
  contain it. The composition root checks the signed process, publishes that
  exact code-signature blocker in the USB panel, and injects an unavailable
  service rather than attempting an unauthorized AccessoryAccess connection or
  editing the entitlement file outside Xcode.
- Installed macOS VM bundles can persist shared host directories in a private,
  bounded `SharedDirectories.json` capability sidecar. A focused orchestration
  service acquires the runtime lease, rejects running or checkpointed VMs, and
  commits monotonic revisions. Bookmark resolution retains security scope for
  the full engine session; one macOS automount VirtioFS device exposes all
  validated read-only/read-write shares. The selected-VM inspector owns no
  persistence logic and edits only through the service. Existing no-share saved
  states retain the legacy fingerprint, while any sharing history prevents an
  older checkpoint from becoming valid again.
- Stopped macOS VMs now clone through a focused orchestration service and a
  library-owned begin/commit/abort transaction. The source runtime lease remains
  held while Darwin `copyfile` attempts recursive APFS clone-on-write and falls
  back to sparse copying. Fallback writes expose an immediate cancellation
  callback; the sheet stays visibly cancelling until the partial is removed and
  both leases release. The copier rejects links, strips saved/runtime/operation
  state, and writes a fresh `VZMacMachineIdentifier`; commit independently
  validates that identity is well formed and distinct before atomically
  publishing. Deterministic transfer/store/service/app-boundary tests cover
  successful cloning, cancellation, copy failure, ownership contention,
  malicious links, duplicate platform identity, and hard-exit recovery. Live
  guest boot still requires an installed macOS guest.
- Stopped macOS VMs now export to a portable `.nativevm` package through a
  source/runtime lease, balanced destination security scope, shared
  policy-driven bundle preparer, hidden sibling staging directory, and
  cancellable copyfile transfer. Export preserves the manifest and Apple
  platform identities, removes saved/runtime/install/cache/shared-folder
  capability state, refuses replacement, and leaves the source unchanged.
  Import offers explicit identity-preserving restore or import-as-copy; the
  latter creates fresh manifest and `VZMacMachineIdentifier` values. A
  library-owned transaction rechecks UUID/platform collisions and artifacts
  before atomic publication, aborts partials on failure/cancellation, and
  recovers `.Import-*.partial` packages after a hard exit. Deterministic tests
  cover round trips, both identity modes, collisions, runtime ownership,
  cancellation cleanup/retry, and symbolic/hard/special-file rejection.
- Container detail inspection uses Apple’s direct API client for configuration,
  disk usage, one-shot CPU/memory/network/block/process statistics, stdout, and
  boot logs. Log reads are bounded to the newest 512 KiB per stream.
- Container start, stop, delete, selection, and refresh actions are wired into
  the native management UI.
- Volume inventory distinguishes sparse ext4 capacity from allocated host
  storage and derives every referring container configuration. Reviewed
  create/delete/prune revalidates complete configuration identity, blocks use
  by stopped or running containers, reconciles ambiguous replies by operation
  UUID, and exposes cancellable work in the SwiftUI UI.
- Named-network inventory and management show NAT/host-only mode, requested and
  assigned subnets, gateway, plugin metadata, built-in state, and configured
  consumers. Built-in or newly used networks fail closed at execution.
- Container creation is now composed from focused identity, resource, process,
  port, storage, network, Unix-socket, host-access, and lifecycle sections. The
  draft freezes exact reviewed volume/network identities and ordered network
  attachment state before it reaches the creation service.
- `AppleContainerAttachmentService` re-fetches reviewed volumes, networks, and
  container consumers under creation's runtime mutation lease. It rejects
  replacement or newly used volumes, preserves primary-network ordering, and
  constructs mounts, attachments, and socket publications directly without
  invoking Apple's CLI-oriented auto-create parser paths.
- Host-directory sharing is split into focused domain, bookmark, manifest, and
  attachment services. Folder selection creates a security-scoped bookmark,
  rejects symbolic-link leaves, pins the device/inode across canonical path
  resolution, and defaults to read-only until write access is explicitly
  selected. Resolution keeps security scope alive through create/start and
  emits Apple's native VirtioFS configuration. Mode-0600 atomic manifests under
  a mode-0700 private root preserve the reviewed selection; every restart
  revalidates both source identity and the container's exact mount
  configuration before access is granted.
- SSH-agent forwarding is a separate injectable service. It reviews only the
  current absolute `SSH_AUTH_SOCK`, requires a Unix-domain socket, pins its
  device/inode, and rechecks the same dynamic environment before creation and
  every start. Creation uses Apple's native `configuration.ssh` path rather
  than constructing a guest mount, and a missing or replaced socket fails
  closed instead of silently dropping forwarding.
- Published Unix sockets are confined to a mode-0700, current-user operation
  workspace under `/private/tmp/nativecontainers-<uid>`. Directory creation is
  `mkdir`/`lstat` based, arbitrary or occupied leaves fail closed, the portable
  host socket path limit is enforced, every start revalidates the exact path,
  and failed creation or deletion removes only the operation-owned directory.
- Host access is an explicit global prerequisite rather than fake per-container
  configuration. The app only discovers exact, safe resolver/PF pairs and
  presents Apple's fixed `sudo container system dns create` handoff; it never
  mutates privileged state or claims that configured-on-disk PF state is active.
- Infrastructure XPC waits own cancellable connections with a 60-second close
  watchdog. Reconciliation and inventory refresh continue in fresh,
  cancellation-independent tasks. Container creation cancellation sends
  `KILL`, force-deletes only the exact operation-labeled partial container,
  retries with bounded backoff, and verifies that it is absent; an unverifiable
  cleanup is surfaced instead of being silently ignored.
- Persistent Linux machines now use separate inventory, workflow, machine-XPC,
  process-target, command, terminal, and process-XPC services. Machine requests
  use fresh watchdog-closed connections. Process create/start calls have
  ten-second bounds, signal/resize calls have two-second bounds, and long-lived
  wait calls have no false shell-lifetime deadline but remain cancellation-
  closeable. Caller-level setup and command waiters own their own deadlines and
  confirmed KILL escalation. Cancellation after durable creation automatically
  attempts graceful stop then verified backing-container KILL, and explicit
  Force Stop remains available for running or stuck-stopping machines. Every
  terminal mutation is reconciled before success is reported.
- A live app-hosted Xcode smoke fetched Alpine through the focused preparation
  service, created a stopped persistent machine, auto-started and first-boot
  provisioned it through the command service, verified mapped UID/home/Linux
  output, exercised the native PTY, timed out and KILLed a hung command, proved
  the machine remained usable, stopped it, deleted it, and confirmed no machine
  remained.
- Linux-machine tools require a stable creation identity, invoke lifecycle
  readiness, then re-inspect and pin the fresh per-boot backing-container ID.
  Commands and terminals execute `/sbin.machine/init -s` as the persisted
  host-mapped user, default to the machine home, and inherit only the pinned
  PATH plus explicit UI environment entries. Stopped machines expose clear
  Start & Run / Start & Open actions and remain running after successful use.
  Apple 1.0 boot still forwards a present host `SSH_AUTH_SOCK` independently
  of the selected home mount, so “None” is not documented as full isolation.
- Linux-machine inventory re-inspects stale uninitialized list snapshots, and
  destructive actions pin the creation identity. Apple 1.0 still exposes an
  ID-only delete route, so the narrow external same-name replacement race is
  documented rather than presented as atomic safety.
- The runtime integration now has an explicit composition root and narrow
  inventory, creation, attachment, lifecycle, inspection, tooling, terminal,
  image, volume, network, browser, and machine facets. Every runtime capability
  has a focused service; the legacy `AppleContainerService` contains forwarding
  only for callers that still need the complete API.
- Command timeout arbitration publishes a timeout outcome before issuing
  `KILL`, so a signal-induced process exit cannot race the timeout into a false
  success. Caller cancellation also triggers cancellation-independent `KILL`
  and is rechecked after process wait and output drain, so exit 137 cannot race
  cancellation into a normal result.
- Published TCP port ranges are expanded into exact endpoints. Creation
  validates literal IPv4/IPv6 hosts, brackets IPv6 for Apple's parser, and
  rejects host-port/protocol overlap before image work begins. The inspector
  offers explicit HTTP and HTTPS actions after re-fetching the same container
  creation identity and exact mapping; UDP never receives a browser action.
- Native sheets now pull OCI images for the current platform and create
  containers with validated names, native/Intel platform selection, CPU/memory,
  OCI arguments and environment,
  working directory, TCP/UDP port publishing, SSH-agent forwarding, init,
  read-only root, persistence, and create-only/create-and-start behavior.
- Provisioning reports image, unpack, kernel, runtime-image, create, and start
  progress. It tags each operation for ambiguous-XPC reconciliation and removes
  an operation-owned container if startup fails.
- A live Xcode test-host smoke created a stopped Alpine container through the
  app’s direct Swift service, verified its state/resources, deleted it, and
  verified cleanup.
- A live Xcode runtime pass created a named volume and custom NAT network,
  attached both to a stopped Alpine container with a published Unix socket,
  started it, observed the host socket in the private workspace, force-stopped
  it through `KILL`, verified socket removal, and deleted the container,
  operation directory, network, and volume with no probe resources remaining.
- A disposable live Xcode runtime pass mounted a reviewed host folder into
  Alpine through VirtioFS, read its marker, proved the default read-only policy
  rejected a container write, force-stopped and restarted the container, read
  the marker again through the persisted identity-bound manifest, then deleted
  the container and host fixture.
- A second disposable live pass created a real local Unix listener, reviewed
  it as `SSH_AUTH_SOCK`, and verified Apple's native forwarding exposed
  `/var/host-services/ssh-auth.sock` as a socket inside Alpine before and after
  force-stop/restart. The container and socket were removed afterward.
- Running-container inspectors now sample statistics every two seconds, retain
  a bounded 60-sample in-memory history, calculate allocation-normalized CPU
  usage, and can pause live work immediately through structured task
  cancellation.
- Log following reuses bounded tails rather than unbounded memory, with source
  selection, case-insensitive line filtering, match counts, and native text-file
  export. Lifecycle controls include five-second graceful stop, restart, and
  explicit force stop.
- The native exec sheet runs non-interactive commands through the focused,
  bounded process-XPC transport, concurrently drains stdout/stderr into
  independently bounded 1 MiB tails, enforces cancellation and timeouts by
  killing the child process, and reports exit status and duration.
- Bidirectional file transfer uses Apple’s `copyIn`/`copyOut` clients with native
  file/folder pickers, absolute guest-path validation, parent creation, and
  security-scoped URL handling.
- A live Xcode snippet started a disposable Alpine container, captured exec
  output, copied a file in, read it inside, copied it back out, verified the
  round trip, and cleaned all container and host artifacts.
- Running containers and persistent Linux machines now expose interactive
  terminals backed by the focused process-XPC transport with terminal mode
  enabled. Raw bytes flow
  through bounded, lossless backpressure into a pinned SwiftTerm 1.13.0 AppKit
  surface; input, resize, Control-C/Control-D, explicit signals, title, working
  directory, scrollback, copy, and paste are wired without a CLI subprocess.
- Ordinary container terminals no longer assume `/bin/sh`. A shared typed shell
  service prefers the final `SHELL` environment value, recognizes a shell used
  by the container init process, and then probes bounded common-shell candidates.
  The terminal resolves automatic requests through that service, while the exec
  sheet pre-fills the same detected executable and still permits an explicit
  override. Linux machines continue to delegate login-shell selection to
  Apple’s machine init helper.
- Container and Linux-machine terminals now leave the main management window in
  a data-driven SwiftUI `WindowGroup`. Every window has up to 12 identity-stable
  tabs, Command-T creation, explicit close/interrupt/HUP/TERM/KILL controls, and
  per-scene tab/selection restoration. SwiftUI restores the lightweight window
  target and `SceneStorage` restores only tab and preset identifiers; restored
  tabs remain closed until selected so relaunch never silently boots a stopped
  Linux machine. A focused terminal-target service reloads Apple inventory and
  rejects missing or same-name replacement resources before opening any process.
- Container shell presets are a separate injected service. The bounded schema-1
  preferences payload accepts at most 64 validated entries. A preset contains
  only a preferred or explicit shell, login-shell choice, and absolute container
  working directory. Environment variables, terminal output, command history,
  and arbitrary startup commands are not persisted.
- Terminal shutdown closes stdin, sends hangup, allows a short graceful exit,
  and escalates to kill. Output recovery retains only the newest configured
  bytes, while the live stream preserves every byte. The pipe reader uses
  `poll` plus one POSIX `read` so short interactive bursts are delivered before
  EOF rather than waiting to fill a large Foundation read request.
- Input writes are ordered on a dedicated queue, nonblocking, cancellation-aware,
  and protected from `SIGPIPE` without changing process-wide signal handling.
  Descriptor reads and closure share one lifetime lock, resize bursts are
  coalesced, a replacement shell performs a full emulator reset, and an
  unconfirmed kill remains visible and retryable instead of dismissing the
  terminal as though shutdown succeeded.
- A live Xcode test-host smoke created and started a disposable Alpine
  container, opened a native PTY, verified the requested `33×91` geometry,
  round-tripped canonical stdin, delivered Control-C, observed a clean child
  exit, and removed the container.
- The image screen now uses a stable-reference split inspector. OCI indexes are
  resolved lazily into platform variants with real manifest/layer sizes,
  execution configuration, environment, labels, aliases, usage, and partial
  inspection warnings; the former descriptor-size label is no longer presented
  as total compressed image size.
- Tagging normalizes through Apple’s configured registry and requires explicit
  confirmation before moving an existing tag to another digest. Deletion plans
  show aliases and consuming containers, block in-use or Apple infrastructure
  images, and revalidate the exact digest immediately before mutation.
- Dangling and all-unused prune modes show the exact reviewed candidate set,
  exclude active and Apple-managed images, revalidate every reference/digest,
  perform one store-wide orphan cleanup, and report actual reclaimed bytes plus
  partial failures. Cancellation refreshes inventory and triggers best-effort
  cleanup after any partial batch.
- A live Apple-service smoke pulled Alpine, created a unique local tag, resolved
  its real OCI variant/configuration, deleted only that alias, verified removal,
  and left no containers or temporary image references behind.
- Settings now lists Apple container registry logins and supports validated
  login/logout through the runtime’s shared Keychain domain. Docker Hub aliases
  are canonicalized, automatic transport is resolved against the portless host,
  HTTP and different-user replacement require confirmation, and stored secrets
  are never loaded back into the settings model. Full reviewed metadata is
  revalidated after ping and immediately before save/delete; cancellation and
  post-mutation refresh failures have explicit semantics.
- Standalone pulls now review the normalized reference, exact current/arm64/
  amd64/all-platform scope, resolved HTTPS/HTTP transport, replacement of an
  existing local tag, unpack choice, and download concurrency. All-platform and
  HTTP transfers require explicit confirmation, and Apple-managed builder/
  vminit references are blocked before review and again under the mutation lock.
- Pull execution uses Apple’s direct `ClientImage.pull`, validates exact
  platform equality, and materializes each requested snapshot through
  `getCreateSnapshot`. Per-platform results distinguish an existing snapshot, a
  newly created snapshot, and failure; the app never treats Apple’s silently
  skipped all-platform unpack as success. If download commits a new local digest
  before validation, unpack, or cancellation fails, the UI reports the durable
  partial result and refreshes inventory instead of claiming the pull failed
  atomically.
- Image push uses the selected canonical local alias exactly, revalidates its
  digest, platform, infrastructure status, and resolved transport under the
  shared runtime mutation lock, and always confirms that the remote mutable tag
  may be replaced. Transfer tasks are retained by their sheets, cancellable,
  and cancelled on disappearance so they cannot become invisible mutations.
- Direct safety tests cover authorization refusal, automatic transport drift,
  stale digests, exact platform absence, infrastructure references, partial
  pull publication, verified unpack outcomes, and serialization across actor
  suspension points.
- The Builds destination reviews a private local context, typed output,
  destination (when applicable), canonical image reference, exact target
  platforms, builder resources, build arguments, labels, target stage, cache
  policy, optional canonical registry-cache profile, and pull policy before
  execution.
- The native build entry point is now a small facade over independently
  injectable planning, execution, and lifecycle services. Request validation
  can run without runtime collaborators; execution retains the single-flight
  boundary; discard and terminal cleanup have one shared owner.
- A signed embedded one-shot worker owns Apple’s public
  `ContainerBuild.Builder` lifetime. Exact builder descriptor, digest, DNS,
  creation identity, and dial state are revalidated; running or uncertain
  builders are never stopped as failed-create cleanup.
- Build contexts reject links and special files, preserve Docker-visible POSIX
  modes, and bind metadata plus content in a SHA-256 fingerprint checked before
  and after solve. Canceled staging and queued builds remove partial private
  contexts promptly.
- Worker protocol v6 carries typed output/cache kinds, an optional typed remote
  registry-cache profile, and typed artifact metadata,
  but never a user destination. Image-store and OCI-archive builds use Apple's
  OCI exporter, root-filesystem archives use `tar`, and root-filesystem folders
  use `local` with `platform-split=false`; root-filesystem outputs are
  deliberately single-platform. The pinned tar exporter retains its
  `linux_arm64` platform directory, while the local exporter publishes the
  selected platform directly at the destination root.
- Registry cache review requires a lowercase explicit registry plus repository,
  canonicalizes the tag, rejects digests and output/cache collisions, and
  exposes only import-only or import-and-export with min/max export scope. The
  confirmation calls out remote publication and intermediate-layer exposure.
  Protocol and history retain no raw cache options or credentials, and history
  also omits the privacy-sensitive cache reference. Apple 1.0's public builder
  has no cache-auth or SSH-session provider, so remote execution remains limited
  to endpoints the builder can already access and build-time SSH forwarding
  remains gated. Deterministic review, rejection, protocol round-trip, and
  execution-forwarding tests are implemented; live registry execution awaits an
  operator-owned disposable endpoint.
- File exports are copied out of the guest-visible builder directory into a
  descriptor-validated mode-0400 host artifact with a bound byte count and
  SHA-256. Local-directory exports are independently copied into an app-private
  tree that rejects special files, preserves regular-file modes and relative
  symlinks, and binds paths, types, modes, link targets, and contents into a
  SHA-256 tree fingerprint.
- A focused `ImageBuildOutputManaging` service owns destination review and
  publication. It pins an owner-controlled parent directory by descriptor,
  requires explicit authorization to replace the exact reviewed regular file,
  requires folder outputs to be new, revalidates the private artifact, copies
  into a hidden sibling with cancellation checks, and commits with an atomic
  rename. A failure after the rename is reported as retained partial completion
  instead of deleting a possibly durable output.
- Image-store import still revalidates artifact identity, reconciles ambiguous
  XPC import/tag replies, reports durable partial completion, and removes both
  artifact locations independently of task cancellation. Alternate outputs do
  not mutate or refresh Apple's image store.
- Gated live probes now cover every alternate exporter against Apple 1.0.0. The
  OCI archive contained `oci-layout`, `index.json`, and content-addressed blobs
  without image-store mutation; the root-filesystem tar exposed its marker
  under `linux_arm64`; and the local folder exposed the marker directly at its
  root. Every probe removed its private and shared export residue.
- A live Xcode probe exercised the app’s embedded signed worker against Apple’s
  1.0.0 services: it staged a Dockerfile context, reused the shared BuildKit
  container, exported and imported OCI, verified the arm64 snapshot, applied a
  unique reviewed tag, started a container, read the built marker through native
  exec, and removed the container, tag, private artifact, and shared export.
- A separate live cancellation probe observed the real `.building` frame after
  about 104 ms, canceled a 60-second BuildKit step, and returned
  `CancellationError` about 3 ms later. No destination, private artifact, or
  shared export remained. A timing regression proves short progress frames are
  visible before worker exit, so the cancel control is a real in-flight kill
  point rather than a post-build cleanup request.
- The Builds destination is now a modular workspace with separate New Build,
  History, and Builder & Cache views. A focused `ContainerBuilderManaging`
  service reports stable runtime state and whole-bundle allocated storage, and
  prepares reviewed Stop, explicit `KILL`, and stopped-only Delete Builder &
  Cache operations.
- Builder maintenance takes the image-build single-flight lock before the global
  runtime mutation lock, then revalidates the exact creation date, full pinned
  identity, configuration, and runtime root before XPC mutation. Ambiguous XPC
  replies are reconciled in an uncancelled bounded read loop.
- A builder delete is successful only when Apple’s inventory no longer contains
  `buildkit` and `lstat(<appRoot>/containers/buildkit)` reports absence. An
  orphaned bundle is surfaced as incomplete cleanup; the app never removes it
  directly and never treats `<appRoot>/builder` exports as cache.
- A live read-only Xcode probe exercised the new service against Apple’s 1.0.0
  runtime and observed the running builder as exact/trusted with its bundle
  present and 530,751,488 allocated bytes. Stop, `KILL`, and deletion were not
  invoked because external CLI build activity cannot be observed safely.
- Protocol v5 now carries one typed cache mode instead of independent
  `noCache` and raw-string configuration. A worker-private adapter maps the
  versioned NativeContainers local profile into Apple's existing builder export
  mount. The app-owned cache service holds a cancellation-aware cross-process
  lease while the worker produces and validates fresh OCI-layout staging. Before
  unlocking, the worker atomically moves it into a tokenized prepared handoff and
  returns a receipt bound to that token, directory identity, OCI metadata hashes,
  and a deterministic metadata tree covering every cache entry. After the app validates the private
  artifact, a host-side service reacquires the lease, reopens that exact token,
  recomputes the fingerprint, and commits with an atomic swap. Inspection and new
  leases recover staging without deleting a live handoff and reclaim prepared
  residue after 24 hours; broken pipes, hard exits, and same-sized payload
  substitutions cannot publish it. Reset touches only the
  app namespace and remains available for malformed caches. Builder & Cache
  exposes size/status and a separate reset control. Deterministic promotion,
  same-sized mutation, intervening-inspection, explicit-reset invalidation,
  rollback, cancellation, lock-wait, staging/prepared hard-exit recovery, and
  namespace-isolation tests are live. A live
  Xcode probe against Apple 1.0.0 produced two 4,004,864-byte OCI outputs and
  observed distinct worker-staged and app-committed events for both
  9-entry/4,018,176-byte cache generations, and reduced the unique four-second
  final four-second probe from about 5.20 seconds to 0.20 seconds before
  resetting the app cache and removing its outputs. Repeated probes did not
  produce stable archive byte equality, so no archive-determinism claim is made.
  Apple's surviving internal cache means the
  timing is not independent proof of local-cache hits; destructive builder-reset
  attribution remains intentionally unclaimed.
- Reviewed file-backed BuildKit secrets are live behind a focused
  `ImageBuildSecretManaging` service. Review pins private, owner-only regular
  files outside the build context by open descriptor and full identity; plans
  retain only ID, privacy-sensitive path, and byte count. Context staging rejects
  every pinned device/inode, closing hard-link races. After the builder is ready,
  the vault revalidates and consumes each descriptor once, then protocol v6
  streams bounded binary and empty values beside—never inside—the Codable control
  request. App-side leases are released when that pipe write commits. Secret
  builds force Apple’s quiet mode, drain and discard worker stderr, sanitize
  failure events, and retain only a fixed suppression notice.
- Private persistent build history is live behind separate recording, storage,
  observable-model, and view boundaries. The recording decorator publishes
  running and typed terminal outcomes without changing build results; a failed
  terminal write removes its known-stale running record, while a post-commit
  maintenance failure preserves the committed terminal outcome. The store
  retains at most 200 terminal attempts, uses per-launch process leases before
  reconciling abandoned running work as interrupted, removes leases on graceful
  release, isolates corrupt/special records, retains newer-schema records,
  defaults newly added schema-1 fields for existing records, scavenges partial
  writes, and streams local plus cross-process updates to every visible History
  model. Cross-process observation polls only a cheap directory change token and
  known foreign-running lease locks; unchanged history performs no record scan.
  Models coalesce updates that arrive during I/O, and unreadable-record warnings
  remain latched across windows until Clear History. Partial-import history
  preserves every retained reference/digest pair.
- History I/O is confined to a verified directory descriptor. Canonical
  record names use `openat`/`renameat`/`unlinkat`, reads use `O_NONBLOCK`, writes
  and removals durably sync the directory, every newly created ancestor is
  synced from its first existing parent, bounded enumeration fails closed on
  floods, and mode-0700/0600 boundaries also strip and sync inherited macOS
  ACLs. History records retain the typed output kind but no output destination;
  persisted data excludes full paths, option values, secret IDs and paths,
  worker logs, and arbitrary error text.
- The Build workspace keeps one app-level image-build model and builder model.
  A reviewed plan or active operation locks both its segmented picker and the
  top-level sidebar, preventing view teardown from silently discarding work.
  Builder inspection/actions expose Cancel Operation while locked; normal Stop
  retains the documented TERM-to-KILL escalation and Force Stop remains an
  explicit immediate KILL path.
- The History preview renders successfully in Xcode after replacing the macOS
  `List` path that crashed the current SDK’s outline diff with a stable
  `ScrollView`/`LazyVStack` presentation, and remains covered by the full Xcode
  suite.

## Docker compatibility checkpoint

- Settings now exposes a modular, optional Socktainer compatibility lane rather
  than presenting Docker Engine behavior as part of Apple’s native runtime.
- The installer downloads only Socktainer 1.0.0’s direct HTTPS asset, bounds its
  size, retains the URLSession temporary file safely, verifies the pinned
  SHA-256 and Developer ID team, and atomically installs mode 0700 into private
  app support.
- Start checks the running Apple API server through `ClientHealthCheck`, then
  waits for a complete HTTP `/_ping` response with body `OK` and API 1.51 before
  publishing Running. Socket identity is rechecked after readiness.
- Stop targets the exact app-owned PID, escalates TERM to KILL on timeout, and
  confirms exit. Force Stop is a separate confirmed kill point. App termination
  performs synchronous exact-PID shutdown and captured-inode cleanup.
- A stale socket can be removed explicitly only after three listener probes fail
  and its inode remains unchanged. A live external listener is never killed or
  unlinked.
- Docker context creation/repair uses the supported CLI, sanitizes
  `DOCKER_CONTEXT`/`DOCKER_HOST` for its own inspection, never calls
  `docker context use`, and verifies the active context did not change.
- Production-path Xcode snippets verified the 67,440,560-byte install at mode
  0700 and an isolated live bridge/context: Apple API 1.0.0, Docker API 1.51,
  `docker ps -a`, clean graceful exit, and no remaining socket.
- The full Xcode plan passes 463/463 outcomes: 452 deterministic tests passed
  and 11 explicitly gated live tests skipped, with no failures or warnings.

## Compose observability checkpoint

- Container labels now survive the Apple `ContainerSnapshot` adapter verbatim;
  volumes and networks already retained their Apple inventory labels.
- An injected, pure `ComposeTopologyService` derives deterministic projects,
  services, replicas, one-off markers, objective running counts, canonical
  volumes and networks, typed reverse associations, and provenance metadata from
  one completed inventory refresh. Logical Compose volume/network keys remain
  distinct from runtime resource names, and absent/valid/invalid optional labels
  remain distinguishable. The service does not require Socktainer or the Docker
  CLI to be running.
- Canonical membership validates Compose naming rules and exact project/service,
  volume, and network labels. Anonymous volumes, built-in Apple networks,
  missing labels, invalid optional or identity values, and cross-project
  consumers are excluded or surfaced as expandable evidence notices.
  Project-only containers cannot affect project counts, observed state, or
  membership links.
- Compose now has a first-class read-only workspace with exact Quick Open routes,
  service/replica views, canonical volume/network links, and best-effort source
  metadata. Overview shows observed projects, while container, volume, and
  network inspectors link back to their canonical project.
- No project lifecycle action was added. Existing prepare/re-read resource
  services remain the only authority for starts, stops, force stops, and
  destructive changes. Generic volume prune now preserves every volume carrying
  a reserved Compose label; explicit reviewed deletion remains available.
- A production-path Xcode snippet created unique canonically labeled Apple volume
  and network resources, observed one resource-only project with the logical
  names preserved separately from runtime names and zero evidence notices, then
  deleted both resources and confirmed the project disappeared on refresh.
- The full Xcode plan passes all 476 outcomes: 465 deterministic tests passed
  and 11 explicitly gated live tests skipped, with no failures.

## Compose bridge conformance checkpoint

- `SocktainerComposeConformanceService` is a pure, injected service independent
  from bridge process ownership and Apple-inventory topology. It evaluates an
  immutable contract pinned to Socktainer 1.0.0, Engine API 1.51, and release
  revision `876c2fc`.
- Nine explicit fixtures describe required Engine operations, source evidence,
  semantic limitations, unsupported behavior, and application-policy blocks.
  Missing operations fail closed. Network aliases are partial; health checks,
  restart policies, configs, and secrets remain unsupported even when generic
  create/inspect routes exist.
- Settings shows four supported capabilities and five gaps in a disclosure
  report that identifies itself as source-pinned rather than a live Compose run.
  Bridge install/start/stop/Force Stop/context controls remain owned by their
  existing services.
- Project lifecycle is explicitly policy-blocked until a reviewed Compose model
  supplies desired replicas, orphan handling, volume intent, and frozen resource
  identities. No project mutation action was added.
- The full Xcode plan passes all 479 outcomes: 468 deterministic tests passed
  and 11 explicitly gated live tests skipped, with no failures.

## Compose live-wire checkpoint

- A modular `SocktainerComposeLiveConformanceService` now owns one fixed,
  uniquely named Alpine service/volume/network fixture. Private workspace,
  exact-label cleanup planning, Apple-native cleanup, and orchestration are
  separate injectable facets.
- Config, up, and down commands are deadline-bounded by the existing host
  executor, which escalates TERM to KILL. Cleanup does not inherit caller
  cancellation: it runs the reviewed Compose model first, verifies Apple
  inventory absence, and only then rethrows cancellation or the original error.
- Failed Compose teardown falls back only after exact names and canonical labels
  match. It freezes and revalidates Apple identities, force-stops/deletes the
  container through `AppleContainerLifecycleService`, and deletes native
  network/volume plans through `AppleInfrastructureService`. Foreign or
  recreated resources fail closed.
- Two production-path Xcode runs passed. The normal run observed project
  `ncwire-217fee99` in `allRunning` state with service `probe`, logical volume
  `data`, and logical network `default`, then removed every resource. A second
  run forced Compose down to exit 17; Apple-native fallback completed, reported
  `FALLBACK=true`, and again left no resource, bridge process, or socket.
- The isolated Docker configuration correctly found no Compose plugin. The
  proof used the host’s standalone Compose 5.1.2 client, which currently resolves
  to OrbStack. Product packaging remains blocked from using that path; the next
  client slice must pin and verify Docker’s own Darwin arm64 release artifact.
- The full Xcode plan passes all 486 outcomes: 473 deterministic tests passed
  and 13 explicitly gated live tests skipped, with no failures.

## Private Docker Compose client checkpoint

- `DockerComposeClientInstallService` now owns Docker Compose 5.1.4 for Darwin
  arm64 as an independent service boundary. The official binary and SLSA
  provenance URLs, both SHA-256 digests, source tag/revision, build type, builder
  run, architecture, and download bounds are immutable release data.
- Downloads require HTTPS and bounded regular files. Validation rejects links,
  foreign ownership, extra hard links, writable group/world modes, digest drift,
  non-arm64 Mach-O headers, and provenance whose subject/source/builder identity
  differs from the reviewed release. The official executable is ad-hoc signed,
  so its code signature is not treated as publisher identity.
- Installation stages and revalidates both artifacts, publishes provenance
  before the executable activation point, and retains mode-0700/0600 files only
  under `~/Library/Application Support/NativeContainers/Compatibility/`
  `DockerCompose/5.1.4`. It never writes Docker CLI plug-in directories. A
  checked accessor returns an executable URL only while the complete install
  still validates.
- Settings exposes the verified state, exact version, private path, and an
  explicit install/reinstall action through the existing app-scoped
  compatibility model. The service remains independently injectable in tests
  and previews.
- Xcode installed the official artifact, revalidated both exact digests, and
  executed `version --short` as `5.1.4`. A live run through that private binary
  observed `ncwire-b84938f3` in `allRunning` state and removed every fixture
  resource normally. A second run forced `down` to exit 17; the Apple-native
  identity-revalidated fallback reported `FALLBACK=true` for
  `ncwire-efdce9a3`. Both runs ended with zero container/volume/network residue,
  a stopped bridge, and no socket.
- The full Xcode plan passes all 523 outcomes: 505 deterministic tests passed
  and 18 explicitly gated live tests skipped, with no failures. The build emits
  only nine pre-existing warnings in macOS saved-state tests.

## Compose desired-state review checkpoint

- Compose project work is now split across focused source-access, canonical
  rendering, desired-state decoding, lifecycle planning, and facade services.
  `AppModel` owns only an app-scoped workspace model; topology remains a
  separate read-only inventory projection and is never treated as mutation
  authority.
- Source review holds security-scoped access to one selected project directory,
  accepts exactly one conventional Compose filename, and pins an owner-only,
  non-symlink, single-link regular file by descriptor metadata and SHA-256. It
  revalidates both the descriptor and directory-relative path before, between,
  and after canonical renders.
- The verified private Docker Compose 5.1.4 client renders the full declaration
  with `--profile '*'` and the selected active-profile model separately. The
  facade requires two byte-stable normalized render pairs under a controlled
  environment. Truncated output, source drift, renderer drift, or a project-name
  mismatch fails closed.
- The decoder retains service/image/replica/profile, named-volume, network, and
  published-port intent but never persists service environment values. Builds,
  health checks, restart policies, configs, secrets, bind/anonymous mounts,
  custom aliases, and unsupported isolation/resource settings become typed
  blockers.
- The deterministic planner keeps the full declaration boundary distinct from
  active services, so inactive-profile containers are not orphans. External
  resources are always lookup-only, deletion intent is explicit, cross-project
  consumers and foreign resource identities block, and the review freezes exact
  observed container/volume/network identities. Generic network prune now
  mirrors volume prune by preserving every Compose-labeled resource.
- The Compose workspace exposes a source-backed review sheet with explicit Up,
  Start, Stop, or Down intent, profiles, pull policy, orphan/volume choices,
  hashes, affected resources, and findings. Review and execution cancellation
  are explicit kill points.
- Host command cancellation now completes an uncancelled TERM, grace period,
  KILL, and confirmed-exit sequence. Failure to confirm SIGKILL is surfaced
  instead of being mistaken for cancellation or timeout completion.
- A production-path Xcode probe used the installed private Compose 5.1.4 client
  to render the same source twice. It reported full services `web,worker`, active
  service `web`, normalized managed volume/network names, and zero parser
  blockers. The complete facade then reviewed a fresh project against current
  Apple inventory, found no observed containers or parser blockers, and retained
  the expected execution-policy lock.
- The reviewed execution contract now consists of ordered, typed container,
  network, volume, orphan, and preservation actions. Exact container identity
  includes the actual descriptor digest, platform, CPU, memory, ports, creation
  time, and labels; mutable state is deliberately excluded. Commit-time replans
  compare the complete typed contract rather than lossy name arrays.
- The mutation coordinator is a thin orchestrator over separately injectable
  container-action, resource-action, Compose-command, and postcondition services.
  Fresh Up remains command-backed. Exact-count existing-project Up reuses the
  frozen IDs and natively starts only stopped containers; it never invokes
  Compose convergence. Start, Stop, declared Down, and separately typed orphan
  Down execute the planner's frozen dependency order directly.
- Down can delete reviewed managed networks and named volumes after immediate
  identity and consumer revalidation. Container and network deletion use exact
  IDs; Apple 1.0 exposes volume deletion by name only, so the executor confirms
  both the frozen ID and runtime name before and after the call but cannot claim
  a runtime-level CAS guarantee against an external same-name replacement.
- Journal schema v3 stores only deterministic opaque step tokens and validates
  membership, order, monotonic progress, and full completion before verification.
  It never writes resource IDs or names as progress. Existing v2 records load as
  redacted manual-only recovery snapshots and cannot be resumed automatically.
- Create-missing Up and recreation remain separate policy blockers. Research
  confirms create-missing can use Compose 5.1.4 `--no-recreate` without new
  Socktainer routes because API 1.51 supplies initial network attachments at
  create time. It still needs a deterministic external-resource overlay, stable
  project/config label paths, contiguous replica-prefix validation, attachment
  postconditions, and an explicit supported-key allowlist. Recreation remains
  blocked while Socktainer 1.0.0 lacks rename and network connect/disconnect.
- A separate doubly gated lifecycle smoke now wires the real source renderer,
  planner, journal, execution workspace, Apple inventory, exact mutation
  services, pinned Compose client, and isolated Socktainer context through Up,
  Stop, Start, and Down. Its cleanup is detached, identity checked, and discards
  a journal record only after exact absence. It built and registered in this
  checkpoint; runtime execution remains intentionally gated by both
  `NATIVECONTAINERS_LIVE_SOCKTAINER=1` and
  `NATIVECONTAINERS_LIVE_COMPOSE_LIFECYCLE=1`.
- The full Xcode plan passes all 587 outcomes: 568 deterministic tests passed
  and 19 explicitly gated live tests skipped, with no failures. Xcode also built
  for testing successfully.
- Transactional VM cloning adds a separate store, transfer, identity, service,
  app-model, and SwiftUI boundary rather than expanding the library actor into a
  UI facade. The current full Xcode plan passes all 599 outcomes: 580
  deterministic tests passed and 19 explicitly gated live tests skipped, with
  no failures. Build-for-testing, zero Xcode navigator warnings, the clone-sheet
  Preview, and an app launch/stop smoke on `My Mac` also succeeded; no app
  process remains running.
- On-demand storage accounting is live behind independent Apple-runtime and VM
  library services, one app-facing facade, and a stable Overview model. The
  Apple lane uses the bounded cancellation-closing XPC client; the VM lane uses
  one descriptor-relative no-follow traversal that includes hidden partials,
  deduplicates hard links, attributes managed bundles, and propagates caller
  cancellation into its detached utility task. Overview never measures during
  ordinary inventory refresh, retains prior values on partial failure, exposes
  Cancel, and automatically cancels when the view disappears. The full Xcode
  plan passes all 621 outcomes: 602 deterministic tests passed and 19 gated live
  tests skipped, with no failures. The deterministic loaded-state Preview also
  renders in light and dark appearances, build-for-testing succeeds, and the
  app launch/stop smoke leaves no NativeContainers process running.
- Reviewed Apple-runtime reclamation is live behind separate container, image,
  volume, aggregate, and app-model services. The review is sealed to the Apple
  accounting and inventory revisions, lists every exact candidate, and requires
  a second destructive confirmation. Images and volumes are selected by
  default; stopped containers are opt-in and limited to exact UUID-owned app
  configurations. Commit-time checks preserve active, changed, Compose,
  builder, machine, Apple-managed, and unowned resources. Container deletion is
  bounded and non-force; no reclamation path invokes Stop, KILL, force-delete,
  or any VM mutation. Image deletion/GC now uses a bounded core-images adapter,
  while cancellation checkpoints and cancellation-independent reconciliation
  retain confirmed partial results. The full Xcode plan passes all 644 outcomes:
  625 deterministic tests passed, 19 explicitly gated live tests skipped, and
  no failures. Build-for-testing succeeds; the loaded review renders in light
  and dark, the loaded Overview renders with its Apple-card action, and a fresh
  app launch/stop leaves no NativeContainers process running. Launch emitted
  only the existing macOS 27 beta `com.apple.linkd.autoShortcut` registration
  noise.
- Reviewed VM host-storage reclamation is live behind separate saved-state,
  interrupted-residue, artifact-inspection, aggregate, app-model, and SwiftUI
  services. Plans are sealed to the VM accounting and library revisions and
  list exact committed saved states plus allowlisted app transaction residue.
  Commit-time checks hold operation/runtime locks and reject replacement,
  symbolic links, hard links, special files, foreign ownership, and mount
  crossings before an atomic retirement. Cancellation preserves exact partial
  results. The workflow never starts, stops, force-stops, or kills a VM and
  never touches committed disks or restore images. Build-for-testing succeeds,
  all 18 focused service/store/model/accounting tests pass, and the reviewing,
  empty, partial-result, and loaded Overview previews render successfully. The
  full Xcode plan passes all 661 outcomes: 642 deterministic tests passed, 19
  explicitly gated live tests skipped, and no tests failed. A fresh Xcode
  launch/stop succeeds; an orphaned Preview process accepted exact-PID TERM,
  and no NativeContainers process remains. The only launch errors were the
  existing macOS 27 beta `com.apple.linkd.autoShortcut` registration noise.
- Restore-image ownership is now a modular application service rather than a
  handoff between the download and import UI paths. One acquisition facade
  composes independent download/import services with a shared cache authority;
  versioned markers and a cache-wide cross-process lease span byte acquisition,
  Virtualization platform preparation, and manifest commit. Remote partials
  remain resumable, failed private imports are discarded, already-cached files
  receive real leases, completed URL-hash identities are immutable, and
  startup recovery takes the cache lock before loading fresh manifest
  references. Successful installation clears its now-unneeded reference while
  cancellation and failure retain it for retry.
- Restore images are also a third, explicitly opt-in VM reclamation category.
  Planning admits only unreferenced current-user regular IPSWs with no active
  marker; partial downloads must be at least seven days old. Execution reloads
  references, revalidates exact filesystem identity, atomically retires the
  reviewed file, and leaves a recovery-recognized tombstone if deletion is
  interrupted. The review UI discloses redownload cost and keeps VM disks,
  active leases, referenced images, replacements, links, and special files out
  of scope. Build-for-testing succeeds and the full Xcode plan passes all 676
  outcomes: 657 deterministic tests passed, 19 explicitly gated live tests
  skipped, and no tests failed. Reviewing light, dark-variant, and large-text
  previews render without clipping; Xcode launch/stop succeeds, the Preview
  host accepted exact-PID TERM, the navigator has no issues, and no
  NativeContainers process remains. Launch emitted only the existing macOS 27
  beta `com.apple.linkd.autoShortcut` registration noise.
- Restore-image persistence now has explicit service boundaries. Acquisition
  handles leases only; a dedicated launch-maintenance service composes legacy
  recovery, journaled migration, and durable-store recovery, while the VM
  library exposes a narrow exact-reference API. New IPSWs live in private,
  backup-excluded Application Support. Referenced Caches IPSWs are copy-first
  migrated under legacy-store, durable-store, and library locks; every partial
  manifest rewrite still names an existing file, relaunch resumes the phase
  journal, and the old unreferenced copy is retained for a future composite
  cleanup review or OS cache purging. The current reclamation review owns only
  the durable store.
  Focused migration, acquisition, reclamation, library, model, and composition
  tests pass. Xcode MCP then ran the complete 689-test plan in eight bounded
  shards: 670 passed, 19 live-environment tests skipped, 0 failed, and 0 were
  left unrun. Build-for-testing passed in 2.739 seconds, the app launched on My
  Mac, Xcode stopped its exact PID, and the Issue Navigator reported no warnings
  or errors. Launch emitted only the existing macOS 27 beta
  `com.apple.linkd.autoShortcut`/SetStore registration noise.
- macOS VM disks now have an explicit RAW/ASIF model and a modular macOS 27
  replacement lane. DiskImageKit supplies ASIF virtual geometry and the native VZ
  attachment, so sparse host length is never mistaken for guest capacity.
  Conversion is stopped-only and saved-state-free, runs out of place through
  the documented `diskutil image create from --format ASIF` route, inherits
  exact-PID TERM-to-KILL cancellation, seals both files, journals five durable
  phases, atomically switches the manifest, and finishes old-RAW cleanup without
  another cancellation point. Unconfirmed exit retains the runtime lease and
  journal; failed KILL delivery is tied to `kern.bootsessionuuid` and cannot
  recover until a reboot proves quiescence. Runtime/discard leases and
  clone/export/import paths reject pending replacement state. Relaunch continues
  recovery across per-VM failures, rolls back only safe pre-commit artifacts,
  or completes post-commit cleanup. The same coordinator now supports a
  standalone ASIF-to-ASIF rewrite. It rejects cache/overlay layers, verifies
  virtual capacity and block size, and commits a uniquely named candidate only
  when sealed filesystem accounting measures fewer allocated bytes; equal or
  larger candidates are cleaned up as a successful no-op. Journal schema 3
  records source block geometry in addition to schema-2 operation/format data,
  while recovery remains compatible with schema-1 and schema-2 journals.
  Thin migration/rewrite services, required shared recovery, and one app-scoped
  maintenance model keep the runtime, discard, transfer, and shared-folder gates
  aligned. The VM
  configuration screen exposes the operation, its blockers, cancellation,
  uncancellable refresh, and measured savings; competing
  controls remain disabled, and raw truncation remains prohibited.
  Xcode MCP's complete 747-outcome plan passed 728 deterministic outcomes,
  skipped the 19 explicit live gates, and left no failures or unrun tests.
  Build-for-testing passed, and both RAW and ASIF VM inspectors rendered in
  Preview. The signed app launched as PID 20113 and Xcode stopped that exact
  process; the Preview-owned PID 13620 accepted bounded TERM cleanup, and no
  NativeContainers process remained. The Issue Navigator reported no warnings
  or errors. Launch emitted only the existing macOS 27 beta SetStore donation
  noise.

- macOS VM disk snapshots are now a distinct manifest/domain, transactional
  layer-store, orchestration-service, runtime-adapter, app-model, and SwiftUI
  lane. Up to eight named stopped-VM checkpoints use canonical bundle-local
  DiskImageKit overlays. Creation and restore hold runtime ownership, reject
  saved states, clean failed pre-commit layers, and report post-commit cleanup
  residue without misreporting a committed restore as failed. Restore retains
  the selected prefix, prunes newer history, and creates a fresh writable top
  layer. Runtime stack assembly, resolver ordering, transfer validation, and
  saved-state fingerprints all include the complete layer topology; disk
  replacement is blocked while history exists. Real DiskImageKit overlay and
  writable-VZ-attachment tests pass. The native snapshot section renders in
  both light and dark Xcode previews without clipping. Live guest I/O and
  restore behavior still require an installed disposable macOS guest.

- Compose create-missing Up is now implemented as a separate non-recreation
  lane. Canonical full/active models fail closed on an explicit supported-key
  allowlist. Execution writes a digest-named immutable overlay beneath a stable
  private project directory, converts every reviewed resource to an exact
  external reference, and proves unchanged Compose service hashes before any
  Apple mutation. Missing managed networks and volumes are created natively
  with operation-scoped ownership; stopped replicas in the reviewed contiguous
  prefix start by exact ID before Compose 5.1.4 runs `--no-recreate` for the
  missing suffix. Planner and postcondition services independently require exact
  named-volume/network attachments. Sparse replica sets, scale-down,
  configuration/image drift, custom resource labels, and all recreation remain
  blocked. The focused overlay/workspace/planner/executor/resource proof passed
  12 tests. Xcode MCP then completed the full plan in eight bounded, ordered
  suite shards: 735 outcomes passed, the 19 explicit live-environment gates
  skipped, and no outcome failed or remained unrun. At that checkpoint Xcode
  discovered 749 test declarations; five parameterized cases expanded the
  execution to 754 outcomes. Build-for-testing also passed.

## GUI Linux VM foundation checkpoint

- General-purpose Linux VM storage is now a separate modular lane rather than
  another branch inside the macOS runtime. A Linux manifest owns persistent
  EFI/NVRAM, generic machine identity, stable locally administered MAC identity,
  copied ISO media, and its writable disk inside the `.nativevm` bundle.
- ISO acquisition rejects non-file, non-ISO, empty, symbolic, incomplete, and
  concurrently changed inputs. Preparation stages inside the target bundle,
  validates all required regular files, atomically promotes the platform
  directory, and rolls back both artifacts and manifest on every tested failure.
- macOS and Linux resolvers now share one containment/no-symlink artifact
  service while retaining platform-specific errors and resolved models.
- The Apple configuration factory passes
  `VZVirtualMachineConfiguration.validate()` with a real generated ISO and
  includes EFI boot, USB installer media, writable Virtio storage, persistent
  NAT networking, Virtio graphics and host audio output, USB input, entropy,
  memory ballooning, and optional SPICE clipboard.
- Thirteen focused Linux tests pass, covering legacy manifest decoding,
  transaction commit/rollback, missing artifacts, guest separation, safe ISO
  copy, path traversal, clipboard topology, and the validated Apple
  configuration.
- The full Xcode plan passes all 847 outcomes: 826 deterministic tests passed,
  21 explicitly gated live tests skipped, and no outcome failed or remained
  unrun. A normal build and app launch also passed; launch emitted only the
  known macOS 27 beta SetStore donation-service noise, and the app was stopped.

## GUI Linux VM runtime checkpoint

- Linux VM creation is one application transaction: draft creation and platform
  preparation are composed behind `LinuxVirtualMachineCreationService`, with
  draft rollback and composite error preservation on failure.
- A Linux-specific runtime coordinator owns generation-pinned bundle leases,
  engine sessions, observable state, and exactly-once terminal cleanup. It
  supports start, pause, resume, graceful stop, explicit Force Stop, and Force
  Stop queued behind an in-flight framework transition.
- Graceful stop arms a 30-second watchdog. A guest that does not exit is
  automatically force-stopped after a bounded framework capability wait, while
  the explicit Force Stop control remains available immediately for manual
  recovery.
- Installer ISO media is attached through XHCI USB mass storage. The runtime can
  hot-eject it, persist installation completion only after detach succeeds, and
  retry persistence without detaching twice.
- The workspace now dispatches macOS and Linux VMs to separate row,
  configuration, and runtime views while sharing the console bridge and resource
  catalog. The Linux creation form copies a selected ISO through the
  transactional service; the runtime view embeds the native Virtualization
  console and exposes lifecycle and ejection controls.
- Ten focused creation, ownership, lifecycle, watchdog, ejection, configuration,
  app-model, and navigation regressions pass. Both mixed-guest workspace and
  Linux-creation previews render successfully in Xcode.
- The full Xcode plan passes all 864 outcomes: 843 deterministic tests passed,
  21 explicitly gated live tests skipped, and no outcome failed or remained
  unrun. A normal build and signed app launch also passed; launch emitted only
  the known macOS 27 beta SetStore donation-service noise, and the app was
  stopped cleanly.

## GUI Linux VM shared-folder checkpoint

- Shared-folder domain values, validation, security-scoped bookmark access,
  mode-0600 sidecar persistence, app state, and VirtioFS construction are now
  guest-neutral contracts rather than macOS-owned primitives. macOS and Linux
  services contain only their distinct lifecycle rules.
- `LinuxVirtualMachineSharedDirectoryService` provides stopped-only add/remove
  operations through generation-pinned Linux runtime leases. Runtime acquisition
  reloads the sidecar, resolves every bookmark fail-closed, and holds the access
  lease until the exact engine session closes.
- One Linux `VZMultipleDirectoryShare` exposes all selected folders under the
  stable `nativecontainers` tag. The configuration inspector shows host and guest
  paths, read-only/read-write policy, cold-start behavior, the required VirtioFS
  kernel support, and an exact selectable guest mount command.
- Portable exports/imports continue to strip host-local bookmark capability
  data; same-host clones retain it. The existing portability regression and 21
  focused sharing, runtime, composition, and macOS compatibility tests pass.
- The full Xcode plan passes all 871 outcomes: 850 deterministic tests passed,
  21 explicitly gated live tests skipped, and no outcome failed or remained
  unrun. Build-for-testing, the selected-Linux preview, a normal build, and a
  signed launch/stop also pass on `NativeContainers` / `My Mac`; launch emits
  only the known macOS 27 beta SetStore donation-service error.

## Persistent Linux machine configuration checkpoint

- Apple Linux-machine CPU, memory, and none/read-only/read-write home-mount
  values now round-trip through one shared snapshot mapper instead of separate
  inventory and lifecycle conversions.
- `MachineConfigurationManaging` is a dedicated composition facet backed by
  `AppleLinuxMachineConfigurationService`. It shares the runtime mutation
  coordinator, requires a stable creation identity, re-inspects immediately
  before Apple’s ID-only route, and verifies the exact persisted configuration
  after every reply.
- Cancellation and request failures reconcile in a cancellation-independent
  task. A committed desired state is accepted, a missing or replaced machine
  fails explicitly, and unverifiable persistence reports an unknown outcome
  instead of a false success or retry suggestion.
- The native configuration sheet edits only Apple 1.0’s supported fields,
  requires explicit confirmation for writable host-home access, and explains
  next-start versus next-restart application. Disk, kernel, Rosetta, and nested
  virtualization controls remain deferred because the pinned runtime does not
  expose them.
- Seven focused configuration-service cases plus transport, inventory,
  composition, and observable-model regressions pass. The editor Preview,
  build-for-testing, normal build, and signed launch/stop pass. The full Xcode
  plan passes all 879 outcomes: 858 deterministic tests passed, 21 explicit
  live gates skipped, and no outcome failed or remained unrun. Launch emitted
  only the known macOS 27 beta SetStore donation-service error.

## Host-aware creation-default checkpoint

- `ProcessInfoHostResourceStateProvider` is the only Foundation-facing adapter;
  `HostResourceDefaultService` is a pure, injectable policy over framework-free
  host state and workload-default domain values.
- Container, persistent Linux-machine, and GUI-VM creation sheets sample the
  service when opened. Low Power Mode or serious/critical thermal pressure
  initializes each editable CPU control at two cores, clamped to the active
  processor count; nominal and fair states preserve the established defaults.
- A shared native notice explains constrained defaults. Memory and disk values
  are unchanged, and existing or running workloads are never resized.
- Eight policy cases, two draft-integration cases, and the composition-root
  regression pass. Build-for-testing and the constrained-default Xcode Preview
  also pass. The full Xcode plan passes all 933 outcomes: 912 deterministic
  tests passed, 21 explicit live gates skipped, and no outcome failed or
  remained unrun. The normal build and signed Xcode launch/stop smoke pass with
  only the existing macOS 27 beta SetStore/CoreSpotlight donation error.
- Idle suspension remains open because app, window, and console inactivity do
  not prove that an unattended guest has stopped useful work.

## Demand-started service checkpoint

- `AppServices` and `AppCompositionRoot` now live in separate files, with the
  live assembly organized under `App/Composition` instead of sharing the
  dependency-value file.
- Launch-critical inventory plus VM installation, disk-replacement, and
  restore-image recovery stay eager. Docker compatibility and Compose share one
  `DemandStartedService` module behind their existing protocols, so ordinary
  app construction and first refresh allocate no Socktainer, Docker context,
  Compose client/config, mutation, or journal service.
- The holder serializes first access and releases its factory after publishing
  one complete graph. Two focused holder tests cover zero work before resolve
  and 64 concurrent resolvers; the composition-root regression proves all three
  optional facades observe the same activation. The focused run passes 3/3.
- The full Xcode plan passes all 935 outcomes: 914 deterministic tests passed,
  21 explicit live gates skipped, and no outcome failed or remained unrun. The
  normal build succeeds and the Issue Navigator reports no warnings or errors.
  The signed app launched through Xcode as PID 93433 and Xcode stopped that exact
  process; console output contained only the existing macOS 27 beta
  SetStore/CoreSpotlight donation-service error.

## Native commands and localization-readiness checkpoint

- The main scene now installs a focused `NativeContainersCommands` value.
  Apple's sidebar and toolbar command groups supply standard View-menu items,
  while a Navigate menu exposes Command-1 through Command-9 in visible sidebar
  order. Settings retains the system-owned Command-comma behavior.
- Menu-item enablement goes through `AppModel.canNavigate` and the existing
  workspace route authority. A reviewed build therefore keeps every conflicting
  sidebar, Quick Open, and keyboard route disabled while Builds remains active.
- Quick Open and Refresh publish alternate Voice Control/Full Keyboard Access
  input labels; Quick Open result buttons publish each visible runtime resource
  name. Swift source-string extraction and String Catalog preference are enabled
  in Xcode and `project.yml`. The refreshed English catalog contains 1,225
  source keys, up from 363 before full extraction.
- The focused command-metadata and reviewed-build-lock run passes 2/2. Xcode's
  realized main menu contains the expected View commands, Settings
  Command-comma behavior, and Navigate entries from Overview Command-1 through
  Virtual Machines Command-9. The full Xcode plan passes all 937 outcomes: 916
  deterministic tests passed, 21 explicit live gates skipped, and no outcome
  failed or remained unrun. The normal build succeeds and the Issue Navigator
  reports no warnings or errors.
- The target's USB capability setting reports enabled, but an app-context
  entitlement probe still returns false. Xcode's entitlement action rejects the
  macOS 27 key, so NativeContainers keeps the existing fail-closed USB service
  and no manual entitlement-file workaround was made.

## Accessibility source-contract checkpoint

- GUI Linux and macOS VM list summaries now select through plain semantic
  buttons instead of row-wide tap gestures. Each selection button publishes the
  visible VM name as an input label, a selection hint, and the selected/not
  selected value; runtime and destructive actions remain independent sibling
  controls.
- The management-view audit found no remaining raw tap activation. Existing
  icon-only actions retain standard `Button` or `Menu` titles, or an explicit
  localized accessibility label; enumerated shared-folder rows continue to use
  stable domain IDs rather than offsets.
- `docs/ACCESSIBILITY_QA.md` defines the source rules, a workflow-wide live
  VoiceOver, Full Keyboard Access, Voice Control, visual-settings, and
  localization matrix, and the required exact-build evidence record.
  `scripts/validate-accessibility-contract.sh` passes and guards semantic
  selection, visible-name input labels, selection values, directional layout,
  localization settings, and release-document drift.
- This closes only the source-level gate. Reviewed non-English translations and
  live assistive-technology testing remain open. Exact-head Xcode build and test
  evidence also remains pending because the Xcode MCP transport is closed; no
  shell build or test was substituted.

## macOS 27 menu-bar scene stability checkpoint

- An untouched Xcode launch on macOS 27 held the main thread at 99-100% CPU.
  Debugger samples repeatedly landed in SwiftUI menu-bar/app-graph updates.
  Removing `MenuBarExtra` dropped idle CPU to roughly 0.6-1.1%; keeping the
  scene declared but binding `isInserted` to false produced the same stable
  result.
- `AppExecutionContext` now owns one injectable operating-system policy in
  addition to its test and Preview gates. Menu-bar insertion remains available
  on the verified macOS 26 runtime and is forced off on macOS 27 and later until
  a fixed framework is revalidated. Settings hides the unavailable visibility
  toggle instead of persisting an action that cannot safely take effect.
- Two focused execution-context tests pass, including macOS 26, 27, and future
  runtime cases. The final Xcode-launched process idled across five samples at
  0.2-0.4% CPU. Console output contained only the existing macOS 27 beta
  SetStore/CoreSpotlight donation-service error, and Xcode stopped the exact
  process.

## Local performance-baseline checkpoint

- A new `PerformanceBenchmarking` service graph separates timing policy from
  Settings and composes three bounded scenarios: read-only warm Apple inventory,
  private temporary-file write/synchronize/read/remove I/O, and
  Network.framework localhost TCP. The app-scoped model exposes explicit Run
  and Cancel controls and preserves the last completed report.
- The focused suite passes 5/5, covering warmups and median/P95/throughput math,
  per-scenario failure isolation, cancellation propagation, temporary-artifact
  cleanup, and a real 1 MiB localhost transfer. Composition and stable-model
  checks pass 2/2, and the SwiftUI preview renders cleanly.
- A live Xcode snippet through `AppCompositionRoot.live()` completed every lane:
  warm inventory measured 1.3 ms median/P95, private disk measured 5.3/5.4 ms
  at 6013.8 MiB/s, and loopback TCP measured 11.5/12.4 ms at 1353.3 MiB/s.
  These are host-session baselines, not product promises.
- The final full Xcode plan passes all 942 outcomes: 921 deterministic tests
  passed, 21 explicit live gates skipped, and no outcome failed or remained
  unrun. Build-for-testing succeeds in 15.985 seconds, and both the build log
  and Issue Navigator contain zero warnings or errors.
- The final normal Xcode launch ran as PID 20767 and sampled at 1.0-1.8% CPU
  across five idle checks, with no recurrence of the macOS 27 menu-scene loop.
  Xcode stopped that exact process. The preview-owned PID 11613 accepted TERM;
  no NativeContainers or Preview process remained. Console errors were limited
  to the existing macOS 27 beta CoreSpotlight/SetStore service failure.
- The benchmark runner now has per-iteration preparation and
  cancellation-independent cleanup outside the measured interval. The first
  mutating lane is a separate `NATIVECONTAINERS_LIVE_PERFORMANCE=1` gate: it
  requires an already-local image, creates a fresh stopped one-CPU/256-MiB
  container, verifies the preflighted image reference/digest, and measures
  production lifecycle start through an authoritative
  running snapshot, then gracefully stops (with KILL fallback), deletes, and
  verifies no run-prefixed container remains. Creation-operation identity is
  revalidated before every mutation, and a same-name replacement is left
  untouched. One warmup and three samples are
  emitted as marker-framed JSON with host OS, Apple runtime version, image
  reference/digest, median, and P95. Deterministic coverage proves setup and
  cleanup boundaries, cancellation/failure cleanup, and suite abort before any
  later lane after a cleanup fault. This exact head is unclaimed because Xcode
  MCP currently fails at `XcodeListWindows` with `Transport closed`.
- A second opt-in I/O gate now compares a fresh container's writable root with
  the product's reviewed writable VirtioFS host-folder path. Both lanes use the
  bounded Apple process-XPC command service and a fixed 16-MiB BusyBox workload:
  sequential write with `conv=fsync`, immediate read, exit-trap deletion, and
  one completion marker. The measured interval is end-to-end command latency,
  not a cache-cold raw-device claim. One warmup and three samples per lane emit
  raw timings, median/P95, aggregate throughput, payload, host/runtime version,
  and exact image provenance. Deterministic coverage pins the fixed paths,
  writable reviewed mount, processed-byte accounting, and residual cleanup;
  the live gate additionally requires no run-prefixed container and no host
  artifact. This exact head also awaits Xcode MCP build/test/live execution.
- A third opt-in performance gate now runs the production embedded-worker image
  build path over a disposable fixed context: a digest-pinned local Alpine base,
  an 8-MiB payload, one COPY, and one in-image SHA-256 operation. Planning and
  reviewed output authorization precede the clock; the timed interval includes
  no-cache BuildKit execution, context transfer, layer creation, OCI export,
  reviewed publication, and final archive validation. The gate never imports
  its tag into the shared image store and does not request a newer base image.
  One warmup plus three samples emit raw timing, median/P95, host/runtime and
  exact base provenance, payload, cache policy, and output kind. Deterministic
  coverage proves request/plan/result pinning and output removal on success and
  validation failure; the live postcondition also rejects output, staged
  context, app-private artifact, shared worker-export, or image-store residue.
  This exact head awaits Xcode MCP build/test/live execution because the bridge
  remains unavailable.
- A fourth opt-in gate now measures a fresh Apple persistent Linux machine from
  production `startMachine` through first-user provisioning and authoritative
  running/initialized readiness. Local arm64 image presence, image index digest,
  stable machine creation identity, platform, stopped preparation, and a nil
  pre-start timestamp are checked outside the clock; final digest/identity,
  running state, initialization, and start timestamp are checked inside it.
  Graceful stop, authorized KILL fallback, exact deletion, and run-prefix
  absence stay outside the interval. Deterministic coverage proves timing
  boundaries, fixed no-home configuration, digest rejection with cleanup,
  force-stop recovery, and same-name replacement protection. One warmup plus
  three fresh-machine samples emit raw timing, median/P95, host/runtime/image,
  platform, CPU, memory, and provisioning provenance. This exact head awaits
  Xcode MCP build/test/live execution because the bridge remains unavailable.
- A fifth opt-in gate now measures an IPSW-installed macOS GUI VM without
  starting or mutating the selected source. Each iteration verifies the source
  is stopped, installed, and through first boot, then creates an
  identity-regenerated disposable clone outside the clock and confirms the
  clone has no saved state. The timed interval runs the production
  `MacVirtualMachineRuntimeService.start` path through a newer authoritative
  running snapshot, a fresh runtime generation, and an available graphical
  console. It intentionally does not claim that a guest login screen or user
  session is interactive. Cleanup requests guest shutdown, force-stops only the
  reviewed runtime generation when necessary, and conditionally deletes only
  an unchanged clone manifest; source equality and empty run-prefix residue are
  postconditions. One warmup plus three samples emit host, source UUID/name,
  guest build/version, resources, raw timing, median, P95, and the precise
  readiness boundary. This exact head awaits Xcode MCP build/test/live
  execution because the bridge remains unavailable.
- A sixth opt-in gate now measures an operator-supplied non-local HTTPS payload
  from inside a fresh digest-pinned Apple container. Container creation and
  startup remain outside the clock. The timed production command performs DNS,
  TLS and certificate validation, an HTTP transfer with a no-cache request,
  guest-root file writes, byte counting, SHA-256 verification, and a final
  authoritative running-state check. Payloads are limited to 1–128 MiB; the
  URL may not embed credentials or name an obvious local/private literal, and
  no third-party endpoint is selected by default. A remote cache can still
  satisfy the request, so this is an end-to-end guest HTTPS metric rather than
  a pure link-capacity claim. Exit-trap file removal plus exact container
  stop/delete and run-prefix absence remain outside the interval. One warmup
  plus three samples emit raw timing, median/P95, aggregate throughput,
  host/runtime/image provenance, endpoint authority, cache request, byte count,
  digest, and verification mode. This exact head awaits Xcode MCP
  build/test/live execution because the bridge remains unavailable.
- A seventh opt-in gate now measures a fresh idle Apple container using the
  product's authoritative `stats` path. Every iteration creates and starts a
  digest-pinned one-vCPU/256-MiB container running `/bin/sleep 3600` outside the
  clock, allows a bounded two-second settling period, then measures two stats
  snapshots around a configurable 1–300 second window. CPU, network, and block
  counters must be paired and monotonic; memory usage, the exact reviewed memory
  limit, and process count must be present. Optional network/block families may
  be absent only in both snapshots. The measured duration includes both stats
  RPCs and the idle wait, and normalized CPU is derived from cumulative CPU
  microseconds over that observed duration. No pass threshold is asserted
  because host load and runtime warmth are uncontrolled. One warmup plus three
  measured fresh containers emit raw counters, CPU percentages, peak final
  memory, host/runtime/image provenance, configuration, and sampling boundary.
  Cancellation-independent exact container cleanup and run-prefix absence are
  still required. This exact head awaits Xcode MCP build/test/live execution
  because the bridge remains unavailable.

## Distribution-readiness checkpoint

- Project and target settings now define arm64 architecture, marketing version
  0.1.0, build 1, Apple-generic versioning, product validation, and hardened
  runtime for both the app and one-shot build worker. The worker remains
  `SKIP_INSTALL=YES` and is embedded exactly once in the app.
- Stale inherited capability settings were removed from both executable
  targets. The clean Release signature contains microphone input and
  virtualization on the app only; the worker contains no app capability. The
  validator fails archives that reintroduce broad file, network, device,
  personal-information, printing, Apple Events, or runtime-exception
  entitlements.
- Xcode archived version 0.1.0 (1) successfully on `Any Mac (arm64)`. The local
  validator passed architecture, layout, version, strict nested signature,
  hardened-runtime, team, and entitlement gates. The final Xcode test run also
  passed all 942 outcomes: 921 deterministic tests passed, 21 explicit live
  gates skipped, and no outcome failed or remained unrun.
- The strict release gate correctly rejects the archive because its authority
  is Apple Development. The signing keychain currently exposes no Developer ID
  Application identity, so public signing, notarization, and stapling are not
  claimed. The repeatable operator flow is in `docs/DISTRIBUTION.md`.
- Product data schema 1 now has a source-backed migration and rollback contract.
  It separates authoritative VM/restore/bookmark/preset data from resumable
  journals/history, disposable caches and compatibility assets, and external
  Apple runtime, Keychain, system-permission, and user-selected authorities.
  Future schema changes must use locked per-store staging, sealed rollback
  generations, production-reader validation, atomic commit, hard-exit recovery,
  reverse-order rollback, and downgrade evidence. Release 0.1.0 performs no
  whole-app migration. `scripts/validate-data-migration-contract.sh` binds the
  documented inventory to current schema constants, storage roots, preference
  keys, and release instructions.

## Field-diagnostics checkpoint

- The normal app now registers one launch-safe `MXMetricManagerSubscriber` and
  captures Apple's exact diagnostic and daily-metric JSON without installing a
  crash handler or introducing an upload path. Xcode's current MetricKit
  documentation confirms immediate macOS diagnostic delivery, macOS 26 daily
  metrics, previously undelivered reports, and launch-safe subscription. Hosted
  tests and Preview processes receive an unavailable service instead.
- A dedicated actor retains at most 30 payloads and 20 MiB in a backup-excluded
  mode-0700 root with mode-0600 records. It rejects symbolic roots and records,
  hard links, foreign ownership, unsafe permissions, invalid JSON, digest or
  identifier drift, oversized payloads, unbounded counts, and excessive scans.
  Settings shows bounded metadata and category totals; raw JSON leaves the
  store only through explicit export, and deletion requires confirmation.
- The archive validator now requires matching app and embedded-worker dSYMs;
  the latest local archive passes the UUID, layout, signature, hardened-runtime,
  team, and constrained-entitlement gates. Build-for-testing succeeds, source
  diagnostics report no issues, and all 10
  focused collection/store/model tests pass. The final full Xcode plan passes
  952 outcomes: 931 deterministic tests passed, 21 explicit live gates skipped,
  and no outcome failed or remained unrun.
- The normal app launched through Xcode in 4.84 seconds as PID 25881 and Xcode
  stopped that exact process. Console errors were limited to the existing
  macOS 27 beta CoreSpotlight/SetStore service failure. The field-diagnostics
  canvas preview itself twice hit Xcode's 30-second app-launch timeout, so a
  rendered-preview claim remains intentionally open despite the successful
  build and normal launch.

## Native Kubernetes control-plane checkpoint

- AppleKubernetesClusterService now composes the existing public Apple
  machine, lifecycle, inventory, process-target, and bounded-command services
  into one app-owned K3s control plane. The dedicated persistent machine has
  no host-home mount, retains an exact creation identity, and fails closed if
  a same-name machine is missing or replaced.
- Provisioning pins K3s v1.36.1+k3s1, verifies the exact-tag installer against
  the embedded SHA-256, leaves the official release checksum check enabled,
  runs K3s as the guest's native service with secret encryption, and keeps
  kubeconfig mode 0600. The host descriptor is owner-only, backup-excluded,
  and contains no token, key, certificate, or kubeconfig.
- The live Apple machine uses `vminitd` rather than OpenRC as PID 1. Provisioning
  therefore installs the native OpenRC unit without auto-starting it, prepares
  the delegated cgroup-v2 hierarchy explicitly, and starts K3s through that
  unit. Readiness now requires the API, a Ready node, flannel state, the default
  service-account controller, and a mode-0600 kubeconfig. Exact creation dates
  retain their full binary precision across descriptor persistence, so a
  freshly reloaded descriptor does not falsely classify its machine as stale.
- A dedicated SwiftUI workspace exposes setup with reviewed CPU and memory
  floors, progress, status, Start, graceful Stop, explicit Force Stop, Delete,
  stale-record recovery, and user-initiated kubeconfig export. Workspace
  routing and Navigate Command-0 use one stable app-scoped observable model.
- Ready and degraded clusters now expose a native, searchable, read-only
  workload, pod, and service browser. Every refresh revalidates the stored
  Apple machine identity and running state before addressing the current
  backing container. K3s JSON is reduced inside the guest with `jq` to only
  names, namespaces, replica/status counts, node names, service addresses, and
  ports; pod environment, annotations, and secret payloads never cross into
  the host model. Each resource family is capped at 500 records, stable IDs are
  duplicate-checked, and truncated or malformed output fails closed.
- Pod rows now open an explicit-container log sheet. The inventory retains the
  Pod API UID and standard container names without images or environment; each
  request validates those identifiers, rechecks the current Pod UID, and loads
  a timestamped snapshot capped at the latest 2,000 lines and 512 KiB. Search
  is cached, stale responses cannot overwrite a newly selected container, and
  export is explicit. A second UID check and service-owned marker after the
  name-addressed log call make any concurrent same-name replacement fail closed.
- The same sheet can open an interactive terminal in its selected standard
  container. The restorable target pins the exact cluster machine, Pod API UID,
  namespace, Pod name, and container name. A fixed bounded probe discovers only
  allowlisted shells with UID checks before and after, then a terminal-mode
  Apple process performs one last UID preflight and enters explicit-container
  K3s exec with stdin and TTY. A separate bounded post-launch UID read must
  still match before the session is returned, otherwise the PTY is closed. Pod
  presets and arbitrary startup commands are disabled; the remaining upstream
  name-addressed race is documented.
- The Pod detail sheet now also presents a native one-shot command form for the
  selected standard container. A typed request caps executable/argument bytes,
  128 arguments, aggregate command size, and a 300-second timeout. The fixed
  guest wrapper shell-quotes each argv value, adds no implicit shell, brackets
  explicit-container `kubectl exec` with Pod-UID checks, and marker-binds the
  expected UID to the remote exit status. Stdout and stderr stay in memory with
  newest-1-MiB retention; cancellation rejects late results without claiming
  authoritative remote-process termination. Deterministic validation, quoting,
  identity-marker, nonzero-exit, truncation, model, and gated live-smoke coverage
  are checked in; exact-head Xcode execution remains pending while MCP is closed.
- Deployment and StatefulSet rows now expose a native scale review sheet;
  DaemonSets and Jobs remain non-scalable. The request freezes UID,
  resourceVersion, current replicas, and target replicas. The bounded guest
  command revalidates all reviewed state, sends Kubernetes' server-enforced
  resource-version and current-replica preconditions, then requires the same
  UID, a new version, and the target count. Deterministic service/model coverage
  is present, and the selected live smoke scaled a real Deployment to two Ready
  replicas while retaining its UID and advancing its resourceVersion.
- Deployment, StatefulSet, and DaemonSet rows now expose a reviewed restart
  action; Jobs remain excluded. The service avoids stock `kubectl rollout
  restart` and its last-write-wins patch. It verifies the full reviewed
  identity, changes only the standard Pod-template restart annotation inside
  the guest, performs a resourceVersion-bearing full replace, and confirms the
  same UID, new version, and annotation. The complete workload object never
  crosses to the host. Deterministic service/model coverage is present, and the
  same live smoke completed a real Deployment rollout and observed the expected
  restart annotation on the retained UID.
- Every workload row now exposes a destructive deletion review that requires
  the exact workload name and adds a critical warning for system namespaces.
  A fixed kind-specific API path receives a raw Kubernetes DeleteOptions body
  with server-enforced UID/resourceVersion preconditions and foreground
  propagation; force deletion and grace-period overrides are absent. A bounded
  identity poll distinguishes completed deletion, pending finalizers, and an
  untouched same-name replacement. Deterministic service/model coverage is
  present, and the same live smoke removed the reviewed Deployment through this
  preconditioned foreground path and confirmed its UID was absent afterward.
- The current Xcode MCP probe fails at `XcodeListWindows` with `Transport
  closed`. The selected live verification therefore used Xcode's native Test
  action through UI automation after resetting a stale test coordinator; no
  shell build or test command substituted for Xcode.
- An opt-in Xcode smoke passed the complete destructive lane on Apple container
  1.0.0: it created a unique two-core/2-GiB Alpine machine, installed the pinned
  K3s release, exported a host-usable kubeconfig, created a namespace,
  Deployment, Service, and standalone Alpine pod, waited for real readiness,
  verified pod logs, loaded those resources through the app service, then
  loaded the standalone Pod's logs through the UID-checked bounded app path.
  It deleted the namespace, stopped and restarted the cluster, rechecked the
  API, and deleted the exact machine. The follow-up exact live run passed in
  114.549 seconds after the log integration; independent CLI inventory found no
  remaining Apple machines afterward, and no temporary kubeconfig directory
  remained.
- The expanded selected Xcode smoke passed 1/1 in 220.603 seconds on My Mac with
  zero failures, skips, expected failures, or runtime warnings. It installed the
  pinned K3s release, loaded inventory and UID-checked logs, scaled the real
  Deployment to two Ready replicas, completed an optimistic restart, opened an
  identity-pinned Pod terminal and exited it cleanly, deleted the workload with
  UID/resourceVersion preconditions, deleted the namespace, then stopped,
  restarted, rechecked, and deleted the exact Apple machine. Independent Apple
  CLI inventory found only the pre-existing stopped BuildKit helper afterward,
  and temporary-directory inspection found no smoke residue.
- The most recent complete deterministic Xcode checkpoint containing all three
  workload mutation implementations is `c7e04e9`: all 985 outcomes completed,
  with 963 deterministic tests passing, 22 explicit live gates skipped, and no
  failures or unrun outcomes. Later benchmark-only commits do not alter the
  Kubernetes production paths, but their exact-head full plan remains tracked
  separately under the performance checkpoint.
- At the earlier Pod-log checkpoint, Xcode build-for-testing succeeded with zero
  warnings. That default plan passed all 975 outcomes: 953 deterministic tests
  passed, 22 explicit live
  gates skipped, and no outcome failed or remained unrun. The normal app
  launched in 3.852 seconds as PID 60426 and Xcode stopped that exact process;
  its only console errors were the existing macOS 27 beta
  SetStore/CoreSpotlight failures before the Pod-log slice. The new Pod-log
  preview returned an Xcode `SchemeBuildError` despite the clean scheme build,
  and its stale preview session cancelled subsequent Run/Test actions; a fresh
  launch and all four Kubernetes canvas renders therefore remain unclaimed for
  this exact head rather than being inferred from the successful tests.

## GUI Linux VM clone and transfer checkpoint

- Stopped GUI Linux guests now use the production VM clone and `.nativevm`
  transfer transactions instead of stopping at runtime/share parity. The
  library selects the Linux runtime lease, the shared preparer copies through
  cancellable clone/sparse transfer, and the Linux row exposes Clone and Export
  only when no runtime owns the installed guest.
- Preserve export/import keeps the manifest UUID, opaque
  `VZGenericMachineIdentifier`, EFI/NVRAM, disk, clipboard choice, and stable
  MAC. Portable packages remove security-scoped shared-folder bookmarks and
  reject installer media or macOS-only platform residue.
- Same-host clone and copy import generate a fresh generic machine identifier
  and locally administered MAC. The preparer requires a valid, distinct source
  pair; commit checks identifier and normalized-MAC collisions against the
  current library before atomic publication. Apple's random MAC API does not
  promise uniqueness, so planning retries bounded candidates rather than
  assuming randomness is a conditional token.
- Focused model/service coverage now exercises Linux same-host cloning,
  identity-preserving portable round trip, copy-import identity rotation,
  shared-bookmark stripping, and network-identity collision rejection. The
  exact-head Xcode build-for-testing and full test suite pass through Xcode MCP.

## Cross-guest GUI VM networking checkpoint

- GUI Linux no longer hardcodes `VZNATNetworkDeviceAttachment`. Its persisted
  revisioned network choice now flows through a Linux runtime-lease service and
  the same focused device factory already used by macOS.
- The composition root owns one shared and one host-only vmnet logical network
  and injects the same pool into both guest factories. Automatic NAT remains
  private with outbound access; shared mode lets participating macOS/Linux VMs,
  the host, and external networks communicate; host-only omits external access.
- The Linux configuration screen uses the shared native mode selector. Edits
  are disabled until platform preparation completes and whenever a runtime or
  another app instance owns the bundle. Accepted changes apply on the next cold
  start. Same-host clone preserves the mode, while portable package preparation
  clears it to NAT independently of the stable Linux MAC.
- Focused tests cover Linux lease-backed persistence, app-model reuse,
  same-host and portable policy, and one real shared vmnet object reused by a
  Linux configuration and a peer device. Thirteen focused tests pass. The
  exact-head normal build and build-for-testing pass on the `NativeContainers`
  scheme for `My Mac` (arm64, macOS 27.0); the full suite reports 1,016 passed,
  zero failed, and 29 explicitly gated live/destructive tests skipped.
- A Linux-specific network preview is checked in. Xcode compiled it, but the
  canvas host timed out twice while launching `NativeContainers.app`; an
  ordinary Xcode MCP launch succeeded immediately. Its only captured live log
  was the existing Core Spotlight/SetStore donation failure. Static canvas
  inspection and live cross-guest packet flow therefore remain in the
  disposable installed-guest smoke pass rather than being inferred.

## Cross-guest VM compute configuration checkpoint

- The selected-VM configuration screen now stages and applies virtual CPU and
  memory changes for both macOS and GUI Linux. The editor uses Apple's current
  host minimums and maximums, keeps disk capacity visibly separate, refreshes
  inventory after a successful write, and applies changes on the next cold
  start.
- Guest-specific services acquire the existing generation-pinned runtime lease,
  revalidate the complete compute state observed by that lease, preserve disk
  capacity, and atomically persist only CPU and memory. macOS also rejects a
  saved checkpoint; its existing configuration descriptor already fingerprints
  both values.
- New macOS preparations persist the selected restore image's minimum supported
  CPU count and memory size. The editor cannot cross those requirements. Older
  bundles decode without migration and conservatively use their current
  allocation as the floor. Clone and portable transfer retain both allocation
  and requirements; transfer preparation and commit validation reject partial,
  unaligned, guest-incompatible, or allocation-exceeding requirement metadata.
- Twenty-four focused model/service/library/compatibility tests pass. The
  exact-head normal build and build-for-testing have zero Xcode warnings, and
  the full plan reports 1,035 passed, zero failed, and 29 explicitly gated
  live/destructive tests skipped. Xcode launched the app as PID 67457 and
  stopped that exact process; its only logs were the existing Core
  Spotlight/SetStore donation failures. Xcode compiled the standalone compute
  preview, but its canvas host
  hit the same `NativeContainers.app` launch timeout as the networking preview,
  so no rendered-image claim is inferred.

## Cross-guest VM rename checkpoint

- The selected-VM configuration screen now includes a shared General section
  for renaming both macOS and GUI Linux machines. It stages edits, trims the
  persisted value, rejects an empty label, preserves unsaved user input across
  unrelated manifest refreshes, and updates inventory/navigation only after a
  successful atomic write.
- Guest-specific services acquire the existing stopped runtime lease and
  revalidate the name observed by that exact lease before changing only
  `name` and `updatedAt`. The manifest UUID, canonical bundle path, guest
  platform and network identity, disks, resources, and device configuration do
  not change. macOS saved state remains valid because the configuration
  fingerprint is untouched; runtime ownership, transitions, and disk
  maintenance still block editing.
- Fourteen focused model/policy/service/library/composition checks pass. The
  exact-head normal build and build-for-testing are warning-free, and the full
  plan reports 1,047 passed, zero failed, and 29 explicitly gated
  live/destructive tests skipped. Xcode launched the app as PID 29559 and
  stopped that exact process; its only logs were the existing Core
  Spotlight/SetStore donation failures. The standalone rename preview hit the
  existing `PreviewsFoundationHost.TaskTimeoutError`, so no rendered-image
  claim is inferred.

## GUI Linux same-host suspend checkpoint

- Apple's installed Virtualization documentation confirms that saved-state
  methods live on guest-neutral `VZVirtualMachine`: save requires paused,
  restore requires stopped and returns paused, and
  `validateSaveRestoreSupport()` is the exact-configuration authority. A
  focused Xcode-run check proves the app's installed EFI Linux topology passes
  that validation.
- GUI Linux now uses the same actor-isolated, lease-borrowed, crash-recovered
  transaction core as macOS. Its own fingerprint covers generic machine
  identity, writable disk and EFI/NVRAM identities, optional installer,
  compute, stable MAC/network revision, graphics/audio/input/entropy/balloon,
  SPICE clipboard, and VirtioFS share semantics. Display-name changes remain
  compatible.
- Suspend pauses and atomically saves before power-off. A later Start consumes
  the checkpoint, restores to paused, and resumes. The native runtime and row
  views expose Suspended, Resume, confirmed Start Fresh/Discard Saved State,
  incompatibility diagnostics, and configuration-specific unavailability.
  Installer ejection disables suspend for that live generation until restart
  because its launched topology changed.
- Compute, network, and shared-folder changes now reject Linux saved state.
  Clone/export continue to strip host-local state, while guest-aware storage
  reclamation routes Linux candidates through Linux runtime leases.
- Fifty-two focused capability, shared-store regression, Linux transaction,
  fingerprint, lifecycle, edit-exclusion, and reclamation checks pass. The full
  Xcode plan reports 1,059 passed, zero failed, and 29 explicitly gated
  live/destructive checks skipped; build-for-testing succeeds on
  `NativeContainers` / `My Mac` (arm64, macOS 27.0), and the normal build is
  warning-free. Xcode launched and stopped PID 95072; its only error logs were
  the existing Core Spotlight/SetStore donation failures. The existing Linux
  VM preview still hits Xcode's `NativeContainers.app` 30-second canvas launch
  timeout, so no rendered-image claim is inferred. A real
  installed-distribution suspend/restore remains in the disposable guest smoke
  pass.

## Cross-guest VM disk growth checkpoint

- Stopped macOS and GUI Linux guests now share one DiskImageKit-backed grow
  transaction instead of treating capacity as a compute field. The service
  rejects saved state and shrink, revalidates live block geometry against the
  manifest, seals the exact app-owned file, and holds the guest-specific
  runtime lease through a compare-and-swap-style manifest commit. Standalone
  RAW/ASIF images open explicitly read-write; either guest's snapshot stack
  opens only its active overlay read-write after exact ordered stack validation.
- A mode-0600 `.DiskImageResize.json` journal advances only through `planned`,
  `imageExtended`, and `manifestUpdated`. The image and journal are fully
  synchronized, recovery recognizes extension-before-phase and
  commit-before-phase crashes, and cancellation is intentionally unavailable
  after publication because rollback would require unsafe shrink. Ordinary
  runtime, disk replacement, discard, clone, export, and import reject pending
  growth; launch recovery alone receives the recovery-capable lease and reports
  per-VM failures or external ownership without guessing.
- Native macOS and Linux configuration sections show current capacity, accept a
  whole-GiB larger target, require confirmation, disable competing row actions,
  and state that the guest partition and file system must still be expanded.
  There is no shrink action or claim of automatic guest partitioning.
- Snapshot restore now creates its fresh active layer with
  `overlay(blockCount:)` at the manifest's current capacity. A real
  DiskImageKit regression grows an active overlay beyond its base and proves
  the assembled restored stack keeps the larger size, closing the case where a
  checkpoint captured before growth could otherwise shrink the virtual device.
- Xcode DocumentationSearch confirmed the installed macOS 27 truncate,
  read-write, stack, and explicit-overlay contracts. The isolated snippet
  compiled behind the required availability gate but hit the existing
  30-second `NativeContainers.app` snippet-host launch timeout, so runtime
  evidence comes from real RAW, ASIF, overlay-stack, recovery, lease, transfer,
  snapshot, model, and startup tests.
- Xcode MCP build-for-testing passes and discovers 1,100 enabled tests. The
  complete plan reports 1,106 outcomes: 1,077 passed, zero failed or unrun, and
  29 explicitly gated live/destructive checks skipped. The normal
  `NativeContainers` / `My Mac` build passes in 6.3 seconds with zero warning
  entries. Xcode launched PID 2694 and stopped that exact process; its two error
  logs were the existing Core Spotlight `SetStoreUpdateService` donation
  failures. Strict Swift formatting, the accessibility contract, the repaired
  data-migration contract, and diff whitespace checks pass.

## Cross-guest runtime memory target checkpoint

- Xcode DocumentationSearch confirmed the installed Virtualization contract:
  one configured Virtio balloon becomes a runtime device, its mutable target is
  available while the VM runs, targets are MiB-aligned and capped by configured
  memory, and a lower target only asks the guest to return pages. The target
  does not measure guest compliance or host bytes reclaimed.
- macOS and GUI Linux engine sessions now expose that device through one
  focused adapter. Guest runtime services require the exact current generation,
  no concurrent lifecycle transition, and a running state before mutation.
  Snapshots and native full/75%/50%/minimum controls carry only the requested
  target; a visible notice states that reclamation is cooperative.
- Linux keeps at least the greater of Apple's host floor and 1 GiB. macOS uses
  its persisted restore-image minimum; an older bundle with no minimum evidence
  conservatively remains at its configured allocation. Percentage presets below
  the floor are omitted. No reduced target is persisted in the manifest, and a
  cold session returns to the full configured allocation.
- Build-for-testing and the normal `NativeContainers` / `My Mac` build pass;
  the normal build completes in 4.457 seconds with no warning entries. The
  complete plan reports 1,112 outcomes: 1,083 passed, zero failed or unrun, and
  29 explicitly gated live/destructive checks skipped. The focused memory-policy
  plus complete macOS/Linux runtime-service selection passes 46/46. Xcode
  launched PID 2560 and stopped that exact process; its only error logs were
  the two existing Core Spotlight `SetStoreUpdateService` donation failures.
  The standalone control preview compiled, but its canvas host hit the existing
  30-second `NativeContainers.app` launch timeout, so no rendered-image claim
  is inferred.
- A disposable installed Linux guest and a disposable macOS guest still need
  live under-load target-lower/restore-to-full observation. That pass must
  report requested targets separately from host memory measurements and must
  not infer full reclamation from a successful property assignment.

## Cross-guest VM disk snapshot checkpoint

- The bounded DiskImageKit snapshot lane now serves stopped macOS and GUI Linux
  VMs through one domain, observable model, layer store, transaction engine, and
  SwiftUI section. Small guest adapters acquire the matching generation-pinned
  runtime lease, inspect the matching saved-state store, and compare-and-swap
  the guest-scoped manifest value. Linux installer state is rejected until the
  VM is fully installed.
- Linux bundle resolution now validates the ordered canonical overlay paths,
  and the Linux Virtualization configuration uses the same DiskImage-backed VZ
  attachment as macOS. The base and frozen layers open read-only; only the top
  overlay receives writes. Linux configuration descriptors and saved-state
  fingerprints include the snapshot revision, paths, and stable identity of
  every layer, invalidating incompatible suspended memory state.
- Active-overlay disk growth, same-host clone, portable export/import, and exact
  staged-bundle validation now preserve Linux snapshot history. Unknown, extra,
  missing, linked, or guest-incompatible artifacts fail closed; recognized
  post-commit residue remains recoverable by the next snapshot transaction.
- The Linux configuration screen exposes the same create/restore-to-prune
  controls, progress, saved-state discard action, eight-checkpoint bound, and
  maintenance mutual exclusion as macOS. Disk snapshots remain stopped-only;
  no live, merge, flatten, arbitrary-delete, or automatic guest-filesystem
  behavior is claimed.
- Xcode DocumentationSearch confirmed that `VZDiskImageStorageDeviceAttachment`
  accepts single and stacked DiskImageKit images and that an explicit overlay
  block count controls stack capacity. Build-for-testing passes. The focused
  Linux adapter, app routing, and cross-layer regressions pass 14/14, including
  real overlay attachment, persistence, fingerprint invalidation, active-layer
  growth, clone, and portable import. The complete Xcode plan reports 1,125
  outcomes: 1,096 passed, zero failed or unrun, and 29 explicitly gated
  live/destructive checks skipped. The warning-level build log is empty. Xcode
  launched PID 17580 and stopped that exact process; its only error logs were
  the two existing Core Spotlight `SetStoreUpdateService` donation failures.
  The shared snapshot-section preview compiled but hit the existing 30-second
  `NativeContainers.app` canvas launch timeout, so no rendered-image claim is
  inferred. Live guest-write and restore behavior still need the disposable
  installed-guest pass.

## Detached VM console window checkpoint

- Apple's installed SwiftUI documentation confirms that a data-presenting
  `WindowGroup` persists its lightweight `Codable`/`Hashable` value and that
  `openWindow(id:value:)` brings an existing window for the same value forward.
  The VM list now uses that path instead of a modal runtime sheet. One request
  pins the manifest UUID plus immutable guest family, so macOS and GUI Linux
  each receive one native, system-restorable console window per VM.
- A restored window resolves the current canonical manifest and reuses the
  app-scoped runtime and USB models. Rename and inventory changes therefore
  appear without persisting a stale manifest, while a missing or guest-mismatched
  VM fails closed into an inert unavailable view. The request contains no live
  `VZVirtualMachine`, adaptor, console generation, saved-state choice, or
  auto-start intent; reopening the app cannot boot a guest merely to restore a
  window.
- Focused Codable/current-manifest/mismatch routing checks pass 3/3. The complete
  Xcode plan reports 1,128 outcomes: 1,099 passed, zero failed or unrun, and 29
  explicitly gated live/destructive checks skipped. Build-for-testing succeeds,
  and the normal `NativeContainers` / `My Mac` build completes in 3.612 seconds
  with no warning entries. Every changed Swift file passes strict
  `swift-format`; the accessibility and data-migration contract validators pass.
- Xcode launched PID 22783 and stopped that exact process. A debugger-attached
  launch also confirmed a visible SwiftUI app window titled `Overview`; Xcode
  stopped PID 24659, and no NativeContainers process remained. Runtime output
  contained only the two existing Core Spotlight `SetStoreUpdateService`
  donation failures. The dedicated VM-window preview compiled but hit
  `PreviewsFoundationHost.TaskTimeoutError`, so no rendered-image claim is
  inferred. A disposable installed guest is still required to exercise the
  actual graphical display and input in the detached window.

## Stopped container filesystem export checkpoint

- Apple container 1.0.0's public client and pinned source confirm an ID-only
  `ContainerClient.export(id:archive:)` route. The server requires a stopped
  container and exports only its EXT4 rootfs as an uncompressed restricted-PAX
  tar. NativeContainers now exposes that exact capability from the stopped
  inspector rather than spawning the CLI or approximating it with recursive
  copy. The review sheet states that named volumes, bind mounts, process state,
  and VM state are excluded.
- A request freezes ID plus creation timestamp. The service re-fetches that
  exact identity and stopped state before and after Apple's route. Apple writes
  only into one owner-controlled, mode-0700, advisory-locked private operation
  directory; accepted XPC work settles before caller cancellation may remove
  it. A later operation removes recognized unlocked residue and preserves
  cross-process locked work.
- User publication is independent of the Apple service. It pins and revalidates
  the selected parent descriptor, rejects every existing file/directory/link,
  validates the staged archive as owner-owned, regular, single-link, and
  nonempty, then copies and SHA-256 hashes into an exclusive hidden sibling,
  flushes it, and commits with `RENAME_EXCL` plus parent `fsync`. Destination,
  parent, container identity, or state drift leaves the final path untouched.
- Ten focused request/service tests cover successful bytes/digest/mode,
  stopped and identity gates, post-export replacement, existing and raced
  destinations, symlinks and unsafe parents, transport failure, accepted-work
  cancellation, and lock-aware residue recovery; three observable-model tests
  cover success, failure, and retained partial completion. The complete Xcode
  plan reports 1,142 outcomes: 1,112 passed, 30 explicit live/destructive skips,
  zero failed, and zero unrun. Build-for-testing and the normal
  `NativeContainers` / `My Mac` build succeed; the latter completed in 3.871
  seconds with an empty warning log. Changed Swift files pass strict
  `swift-format`, and both repository contract validators pass.
- The gated `exportStoppedRootFilesystemAndCleanUp()` smoke passes 1/1 through
  Xcode against Apple container 1.0.0 and the already-local Alpine 3.21 image.
  It creates a uniquely named container whose init writes a unique rootfs
  marker, waits for the exact record to stop, exports through the production
  `AppleContainerService`, and verifies the committed file's mode, byte count,
  SHA-256, tar member, and contents. A second attempt proves an existing archive
  is preserved, with no new staging directory or hidden partial sibling. The
  test deletes the exact container and its private output; post-run Apple
  inventory, temporary-output, staging, and process checks were empty.
- The dedicated export preview compiled, but Xcode's renderer timed out waiting
  for its app host inside the canvas's 30-second limit, so no rendered-image
  claim is inferred. Its residual exact process was terminated through Xcode's
  debugger. The actual app launched through Xcode as PID 35888 with a visible
  `Overview` window and was stopped through Xcode. A later Xcode snippet attempt
  timed out before its code executed and left PID 37951; Xcode's debugger
  terminated that exact process from cleanup host PID 38310, then Xcode stopped
  the cleanup host. No app or worker process remained. The gated test above,
  not either timed-out app-host attempt, is the live Apple-service evidence.

## Official Ubuntu ARM64 Virtualization smoke checkpoint

- Ubuntu's official 26.04 LTS release supplies a generic ARM64 desktop ISO. The
  3.9-GB image is retained in the host's `Downloads/NativeContainers-Fixtures`
  directory, and both an independent host hash plus the gated test matched the
  published SHA-256
  `c2afd538d66fdd77377d03f1ed2ac76a34f1c116baecc9a8170d68f833121f57`.
- `bootsReviewedInstallerAndCleansIsolatedBundle()` adds a reusable destructive
  gate requiring `NATIVECONTAINERS_LIVE_LINUX_VM=1`, an explicit local ISO path,
  and its reviewed digest. An optional bounded
  `NATIVECONTAINERS_LIVE_LINUX_VM_VISUAL_SECONDS` value from 1 through 7,200
  presents the exact production `VirtualMachineConsoleView` and publishes its
  visible native window number for operator capture. With
  `NATIVECONTAINERS_LIVE_LINUX_VM_INPUT_PROBE=1`, a mode-0700, 4-KiB-bounded,
  allowlisted command channel sends keyboard, pointer, and short text events to
  that production view; its mode-0600 marker acknowledges each command and an
  explicit `finish` continues lifecycle cleanup. The gate creates a mode-0700
  temporary library, copies the ISO through the production media service,
  prepares persistent EFI/NVRAM, generic-machine, MAC, and 64-GiB sparse-disk
  artifacts, then starts the exact production
  `AppleLinuxVirtualMachineRuntimeEngine` configuration.
- The live Xcode run passed 1/1 for VM ID
  `6a2eef4f-56b3-472a-8c05-725711af255b`. It confirmed the runtime and underlying
  `VZVirtualMachine` stayed running for ten seconds with installation media and
  a native console object, then confirmed pause, resume, 8-to-4-to-8-GiB
  balloon requests, exact force stop, manifest deletion, and complete isolated
  library cleanup. The temporary `/private/tmp` ISO clone was also removed.
- A follow-up Xcode MCP visual run passed 1/1 for VM ID
  `c3db69d1-c675-478a-8bd8-4ef59a5773f1`. It held native window 14856 for 120
  seconds and a direct window capture showed the production console rendering
  Ubuntu's orange boot mark, wordmark, and activity spinner. The same run then
  passed pause/resume, balloon, force-stop, manifest-deletion, and empty-library
  postconditions; its ready marker, VM library, app process, and temporary ISO
  clone were absent afterward.
- A 240-second follow-up reached the full Ubuntu 26.04 GNOME live desktop, and
  a later direct capture reached the actual `Welcome to Ubuntu` language page.
  This closes the gap between a firmware splash and a rendered graphical guest
  session without claiming that installation completed.
- The command-driven Xcode run passed 1/1 for VM ID
  `fca19ab1-a719-4665-9013-2bf0ce76c89e` in native window 16808. The in-process
  probe sent Down, Up, and Return through the real nested
  `VZVirtualMachineView`, preserving the intended Ubuntu boot. Owner-only
  commands `c1` and `c2` then clicked the English row and Next control; both
  were acknowledged, and the post-command capture had left the Welcome page
  for the installer's transition window. `done` ended the hold, after which the
  same run confirmed pause/resume, 8-to-4-to-8-GiB balloon requests, force stop,
  manifest deletion, and complete isolated-library cleanup.
- The extended one-shot run for VM ID
  `56b04fcf-e464-4cf0-9b28-564d4aead54b` completed the graphical Ubuntu
  installer and passed 1/1 after 1,413.327 seconds. It persisted production
  media ejection, pause/resume, 8-to-4-to-8-GiB balloon requests, force stop,
  manifest deletion, and isolated-library cleanup. Ejecting at the installer's
  completion screen also exposed the expected SQUASHFS read failure while the
  live root still depended on that device, so that run is installation and
  ejection evidence but is intentionally not used as disk-boot evidence.
- A corrected run retained the ISO through Ubuntu's own Restart action. VM ID
  `64926411-0e77-4ff6-aaca-0f6e8d903b28` rebooted to the installed-disk login
  screen, authenticated into the installed GNOME first-run desktop, and only
  then ejected the now-unused ISO through
  `LinuxVirtualMachineRuntimeService`. The manifest immediately persisted
  `installState: stopped` with no installation-media path while the guest kept
  running. The Xcode result passed 1/1 after 1,263.100 seconds and then proved
  pause/resume, balloon requests, exact force stop, manifest deletion, empty
  library cleanup, and removal of the test host, marker, and input channel.
- The installed-guest VirtioFS run passed 1/1 for VM ID
  `ba1a3b9c-80e2-41d2-a754-f58180dc00f0` after 1,609.930 seconds. Before start,
  the one-shot request added one read-only and one read-write host directory
  through `LinuxVirtualMachineSharedDirectoryService`; the runtime then resolved
  both security-scoped bookmarks into the production `nativecontainers`
  multiple-directory share. After the graphical install, disk reboot, login,
  first-run completion, and production ISO ejection, installed Ubuntu mounted
  that exact tag. A guest operation matched the read-write marker and created a
  single-link regular `guest-write.txt` on the reviewed host directory. The
  equivalent operation against the read-only marker returned `Permission
  denied`, and host inspection confirmed that no file appeared there. The same
  Xcode result then confirmed pause/resume, balloon requests, exact force stop,
  manifest deletion, and complete isolated-library cleanup. Both host fixtures,
  every marker/input channel, and the test-host process were removed afterward.
- A separate live-desktop run passed 1/1 for VM ID
  `d837b100-6a7a-48b5-a11e-2531f3e471c2` after 475.564 seconds. In the native
  console, `wpctl status` exposed `virtio 1.0 sound Stereo`, `aplay -l` exposed
  card 0 `VirtIO SoundCard` with the `virtio-snd` playback device, and a bounded
  mono 48-kHz `speaker-test` opened the default device, completed a sine period,
  and returned without a device error. This verifies the Linux guest's Virtio
  playback path; no audio capture or human listening assertion is used to claim
  that the host output was audible.
- The live runs also exposed that modifier flags embedded only in key-down/up
  events were not enough for the nested `VZVirtualMachineView`, and that generic
  flags alone were still insufficient on explicit `flagsChanged` events. The
  harness now carries AppKit's left-device bits through each Shift, Control, and
  Option press/release transition and the chord's key-down/up events. VM ID
  `904304a6-bcfb-4add-8bff-e9e1de312347` passed 1/1 after 204.246 seconds while
  the synthetic Control-Option-T command opened Terminal and `echo MODIFIEROK`
  arrived and printed with uppercase preserved. The transition test asserts
  both device-independent semantics and exact device-bearing flag values.
- The installed cold-reconfiguration run passed 1/1 for VM ID
  `fd41647b-54a4-4b41-9392-3f973f6c3168` after 1,559.686 seconds. Installed
  Ubuntu first reported 4 CPUs and a 68,719,476,736-byte `vda`; production
  media ejection persisted before `requestStop` completed in under four
  seconds. `LinuxVirtualMachineComputeService` then committed 2 CPUs and
  6,442,450,944 bytes of memory, while
  `VirtualMachineDiskImageResizeService` grew the sparse RAW image and
  manifest from 68,719,476,736 to 77,309,411,328 bytes with no pending
  journal. On the cold start, `nproc` returned 2, `MemTotal` reflected the
  6-GiB configuration, and `lsblk -b` reported the exact 77,309,411,328-byte
  disk while root partition `vda2` remained 67,590,160,384 bytes. Guest
  `growpart` expanded `vda2` to 76,181,126,656 bytes and online `resize2fs`
  completed at 18,898,907 4-KiB blocks. A further guest reboot preserved the
  2-CPU topology, reduced memory, expanded partition, and expanded root
  filesystem. The result then force-stopped the exact active generation,
  deleted its manifest and sparse image, removed both command channels and
  markers, and reported `cold_reconfiguration=confirmed` with no residue.
- After the cold-reconfiguration harness and result-marker changes, the four
  focused request tests pass. The complete Xcode plan reports 1,151 outcomes:
  1,120 passed, 31 explicit live/destructive gates skipped, zero failed, and
  zero unrun. Build-for-testing passed in 4.111 seconds and the normal
  `NativeContainers` / `My Mac` build passed in 3.999 seconds. Xcode reports
  zero diagnostics in the changed test file and zero warning-level Issue
  Navigator items; strict Swift formatting, both repository contract
  validators, and diff whitespace validation pass.
- One intermediate corrected-sequence attempt failed safely after 219.366
  seconds because the allowlisted text channel rejected `!` before any disk
  write. Xcode reported `.unsupportedInputCharacter("!")`, force-stopped the
  exact guest, and removed its isolated bundle. The successful retry used an
  alphanumeric disposable credential within the existing input policy.
- After the installed-disk pass, the complete Xcode plan reports 1,147
  outcomes: 1,116 passed, 31 explicit live/destructive gates skipped, zero
  failed, and zero unrun. Build-for-testing completed in 2.667 seconds and the
  normal `NativeContainers` / `My Mac` build completed in 3.818 seconds. The
  warning-level build log and Issue Navigator are empty; both repository
  contract validators and diff whitespace checks pass.
- Xcode MCP's current test request stops waiting at about 300 seconds, so its
  automated runs use the explicit `finish` command while direct Xcode
  observation may use the harness's 7,200-second maximum. A current-user,
  mode-0600, single-link regular JSON request provides the reviewed ISO digest,
  hold, input, and required-media-ejection policy to one Xcode run and is
  consumed before the VM starts. The input channel likewise rejects symbolic
  and multiply linked command files. One exploratory
  over-bound run required cleanup after Xcode's Stop action also timed out; only
  that exact current test host and uniquely named temporary bundle were
  removed. The unrelated long-lived app process was left untouched, and no
  current test host, marker, input channel, or live-VM bundle remained.
- After restoring the opt-in gate, Xcode reported zero diagnostics in the
  changed test file, build-for-testing passed in 9.195 seconds, and the focused
  normal-config test skipped 1/1. The complete plan reports 1,143 outcomes:
  1,112 passed, 31 explicit live/destructive gates skipped, zero failed, and
  zero unrun. The normal app build passed in 3.672 seconds with empty warning
  output and no warning-level Issue Navigator entries; strict formatting, both
  repository contract validators, and diff whitespace checks also pass.
- A first attempt against the Downloads path stalled before creating a VM
  bundle; the identical clone's successful run is consistent with an app-host
  privacy boundary. After Xcode MCP's Stop action also timed out, only the exact
  idle app-host PIDs were terminated. The successful retry used the hash-pinned
  APFS clone in `/private/tmp`. After the visual run, build-for-testing passed
  in 8.982 seconds, the normal gated focused test skipped 1/1, all 1,143 full
  suite outcomes completed with 1,112 passes and 31 expected live-gate skips,
  and the 3.444-second app build had an empty warning log. No VM bundle,
  temporary library, app process, or build worker remains.
- This checkpoint proves real firmware/installer-backed VZ start, rendered
  GRUB, live-desktop and installer frames, completed graphical installation,
  reboot from the virtual disk, installed login and authenticated GNOME
  first-run desktop, keyboard and pointer delivery, persisted production ISO
  ejection, installed-guest mounting of the production VirtioFS tag,
  host-visible read-write mutation, read-only denial, and native runtime control
  in the production console. The separate live-desktop pass additionally proves
  guest enumeration and successful stream opening through the Virtio audio
  output path. The installed cold pass additionally proves production
  CPU/memory persistence, DiskImageKit growth, manual guest partition and
  filesystem expansion, and reboot persistence. It does not infer audible host
  playback, microphone input, or any broader installed-guest integration not
  exercised by those exact runs.

## Remaining live verification gap

The entitlement, signing configuration, build, capability availability,
hash-pinned Ubuntu ARM64 graphical installation, virtual-disk boot,
authenticated installed desktop, input, media ejection, and core runtime
controls plus read-only/read-write VirtioFS guest semantics and the guest-side
Virtio audio playback path, CPU/memory cold reconfiguration, disk growth,
guest partition/filesystem expansion, and graceful guest stop are verified.
Audible host playback, snapshot rollback, suspend/restore, clone and
portable-copy boot, shared and host-only packet flow, and watchdog stop still
need installed-guest live passes. Installing, booting, saving/restoring, growing
the disk, expanding the macOS container, and clone-booting macOS are not claimed
as live-verified until a local IPSW and disposable installed guest are available
for that destructive integration pass.

## Next implementation slice

1. Reuse the verified hash-pinned Ubuntu 26.04 ARM64 install/disk-boot workflow
   to capture or human-confirm host-audible playback; create a named disk
   checkpoint, mutate guest storage, restore it, and verify both data rollback
   and retained virtual capacity; suspend and restore the installed session,
   request a lower memory target under guest load, restore the full target,
   record host observations without treating the request as guaranteed
   reclamation, verify shared and host-only vmnet connectivity, clone and
   portable-round-trip it, and exercise the watchdog force-stop fallback.
2. Live-verify the implemented macOS installer, lifecycle service, force-stop
   recovery, console, CPU/memory reconfiguration, disk growth plus APFS
   container expansion, cooperative lower/full runtime memory targets,
   same-host save/restore, and fresh-identity clone boot against a local IPSW.
3. Live-verify a second reviewed Up that grows a real pinned Socktainer project
   from a contiguous replica prefix, including stable metadata and exact Apple
   attachment observations. Keep recreation blocked until the pinned bridge
   implements rename and network attachment routes.
4. Provision a Developer ID Application identity, run Xcode's Developer ID
   distribution and notarization flow, then pass the strict stapled-product
   validator before calling the app publicly distributable.

## External Apple runtime distribution checkpoint

- ADR-006’s proposed namespaced embedded runtime is superseded by ADR-088. The
  pinned Apple 1.0.0 source and installed package show that the supported runtime
  is an administrator-installed, multi-binary package under `/usr/local`, while
  `ClientHealthCheck`, `ContainerClient`, the image/volume clients,
  `MachineClient`, and `system start` use fixed `com.apple.container.*` Mach
  services. Shipping an isolated copy would require a maintained client,
  service, launchd, plugin, updater, and signing fork rather than a different app
  bundle layout. NativeContainers now makes Apple’s signed 1.0.0 system runtime
  an explicit external prerequisite.
- Overview links to Apple’s exact signed 1.0.0 release and exposes a separate
  **Start Apple Runtime** recovery action. The action requires the fixed
  `/usr/local/bin/container` path to be a root-owned, single-link,
  non-group/world-writable regular executable with Apple team `UPBK2H6LZM` and
  signing identifier `com.apple.container.cli`. It accepts only version 1.0.0,
  bounds command output and startup time, invokes
  `system start --enable-kernel-install`, and refreshes app inventory only after
  both container and machine endpoints respond. It never downloads an
  installer, requests elevation, invokes `installer`, updates, uninstalls, or
  re-signs Apple code.
- A repeatable runtime-distribution source gate keeps the Swift package pin,
  runtime version, package receipt, executable path, release URL, signing
  identity, architecture docs, migration authority, roadmap, and archive rule
  aligned. The artifact validator now rejects Apple CLI, API-server, plugin,
  updater, or uninstaller payloads anywhere in the app. It passes against the
  current Xcode-built development app, and a private cloned app with an injected
  `Contents/Helpers/container` payload fails with the expected external-runtime
  error.
- On the exact `aa3ed1e` tree, the installed receipt is
  `com.apple.container-installer` 1.0.0 under `/usr/local` and the running API
  server reports 1.0.0 commit `ee848e3ebfd7c73b04dd419683be54fb450b8779`.
  The live service was not stopped merely to exercise recovery; the focused
  command/version/re-probe and AppModel coverage passes 10/10 without mutating
  the user runtime. The full Xcode plan reports 1,162 outcomes: 1,131 passed,
  zero failed or unrun, and 31 explicit live/destructive gates skipped.
  Build-for-testing completed in 4.823 seconds and the normal
  `NativeContainers` / `My Mac` build completed in 3.625 seconds with no warning
  log or Issue Navigator entries. The runtime-distribution, accessibility, and
  data-migration validators, strict formatting for every changed Swift file,
  and diff whitespace checks pass.
- The runtime-unavailable SwiftUI preview compiled but Xcode’s preview host did
  not launch the app within its 30-second window, so no rendered-image claim is
  inferred. Xcode’s Stop action was issued for that preview launch. No device
  interaction session was opened and no project capability, entitlement, build
  setting, scheme, or destination was changed.

## Capability availability and contract checkpoint

- The macOS 27 menu-bar control is available again without the looping SwiftUI
  scene. `MenuBarExtra` is removed; one app-scoped `NSStatusItem` presents the
  existing quick-controls view in an `NSPopover` and continues to use the shared
  `AppModel`, lifecycle services, routes, errors, and visibility preference. A
  post-launch installer captures window and Settings actions only after the main
  scene exists. The app-hosted controller test creates a real status item on
  macOS 27, confirms that construction alone has no AppKit side effect, and
  removes the item cleanly.
- Physical USB is classified as **Blocked**, not complete. The current signed
  target still lacks `com.apple.developer.accessory-access.usb`; Xcode MCP exposes
  no capability action for that key. Composition now publishes the exact
  code-signature blocker, and rejected service actions preserve the same reason.
  No entitlement, capability, signing setting, scheme, or destination was
  changed.
- Settings and the feature matrix now enumerate all eight performance-contract
  requirements: zero complete, five partial, and three missing. Existing local
  and opt-in lanes remain intact, while warm container start, 10/50-container
  density, post-stress retention, bind-mount metadata, PostgreSQL durability,
  image-pull/disk-growth, comparative NAT/direct-IP, and sleep/wake/crash gaps
  remain explicitly open as applicable.
- The pinned Compose report now presents recreation, network aliases, health
  checks, restart policies, configs, and secrets as separate upstream-blocked
  results. The report has four supported fixtures and eight gaps; fresh and
  create-missing Up remain distinct from replacement. Persistent Apple-machine
  snapshots/backups and build-time SSH are separate upstream-blocked feature
  rows because Apple container 1.0 exposes neither mutation contract.
- `scripts/validate-capability-claims.sh` binds those states to source and docs.
  It passes together with the runtime-distribution, accessibility, and
  data-migration validators and diff whitespace checks. Strict formatting passes
  for every changed Swift file.
- The complete Xcode test plan reports 1,164 outcomes: 1,133 passed, 31 explicit
  live/destructive gates skipped, and zero failed or unrun. Build-for-testing
  completed in 17.648 seconds; the final normal `NativeContainers` / `My Mac`
  build completed in 6.326 seconds with no warning-level build-log entries.
  A pre-existing app process prevented an isolated current-head window launch,
  so it was left untouched and no visual or idle-CPU claim is inferred from it.

## Compose inputs and NativeContainers runtime checkpoint

- Compose config/secret review is implemented as a two-stage discovery and
  review boundary. Environment values remain in an in-memory vault; Keychain
  HMAC seals, descriptor-relative file validation, bounded mode-0400 stable
  copies, redacted child-process diagnostics, final-overlay hashes, and the
  reserved service input-seal label make changed inputs require replacement.
  File, environment, and literal config sources plus file and environment secret
  sources have deterministic coverage. Execution remains blocked: live tests
  against signed Socktainer 1.0.0 proved that Apple host mounts reject files and
  pre-start archive injection has no container root filesystem. The app does not
  approximate those semantics or advertise the dormant path as supported.
- Signed-release conformance now requires 41 observed semantic scenarios before
  recreation, aliases, health checks, or restart policies can be enabled: eight
  recreation, seven alias, sixteen health, and ten restart-policy cases. Every
  case requires a state postcondition, so HTTP 200 no-ops cannot satisfy the
  gate. Socktainer 1.0.0 passes none of those scenarios and all four features
  remain upstream-blocked.
- The sibling forks are immutably pinned at `container` `1.0.0-nc.2` revision
  `3abca3683c9dd81d1ce3a1b20c13688b2e0888e6` and builder shim
  `0.12.0-nc.2` revision `f66f1680fe6b74d814fb5527247e7d81227fcecb`.
  The reproducible Linux/arm64 OCI archive has SHA-256
  `d872daa5ff4534aeb18fb747e015e56cef1cd1b584e05d725b72b624b41a7680`
  and resolved manifest digest
  `sha256:b3574dc6b867fc91d1ed1d2941c74811961e2645ffa4c1fc68c19ae69e5fdbff`.
  The fork keeps Apple-compatible Mach names, restores Apple’s builder as the
  official default, and selects the exact native image only through the
  separately packaged runtime config.
- Runtime management is reachable in Settings. It verifies package receipts,
  versions, every listed digest, code-signing identities, launch-service paths,
  and active graph ownership before connection or switching. Apple and native
  graphs are mutually exclusive; activation has verified rollback. The one-time
  migration clone runs with both graphs stopped, copies only reviewed persistent
  content/configuration/machine paths into an exclusive staging root, publishes
  atomically, and never changes or deletes Apple’s source data.
- The forked Machine API and native UI implement stopped-only create, list,
  restore, clone, and delete for up to eight snapshots with generation/catalog
  compare-and-swap and crash recovery. Snapshot publication rejects links,
  special files, extra hard links, foreign ownership, and writable group/world
  modes; size reports allocated restorable bytes. Build protocol v7 separately
  forwards only reviewed SSH agent ID `default`, revalidates the socket twice,
  suppresses sensitive diagnostics, and registers no attachable without opt-in.
  Both capabilities remain conditional on an installed, fully verified native
  runtime; no native package is installed on this host.
- Builder-shim Go tests, OCI verification, runtime package preflight/tamper
  tests, the runtime fork’s 21 focused tests, the app’s 120 focused runtime
  tests, and the live official-runtime gate pass. The exact app package pin
  resolves to `1.0.0-nc.2`. The complete app test action reports 1,251 total:
  1,217 passed, 34 explicit live/destructive gates skipped, and zero failures;
  its result bundle reports zero build warnings or errors. All four repository
  contract validators, strict Swift formatting, JSON/project parsing, and diff
  whitespace checks pass.
- A signed/notarized native runtime package and its generated signed-binary
  release contract could not be produced on this host because the required
  Developer ID Application/Installer identities and notary profile are absent.
  The bundled schema-0 placeholder therefore fails closed. Native snapshot and
  build-SSH live tests remain gated until those release credentials produce a
  manually installed notarized package.

## Performance contract benchmark checkpoint

- All eight performance-contract requirements now have dedicated,
  executable benchmark lanes. Cold creation and warm restart are separated;
  runtime-reported idle memory covers exact concurrent counts of 1, 10, and 50;
  a bounded guest workload records baseline, stressed, and post-idle retention
  before confirmed stop; and reviewed VirtioFS coverage includes both
  sequential write/fsync/read and fixed metadata-operation batches.
- The database lane uses a digest-pinned PostgreSQL 17 image, waits for
  readiness outside the timed region, runs `pg_test_fsync`, requires `fsync=on`
  and `synchronous_commit=on`, commits a fixed payload, and issues `CHECKPOINT`.
  The image lane separately times an absent-reference current-platform HTTPS
  pull, records Apple runtime allocated-image bytes before and after, and
  deletes only the exact pulled identity; the existing no-cache build lane
  remains separate.
- Comparative networking serves one fixed byte-verified payload from one
  identity-pinned container. Alternating requests measure per-route latency and
  throughput through the published localhost port and the container's dedicated
  IP, preventing different payloads or servers from masquerading as a route
  comparison.
- Recovery is split into three non-approximate lanes. Host recovery registers
  the documented `NSWorkspace` sleep and wake notifications concurrently and
  times only post-wake verified runtime/inventory revalidation. App recovery
  SIGKILLs an isolated worker after atomic publication of a private journal,
  validates ownership/mode/link identity, atomically promotes its staged
  payload, synchronizes the result, and proves residue removal. Runtime recovery
  verifies the installed origin and exact launch-service executable before
  SIGKILL, then requires a replacement PID, unchanged origin, and authoritative
  inventory; failed recovery attempts invoke bounded start-and-verify cleanup.
  The real host-sleep and runtime-crash lanes remain explicit operator-controlled
  gates, while deterministic orchestration, real isolated SIGKILL recovery, and
  launchctl parsing run in the ordinary suite.
- The initial Xcode MCP build-for-testing completed in 30.976 seconds with zero
  errors. Six focused recovery/coverage tests pass, including a real SIGKILL of
  the isolated worker. Full-suite and repository-validator results are recorded
  after the remaining completion slices.
