# Current status

Updated: 2026-06-21.

## Verified

- Xcode project generated and open as scheme `NativeContainers` on `My Mac`.
- Exact `apple/container` 1.0.0 package resolves and compiles.
- Build-for-testing succeeds with no warnings.
- The suite currently contains 328 test declarations. The current full
  app-hosted Xcode run passed all 318 deterministic tests, with ten destructive
  or external-service integrations skipped behind explicit live gates. That run
  includes Linux-machine recovery/XPC/inventory coverage, build-history
  privacy/durability, short-pipe framing, builder mount normalization, and
  strict path-component-containment regressions. Existing
  opt-in tests pass against Apple’s live runtime for provisioning, interactive
  PTY, and image-reference behavior. The push/pull round trip remains
  hard-gated to a disposable localhost registry and is never run against public
  services.
- The app launches through Xcode and stops cleanly.
- The SwiftUI overview, split container inspector, Linux-machine list,
  Linux-machine creation form, and machine command runner render successfully
  in Xcode Preview in light mode.
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
  success. Caller cancellation also triggers cancellation-independent `KILL`.
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
- A signed embedded one-shot worker owns Apple’s public
  `ContainerBuild.Builder` lifetime. Exact builder descriptor, digest, DNS,
  creation identity, and dial state are revalidated; running or uncertain
  builders are never stopped as failed-create cleanup.
- Build contexts reject links and special files, preserve Docker-visible POSIX
  modes, and bind metadata plus content in a SHA-256 fingerprint checked before
  and after solve. Canceled staging and queued builds remove partial private
  contexts promptly.
- Worker protocol v4 carries a typed output kind and typed artifact metadata,
  but never a user destination. Image-store and OCI-archive builds use Apple's
  OCI exporter, root-filesystem archives use `tar`, and root-filesystem folders
  use `local`; root-filesystem outputs are deliberately single-platform.
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
- A live Xcode probe exercised the app’s embedded signed worker against Apple’s
  1.0.0 services: it staged a Dockerfile context, reused the shared BuildKit
  container, exported and imported OCI, verified the arm64 snapshot, applied a
  unique reviewed tag, started a container, read the built marker through native
  exec, and removed the container, tag, private artifact, and shared export.
- A separate live cancellation probe interrupted a 60-second BuildKit step five
  seconds after launch. The worker surfaced `CancellationError`, no final tag or
  build artifact remained, and the preexisting container/image counts were
  unchanged.
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
- Reviewed file-backed BuildKit secrets are live behind a focused
  `ImageBuildSecretManaging` service. Review pins private, owner-only regular
  files outside the build context by open descriptor and full identity; plans
  retain only ID, privacy-sensitive path, and byte count. Context staging rejects
  every pinned device/inode, closing hard-link races. After the builder is ready,
  the vault revalidates and consumes each descriptor once, then protocol v4
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
  `ScrollView`/`LazyVStack` presentation. The full 281-test Xcode run and a
  warning-free build-for-testing pass are green.

## Known configuration issue

Apple documentation and SDK headers require
`com.apple.security.virtualization`. Xcode MCP’s entitlement action returned
“This entitlement does not exist” for that documented key and explicitly
forbids a manual workaround. The app therefore builds and the container lane is
live, but constructing a VM is intentionally not claimed as runtime-verified
until the entitlement can be added through a functioning Xcode capability
surface. Official Apple sources confirm this is a normal Boolean entitlement;
no developer-team or provisioning-profile change should be needed.

## Next implementation slice

1. Run gated live probes for OCI archive, root-filesystem tar, and local-folder
   export against Apple 1.0.0, including cancellation cleanup. Then gate any
   app-owned local cache profile behind a separate two-build reuse/reset probe.
   Keep raw cache strings, remote credentials, SSH forwarding, and cache-only
   prune out of the UI until the pinned native API exposes a verifiable contract.
2. Package a signed and notarized privileged helper if automated host-access
   mutation is still desired after the explicit command handoff is exercised.
3. Add the entitlement through a functioning Xcode capability surface, then
   implement and live-verify macOS installation and VM lifecycle.
4. Spike a pinned Socktainer process and a product-specific Docker context.
