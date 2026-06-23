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
- [Distribution](docs/DISTRIBUTION.md)
- [User-data migration and rollback](docs/DATA_MIGRATION.md)
- [Accessibility quality gate](docs/ACCESSIBILITY_QA.md)
- [Roadmap](docs/ROADMAP.md)
- [Feature matrix](docs/FEATURE_MATRIX.md)
- [Research notes](docs/RESEARCH.md)
- [Architecture decisions](docs/DECISIONS.md)
- [Current status](docs/STATUS.md)

The current foundation includes native container lifecycle and inspection,
exec/copy and interactive PTY workflows, stopped-container root-filesystem
export through Apple's public client with identity-pinned, create-new-only tar
publication, safe OCI image management, reviewed
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
resets on clone/export, host audio output, same-host suspend for macOS and GUI Linux,
persistent typed console windows that restore without starting a guest,
persistent macOS and GUI Linux VirtioFS shares, stopped-only renaming and
host-bounded CPU/memory editing, generation-pinned cooperative runtime memory
targets for both GUI guest families, per-VM automatic
NAT/shared/host-only networking for both guest families, and stopped-only
macOS and GUI Linux VM cloning with fresh guest-specific
platform identity and cancellable APFS/sparse transfer. Portable VM package
export/import supports both guests, identity-preserving restore, or an explicit
fresh-identity copy, with cancellable transaction cleanup and no destination
replacement. Installed macOS
VMs can now convert a stopped RAW disk to ASIF through a journaled, out-of-place transaction;
the runtime reads logical capacity through DiskImageKit instead of mistaking the
sparse container's host file length for guest capacity. TERM-to-KILL cancellation
keeps uncertain exits quarantined, and pending replacement journals block runtime,
discard, clone, and transfer paths until recovery is safe. Standalone ASIF disks
can also be rewritten out of place; the manifest switches only when the verified
candidate has a smaller measured allocation, without claiming guaranteed
compaction or APFS free-space recovery. Stopped macOS and GUI Linux VMs can
also keep up to eight named, bundle-local disk checkpoints through native
DiskImageKit overlay stacks. Creating or restoring a checkpoint is
saved-state-free and lease-serialized; restore prunes newer history, and each
runtime opens only the top layer writable. Both guest families can grow their
virtual disk through a shared, crash-recoverable DiskImageKit transaction. Growth is
forward-only, blocks saved state and competing runtime/transfer operations,
and preserves the larger capacity when an older disk checkpoint is
restored. The guest partition and file system still require an in-guest expand;
NativeContainers does not claim guest-aware shrink or automatic partitioning.
Persistent Linux machines now have native
create/start/stop/Force Stop/delete controls, cancellable first-boot user
provisioning with bounded XPC and automatic stop-to-KILL recovery, and CPU,
memory, and reviewed home-directory configuration. Existing machines can edit
those settings through a dedicated identity-pinned configuration service and
native sheet; changes are verified after persistence and apply on the next
start or restart. The same machines now expose
a native login-shell terminal and bounded one-shot shell commands; stopped
machines auto-start and provision before either workflow.
Kubernetes now has a dedicated native control plane built on those Apple
machine APIs: one isolated K3s machine with no host-home mount, a pinned and
checksum-verified install, crash-resumable identity-bound setup, native
start/stop/Force Stop/delete/status controls, and explicit in-memory kubeconfig
export without host-side credential persistence. Its bounded native resource
browser keeps workload and Pod identity pinned, supports preconditioned
Deployment/StatefulSet scaling, optimistic-locked Deployment, StatefulSet, and
DaemonSet restarts, UID/resourceVersion-preconditioned foreground workload
deletion, bounded Pod logs, identity-bracketed one-shot Pod commands, and
identity-checked interactive Pod terminals without exporting workload payloads
or credentials to the host.
Ordinary container terminals and the exec sheet share typed, bounded shell
discovery instead of assuming `/bin/sh`, while preserving explicit executable
overrides for minimal and custom images. Container and Linux-machine shells now
open in detached, system-restorable SwiftUI windows with bounded app tabs,
identity-pinned reconnects, and validated saved shell presets. Restored tabs stay
disconnected until explicit interaction, so reopening the app does not silently
start machines or shell processes.

macOS and GUI Linux VM consoles likewise open in typed SwiftUI windows instead
of modal sheets. Reopening the same VM brings its existing window forward,
while restoration resolves the current manifest and never serializes or starts
a live Virtualization session.

