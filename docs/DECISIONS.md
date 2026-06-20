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

