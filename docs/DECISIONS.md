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

## ADR-010: Keep terminal transport native and terminal rendering replaceable

**Status:** Accepted — 2026-06-20

Interactive shells use Apple’s `ContainerClient.createProcess` directly with
`ProcessConfiguration.terminal` enabled. The app passes stdin and stdout file
descriptors across the same XPC boundary as Apple’s CLI, starts and resizes the
returned `ClientProcess`, forwards raw input and signals, and owns deterministic
hangup-to-kill shutdown. It does not launch `container exec`, allocate a second
PTY in the GUI, or decode output into lines before rendering.

SwiftTerm 1.13.0 is pinned as the replaceable VT renderer. It supplies the
AppKit terminal view, input method integration, selection, scrollback, escape
sequence handling, and terminal protocol replies. The app-specific adapter
blocks guest-originated OSC 52 clipboard writes and only opens HTTP(S) links.
Transport types do not import SwiftTerm.

The Apple package graph is also pinned directly to Containerization 0.33.3 for
the public terminal-size type, exactly matching `apple/container` 1.0.0. This
avoids dependency skew while keeping terminal process ownership inside Apple’s
service client.

Pipe output uses `poll` followed by one POSIX `read`. Foundation’s bounded file
read can wait for the requested byte count or EOF on a blocking descriptor,
which is incorrect for small interactive bursts. The output stream applies
bounded backpressure without dropping bytes, while a separate bounded tail
exists only for reconnect/error recovery.

Input uses a serialized, nonblocking `poll`/`write` pump so SwiftTerm callback
ordering is preserved and a full guest pipe cannot pin an actor executor.
Writes set `F_SETNOSIGPIPE` and temporarily block and drain only the calling
thread’s `SIGPIPE`; the app never changes process-wide signal disposition.
Output reads and descriptor closure share a lifetime lock to prevent descriptor
reuse races. A failed kill is retained as a visible, retryable failed session,
and opening a replacement shell sends a full terminal reset before new output.

## ADR-011: Plan destructive image mutations against Apple’s live store

**Status:** Accepted — 2026-06-20

Image state remains owned by Apple’s `ClientImage` XPC service. The global app
inventory keeps only inexpensive reference/index metadata, while selection
resolves OCI variants lazily behind a narrow `ImageManaging` protocol. Stable
SwiftUI identity is the canonical reference, not `reference@digest`, so moving a
mutable tag does not discard selection.

Tag, delete, and prune are plan-based. A plan records the reviewed canonical
reference and digest. Execution re-fetches current state, refuses digest changes
observed before mutation, blocks builder/vminit images and in-use references,
and never expands a prune batch with candidates that appeared after
confirmation. Tag replacement requires an explicit second action when the
target currently names a different digest.

Batch deletion mirrors Apple’s safe content semantics: remove each reference
with garbage collection disabled, then request one global orphan cleanup. The
result distinguishes successfully removed references, skipped/failed entries,
deleted blob digests, and actual reclaimed bytes. Shared layers and aliases are
therefore preserved by the content store rather than guessed in the UI.

Apple Containerization’s `AsyncLock` serializes every app-initiated pull,
container creation, tag, delete, and prune across actor suspension points. This
keeps a second app window from changing image state between revalidation and the
XPC mutation. Apple 1.0.0’s tag and delete requests do not carry a digest
precondition, so a concurrent external CLI or process can still race the final
reference-only request; full cross-process compare-and-swap safety requires an
upstream API addition.

## ADR-012: Share Apple container registry credentials without owning secrets

**Status:** Accepted — 2026-06-20

Registry login metadata is presented through a narrow `RegistryManaging`
adapter, while credentials are written by ContainerizationOCI’s
`KeychainHelper` to `Constants.keychainID` (`com.apple.container.registry`).
This is the same domain used by Apple’s CLI and image XPC service. The app never
lists stored passwords; a new password/token remains in secure SwiftUI state
only for the validation-and-save operation.

Login resolves and canonicalizes the endpoint, pings `/v2/` with the proposed
credential before saving, and confirms both resolved HTTP and replacement of a
different stored user. Login/logout use Apple’s async lock and immutable review
metadata, then re-list immediately before mutation. Cancellation is checked
after the network ping and immediately before save. A post-mutation list failure
is reported as a refresh warning rather than pretending the Keychain mutation
failed.

Apple’s Keychain entry stores no transport; pulls and pushes must resolve and
confirm HTTP independently. `KeychainHelper.save` deletes before adding a
replacement, so an uncommon add failure can lose the previous credential.
Apple 1.0 also provides no atomic cross-process compare-and-swap, leaving a
narrow external-CLI race after the final metadata check.
