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
  Registry credential UI and push are the next image slice; passwords must not
  be mirrored into observable app state.
- Apple’s public `ContainerBuild.Builder` remains the native build path, but it
  owns NIO/gRPC resources without a public shutdown surface and relies on a
  reserved `buildkit` container. Builds will run in a bundled per-build worker
  process so cancellation closes the native vsock reliably. The 1.0.0
  Dockerfile limit remains strictly below 16 KiB.

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
