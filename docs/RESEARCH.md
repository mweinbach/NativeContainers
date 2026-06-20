# Research notes

Last updated: 2026-06-20.

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

## Interactive terminal

- Apple’s own `container exec` creates a `ProcessIO`, passes stdin/stdout pipe
  handles to `ContainerClient.createProcess`, enables terminal mode, starts the
  process, closes the app’s child-side descriptor copies, applies the current
  terminal size, and forwards signals. The app follows that public-client
  lifecycle instead of wrapping the CLI.
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
- OCI is the only initial output. The archive carries one unique internal
  staging tag; the app applies one or more reviewed final tags after import.
  Docker/registry exporters, arbitrary output backends, SSH forwarding, cache
  import/export UI, structured progress, and supported cache pruning remain
  later parity work.
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
- Builder cache has no supported prune command in 1.0.0 and can become hard to
  stop/delete ([#1159](https://github.com/apple/container/issues/1159),
  [#932](https://github.com/apple/container/issues/932)). Builder lifecycle and
  cache deletion therefore remain explicit management operations, never
  automatic cleanup after each build.

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
- New auxiliary storage is created with
  `VZMacAuxiliaryStorage(creatingStorageAt:hardwareModel:options:)`. The exact
  hardware model used there must also be set on the VM platform configuration.
- Both `VZMacHardwareModel` and `VZMacMachineIdentifier` provide opaque
  `dataRepresentation` values intended for persistent reconstruction.
- A macOS VM must persist its hardware model, machine identifier, auxiliary
  storage, and main disk together.
- `VZVirtualMachineConfiguration.validate()` is the preflight gate.
- Save/restore support has its own configuration validation and is not assumed
  for every configuration.
- `VZVirtualMachineView` is the native interactive display. It supports
  automatic display reconfiguration and optional capture of system keys.
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

Apple maintainers treat the Engine API as a separate service/plugin concern.
[Socktainer](https://github.com/socktainer/socktainer) is an active Apache-2.0
bridge for part of Docker API v1.51 and is the preferred starting point. A
native `container compose` change is under review upstream but was not merged
at kickoff, so the foundation does not depend on it.

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
