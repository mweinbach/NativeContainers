# NativeContainers

NativeContainers is a native macOS management app for Apple’s open-source
`container` stack and Virtualization framework. The product goal is the fast,
polished container and virtual-machine workflow people expect from OrbStack,
implemented on Apple’s supported APIs and open-source runtime.

This repository is intentionally split into two runtime lanes:

- Linux containers and Linux development machines use Apple’s
  [`container`](https://github.com/apple/container) services and public Swift
  client libraries.
- General Linux and macOS virtual machines use
  [`Virtualization.framework`](https://developer.apple.com/documentation/virtualization)
  directly, including `VZVirtualMachineView` for native guest display.

The app targets Apple silicon and macOS 26 or newer. The current development
host is macOS 27 with Xcode 27; Apple `container` 1.0.0 is installed and its
services are running.

## Status

Foundation work is underway. See:

- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Feature matrix](docs/FEATURE_MATRIX.md)
- [Research notes](docs/RESEARCH.md)
- [Architecture decisions](docs/DECISIONS.md)
- [Current status](docs/STATUS.md)

The current foundation includes native container lifecycle and inspection,
exec/copy and interactive PTY workflows, safe OCI image management, reviewed
volume/network lifecycle, explicit HTTP/HTTPS opening for published TCP ports,
reviewed named-volume and ordered-network attachments, private Unix-socket
publishing, reviewed read-only/read-write host-folder sharing, native
identity-pinned SSH-agent forwarding, read-only host-access discovery,
Apple Keychain-backed registry login management, reviewed native pull/push
transfers, reviewed Dockerfile/Containerfile builds through Apple’s public
BuildKit APIs with image-store, OCI-archive, root-filesystem tar, and folder
outputs, one-shot reviewed file-backed build secrets, reviewed shared-builder
Stop/Force Stop/internal-cache reset, a transactional app-owned local build
cache with token-bound promotion and separate status/reset controls, private
persistent build history, and macOS restore-image preparation, installation,
generation-safe runtime/console controls, per-VM opt-in host audio input that
resets on clone/export, host audio output, same-host suspend,
persistent VirtioFS shares, per-VM automatic NAT/shared/host-only networking,
and stopped-only VM cloning with fresh platform
identity and cancellable APFS/sparse transfer. Portable VM package export/import
supports identity-preserving restore or an explicit fresh-identity copy, with
cancellable transaction cleanup and no destination replacement. Installed macOS
VMs can now convert a stopped RAW disk to ASIF through a journaled, out-of-place transaction;
the runtime reads logical capacity through DiskImageKit instead of mistaking the
sparse container's host file length for guest capacity. TERM-to-KILL cancellation
keeps uncertain exits quarantined, and pending replacement journals block runtime,
discard, clone, and transfer paths until recovery is safe. Standalone ASIF disks
can also be rewritten out of place; the manifest switches only when the verified
candidate has a smaller measured allocation, without claiming guaranteed
compaction or APFS free-space recovery. Persistent Linux machines now have native
create/start/stop/Force Stop/delete controls, cancellable first-boot user
provisioning with bounded XPC and automatic stop-to-KILL recovery, and CPU,
memory, and reviewed home-directory configuration. The same machines now expose
a native login-shell terminal and bounded one-shot shell commands; stopped
machines auto-start and provision before either workflow.
Ordinary container terminals and the exec sheet share typed, bounded shell
discovery instead of assuming `/bin/sh`, while preserving explicit executable
overrides for minimal and custom images. Container and Linux-machine shells now
open in detached, system-restorable SwiftUI windows with bounded app tabs,
identity-pinned reconnects, and validated saved shell presets. Restored tabs stay
disconnected until explicit interaction, so reopening the app does not silently
start machines or shell processes.

The app is composed from narrow injectable service facets. Inventory, container
creation and lifecycle, inspection, command tools, terminal sessions, image
management, infrastructure, attachment resolution, private socket workspace,
host-directory bookmark/manifest management, SSH-agent validation,
host-access discovery, build-secret review/consumption, shared-builder
management, build-history recording and persistence, machine lifecycle, bounded
XPC/process transport, machine image preparation, machine process-target
resolution, machine commands/terminals, container shell discovery, canonical
Compose topology derivation,
source-pinned and isolated live Compose conformance, reviewed Compose planning,
container/resource action execution, command execution, postcondition proof,
owned-resource recovery, VM bundle transactions, cancellable bundle transfer,
portable package preparation/import/export, platform-identity generation,
installation, runtime, saved state, shared directories, and cloning are
independent services. VM networking is likewise split across a manifest-backed
configuration service, an app-owned vmnet pool, and a focused Virtualization
device factory; SwiftUI only renders snapshots and invokes actions. A
dedicated machine-management service owns machine creation and lifecycle rather
than routing those operations through the container compatibility facade.

## Build

The Xcode project is generated from `project.yml` so project configuration is
reviewable. Build and test with the `NativeContainers` scheme on `My Mac`.
Agent-driven Xcode work uses Xcode MCP exclusively for project configuration,
builds, tests, launches, logs, and debugging. `xcodebuild` and shell-launched app
bundles are intentionally not part of this repository’s development workflow;
see [AGENTS.md](AGENTS.md).

The deterministic suite runs without mutating the local runtime. To run the
reversible live provisioning, Linux-machine lifecycle, attachment, PTY, and
image-reference smokes, set `NATIVECONTAINERS_LIVE_TESTS=1` for the test action.
They create uniquely named
Alpine resources, verify native lifecycle, reviewed volume/network/Unix-socket
attachments, container and machine interactive terminals, machine command
timeout/KILL recovery, and image tag/inspect/delete behavior, and delete every
uniquely created test resource.

Remote push is never exercised against a public registry. An additional
round-trip smoke is available only when
`NATIVECONTAINERS_LOCAL_REGISTRY_REPOSITORY` names a repository on a disposable
`localhost`, `127.0.0.1`, or `[::1]` registry.

Native build smokes are separately gated because first use can fetch and start
Apple’s shared builder VM. Set `NATIVECONTAINERS_LIVE_BUILD_TESTS=1` to build a
unique Alpine-derived image through the signed embedded worker, verify its
snapshot and marker in a running container, and remove the test resources.
The longer cancellation probe requires
`NATIVECONTAINERS_LIVE_BUILD_CANCELLATION_TESTS=1`.

The reviewed Compose lifecycle wire probe is separately destructive and remains
double gated. Set `NATIVECONTAINERS_LIVE_SOCKTAINER=1`,
`NATIVECONTAINERS_LIVE_COMPOSE_LIFECYCLE=1`, and explicitly point
`NATIVECONTAINERS_SOCKTAINER_BINARY` at the pinned bridge to exercise isolated
Up, Stop, Start, and Down with Apple-inventory proof and exact cleanup.
