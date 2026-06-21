# Current status

Updated: 2026-06-21.

## Verified

- Xcode project generated and open as scheme `NativeContainers` on `My Mac`.
- Exact `apple/container` 1.0.0 package resolves and compiles.
- Build-for-testing succeeds; refreshed source diagnostics report no issues.
- The suite currently contains 414 test declarations. The current full
  app-hosted Xcode run passed all 404 deterministic tests, with ten destructive
  or external-service integrations skipped behind explicit live gates. That run
  includes Linux-machine recovery/XPC/inventory coverage, build-history
  privacy/durability, short-pipe framing, builder mount normalization, and
  strict path-component-containment regressions. Existing
  opt-in tests pass against Apple’s live runtime for provisioning, interactive
  PTY, and image-reference behavior. The push/pull round trip remains
  hard-gated to a disposable localhost registry and is never run against public
  services.
- The app launches and stops through Xcode. A Preview-owned orphan was terminated
  with a bounded TERM/KILL cleanup, and no residual app process remained.
- The SwiftUI overview, split container inspector, Linux-machine list,
  Linux-machine creation form, machine command runner, macOS VM list,
  restore-image preparation sheet, macOS installation sheet, and
  generation-keyed macOS runtime console render successfully in Xcode Preview
  in light mode. The app-wide Quick Open sheet, actionable Overview, and
  initial-selection paths for Volumes and Networks also render successfully.
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
  ownership/service/model tests pass, while real VM launch remains
  entitlement-gated.
- Same-host suspend/resume is implemented behind focused runtime, saved-state
  callback, and transactional filesystem services. The live configuration uses
  a deterministic per-VM MAC and records save/restore capability independently
  from cold-boot support. Checkpoints are configuration-fingerprinted,
  lease-borrowed, crash-recovered, and single-use on restore; Start Fresh and
  live Resume atomically invalidate them before storage advances. The UI exposes
  Suspend, Resume, confirmed Start Fresh/Discard Saved State, incompatible-state
  diagnostics, and a generation-pinned Force Stop that queues while save/restore
  callbacks are outstanding. Deterministic store/service/runtime/model tests are
  implemented; a real save/restore remains gated by the Virtualization
  entitlement and installed macOS guest.
- Installed macOS VM bundles can persist shared host directories in a private,
  bounded `SharedDirectories.json` capability sidecar. A focused orchestration
  service acquires the runtime lease, rejects running or checkpointed VMs, and
  commits monotonic revisions. Bookmark resolution retains security scope for
  the full engine session; one macOS automount VirtioFS device exposes all
  validated read-only/read-write shares. The selected-VM inspector owns no
  persistence logic and edits only through the service. Existing no-share saved
  states retain the legacy fingerprint, while any sharing history prevents an
  older checkpoint from becoming valid again.
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

## Known configuration issue

Apple documentation and SDK headers require
`com.apple.security.virtualization`. Xcode MCP’s entitlement action returned
“This entitlement does not exist” for that documented key and explicitly
forbids a manual workaround. The app therefore builds and the container lane is
live, but installing or starting a VM is intentionally not claimed as
runtime-verified until the entitlement can be added through a functioning Xcode
capability surface. Official Apple sources confirm this is a normal Boolean
entitlement; no developer-team or provisioning-profile change should be needed.

## Next implementation slice

1. Keep raw cache strings, remote credentials, SSH forwarding, and cache-only
   prune out of the UI until the pinned native API exposes a verifiable contract;
   the fixed app-owned local profile is the only reviewed non-internal mode.
2. Package a signed and notarized privileged helper if automated host-access
   mutation is still desired after the explicit command handoff is exercised.
3. Add the entitlement through a functioning Xcode capability surface, then
   live-verify the implemented macOS installer, lifecycle service, force-stop
   recovery, console, and transactional same-host save/restore against a local
   IPSW.
4. Design a reviewed Compose desired-state parser before any user-project
   lifecycle; do not infer replicas, health, orphan removal, or volume intent
   from observed labels.