The app is composed from narrow injectable service facets. Inventory, container
creation and lifecycle, inspection, command tools, stopped-filesystem export,
terminal sessions, image
management, infrastructure, attachment resolution, private socket workspace,
host-directory bookmark/manifest management, SSH-agent validation,
host-access discovery, build-secret review/consumption, shared-builder
management, build-history recording and persistence, machine lifecycle and
configuration, shared machine-snapshot mapping, bounded XPC/process transport,
machine image preparation, machine process-target
resolution, machine commands/terminals, container shell discovery, canonical
Compose topology derivation,
source-pinned and isolated live Compose conformance, reviewed Compose planning,
container/resource action execution, command execution, postcondition proof,
owned-resource recovery, VM bundle transactions, cancellable bundle transfer,
portable package preparation/import/export, platform-identity generation,
installation, runtime, saved state, shared directories, cloning, Linux VM
creation, installer ejection, and native console presentation are independent
services. VM networking is likewise split across a manifest-backed configuration
service, an app-owned vmnet pool, and a focused Virtualization device factory;
runtime memory targets flow through a separate generation-pinned Virtio balloon
controller and are reported as cooperative requests rather than reclaimed bytes;
physical USB uses a separate AccessoryAccess discovery adapter,
generation-pinned runtime controller service, and entitlement-aware composition
gate. SwiftUI only renders snapshots and invokes actions. A dedicated
machine-management service owns machine creation and lifecycle rather than
routing those operations through the container compatibility facade.

## Build

The Xcode project is generated from `project.yml` so project configuration is
reviewable. Build and test with the `NativeContainers` scheme on `My Mac`.
Agent-driven Xcode work uses Xcode MCP exclusively for project configuration,
builds, tests, launches, logs, and debugging. `xcodebuild` and shell-launched app
bundles are intentionally not part of this repository’s development workflow;
see [AGENTS.md](AGENTS.md).

The deterministic suite runs without mutating the local runtime. To run the
reversible live provisioning, Linux-machine lifecycle, attachment, PTY,
image-reference, and stopped-filesystem-export smokes, set
`NATIVECONTAINERS_LIVE_TESTS=1` for the test action. They create uniquely named
Alpine resources, verify native lifecycle, reviewed volume/network/Unix-socket
attachments, container and machine interactive terminals, machine command
timeout/KILL recovery, image tag/inspect/delete behavior, and a stopped-rootfs
marker/digest/replacement round trip, then delete every uniquely created test
resource and private output.

The general-purpose GUI Linux VM smoke is separately gated because it boots a
real `VZVirtualMachine` and copies a multi-gigabyte installer into an isolated
bundle. Set `NATIVECONTAINERS_LIVE_LINUX_VM=1`,
`NATIVECONTAINERS_LIVE_LINUX_VM_ISO` to a locally readable ARM64 `.iso`, and
`NATIVECONTAINERS_LIVE_LINUX_VM_ISO_SHA256` to its reviewed digest. The smoke
hashes the source, boots the production Virtio configuration, verifies the
running console object, pause/resume, memory-balloon requests, force stop, and
exact cleanup. Optionally set
`NATIVECONTAINERS_LIVE_LINUX_VM_VISUAL_SECONDS` to an integer from 1 through
7,200 to present the exact production `VirtualMachineConsoleView` in a native
window before the lifecycle checks. The reviewed Ubuntu 26.04 run rendered
GRUB, completed the graphical installer, rebooted from the virtual disk, and
authenticated into the installed GNOME first-run desktop there.
Set `NATIVECONTAINERS_LIVE_LINUX_VM_INPUT_PROBE=1` with a visual hold of at
least 34 seconds to focus that production `VZVirtualMachineView`, exercise the
GRUB selection with Down, Up, and Return, and publish an owner-only input
channel in the visual-ready marker. The channel accepts one tab-delimited,
at-most-4-KiB command at a time:

```text
<id>\tkey\t<tab|shift-tab|escape|space|left|right|down|up|return>
<id>\tclick\t<x>\t<y>
<id>\ttext\t<base64-encoded UTF-8>
<id>\teject-media\t-
<id>\tfinish\t-
```

Click coordinates use the guest display's top-left origin. Write through a
single-link regular temporary sibling owned by the current user and rename it
to the advertised `command` path; each accepted command appears as
`stage=command-<id>` in the marker. `eject-media` uses the production runtime to
persist installation completion and detach the ISO. `finish` ends the visual
hold early and continues the lifecycle and cleanup assertions.

For an Xcode MCP run that cannot inherit test-scheme environment variables,
write the equivalent configuration as owner-only mode-0600 JSON to
`FileManager.default.temporaryDirectory` (normally
`$TMPDIR/nativecontainers-live-linux-vm-run-request.json`). The smoke
accepts only a current-user, single-link regular file, consumes it once, and
supports `isoPath`, `isoSHA256`, `visualHoldSeconds`, `probesGuestInput`, and
`requiresInstallationMediaEjection`. An optional `sharedDirectories` array may
contain up to eight objects with an absolute `sourcePath`, `guestName`, and
`readOnly` policy. Each entry goes through the production stopped-VM service,
security-scoped bookmark validation, sidecar persistence, and runtime VirtioFS
resolution; a successful start proves host attachment, while guest access still
requires the documented
`mount -t virtiofs nativecontainers /mnt/nativecontainers` command. The reviewed
run used the command channel to complete the Ubuntu installer, request its
reboot, authenticate after disk boot, persist production ISO ejection, and then
complete exact lifecycle and bundle cleanup. Audio and the other expanded
installed-guest integrations are not inferred from that pass.

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
