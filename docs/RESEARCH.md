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
