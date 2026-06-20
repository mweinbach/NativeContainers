# Architecture decision log

## ADR-001: Use Apple’s service client libraries

**Status:** Accepted — 2026-06-20

The GUI integrates the public library products from the exact installed
`apple/container` release instead of parsing CLI tables. The Apple services own
container state; our adapter only maps snapshots into stable app-domain values.

CLI invocation remains an escape hatch for installer/service operations that do
not have a published client API, never the default data plane.

## ADR-002: Keep container micro-VMs and user VMs separate

**Status:** Accepted — 2026-06-20

Container micro-VMs are implementation details managed by Apple’s runtime.
Persistent Linux container machines are first-class Apple runtime resources.
General Linux and macOS VMs are app-owned Virtualization.framework bundles.
They get separate service protocols and UI sections.

## ADR-003: Require macOS 26 and Apple silicon

**Status:** Accepted — 2026-06-20

Apple supports `container` on macOS 26+ and Apple silicon. Compatibility shims
for older hosts would undermine the native-runtime objective and multiply the
test matrix before the core product exists.

## ADR-004: Self-contained, versioned VM bundles

**Status:** Accepted — 2026-06-20

Every app-owned VM is a directory bundle with a versioned manifest and relative
resource paths. Creation is transactional. Moving, cloning, backing up, and
deleting a VM therefore have one obvious filesystem boundary.

## ADR-005: NAT networking first

**Status:** Accepted — 2026-06-20

NAT is the public, low-friction Virtualization.framework default. Bridged
networking is deferred until entitlement availability, signing, and distribution
constraints are proven. Apple container networking remains owned by its runtime.

## ADR-006: Bundle a namespaced, version-matched runtime for distribution

**Status:** Accepted — 2026-06-20

The foundation talks to the installed Apple 1.0.0 services so API integration
can be proven immediately. The shipping app will embed a namespaced build of
the matching Apple services/helpers and use app-owned Mach service labels,
sockets, and data roots. This avoids collisions with the standalone CLI and
prevents unsupported client/server drift.

## ADR-007: Treat Docker Engine compatibility as a plugin

**Status:** Accepted — 2026-06-20

Apple’s runtime does not implement the Docker Engine HTTP API. Docker CLI and
Compose compatibility will live behind a separate adapter, initially based on
Socktainer and backed by protocol conformance fixtures. The native app remains
fully usable without that compatibility mode.

## ADR-008: Compose container creation from public client primitives

**Status:** Accepted — 2026-06-20

The GUI uses `ClientImage`, `ClientKernel`, `NetworkClient`,
`ContainerConfiguration`, and `ContainerClient` directly for provisioning. It
does not invoke `Utility.containerConfigFromFlags`, even though that helper is
public: repeated Xcode preview and test-host probes exited the host process with
status 1 inside that CLI-oriented orchestration path. The equivalent direct
sequence passed a live create/inspect/delete smoke test and gives the app clear
transaction, progress, and error boundaries.

Parser helpers remain appropriate for OCI command/environment merging,
resource syntax, and port descriptors. The app owns orchestration and rollback.

## ADR-009: Separate restore-image cache from transactional VM identity

**Status:** Accepted — 2026-06-20

Downloaded IPSWs live in the app cache rather than inside every VM bundle. A
persistent `.partial` file supports HTTP range continuation; a validated 206
response appends at exactly the requested offset, a 200 response restarts the
file, cancellation keeps resumable bytes, and a complete response is promoted
atomically. Progress is coalesced so a multi-gigabyte transfer cannot build an
unbounded UI backlog.

The VM bundle stores only the artifacts that define that virtual Mac: disk,
hardware model, machine identifier, auxiliary storage, and manifest. Those
platform artifacts are prepared together in a staging directory. The directory
is atomically renamed before the manifest is atomically updated; any failure
removes staged or promoted artifacts and leaves the draft manifest unchanged.

This avoids copying a large IPSW per VM while preserving a self-contained VM
identity boundary for move, clone, backup, and delete operations.
