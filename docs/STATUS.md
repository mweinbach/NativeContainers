# Current status

Updated: 2026-06-21.

## Verified

- Xcode project generated and open as scheme `NativeContainers` on `My Mac`.
- Exact `apple/container` 1.0.0 package resolves and compiles.
- Build-for-testing succeeds; refreshed source diagnostics report no issues.
- The current full app-hosted Xcode run contains 909 expanded outcomes: all 888
  deterministic outcomes passed, with 21 destructive or external-service
  integrations skipped behind explicit live gates and no failures or unrun
  tests. Existing opt-in tests cover Apple runtime
  provisioning, reviewed host-directory and SSH-agent attachments, interactive
  PTY, image behavior, Compose lifecycle, and disposable local-registry paths;
  none run against public services by default.
- The app launches and stops through Xcode. A Preview-owned orphan was terminated
  with a bounded TERM/KILL cleanup, and no residual app process remained.
- A native menu-bar control plane shares the app-scoped `AppModel`, inventory,
  lifecycle services, routing, and error state instead of introducing a second
  poller. It reports runtime and machine counts, exposes bounded container
  Start/Stop/Restart/Force Stop actions, and deep-links into the unique main
  window. App Behavior settings persist menu-bar visibility and route launch at
  login through an injectable `SMAppService.mainApp` adapter with explicit
  approval, unavailable, and failure reconciliation states. Persistent system
  scenes are suppressed in hosted tests and Preview agents so those auxiliary
  processes terminate deterministically without changing production behavior.
- The app target is automatically Apple Development signed with
  `com.apple.security.virtualization` and the microphone-specific
  `com.apple.security.device.audio-input`; `ENABLE_APP_SANDBOX` remains `NO` as
  required by the checked-in project specification and the app's private
  `/private/tmp` socket workspace. Shared and host-only VM networking use public
  vmnet objects and add no entitlement; the restricted physical-bridge
  entitlement remains absent. An app-hosted availability probe reports the
  Virtualization capability as available.
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
  saved-state lock/discard path without clipping its mode controls.
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
  policy, and pull policy before execution.
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
- Worker protocol v5 carries typed output/cache kinds and typed artifact metadata,
  but never a user destination. Image-store and OCI-archive builds use Apple's
  OCI exporter, root-filesystem archives use `tar`, and root-filesystem folders
  use `local` with `platform-split=false`; root-filesystem outputs are
  deliberately single-platform. The pinned tar exporter retains its
  `linux_arm64` platform directory, while the local exporter publishes the
  selected platform directly at the destination root.
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
  final unique four-second probe from about 5.20 seconds to 0.20 seconds before
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
  the vault revalidates and consumes each descriptor once, then protocol v5
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

## Remaining live verification gap

The entitlement, signing configuration, build, and capability availability are
verified. Installing and rebooting a reviewed Linux distribution through the
new GUI workflow, then mounting and exercising a shared folder, still need a
disposable ISO smoke pass. Installing, booting,
saving/restoring, and clone-booting macOS are not claimed as live-verified until
a local IPSW and disposable installed guest are available for that destructive
integration pass.

## Next implementation slice

1. Live-install a reviewed arm64 Linux distribution, verify console/input/audio,
   mount a read-only and read-write host folder, eject its ISO, reboot from disk,
   and exercise both graceful and watchdog force-stop paths.
2. Live-verify the implemented macOS installer, lifecycle service, force-stop
   recovery, console, same-host save/restore, and fresh-identity clone boot
   against a local IPSW.
3. Live-verify a second reviewed Up that grows a real pinned Socktainer project
   from a contiguous replica prefix, including stable metadata and exact Apple
   attachment observations. Keep recreation blocked until the pinned bridge
   implements rename and network attachment routes.
