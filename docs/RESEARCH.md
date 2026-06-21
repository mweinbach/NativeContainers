# Research notes

Last updated: 2026-06-21.

## Host baseline

- Apple silicon host running macOS 27.0.
- Xcode 27.0 beta (`27A5194q`), macOS 27 SDK, Swift 6.4 compiler.
- Apple `container` CLI 1.0.0 is installed at `/usr/local/bin/container`.
- `container system status --format json` reports the 1.0.0 API server running.
- The live container, image, and machine inventories were empty at kickoff.

## Apple container stack

Primary sources:

- [`apple/container` 1.0.0](https://github.com/apple/container/tree/1.0.0)
- [`apple/container` API docs](https://apple.github.io/container/documentation/)
- [`apple/containerization` 0.33.3](https://github.com/apple/containerization/tree/0.33.3)
- [Containerization API docs](https://apple.github.io/containerization/documentation/)

Verified architecture:

- The Containerization package runs each Linux container in its own lightweight
  Virtualization.framework VM, using an optimized kernel and a minimal init
  service communicating over vsock.
- Containers can receive dedicated IP addresses, avoiding mandatory per-port
  forwarding for host access.
- The stack consumes and produces OCI images, pulls from standard registries,
  builds Dockerfiles/Containerfiles through BuildKit, supports volumes,
  networks, statistics, logs, copy, exec, registries, and persistent
  `container machine` Linux environments.
- Release 1.0.0 publishes Swift library products including
  `ContainerAPIClient`, `ContainerResource`, `MachineAPIClient`, and related
  service clients. Those are preferable to scraping CLI table output.
- The exact 1.0.0 `ClientVolume` surface provides create, list, inspect, delete,
  and allocated-disk-usage calls. Volumes are sparse local ext4 images;
  configured capacity and physically allocated bytes are distinct. Any
  container configuration, running or stopped, blocks deletion. Prune is
  client-side orchestration and each server delete repeats the in-use check.
- The exact 1.0.0 `NetworkClient` surface provides create, list, get, delete,
  and built-in lookup. `NetworkConfiguration` supports NAT/host-only mode and
  optional IPv4/IPv6 subnets, but attachment options expose hostname, MAC, and
  MTU rather than a requested static IP. The built-in network is undeletable.
- OCI configuration at the pinned revision does not model an HTTP scheme for a
  published port. Browser helpers must therefore offer explicit HTTP/HTTPS,
  use the published host endpoint, expand `PublishPort.count` ranges, reject
  UDP, and revalidate the exact live mapping before opening.
- Host DNS and packet-filter helpers mutate privileged `/etc/resolver` and PF
  state. They remain outside the unprivileged GUI until the signed privileged
  helper lane is implemented.
- The public `Utility.containerConfigFromFlags` helper mirrors CLI creation but
  is not safe to assume as a GUI boundary. On this host it exited both Xcode’s
  snippet process and the XCTest host with status 1 before returning. Rebuilding
  the same sequence from public image, snapshot, kernel, network,
  configuration, and lifecycle clients passed live.
- `ClientImage.fetch` in 1.0.0 only falls back to a pull for a missing local
  reference. If a cached reference lacks the requested platform, its
  `.unsupported` error must be handled by an explicit platform pull.
- Release 1.0.0 pins Containerization 0.33.3. Its XPC compatibility shim was
  removed and protocol negotiation is not yet available, so client/server
  versions must remain matched.
- The runtime is supported on macOS 26+ and Apple silicon.

The package remains an actively evolving open-source surface. Pinning an exact
release and isolating it behind an adapter are both deliberate.

## Container attachments and host access

- A named volume or network is not safe to retain by display name alone. The
  creation review freezes its complete intrinsic identity, then re-lists
  volumes, networks, and all container consumers immediately before creating
  the container. A volume that changed or gained any consumer fails closed.
- `PublishSocket` means container-to-host publication. The pinned runtime maps
  its container path to `UnixSocketConfiguration.source`, its host path to the
  destination, and uses direction `.outOf`.
- Apple's CLI parser is not a safe GUI boundary for sockets: it creates parent
  directories and deletes an existing non-socket host leaf. The runtime relay
  also binds with `unlinkExisting: true` at every start and removes the host
  socket on stop. The app constructs `PublishSocket` directly and confines that
  unlink behavior to an operation-owned private directory.
- A 124-byte socket path beneath Application Support persisted in the container
  configuration but did not materialize a host listener in the live pinned
  runtime. Moving the workspace to a protected short `/private/tmp` root
  produced a 79-byte path that appeared on start and disappeared after `KILL`.
  The app therefore enforces the portable Darwin `sockaddr_un` boundary of
  fewer than 104 UTF-8 bytes even though the pinned helper accepts longer input.
- `container system dns create <domain> --localhost <IPv4>` writes a resolver
  entry, updates `/etc/pf.conf` and `com.apple.container`'s PF anchor, reloads
  PF, and signals mDNSResponder. The pinned package publishes no equivalent DNS
  XPC mutation route; this is global host state, not per-container networking.
- An unprivileged process can validate exact safe files but cannot prove the PF
  anchor is loaded in the kernel. The UI labels discovered aliases as
  configured on disk and offers the fixed setup command. Automated mutation
  requires a separately packaged, signed, notarized, narrowly authorized
  helper rather than privilege inside the GUI.

## Interactive terminal

- Apple’s own `container exec` creates a `ProcessIO`, passes stdin/stdout pipe
  handles to `ContainerClient.createProcess`, enables terminal mode, starts the
  process, closes the app’s child-side descriptor copies, applies the current
  terminal size, and forwards signals. The app follows that process lifecycle
  through its bounded, cancellation-closeable XPC adapter instead of wrapping
  the CLI or inheriting the high-level client’s unbounded sends.
- A terminal transport must preserve arbitrary bytes; UTF-8 decoding, ANSI/VT
  parsing, and terminal replies belong in the emulator. A bounded-one async
  stream therefore retries backpressured chunks rather than accepting
  `.dropped` as success.
- On a blocking pipe, Foundation’s `read(upToCount:)` can hold a short terminal
  burst until the requested buffer fills or the writer closes. `poll` plus a
  single POSIX `read` delivered the available bytes immediately and is covered
  by both an open-writer regression and a live Apple-service smoke.
- Guest stdin has the inverse risk: a blocking write can suspend the session
  actor indefinitely, while a closed pipe can terminate the host with
  `SIGPIPE`. A serial nonblocking writer, `poll(POLLOUT)`, `F_SETNOSIGPIPE`, and
  thread-scoped signal masking keep ordering, cancellation, and host survival
  explicit. A shared descriptor-lifetime lock prevents close/read reuse races.
- [SwiftTerm 1.13.0](https://github.com/migueldeicaza/SwiftTerm/tree/1.13.0)
  is the pinned renderer. It is an MIT-licensed native Swift terminal engine
  with AppKit `TerminalView`, selection, copy/paste, scrollback, input-method
  handling, links, title/current-directory callbacks, and terminal response
  forwarding. OrbStack also publishes a SwiftTerm fork, which is useful prior
  art but not an API dependency.
- Upstream SwiftTerm’s macOS accessibility service is currently minimal, and
  its README notes limits around some complex IME behavior. The wrapper exposes
  an accessibility group, label, and help now; full VoiceOver transcript
  semantics and broader IME conformance remain explicit polish work rather than
  hidden parity claims.
- SwiftTerm can retain private terminal modes across process boundaries, so a
  newly opened shell must receive a full RIS reset (`ESC c`), not only a clear
  screen. Shell-path discovery and fallback beyond the current `/bin/sh`
  default remain a separate workflow feature.

## Native image management

- `ContainerAPIClient.ClientImage` is the correct authority because it talks to
  Apple container’s configured XPC image service and remote content store.
  Creating a separate Containerization `ImageStore.default` would fork GUI state
  away from the `container` CLI.
- There is no separate inspect API. Apple’s CLI resolves a `ClientImage`, then
  reads its OCI index, manifest, and config (or calls `toImageResource`). The
  root descriptor’s `size` is only the index descriptor; each variant’s useful
  size includes its manifest descriptor, config, and compressed layers.
- `tag(new:)` overwrites an existing reference without prompting. A native GUI
  must preflight the normalized target and explicitly confirm moving a mutable
  tag to a different digest. Its XPC request carries references but no expected
  digest, so Apple Containerization’s `AsyncLock` closes same-process actor
  reentrancy races; it cannot make concurrent external CLI writes atomic.
- Direct image deletion does not guard container use. The app compares exact
  current container references, protects the configured builder and vminit
  images, deletes references with `garbageCollect: false`, and calls
  `cleanUpOrphanedBlobs()` once after a batch so shared layers remain intact.
- Prune is orchestration, not one API call: list images and containers, classify
  dangling or unused references, show a plan, then re-list and intersect that
  exact reference/digest set before deletion. Apple 1.0.0’s own prune command
  does not exclude infrastructure images, so the app adds that safety boundary.
- Push uses the same Apple image service and Keychain-backed registry domain.
  Registry login/list/logout now use `KeychainHelper` with
  `Constants.keychainID`, not Containerization’s separate cctl domain. Apple’s
  image service reads that domain automatically after checking its registry
  environment-variable override.
- `ClientImage.pull(platform:nil)` downloads every platform but does not unpack
  it. Apple’s CLI performs a second `image.unpack(platform:samePlatform)` call.
  Platform filtering is exact `Platform` equality, so the app constructs
  `linux/arm64/v8` explicitly rather than relying on a parser that may omit the
  ARM variant.
- `ClientImage.unpack(platform:nil)` cannot prove readiness: the pinned
  `SnapshotStore` silently skips a platform when its unpack strategy returns no
  unpacker. `getCreateSnapshot(platform:)` first returns an existing verified
  snapshot or unpacks and then calls `getSnapshot`; that final read proves the
  snapshot and its filesystem metadata exist. All-platform readiness therefore
  requires enumerating non-attestation OCI manifest platforms and verifying
  each one separately.
- Pull commits the returned reference/digest before app-side exact-platform and
  snapshot verification. Later validation, cancellation, or unpack failure is
  partial completion, not rollback: inventory is refreshed and the committed
  digest plus per-platform outcomes are shown. A reviewed plan becomes stale
  once that local reference moves.
- `ClientImage.push` has no destination parameter; it publishes
  `image.reference`. A different destination must first be created as an exact
  local tag. A filtered push can publish an empty index when the requested
  platform is absent, so the app validates the exact local platform before the
  network call. A network error or cancellation can arrive after a registry has
  accepted the manifest, so the UI treats remote state as uncertain and tells
  the user to inspect the registry before retrying.
- Registry `auto` is resolved both at review and execution. Any HTTPS-to-HTTP
  drift invalidates the plan. Image-service registry environment credentials
  take precedence over the shared Keychain, so login metadata cannot be treated
  as proof of which credential a separately configured service will use.
- Pull, unpack, push, tag, delete, prune, and container creation share one
  `AsyncLock`-backed coordinator. Cancellation is checked immediately before
  each irreversible transfer/snapshot call. This closes same-process actor
  reentrancy, while Apple’s reference-only XPC requests still cannot provide a
  cross-process compare-and-swap against the CLI.
- Apple’s `Utility.isInfraImage` only compares literal builder/vminit strings.
  The app additionally compares normalized configured references and repeats
  the guard under the mutation lock before pull or push.
- A live push smoke is restricted in code to a unique repository tag on a
  disposable localhost registry. Public registries are never mutation-tested.
- The CLI resolves `docker.io` to `registry-1.docker.io`; the app additionally
  canonicalizes Docker’s historical `index.docker.io` and
  `https://index.docker.io/v1` credential-helper aliases so a login cannot be
  saved under a key the image service will not query.
- Registry `auto` is a static policy, not TLS negotiation: localhost, private
  IPv4, and Apple’s internal DNS suffix resolve to HTTP. Host classification
  must omit the port, and resolved HTTP is confirmed before sending credentials.
  Keychain stores no scheme, so pull/push must resolve and confirm it again.
- `RegistryClient.ping()` proves `/v2/` authentication, not repository-specific
  push permission. `KeychainHelper.save` replaces by delete-then-add and cannot
  atomically preserve the prior secret if the add fails.
- Apple’s public `ContainerBuild.Builder` remains the native build path, but it
  owns NIO/gRPC resources without a public shutdown surface and relies on a
  reserved `buildkit` container. Builds run in a bundled per-build worker
  process so cancellation closes the native vsock reliably. The 1.0.0
  Dockerfile limit remains strictly below 16 KiB.
- Apple container 1.0.0 accepts build secrets only as `[String: Data]` and
  base64-encodes each `id=value` into repeated gRPC metadata. Its CLI supports
  environment or file sources, arbitrary binary values, and empty files, but
  defines no count, size, validation, redaction, or zeroization contract. The
  app therefore keeps values outside Codable control state and applies a local
  product safety policy of
  32-entry/500-KiB-per-entry/1-MiB-total limits, and suppresses all secret-build
  diagnostics before retained progress or results.

## Native BuildKit integration at the 1.0.0 pin

- [`ContainerBuild.Builder`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerBuild/Builder.swift)
  exposes `info()` and `build(_:)`. It does not start BuildKit, import an OCI
  archive, unpack platforms, apply tags, return a digest, or publish a shutdown
  method. Its gRPC task and caller-owned event-loop group make a one-shot
  process the deterministic lifetime boundary.
- Foundation `FileHandle.read(upToCount:)` can wait to fill a pipe request while
  the writer stays open. Because stdin is also the parent-lifetime lease, the
  worker must consume its framed request with one POSIX `read`; a regression
  test keeps the writer open and proves the short frame returns immediately.
- Apple’s CLI orchestration in
  [`BuildCommand`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerCommands/BuildCommand.swift)
  dials the fixed `buildkit` container over vsock port 8088, starts or reuses
  it, exports beneath `<appRoot>/builder/<buildID>`, loads `out.tar`, unpacks,
  and tags. `BuilderStart.start` is internal, so the app reproduces the public
  client sequence while adding immutable review and conflict checks.
- The pinned builder image is Linux arm64/v8 and runs
  `/usr/local/bin/container-builder-shim --debug --vsock`, adding
  `--enable-qemu` when Rosetta is disabled. It mounts the app builder directory
  at `/var/lib/container-builder-shim/exports`, uses Apple’s built-in network,
  and is shared with the CLI. Reconfiguration can interrupt another build and
  discard cache, so it is separately confirmed.
- Builder identity includes the exact image descriptor digest and DNS
  configuration, not only the visible tag and process arguments. The accepted
  snapshot must survive until dial, be revalidated on both sides of the socket
  connection, and close that socket on drift. If a create attempt fails while a
  running or uncertain builder exists, cleanup must leave it intact because it
  may belong to another `container` process.
- Apple 1.0.0's
  [`Builder.BuildExport.destination`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerBuild/Builder.swift)
  is host orchestration state; it is not serialized into the shim request. The
  shim writes OCI and tar
  exports to `<appRoot>/builder/<buildID>/out.tar` and local exports to
  `<appRoot>/builder/<buildID>/local`. The app therefore keeps reviewed user
  destinations entirely on the host side of worker protocol v5.
- Image-store and OCI-image-archive outputs both use `type=oci`. The former
  carries a unique internal staging tag and is imported, snapshot-verified, and
  retagged; the latter carries exactly one reviewed image reference and is
  published as an OCI archive without image-store mutation. `type=tar` and
  `type=local` are root-filesystem outputs, not OCI images, and accept no final
  image tags in the app.
- Root-filesystem tar and local-folder outputs are deliberately limited to one
  platform. Apple's pinned CLI fixtures
  separately exercise
  [`tar`](https://github.com/apple/container/blob/1.0.0/Tests/CLITests/Subcommands/Build/CLIBuilderTarExportTest.swift)
  and
  [`local`](https://github.com/apple/container/blob/1.0.0/Tests/CLITests/Subcommands/Build/CLIBuilderLocalOutputTest.swift)
  export. File outputs are sealed into the private artifact store. Local output
  is sealed into a separate private directory store that rejects
  devices/FIFOs/sockets, preserves regular-file modes and relative symlinks,
  and fingerprints the complete tree before host publication.
- Live Apple 1.0.0 probes confirmed the final exporter contracts. OCI output is
  a valid layout archive and does not mutate the image store. The `tar` exporter
  retains its `linux_arm64` directory envelope. The `local` exporter accepts
  `platform-split=false` and places the selected platform directly at the
  destination root. The same option is not applied to `tar` because the pinned
  exporter ignores it. All three probes left no private or shared export residue.
- Destination review pins the resolved owner-controlled parent descriptor.
  Existing archive files must be owner-controlled, single-link regular files
  and require explicit replacement authorization; folder outputs must be new.
  Publication copies to a hidden sibling, checks cancellation and identities,
  atomically renames, and reports post-commit fsync failure as retained partial
  completion. Live probes verified publication and cleanup for OCI, tar, and
  local-folder destinations.
- Docker/registry exporters, SSH forwarding, and reviewed remote-cache profiles
  remain later parity work. Raw BuildKit cache strings are intentionally not a
  product surface.
- The public build configuration accepts raw BuildKit CSV strings for cache
  import/export, but Apple’s CLI hides both flags, the builder source still
  marks cache-to/from as TODO, and upstream has no cache contract tests. Local
  cache paths resolve inside the builder VM. Protocol v5 now exposes one typed,
  fixed app-owned local profile rather than raw strings or remote credentials.
  The worker lowers it to Docker's documented
  [local-cache `src`/`dest` syntax](https://docs.docker.com/build/cache/backends/local/),
  exports and validates a fresh OCI-layout staging generation, atomically moves
  it into a tokenized prepared handoff, and returns a fingerprint-bound receipt
  before terminal result delivery. The app validates the private artifact before
  a host-side service reopens that exact token, recomputes its identity and OCI
  metadata plus full entry-metadata-tree fingerprint, and atomically promotes
  the generation. Inspection and new worker leases recover staging without
  deleting a live handoff, then reclaim unconsumed handoffs after 24 hours. Unit and
  fault-path coverage is live. A real two-build Xcode probe
  observed separate staged/committed events for both 9-entry generations and
  reduced the final unique four-second probe from about 5.20 seconds to 0.20
  seconds, then reset the namespace and removed both 4,004,864-byte outputs.
  Repeated probes did not produce stable archive byte equality, so cache proof
  rests on validated generations and lifecycle events rather than byte equality.
  The surviving internal
  BuildKit cache confounds hit
  attribution; deleting the builder solely to prove independent local reuse was
  deliberately not performed.
- Apple’s public builder and shim protocols expose build/info operations but no
  build-history, disk-usage, or prune endpoint. NativeContainers therefore owns
  its small product history: schema-versioned private files record typed
  running/terminal outcomes while excluding full paths, option values, secret
  metadata, logs, and error text. Per-launch advisory leases distinguish an
  abandoned attempt from another live app instance. This history is not
  presented as BuildKit’s internal solve database.
- [`BuildFSSync`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerBuild/BuildFSSync.swift)
  accepts paths requested by the builder and is not a host security sandbox.
  The initial product stages only regular files, rejects links/special files
  and custom Dockerfile frontends, and verifies a full tree fingerprint before
  and after the solve. A malicious same-user process can still race filesystem
  access; this is documented rather than disguised as isolation.
- Dockerfile bytes travel in gRPC metadata and must be strictly less than
  16,384 bytes. Local directory contexts are supported; Git/URL contexts are
  not part of the pinned implementation. Large contexts consume host CPU and
  temporary storage while being archived.
- File URLs created with a directory hint can retain a trailing separator.
  Reviewed Dockerfile and ignore files therefore require strict component-wise
  containment; string-prefix checks can reject valid children or admit sibling
  paths with a shared textual prefix.
- `BuildFSSync.FileInfo` sends staged POSIX modes to BuildKit and forces uid/gid
  to root. A private parent directory is sufficient for host confidentiality;
  changing staged children to 0600/0700 breaks images that switch to a non-root
  user after `COPY`, so child file and directory modes must be preserved.
- The builder export directory is guest-visible. A final image is imported only
  after the worker copies the descriptor-validated archive into a mode-0700
  host-private directory as a mode-0400 file and binds it to inode metadata,
  length, and SHA-256. Both locations are removed through
  cancellation-independent cleanup.
- Image-service XPC calls can commit before their reply fails. Import and tag
  failures therefore require a fresh list-and-classify pass: observed committed
  state is success or durable partial completion, never an assumed rollback.
- Containerization 0.33.3 treats `linux/arm64` and `linux/arm64/v8`
  inconsistently in `Hashable`; the fix landed after this pin. Builds are
  serialized as the upstream workaround for multi-stage `COPY --from`
  failures ([apple/container#1542](https://github.com/apple/container/issues/1542)).
- Containerization 0.33.3 `AsyncLock` does not remove canceled waiters. Native
  build serialization uses a local cancellation-aware FIFO so a queued review
  context is discarded promptly instead of waiting behind a long solve.
- Foundation’s counted pipe read buffered short worker progress until EOF in a
  live 60-second cancellation probe. The parent now consumes framed stdout with
  POSIX `read`; `.building` arrived in about 104 ms and cancellation completed
  about 3 ms later with no destination or artifact residue.
- Builder cache has no supported prune command in 1.0.0 and can become hard to
  stop/delete ([#1159](https://github.com/apple/container/issues/1159),
  [#932](https://github.com/apple/container/issues/932)). Builder lifecycle and
  cache deletion are therefore explicit management operations, never automatic
  cleanup after each build. `ContainerClient.diskUsage("buildkit")` reports the
  whole container bundle allocation, not a cache-only size.
- NativeContainers exposes Stop, explicit `KILL`, and stopped-only non-force
  deletion behind a focused reviewed service. It takes the same image-build and
  runtime mutation locks as build execution, freezes and revalidates the full
  builder snapshot, and reconciles every mutation reply by re-reading state.
- Apple’s delete server can remove inventory even if bundle cleanup fails. A
  reset therefore requires both inventory absence and `lstat` absence for
  `<appRoot>/containers/buildkit`. The app reports an orphaned bundle instead of
  deleting it manually, and it never removes `<appRoot>/builder`, which contains
  build exports rather than the builder cache.

## Virtualization.framework

The installed Apple documentation confirms:

- A process using Virtualization APIs needs the
  `com.apple.security.virtualization` entitlement.
- That entitlement is a normal Boolean capability, not a restricted entitlement
  requiring Apple approval. Apple’s own runtime is locally ad-hoc signed with
  it. The current blocker is Xcode MCP’s entitlement catalog rejecting the key,
  not the developer account or provisioning profile.
- `VZMacOSRestoreImage.latestSupported` discovers the newest restore image the
  current host supports; SDK 27 exposes local loading as
  `VZMacOSRestoreImage.image(from:) async throws`.
- The restore image’s most featureful supported configuration supplies the
  compatible hardware model and CPU/memory requirements.
- Apple explicitly requires the network URL returned by latest-image discovery
  to be downloaded to a local file before constructing `VZMacOSInstaller`.
- `VZMacOSRestoreImage.image(from:)` and
  `VZMacOSInstaller.init(virtualMachine:restoringFromImageAt:)` both consume a
  local file URL. No public descriptor-pinning or ownership-lease initializer
  is exposed, so the app must retain its own cache lease across every Apple URL
  consumer and the manifest commit.
- New auxiliary storage is created with
  `VZMacAuxiliaryStorage(creatingStorageAt:hardwareModel:options:)`. The exact
  hardware model used there must also be set on the VM platform configuration.
- Both `VZMacHardwareModel` and `VZMacMachineIdentifier` provide opaque
  `dataRepresentation` values intended for persistent reconstruction.
- A macOS VM must persist its hardware model, machine identifier, auxiliary
  storage, and main disk together.
- `VZVirtualMachineConfiguration.validate()` is the preflight gate.
- macOS guest configuration and installation APIs are Apple-silicon-only in the
  installed SDK. Universal app sources therefore keep the live adapter behind
  `#if arch(arm64)` and return an explicit unsupported-host error on Intel.
- `VZMacOSInstaller` must begin with a stopped VM. Its documented cancellation
  surface is `installer.progress.cancel()` after installation starts; pausing or
  stopping the VM during installation has undefined behavior, so the app never
  escalates installer cancellation to force stop.
- `VZVirtualMachine.start()`, `pause()`, and `resume()` are asynchronous and
  must be gated by their matching capability properties. `requestStop()` only
  asks the guest to shut down; it does not confirm exit. The delegate's guest
  stop and error callbacks are the terminal signal.
- `VZVirtualMachine.stop(completionHandler:)` is Apple's destructive power-off
  path for a running or paused VM. The UI therefore keeps it behind an explicit,
  generation-pinned Force Stop confirmation and retains ownership after a
  failed stop attempt.
- Save/restore support has its own configuration validation and is not assumed
  for every configuration.
- `saveMachineStateTo(url:completionHandler:)` requires a paused VM and leaves
  it paused on success or failure. `restoreMachineStateFrom` requires a stopped
  VM, leaves it stopped on failure, and produces a paused VM on success. Neither
  API exposes cancellation, so an accepted callback must quiesce before runtime
  ownership is released.
- Apple's macOS VM sample validates save/restore support separately from normal
  configuration validation and treats the save file as single-use after a
  restore attempt. NativeContainers additionally renames the active checkpoint
  to a consuming tombstone before the attempt, so a process crash cannot make
  partially restored memory replayable.
- `VZNetworkDeviceConfiguration.macAddress` defaults to a random locally
  administered unicast address. A restorable configuration therefore must set a
  stable address explicitly; NativeContainers derives one from the VM UUID and
  includes it in the shared topology descriptor and saved-state fingerprint.
- `VZVirtualMachineView` is the native interactive display. It supports
  automatic display reconfiguration and optional capture of system keys. SDK
  27's `VZVirtualMachineViewAdaptor` retains its VM, so a console must detach the
  adaptor when its generation closes.
- Shared directories use VirtioFS. Linux clipboard integration uses the SPICE
  agent and requires guest support.

## Docker wording

“Docker support” has several meanings and the product will distinguish them:

1. Docker/OCI image interoperability — present.
2. Dockerfile builds — present.
3. Docker CLI and Engine API compatibility — not established by the 1.0.0
   public docs reviewed so far.
4. Docker Compose behavior — requires either a supported engine compatibility
   endpoint or a native Compose coordinator.

The UI and marketing must not collapse those four claims into one.

### Socktainer 1.0.0 integration audit — 2026-06-21

- [Socktainer v1.0.0](https://github.com/socktainer/socktainer/releases/tag/v1.0.0)
  pins `apple/container` 1.0.0 and Containerization 0.33.3, matching this app’s
  native runtime generation. Its advertised Docker Engine compatibility remains
  partial API v1.51 rather than a complete Docker daemon contract.
- The production downloader uses the direct 67,440,560-byte executable asset,
  pinned by SHA-256
  `8e41e8a75aaf9cb2fa938a7493bbc504d93bfbd14fbf09826d4c57d2150bd020`.
  The arm64 executable passed the app’s Security-framework validation and is
  signed with Developer ID Application team `HYSCB8KRL2`. The separately
  published zip remains pinned by
  `911a207bb791f5ea1592a329938600680263b68022552641f21d1d172d591e37`.
- The v1.0.0 source binds only to `$HOME/.socktainer/container.sock`; it does not
  expose a product-specific socket argument. The release tag also does not
  create a Docker context even though later `main` documentation describes
  automatic context registration. NativeContainers must therefore pin behavior
  to the release tag, validate the existing socket directory before launch, and
  create a separate `nativecontainers` Docker context explicitly rather than
  relying on moving-branch behavior.
- Runtime download/install, process ownership, socket collision handling,
  context review, TERM-to-KILL shutdown, immediate Force Stop, and app-quit
  cleanup now live behind a dedicated compatibility-service slice. They are not
  folded into the native Apple container service graph or represented as
  built-in Engine API support.
- A 2026-06-21 isolated-home live probe verified HTTP 200 `/_ping`, body `OK`,
  `Api-Version: 1.51`, Docker 29.4 client negotiation against server/minimum APIs
  1.51/1.32, `docker ps -a`, graceful stop, and inode-matched socket cleanup.
  Socktainer leaves its socket after exit on its own, so wrapper cleanup is a
  required lifecycle step rather than an optimization.
- Exact v1.0.0 Compose parity is incomplete: aliases, health checks, restart
  policies, several resource settings, and network connect/disconnect behavior
  cannot support a broad Compose claim. The first safe slice was read-only
  project observability from canonical Compose labels and authoritative Apple
  inventory. That slice now ships as a pure service: it validates the Compose
  project and logical-resource naming
  grammars, requires resource-specific labels for volumes and networks, excludes
  Apple built-in networks, and keeps incomplete label evidence out of runtime
  counts and reverse membership indexes. A live Apple-infrastructure probe then
  created isolated volume/network resources, preserved distinct logical and
  runtime names through inventory, derived a resource-only project with no
  notices, deleted both resources, and confirmed the project disappeared.
- Labels are writable metadata, not ownership proof. The topology therefore
  retains suspect evidence for invalid optional labels and cross-project
  consumers, excludes anonymous volumes, and exposes no mutation API. Generic
  volume prune protects all resources with the reserved Compose prefix; future
  project lifecycle needs reviewed Compose-model conformance and frozen resource
  identities rather than label-only inference.
- The next conformance boundary now ships as a second pure service rather than
  being folded into process management or topology. Its immutable 1.0.0
  manifest explicitly requires the reviewed container, volume, and network
  route surface; known alias, health, restart, config, and secret gaps override
  route presence. Settings labels the result as source-pinned rather than live,
  and the project-lifecycle fixture remains policy-blocked.
- The isolated live-wire fixture now proves the supported subset against the
  real socket. A standard Compose 5.1.2 client created one running Alpine
  service plus labeled named volume/network; Apple inventory derived the exact
  canonical project, logical names, and `allRunning` state. Normal down removed
  all resources. A second run intentionally made down exit 17 and proved the
  identity-revalidated Apple-native force-stop/delete fallback, again leaving
  no resources, process, or socket.
- The live environment exposed an important packaging gap: setting an isolated
  `DOCKER_CONFIG` correctly hides the user’s Compose plugin, while
  `/usr/local/bin/docker-compose` currently resolves to OrbStack. That binary is
  acceptable as an external conformance client but cannot become a product
  dependency. Docker’s official
  [v5.1.4 release](https://github.com/docker/compose/releases/tag/v5.1.4)
  publishes a 29.7 MB `docker-compose-darwin-aarch64` asset, SHA-256
  `4cad7fc67dd089a598a15598ad38d04e6f23bf299846d26b2c572f1f96a7c49f`,
  plus checksum, provenance, SBOM, and Sigstore artifacts. Docker’s install docs
  otherwise steer macOS users to Docker Desktop, so NativeContainers needs a
  private, version-pinned installer and license/signature review rather than
  modifying global CLI plugin directories.
- The reviewed 5.1.4 Darwin arm64 executable is a thin Mach-O with an ad-hoc
  linker signature and no Developer ID team identifier. Publisher trust
  therefore cannot come from macOS code-signing identity. NativeContainers pins
  the release binary SHA-256 and the separate provenance-file SHA-256, then
  parses the in-toto/SLSA statement and requires the exact binary subject,
  `docker/compose` v5.1.4 source tag, source revision
  `6ce6411902e8e3c9be91be0c572b2441486357f7`, BuildKit build type, and GitHub
  Actions builder run. The upstream repository is Apache-2.0 licensed.
- The packaging gap is now closed without borrowing OrbStack. Xcode installed
  the official binary and provenance into NativeContainers’ private Application
  Support tree, confirmed version 5.1.4, and ran both the normal live fixture and
  an intentional `down` failure through that path. Normal Compose cleanup and
  Apple-native fallback each left no fixture resources, bridge process, or
  socket. Global and per-user Docker CLI plugin directories were not changed.

Apple maintainers treat the Engine API as a separate service/plugin concern.
[Socktainer](https://github.com/socktainer/socktainer) is an active Apache-2.0
bridge for part of Docker API v1.51 and is the preferred starting point. A
native `container compose` change is under review upstream but was not merged
at kickoff, so the foundation does not depend on it.

## macOS VM clone identity and transfer findings

- Apple documents `VZMacPlatformConfiguration.machineIdentifier` as the unique
  identity of one VM instance and says concurrently running VMs with the same
  value produce undefined guest behavior. Clone detection for iCloud identity
  does not remove that platform-configuration requirement.
- `VZMacMachineIdentifier()` creates a new unique identifier;
  `dataRepresentation` and `init(dataRepresentation:)` are the supported opaque
  persistence and validation boundary. NativeContainers therefore replaces the
  copied identifier and validates it again at transaction commit rather than
  treating the app manifest UUID as sufficient isolation.
- Darwin `copyfile(3)` defines `COPYFILE_CLONE` as best-effort file cloning with
  ordinary-copy fallback. Combined with `COPYFILE_RECURSIVE`, each hierarchy
  entry gets the same clone attempt; `COPYFILE_DATA_SPARSE` preserves holes when
  supported. Clone success is immediate and emits no progress callbacks.
- When clone-on-write is unavailable, the status callback runs on every data
  write. Returning `COPYFILE_QUIT` aborts the transfer and reports cancellation,
  leaving the caller responsible for partial cleanup. That maps directly to the
  clone transaction's abort boundary and provides a real kill point for a large
  fallback copy.

## Portable macOS VM package findings

- SwiftUI's `fileImporter` returns a security-scoped URL and requires balanced
  `startAccessingSecurityScopedResource()` /
  `stopAccessingSecurityScopedResource()` calls. NativeContainers holds that
  scope in the transfer service through validation, copy, and abort cleanup
  rather than ending access in the picker callback.
- `NSSavePanel` is the macOS 26 export boundary because it returns the exact
  destination while the app retains control of a multi-gigabyte asynchronous
  copy, source lease, cancellation callback, and hidden sibling staging
  package. `FileDocument` and `Transferable` exporters hand the final copy
  lifetime to the system. macOS 27's async `WritableDocument` /
  `DocumentWriter` APIs are not a deployment-target baseline.
- The exported `com.nativecontainers.virtual-machine` type conforms to
  `com.apple.package` and uses the `.nativevm` extension, so Finder and the
  import panel treat the bundle as one document without enumerating its
  contents.
- Portable packages cannot include a same-host saved session: Apple documents
  macOS VM saved state as bound to the originating Mac and user. Runtime owner
  files, installation/save partials, the cached restore-image URL, and
  `SharedDirectories.json` security-scoped bookmarks are also host-local and
  are removed. The disk, auxiliary storage, hardware model, manifest UUID, and
  `VZMacMachineIdentifier` remain the restore identity.

## Storage-accounting findings

- The user Caches directory is reclaimable storage rather than a durable
  archive. New acquisitions therefore use private Application Support and set
  `isExcludedFromBackup` on the restore-image directory; Apple documents both
  Application Support as the long-lived support-file location and the backup
  exclusion resource value for large redownloadable files.
- Legacy Caches URLs cannot be changed with a path flip. Launch maintenance now
  takes both store locks, copyfile-clones a referenced regular IPSW into a
  UUID-named durable target, and asks the library to replace exact manifest URLs
  while holding its operation lock. The journal retains both files across every
  partial-write phase, so per-manifest atomic writes converge without claiming
  an impossible multi-bundle filesystem transaction. The old copy is retained
  as unreferenced Caches data rather than silently deleted.
- A restore-image cleanup plan must acquire the cache lock before reading VM
  manifests. With the same cache-before-library order used by preparation, no
  second current-version process can add a reference between that read and the
  deletion decision. Execution still reloads references and the descriptor-
  derived file identity because review is not authorization for a changed
  artifact.

- The pinned `apple/container` 1.0.0 API exposes `systemDiskUsage` and returns
  `DiskUsageStats` with image, container, and volume `ResourceUsage` values:
  total count, active count, allocated bytes, and reclaimable bytes. The server
  calculates the categories concurrently, so the result is a point-in-time
  operational snapshot rather than an atomic deletion plan.
- Image activity means referenced by a container; container activity means
  running; volume activity means referenced by any container configuration.
  Stopped container bundles and unreferenced volumes may therefore appear in
  Apple's reclaimable estimate. The GUI must not translate those estimates into
  an unreviewed prune action.
- The package convenience call has no caller-selected deadline. Reusing
  `AppleXPCRequestClient` preserves the app's 60-second watchdog and closes the
  XPC connection on cancellation while still decoding the pinned response
  shape.
- Sparse VM disks require two values: logical bytes from `st_size` and
  filesystem allocation from `st_blocks * 512`. A single descriptor-relative
  traversal is safer than URL enumeration because it can inspect every entry
  with `AT_SYMLINK_NOFOLLOW`, reject mount crossings, include hidden operation
  partials, and deduplicate hard-linked `(device, inode)` identities.
- APFS clones may share physical extents even though each file reports allocated
  blocks. Public file metadata does not expose uniquely owned physical bytes per
  `.nativevm` bundle, so bundle allocation remains an estimate and cannot be
  labeled reclaimable without a separate mutation-time proof.

## Public-API boundaries

- No public Linux GPU/Metal passthrough.
- No exact bidirectional Docker-style host networking; proxying can only
  approximate shared loopback semantics.
- Virtualization memory ballooning is cooperative and does not guarantee that
  all freed guest memory returns to the host.
- macOS save-state files are encrypted to the originating Mac and user, so they
  are suspend artifacts rather than portable snapshots.
- macOS 27 adds DiskImageKit layers, guest provisioning, and public physical USB
  passthrough. Those remain availability-gated and are not macOS 26 foundation
  requirements.

## Primary references added during the foundation pass

- [`apple/container` technical overview](https://github.com/apple/container/blob/1.0.0/docs/technical-overview.md)
- [`apple/container` 1.0.0 release](https://github.com/apple/container/releases/tag/1.0.0)
- [Docker API discussion](https://github.com/apple/container/issues/66)
- [Apple Virtualization documentation](https://developer.apple.com/documentation/virtualization)
- [VirtualBuddy](https://github.com/insidegui/VirtualBuddy)
- [OrbStack architecture](https://docs.orbstack.dev/architecture)
