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

## ADR-013: Review image transfers and report durable partial completion

**Status:** Accepted — 2026-06-20

Pull and push use immutable plans. Review records the canonical local reference,
digest, exact platform scope, requested and resolved transport, and transfer
options. Execution holds the same runtime mutation coordinator used by image
CRUD, reloads live state, rejects transport or digest drift, repeats normalized
builder/vminit protection, and checks cancellation immediately before the Apple
network or snapshot call. HTTP, all-platform download, local tag replacement,
and remote mutable-tag replacement are fail-closed confirmations.

Apple’s pull commits its local reference before app-side platform validation and
snapshot creation. The app does not describe those later failures as an atomic
pull failure or silently try to restore a mutable prior tag. It publishes a
typed partial-completion result containing the committed reference/digest and
refreshes inventory. Snapshot outcomes are recorded per exact OCI platform as
already present, newly created, or failed.

All-platform snapshot creation enumerates non-attestation manifests and calls
`getCreateSnapshot` for each platform. This deliberately avoids
`unpack(platform:nil)`, whose pinned implementation can return success after
silently skipping platforms without an unpacker. A transfer is only described
as unpacked when every enumerated platform has a verified snapshot.

Push publishes the selected `ClientImage.reference` because Apple’s API has no
destination argument. The user must create a local destination tag first. The
app validates an exact requested platform before push, retains and cancels UI
tasks across sheet lifetime, and provides an opt-in round-trip smoke only for a
disposable localhost registry. If push throws after the network call begins,
remote state is reported as uncertain rather than safe to retry blindly.

## ADR-014: Isolate native BuildKit sessions and finalize images in the app

**Status:** Accepted — 2026-06-20

Dockerfile and Containerfile builds use the exact pinned
`ContainerBuild.Builder` API, not an installed CLI and not a second build
engine. `Builder` owns an unstructured gRPC task, a vsock, and a caller-supplied
NIO event-loop group without a public shutdown method in 1.0.0. Each builder
preparation or build therefore runs in a bundled, code-signed, one-shot tool.
The app launches its exact bundle URL without a shell, exchanges 1 MiB-capped
length-prefixed Codable frames, drains raw BuildKit stderr concurrently, and
uses stdin as a parent-lifetime lease. Cancellation sends TERM, then KILL after
a grace period; an orphaned worker exits when the parent lease closes. The
worker consumes its small request with one POSIX `read`, because Foundation’s
counted pipe read can wait for a full buffer while that lease remains open.

The worker never applies a requested mutable tag. BuildKit exports one OCI
archive under a unique `nativecontainers.local` staging reference. The worker
descriptor-validates that guest-visible export, copies it to an app-owned
mode-0700 directory as a mode-0400 `out.tar`, records its byte count and SHA-256,
removes the shared copy, and exits. The app validates the digest when accepting
the artifact, then revalidates the exact inode metadata and length immediately
before loading it. Under the app-wide image mutation lock,
the GUI revalidates every reviewed target digest, imports the archive, verifies
and materializes every exact platform snapshot, applies the reviewed tags, and
removes the staging reference only if its digest is unchanged. Import and tag
exceptions are reconciled by re-listing committed state; any durable work is
reported as success or explicit partial completion rather than safe to retry.

The shared `buildkit` container is Apple infrastructure. A pure policy checks
its role/plugin labels, pinned executable and arguments, root non-TTY process,
capabilities, exact export mounts, built-in network, image descriptor digest,
DNS configuration, resources, Rosetta, and managed color environment. Identity
conflicts, stopping state, and unknown state are never overridden.
Configuration drift requires separate explicit permission to recreate a
stopped builder or to stop a running builder; the latter warns that an external
CLI build may be interrupted. A failed create never stops a running or
uncertain builder that may belong to another process. The controller retains
the reviewed snapshot and re-fetches the same creation timestamp and full
identity immediately before each mutation and both before and after dialing.
Post-dial drift closes the socket before `Builder` construction. Apple’s
reference-only API still cannot provide a cross-process compare-and-swap for
the final call.

Build contexts are copied beneath a UUID-named mode-0700 app staging boundary
through `lstat`, `O_NOFOLLOW`, and bounded descriptor reads. Symlinks and
special files are rejected; regular-file and child-directory POSIX modes are
preserved so Docker `COPY` semantics remain correct. Dockerfiles at or above
16 KiB are rejected, and custom `# syntax=` frontends are not accepted. A
sorted SHA-256 fingerprint covers entry kind, mode, ownership, size, mtime, and
file bytes and is checked immediately before and after `Builder.build`.
Detached staging propagates cancellation and removes partial trees. A changed
context can produce a disposable archive but cannot be imported or tagged.
Canonical Dockerfile and ignore paths must be strict component-wise descendants
of the staged context; textual prefix checks are invalid because directory URLs
may retain a trailing separator and sibling names may share the same prefix.
This staging and process isolation is a lifecycle and consistency boundary,
not an App Sandbox or a defense against a fully compromised same-user process.

Only one build runs at a time. Containerization 0.33.3 has a platform-Hashable
bug fixed after the pin that can break concurrent multi-stage builds. Its
`AsyncLock` also cannot cancel queued waiters, so the app uses a local
cancellation-aware FIFO lock and cleans a queued plan immediately on cancel.
Builder preparation and final image-store mutation share the runtime mutation
lock; the long BuildKit solve uses the separate single-flight lock so ordinary
container lifecycle work is not blocked for the entire build.

## ADR-015: Review named infrastructure by intrinsic configuration identity

**Status:** Accepted — 2026-06-20

Volumes and networks remain authoritative in Apple’s container service. A
create review pins absence and carries a hidden operation UUID label so a lost
XPC reply can be reconciled without blindly retrying. Delete and prune reviews
pin every intrinsic configuration field plus current referring container IDs;
execution re-fetches that state under the shared runtime mutation coordinator
and fails closed on replacement, new use, or a built-in network.

Every infrastructure request owns a fresh XPC connection. User cancellation
closes it immediately and a 60-second watchdog closes it automatically. Because
the server may commit before a connection closes, post-error reconciliation is
mandatory and runs in a fresh task that does not inherit the cancelled state.
Owned resources created before cancellation are removed and verified; partial
prune results retain exact removed, remaining, and reclaimed state. Apple’s
name-only delete API still lacks compare-and-swap semantics,
so cross-process replacement between the final check and call cannot be made
impossible in 1.0.

## ADR-016: Bound and verify failed container-creation cleanup

**Status:** Accepted — 2026-06-20

Every failed or cancelled container creation performs ownership-checked cleanup
after releasing the shared runtime mutation lease. A dedicated short-lived XPC
client sends `KILL` for a running owned container, requests force deletion,
retries once, and verifies absence. Cleanup never acts on a replacement with a
different operation label. If the postcondition cannot be verified, the app
reports both the original operation error and cleanup failure instead of
claiming rollback succeeded.
