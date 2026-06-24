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

**Status:** Superseded by ADR-088 — 2026-06-23

The foundation talks to the installed Apple 1.0.0 services so API integration
can be proven immediately. The shipping app will embed a namespaced build of
the matching Apple services/helpers and use app-owned Mach service labels,
sockets, and data roots. This avoids collisions with the standalone CLI and
prevents unsupported client/server drift.

The implementation audit in ADR-088 found that this would require a maintained
fork of both Apple’s public clients and its installed service graph, not merely
an alternate app-bundle layout. NativeContainers now uses the official signed
system runtime as an explicit prerequisite instead.

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

ADR-040 preserves this shared-image boundary but supersedes the physical Caches
location for new acquisitions.

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

Interactive shells use the same public container process routes as Apple’s
client with `ProcessConfiguration.terminal` enabled, but cross them through the
app’s cancellation-closeable, bounded `AppleContainerProcessXPCClient`. The app
passes stdin and stdout file descriptors across the same XPC boundary as
Apple’s CLI, starts and resizes the returned runtime-process handle, forwards
raw input and signals, and owns deterministic hangup-to-kill shutdown. It does
not launch `container exec`, allocate a second PTY in the GUI, or decode output
into lines before rendering.

SwiftTerm 1.13.0 is pinned as the replaceable VT renderer. It supplies the
AppKit terminal view, input method integration, selection, scrollback, escape
sequence handling, and terminal protocol replies. The app-specific adapter
blocks guest-originated OSC 52 clipboard writes and only opens HTTP(S) links.
Transport types do not import SwiftTerm.

The Apple package graph remains pinned to versions matching
`apple/container` 1.0.0. The app carries a small validated terminal-size value
and sends the pinned process route’s width/height fields directly, avoiding
dependency skew without accepting the high-level client’s unbounded XPC waits.

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
retries with bounded backoff, and verifies absence. Cleanup never acts on a
replacement with a different operation label. If the postcondition cannot be
verified, the app reports both the original operation error and cleanup failure
instead of claiming rollback succeeded.

## ADR-017: Compose the app from narrow service facets

**Status:** Accepted — 2026-06-20

`AppCompositionRoot` is the only live dependency-construction site. It creates
one container runtime graph and injects the same `RuntimeMutationCoordinator`
into container, infrastructure, machine, and image-build mutation paths.
`AppServices` exposes narrow inventory, lifecycle, creation, inspection,
tooling, terminal, machine-creation, machine-lifecycle, image, volume, network,
and browser facets to `AppModel`; views keep their existing model factories
and do not act as service locators.

Low-level XPC sending, runtime inventory aggregation, creation, lifecycle,
inspection, tooling, terminal sessions, image management,
volume/network/browser management, machine inventory/workflow/XPC/process
operations, and owned-container recovery are separate services. `AppleContainerService`
remains a forwarding-only compatibility facade for container capabilities;
machine operations no longer pass through it. This preserves one global
mutation order while allowing deterministic timeout,
cancellation, reconciliation, malformed-reply, routing, and cleanup tests.

## ADR-018: Review attachments and confine published sockets

**Status:** Accepted — 2026-06-20

Container creation records complete volume and network configuration identities
rather than mutable names alone. Resolution re-lists infrastructure and all
container configurations under the creation mutation lease, rejects stale or
newly used volumes, preserves reviewed network order, and constructs Apple's
mount, attachment, and `PublishSocket` values directly. The app never uses the
CLI parser paths that can auto-create storage or remove an arbitrary host leaf.

Apple's runtime opens published host sockets with `unlinkExisting` and removes
them on stop. Host destinations are therefore generated only beneath a
current-user, mode-0700 operation directory at
`/private/tmp/nativecontainers-<uid>/<operation UUID>`. Creation uses atomic
`mkdir` plus `lstat`, socket names and lexical parents are validated before
every start, occupied leaves are never replaced by the app, and the host path
is capped below 104 UTF-8 bytes. Missing private directories may be recreated
from the persisted operation label; rollback and delete remove only that exact
operation directory.

Host access remains global privileged resolver/PF state. The unprivileged app
only recognizes exact root-owned, non-writable resolver and packet-filter files
and exposes Apple's fixed setup command. It does not run `sudo` or report PF as
active from disk state alone. Any future mutation path must be a separately
signed and notarized helper with a narrow authorization contract.

## ADR-019: Manage the shared builder through a reviewed service boundary

**Status:** Accepted — 2026-06-20

Builder maintenance is independent from image-build orchestration. A narrow
`ContainerBuilderManaging` service owns inspection, action review, mutation,
and reconciliation; the build form and Builder & Cache view depend on separate
models. The service and signed build worker share one snapshot adapter and pure
identity policy so they cannot drift on what qualifies as Apple’s reserved
`buildkit` container.

Stop, explicit `KILL`, and stopped-only deletion take the image-build
single-flight lock before the global runtime mutation lock. Immediately before
mutation the service re-fetches the runtime root, creation date, full identity,
and configuration frozen by review. Running never implies idle because the
native API cannot observe an external CLI solve; both stop paths require a
destructive confirmation that states this limitation.

Mutation errors do not imply rollback. Reconciliation uses fresh uncancelled
reads and accepts only the requested postcondition for the same reviewed
identity. Deletion uses Apple’s non-force route and succeeds only when inventory
is absent and the exact `<appRoot>/containers/buildkit` bundle fails `lstat`
with `ENOENT`. A remaining bundle is an explicit incomplete-cleanup state. The
app never deletes that bundle manually and never touches `<appRoot>/builder`,
which holds exports rather than the container’s BuildKit cache.

## ADR-020: Stream reviewed build secrets through a one-shot vault

**Status:** Accepted — 2026-06-20

Build-secret values must not enter a reviewed plan, observable app state,
Codable worker request, environment, argument vector, temporary file, or retained
diagnostic. A focused `ImageBuildSecretManaging` actor therefore owns each
review. It holds security-scoped, `O_NOFOLLOW` descriptors for private
owner-only files outside the build context, freezes their full filesystem
identity, and exposes only ID, privacy-sensitive path, and byte count to the plan.
Descriptors are pinned before context staging; the stager rejects matching
device/inode identities so a transient hard link cannot copy a secret into the
reviewed context.

Execution consumes the review once, after the shared builder is ready. Protocol
v3 reads the JSON control frame at its exact declared length and then a bounded
binary envelope plus a final commit marker from the same anonymous stdin pipe,
preserving stdin as the parent-death lease without read-ahead loss. The app
streams directly from each pinned descriptor through a zeroed bounded buffer;
the source payload destructively releases its leases when the write completes.
Empty and arbitrary binary values are supported. IDs are canonical and unique;
file and aggregate sizes are bounded by local product policy before Apple’s
`[String: Data]` API is called in the isolated worker.

A Dockerfile can deliberately print a mounted value, and Apple’s 1.0.0 builder
routes normal solve output to the helper’s stderr. Secret builds therefore set
`quiet`, drain but never retain stderr, sanitize failure events, and publish a
fixed suppression notice. Apple still creates `Data`, base64 string, metadata,
and HTTP/2 copies internally, so this boundary promises non-persistence and a
one-shot worker lifetime—not cryptographic memory zeroization.

## ADR-021: Own a private, typed build-history service

**Status:** Accepted — 2026-06-20

Apple’s public 1.0.0 builder surface exposes no history contract. Build history
is therefore an app-owned observation service rather than runtime inventory.
`RecordingImageBuildService` decorates the native builder, records a running
attempt before execution, and best-effort replaces it with a typed success,
partial-success, failure, cancellation, or interruption outcome. Recording
failures never mask or alter the underlying build result.

`ImageBuildHistoryStore` owns one schema-versioned JSON file per attempt under a
current-user mode-0700 Application Support directory. Writes use private
temporary files, `fsync`, and atomic rename; records are mode 0600, corrupt
records are isolated, terminal retention is capped at 200, and a running record
from another app launch is reconciled to interrupted only after its advisory
process lease is no longer held. Newer schemas are reported but retained. A
separate private-file service retains the verified directory descriptor, uses
descriptor-relative operations, bounded enumeration, advisory locking, and
nonblocking reads, strips and syncs inherited ACLs, scavenges interrupted
temporary writes, and durably syncs deletes. The store persists a terminal
replacement before pruning retention and accepts only running-to-terminal
replacement for the same attempt identity.

Lease files are removed on graceful release and stale foreign leases are
scavenged opportunistically. Store update streams publish mutations immediately
within one process and sample a cheap directory token while a History view is
visible; only token changes or a known foreign-running lease losing its lock
trigger a record reload. Refresh requests coalesce during slow I/O, and rejected
record counts are latched across windows until explicit clearing. This lets a
second app process converge without pretending the files are a database.
Additive schema-1 fields decode with explicit defaults; unsupported later schema
versions remain on disk for a newer app rather than being treated as corruption.

The Build workspace owns stable image-build and builder-management models at the
app layer. Navigation stays on Builds while either model holds a reviewed plan or
active operation. Every such operation has an exposed cancellation path; builder
Stop continues to escalate TERM to KILL and Force Stop remains immediate KILL.

The persistence contract intentionally omits full context and secret paths,
build-argument and label values, secret IDs, worker logs, and arbitrary error
messages. It retains display name, immutable fingerprints, requested/completed
tags, platforms, option keys and flags, secret count, timestamps, digest,
retained partial-import reference/digest pairs, and a small typed failure
category. The SwiftUI History workspace depends on its own
observable model and storage port, observes store updates while presented,
warns about isolated unreadable records, and clears history without touching
images, builder state, or cache.

## ADR-022: Bound persistent-machine lifecycle and recovery behind focused services

**Status:** Accepted — 2026-06-20

Persistent Linux machines use separate inventory, creation, lifecycle, image
preparation, Apple machine-transport, and first-boot process-transport services.
The image service uses public fetch/unpack APIs directly instead of the
CLI-oriented flags helper and intentionally prepares standard OCI-rootfs
machines; optional custom machine resource artifacts remain future work. The
composition root shares one machine transport between inventory and mutation
workflows, and the inventory service re-inspects uninitialized list snapshots
because Apple’s persisted list can lag the first-boot marker.

Machine XPC operations use a fresh connection with a 35-second close watchdog.
The first-boot process has independent 10-second create/start and 2-second KILL
bounds; its cancellation-closeable wait is governed by the 30-second setup
waiter rather than a second transport deadline. Caller cancellation closes the
in-flight connection;
after durable creation, failure or cancellation reconciles identity, attempts a
graceful stop, escalates to the verified backing container’s KILL point, and
confirms the terminal state. Explicit Force Stop requires a target-bound
authorization value and also accepts a machine already stuck in `stopping`.
Reply-after-commit errors are reconciled instead of being treated as proof that
the mutation failed.

Image fetch/unpack runs before persistent machine state exists, so that phase
has no machine to stop or KILL. Apple 1.0 also accepts only a mutable ID for
machine deletion. The app revalidates the
complete creation identity immediately before delete and confirms absence
afterward, but it does not claim atomic protection from an external same-name
replacement between those calls.

## ADR-023: Separate Linux-machine readiness from reusable runtime processes

**Status:** Accepted — 2026-06-21

Machine commands and terminals do not enlarge the creation/lifecycle service.
They cross dedicated `MachineCommandRunning` and `MachineTerminalOpening`
facets. `AppleLinuxMachineProcessTargetResolver` first requires a stable
creation identity, invokes the existing idempotent start/provision workflow,
then re-inspects the complete identity and captures the fresh backing-container
ID created by that boot. A stopped machine is therefore started before use and
remains running afterward, matching Apple's persistent-machine contract; a
command is never replayed when creation or start outcome is uncertain.

The backing container's ordinary init configuration is not safe for this
workflow because it would bypass machine user setup and commonly run as root.
`LinuxMachineProcessConfigurationFactory` instead mirrors the pinned Apple 1.0
`machine run` path: `/sbin.machine/init -s`, the persisted host-mapped UID/GID,
machine home as the GUI-safe default working directory, and only a default PATH
plus explicitly entered environment values. The one-shot UI deliberately
models a shell command, not exact argv, because Apple's wrapper ultimately
executes the discovered guest shell with `-c`. Interactive sessions use
`-s` without a command so the guest's configured user shell is discovered.

Container and machine tools share `AppleRuntimeCommandExecutor`,
`AppleContainerTerminalSession`, and `AppleContainerProcessXPCClient`; only
target resolution and process configuration differ. The process client uses a
fresh bounded connection for create/start and signal/resize, duplicates file
descriptors before the pinned XPC wrapper consumes them, and leaves wait
connections without a false lifetime deadline while preserving
cancellation-triggered close. Commands concurrently drain bounded stdout/stderr tails, and
timeout or cancellation sends KILL only to the fixed process ID and confirms
exit. Terminal close sends hangup, waits briefly, then escalates to KILL. A
create reply loss receives one best-effort KILL against the same process ID;
the app never generates a replacement ID or retries a possibly non-idempotent
command.

Apple container 1.0's high-level process client encodes signals as integers,
while its server decodes signal strings. The focused transport follows the
server contract and regression-tests the exact field representation rather
than inheriting that mismatched high-level path.

## ADR-024: Keep macOS VM runtime ephemeral, leased, and generation-pinned

**Status:** Accepted — 2026-06-21

The macOS installation manifest remains durable provisioning truth and does not
gain running or paused states. An app-scoped `MacVirtualMachineRuntimeService`
owns ephemeral snapshots and one engine session per VM. `AppServices` injects
the coordinator, while `AppModel` returns one stable observable runtime model
per machine so navigation and console closure do not own or stop the VM.

Starting a VM briefly takes the library mutation lock, resolves installed
artifacts without requiring the cached IPSW, and acquires a per-bundle advisory
lease. The lease writes an informational launch/PID/generation sidecar, but the
file lock is authoritative. Installation, discard, and writable runtime access
cannot overlap for the same bundle; a running VM does not hold the global lock
or block unrelated machines.

Each session gets a fresh generation. Pause, resume, graceful stop, destructive
stop, and console lookup must target that generation. Delegate guest-stop and
error callbacks are authoritative terminal events and finalize ownership once.
Caller cancellation never implies that Virtualization.framework cancelled an
accepted operation. A graceful stop leaves the session owned and exposes an
explicit Force Stop; destructive stop never runs automatically and a failed
attempt cannot publish a false stopped state. The native console detaches its
view adaptor when the generation closes so a stale AppKit view cannot retain or
control a replacement VM.

Save/restore remains a separate transaction: save only from paused, write and
atomically promote a partial, bind it to a configuration fingerprint, and treat
the same-host state as non-portable.

## ADR-025: Make macOS saved state single-use and service-owned

**Status:** Accepted — 2026-06-21

macOS suspension is composed from three services instead of adding filesystem
work to the UI-facing runtime coordinator. `MacVirtualMachineRuntimeService`
owns generation-pinned transitions and deferred terminal events.
`MacVirtualMachineSavedStateService` sequences pause/save/restore callbacks.
The actor-isolated `MacVirtualMachineSavedStateStore` owns metadata, durability,
atomic promotion, invalidation, and crash recovery.

A save starts only while the runtime lease is active. The store borrows that
lease so a delegate callback can request release without dropping the advisory
file lock before commit or abort. Only one checkpoint may exist. The partial
state and metadata are synchronized before the directory is atomically renamed
to `SavedState`; replacement is rejected rather than retaining a backup that
could later resurrect stale memory.

Restore is a consuming transaction. `SavedState` is atomically renamed to a
hidden restoring tombstone before Virtualization.framework reads it. The
tombstone is deleted after success or failure, and launch recovery always
deletes an interrupted restore instead of making it available again. This is a
deliberate fail-safe against replaying memory after the writable disk may have
advanced. Starting fresh, discarding, and live resume use the same atomic
invalidation path.

The fingerprint is built from the same Codable topology descriptor used by the
Apple configuration factory, plus opaque hardware/machine-identifier digests
and writable storage seals. The descriptor fixes a deterministic, locally
administered per-VM MAC instead of accepting `VZNetworkDeviceConfiguration`'s
random default. `validateSaveRestoreSupport()` records a capability result; an
unsupported configuration may still cold boot but cannot suspend or restore.

Force Stop stays visible during long operations. Because save and restore do not
provide cancellation, a generation-pinned monitor waits for `canStop`, then
issues destructive stop even while the original callback is pending. Stop
completion is reported separately from callback cleanup: the VM may be stopped,
but ownership remains pinned until that callback quiesces. Terminal delegate
events are deferred across the operation, and ownership is released exactly
once after persistence cleanup.

## ADR-026: Derive exact workspace navigation from live inventory

**Status:** Accepted — 2026-06-21

The app uses one typed `WorkspaceRoute` for both sidebar destinations and exact
container, image, volume, network, Linux-machine, and macOS-VM selection. A
focused `WorkspaceResourceCatalog` maps the current inventory snapshot into
stable search entries and ranks normalized exact, prefix, word-prefix, and
substring matches deterministically. Localized resource-kind titles are indexed
alongside English CLI aliases. The catalog is derived state and is never
persisted; Apple’s services and the VM bundle library remain authoritative.

`WorkspaceNavigationModel` owns the active route, Quick Open presentation, and
prepared results so list views do not each invent incompatible selection state.
When refresh removes the selected resource, the route falls back to that
resource type’s top-level destination rather than silently selecting an
unrelated identity. Missing-resource reconciliation runs only after the owning
inventory service completes successfully. Transient service failures may clear
the visible catalog but retain the exact route for a later recovery refresh.
Views may then select the first current item using the same route API. Command-K
and Overview links are navigation-only and cannot perform mutations.

Navigation and Quick Open presentation are app-scoped, so NativeContainers
declares one unique main `Window` instead of advertising independent windows
that would silently share route and sheet state.

The image-build navigation guard applies to every route, not only sidebar
clicks. A reviewed plan or active build refuses Quick Open and Overview routes
outside Builds until the owning operation is discarded or completed.

## ADR-027: Persist macOS shared folders as leased capabilities

**Status:** Accepted — 2026-06-21

macOS shared folders are composed from focused services rather than embedding
bookmark, filesystem, and Virtualization.framework work in SwiftUI. The UI model
depends on `MacVirtualMachineSharedDirectoryManaging`; the orchestration actor
acquires the existing per-bundle runtime lease and rejects any saved checkpoint;
the library commits a private sidecar; the bookmark service owns scoped access;
and the Apple device factory creates one macOS automount VirtioFS device backed
by `VZMultipleDirectoryShare`.

`SharedDirectories.json` remains inside the `.nativevm` bundle but outside the
provisioning manifest. It is a current-user, mode-0600, bounded regular file
written through an exclusive staging file, synchronization, and atomic rename.
Records retain security-scoped bookmark capability bytes, a stable ID, a guest
name, read-only intent, a display-only last-known path for UI, and a device/inode
seal. Loading rejects links, foreign ownership, permissive modes, duplicate
names or IDs, empty bookmarks, and unsupported schemas.

Every semantic add or remove increments a monotonic revision, including the
transition back to an empty list. The saved-state fingerprint includes that
revision and stable guest-visible semantics, but excludes bookmark bytes and the
last-known path so capability renewal does not invalidate memory. A never-shared
VM continues to emit the legacy topology descriptor, preserving existing
same-host checkpoints; once sharing has history, reverting settings cannot
resurrect an older checkpoint.

Configuration changes are stopped-only and fail closed while the runtime is
owned, transitioning, or checkpointed. Runtime acquisition takes the advisory
lock before reading the sidecar. Resolved security scopes live for the complete
VZ session and are explicitly closed when the runtime coordinator finalizes the
generation. Stale bookmarks fail closed and require the user to choose the
folder again until an atomic capability-renewal path exists; a replacement at
the bookmarked path also fails the device/inode check.

Graceful VM shutdown separately arms a service-owned 30-second watchdog. The
watchdog is pinned to the runtime generation and reuses the explicit Force Stop
path; delegate completion, manual Force Stop, or generation replacement cancels
it. A failed automatic stop retains ownership and leaves manual recovery
available. Waiting for Apple’s destructive-stop capability is itself bounded,
and a terminal delegate event finalizes that wait immediately. There is no
process-level PID kill fallback because the public,
state-aware `VZVirtualMachine.stop` API is the only safe destructive boundary.

## ADR-028: Derive Compose topology as read-only application state

**Status:** Accepted — 2026-06-21

Compose project observability is derived by a pure, injected service from one
completed Apple inventory refresh. It is not coupled to Socktainer availability,
Docker CLI state, or a polling/event stream. The topology is recomputed alongside
the authoritative container inventory and cleared when that inventory refresh
fails, so containers, services, volumes, and networks cannot be mixed across
different app refreshes.

Canonical containers require valid project and service labels. Canonical volumes
and non-built-in networks additionally require their resource-specific Compose
labels. Project and logical-resource names are grammar-validated. Project-only
or malformed container evidence may be displayed as excluded evidence, but it
does not affect project status, canonical reverse indexes, or lifecycle links.
Built-in Apple networks and incomplete or malformed resource labels are notices,
not membership. Anonymous volumes are excluded. Typed reverse associations keep
logical Compose volume/network keys distinct from runtime names and preserve
absent, valid, or invalid optional container labels. Cross-project consumer
references are advisory evidence and never reassign a resource. Source paths are
accepted only from canonical service-container labels, and conflicting values
remain visible.

The Compose workspace and Overview report objective observed facts such as
“1 of 2 containers running.” They make no claim about health, desired replicas,
or Engine parity. Project views are navigation-only; all lifecycle and deletion
operations stay on the existing Apple-backed resource services with their own
review and revalidation boundaries. A future project lifecycle coordinator
requires explicit compatibility fixtures for the pinned bridge first. Generic
volume prune preserves every resource carrying the reserved Compose label prefix;
named-volume removal requires an explicit reviewed deletion path.

## ADR-029: Publish pinned Compose bridge conformance as a pure service

**Status:** Accepted — 2026-06-21

The optional Docker bridge and the Compose compatibility claim have different
owners. Process installation, health, exact-PID TERM-to-KILL, Force Stop, socket
cleanup, and Docker context repair remain in `DockerCompatibilityService` and
its focused collaborators. A separate synchronous
`SocktainerComposeConformanceService` owns the source-pinned capability report.

The report is generated from immutable fixtures tied to Socktainer 1.0.0,
Docker Engine API 1.51, and release revision `876c2fc`. Each fixture declares
the Engine operations required for one Compose behavior. Recreation, aliases,
health checks, and restart policies additionally declare exact semantic-scenario
IDs and require observed postconditions for every scenario. Missing operations
or unpassed scenarios keep that fixture blocked; an HTTP 200 no-op cannot satisfy
rename, connect, disconnect, or any other recreation mutation. Known semantic
gaps such as network aliases, health checks, restart policies, configs, and
secrets cannot become supported merely because create/inspect routes exist.
Project lifecycle is a distinct partial fixture until the blocked semantics pass
against one exact signed release.

Settings may display the report as source-pinned evidence, including partial
and blocked results, but must not present it as a live Compose run. The service
does not touch the socket or Apple runtime and remains independently injectable
for previews and tests. Adding a future Engine operation does not update the
pinned manifest automatically; support must be reviewed and added explicitly.

## ADR-030: Prove Compose compatibility with isolated execution and Apple cleanup

**Status:** Accepted — 2026-06-21

Static route evidence is necessary but cannot prove that a real Compose client,
Socktainer, Apple inventory, and the app’s canonical topology agree. An opt-in
`SocktainerComposeLiveConformanceService` therefore runs one fixed, uniquely
named Alpine service with one named volume and one named network. It never pulls
or builds: the fixture requires an already reviewed local image so a failed
probe cannot leave unowned image-store mutation.

The service is decomposed into workspace, cleanup-planning, native-cleanup, and
execution facets. Commands are bounded by the existing exact-process host
executor. Caller cancellation is recorded, but cleanup runs in a detached task
that does not inherit cancellation; cancellation is rethrown only after absence
is confirmed. Normal cleanup uses the reviewed Compose file and explicit volume
intent. If Compose teardown fails, exact names alone are insufficient: canonical
labels must also match, Apple configuration identities are frozen and
revalidated, the container is force-stopped/deleted through Apple APIs, and
network/volume deletion reuses the native reviewed-plan services. A changed or
foreign resource is left untouched and reported.

This is conformance evidence, not a general project lifecycle coordinator. The
fixture cannot authorize operations on user projects, and the UI does not expose
it until a Docker-independent, version-pinned Compose client installation path
is reviewed. The local proof may use an externally installed standard client;
shipping must not depend on an OrbStack-owned symlink.

## ADR-031: Own and authenticate the Compose client privately

**Status:** Accepted — 2026-06-21

NativeContainers owns one reviewed Docker Compose client instead of resolving a
global standalone binary or a user plugin. The pinned Docker Compose 5.1.4
Darwin arm64 artifact is ad-hoc signed and has no Developer ID team identity, so
macOS code signing cannot authenticate its publisher. The trust contract instead
requires the exact HTTPS release URLs, binary and provenance SHA-256 digests,
thin arm64 Mach-O header, and the expected in-toto/SLSA subject, source tag,
source revision, BuildKit build type, and GitHub Actions builder run.

Download, artifact validation, installation, and observable state are separate
protocol facets. Both downloads are bounded and must be current-user regular
files with one hard link and no group/world write access. Installation stages and
revalidates both files, publishes provenance first and the executable last, then
revalidates the complete private installation. A checked executable accessor
fails closed when either file is missing or changed.

The versioned files live only under NativeContainers’ Application Support tree;
the installer never mutates system, Homebrew, Docker Desktop, or per-user Docker
CLI plugin paths. Settings owns the explicit install/reinstall action and shows
the verified version and path. Gated live Compose coverage now requires this
private client, preventing an OrbStack symlink from silently satisfying product
proof. Upgrades require a new reviewed release contract rather than a moving
latest-version lookup.

## ADR-032: Compose native builds from focused lifecycle services

**Status:** Accepted — 2026-06-21

`AppleContainerBuildService` remains the stable `ImageBuilding` facade and owns
only public phase delegation, build single-flight serialization, and terminal
error reporting. Immutable review belongs to `ImageBuildPlanning`; worker and
publication orchestration belong to `ImageBuildExecuting`; discard and
cancellation-independent residue removal belong to
`ImageBuildLifecycleManaging`. The production initializer composes those facets
from the same staging, secret, output, artifact, and image-store collaborators,
while a service initializer permits focused tests without Apple runtime state.

Exporter selection is a separate pure configuration contract shared with the
worker. OCI outputs use `type=oci`, root-filesystem tar uses `type=tar`, and the
single-platform local folder uses `type=local,platform-split=false`. Live Apple
1.0.0 probes confirmed a valid OCI layout, the tar exporter’s retained
`linux_arm64` envelope, the local exporter’s flat destination root, and zero
private/shared residue. Raw exporter and cache strings remain outside the UI.

Worker stdout uses POSIX `read` for immediately available framed progress.
Foundation’s counted pipe read buffered short frames until worker EOF, making an
in-flight cancel appear to work only after the solve had ended. The live
60-second probe now reaches `.building` in about 104 ms and returns cancellation
in about 3 ms; the existing TERM-to-KILL escalation and lifecycle cleanup remain
the bounded fallback.

## ADR-033: Keep app-owned BuildKit cache transactional and worker-private

**Status:** Accepted — 2026-06-21

Build requests and protocol-v6 control frames carry one closed local cache mode:
disabled, Apple builder-internal, or the versioned NativeContainers local
profile. The app and UI never accept raw BuildKit cache CSV or a host/guest
path. Only a worker-private adapter lowers the reviewed local profile to
BuildKit's `type=local` import/export strings inside Apple's existing reviewed
`<appRoot>/builder` VirtioFS mount.

The local profile owns one mode-0700 namespace, stable cross-process lock,
committed `current` generation, disposable per-build `staging`, and tokenized
`prepared` handoffs. A cancellation-aware nonblocking lease spans cache import,
solve, export, context revalidation, and private artifact isolation. The worker
validates the OCI layout, binds a receipt to the build ID, opaque UUID token,
directory identity, OCI metadata hashes, and bounded size/count fingerprint,
plus a deterministic path/inode/mode/size/block/mtime/ctime tree covering every
cache entry. It then atomically moves staging into prepared before releasing the lease. It never
touches `current` and only then writes its terminal result frame.

The app validates the private artifact and receipt before a host-side
finalization service reacquires the lock, reopens that exact prepared token,
recomputes the fingerprint, and publishes with
`renameatx_np(RENAME_SWAP|RENAME_EXCL)`. Ordinary inspection and new leases
recover abandoned staging but never delete prepared handoffs; explicit
lifecycle discard and reset own prepared cleanup. A broken worker pipe,
cancellation, hard exit, intervening inspection, or same-sized replacement
therefore cannot publish an unbound generation or disturb the prior cache. Once
the host-side atomic swap commits, the valid cache generation is independent of
later output publication. Recovery reclaims prepared handoffs only after a
24-hour expiry, bounding hard-exit residue without racing ordinary finalization.

Local-cache inspection and reset are a separate `AppOwnedBuildCacheManaging`
service from `ContainerBuilderManaging`. Reset takes the image-build
single-flight lock and the same cross-process lease, atomically retires only the
NativeContainers generation, and never stops, kills, recreates, or deletes
Apple's shared builder. The Builder & Cache UI consequently presents Apple's
builder/internal cache lifecycle and the NativeContainers local cache as two
explicitly different controls.

## ADR-034: Clone stopped macOS VMs through a cancellable transaction service

**Status:** Accepted — 2026-06-21

Same-host cloning is not a direct `FileManager` action from SwiftUI. A focused
`VirtualMachineCloning` orchestrator obtains a library transaction whose source
runtime lease and global mutation lease remain held until commit or abort. A
replaceable copier performs the private transfer, while the library remains the
only authority that can atomically publish a new bundle identifier.

The transfer uses Darwin `copyfile` with recursive best-effort APFS cloning,
sparse-data fallback, no-follow and cross-mount protections, and a status
callback that returns `COPYFILE_QUIT` after task cancellation. The UI remains in
a cancelling state until the callback stops the transfer and the transaction
removes its partial directory. Startup recovery deletes clone partials left by a
hard exit.

A clone preserves the installed disk, auxiliary storage, compatible hardware
model, resource settings, and shared-directory configuration, but it is not a
byte-identical backup. It receives a new app bundle identifier and a newly
generated, round-trip-validated `VZMacMachineIdentifier`; the app's
manifest-derived network MAC consequently changes as well. Runtime owner files,
operation partials, and same-host saved memory are deliberately removed so the
copy cold boots. The commit boundary independently rejects a copied or malformed
machine identifier even when a custom copier violates the service contract.

## ADR-035: Treat portable VM packages as explicit identity transactions

**Status:** Accepted — 2026-06-21

Clone, export, and import use one `VirtualMachineBundlePreparing` service with
typed identity and portability policies. The service validates a regular
directory tree without symbolic links, hard links, or special files; copies
through the cancellable sparse/clone transfer; proves the source metadata
remained stable; removes transient state; applies the identity policy; and
writes the destination manifest. Same-host clone keeps shared-folder
capabilities and regenerates identity. Portable operations remove saved state,
runtime/install partials, the cache-local restore image URL, and
`SharedDirectories.json` bookmark capabilities.

Export is read-only with respect to the library. It briefly holds the global
operation lock while acquiring a stopped-source runtime lease, then releases
unrelated VM mutations while retaining exclusive access to that writable
bundle. The destination parent remains security-scoped throughout the transfer.
The service copies into a hidden sibling and publishes with a same-directory
rename only when the final `.nativevm` path is absent. Existing exports are
never replaced, and cancellation does not dismiss the sheet until the partial
is removed and the source lease releases.

Import is a library-owned begin/commit/abort transaction with its staging
package under the private library. Restore mode preserves the manifest UUID and
round-trip-valid `VZMacMachineIdentifier`; it rejects either identifier when
already present. Import-as-copy creates a fresh manifest UUID and Apple platform
identity. Commit repeats artifact, portability, destination, and platform
identity checks immediately before atomic publication. Abort removes only the
operation's staging package, and launch recovery removes orphaned
`.Import-*.partial` directories.

SwiftUI `fileImporter` owns selection of an existing package; a narrow
`NSSavePanel` service owns only export destination selection. The transfer
service, not either picker callback, owns security-scope lifetime, leases,
copying, cancellation, and cleanup. System-owned `FileDocument` /
`Transferable` export is not used for multi-gigabyte packages because macOS 26
does not expose its final copy lifetime to these transaction boundaries.

## ADR-036: Keep storage accounting on demand and service isolated

**Status:** Accepted — 2026-06-21

Storage measurement is a separate `StorageUsageLoading` facade with independent
Apple-runtime and app-owned-VM implementations. It is never folded into the
ordinary inventory service: Apple disk usage can wait on runtime XPC, while a
large VM library requires a filesystem traversal. Overview starts both lanes
only after an explicit Measure action, retains successful snapshots across a
partial failure, exposes Cancel, and cancels an in-flight measurement when the
view disappears.

The Apple adapter uses the existing bounded `AppleXPCRequestClient` rather than
the package's unbounded convenience call. The VM scanner receives a canonical
library inventory snapshot, opens the root without following links, performs
one descriptor-relative traversal, includes hidden transactional residue,
refuses cross-device descent, and deduplicates hard-linked inodes. Its detached
utility task is explicitly cancelled by the awaiting task's cancellation
handler.

Apple's reclaimable values remain point-in-time runtime classifications, not
deletion authorization. VM logical and allocated values are accounting signals,
not a reclaimability promise: APFS may share clone extents without exposing
unique physical ownership per bundle. Reclamation and sparse compaction remain
separate reviewed mutations.

## ADR-037: Reclaim only reviewed Apple-runtime identities

**Status:** Accepted — 2026-06-21

Apple's point-in-time reclaimable byte counts are context, not deletion
authorization. A separate `StorageReclamationManaging` facade composes exact
container, image, and volume plans from fresh live adapters and attaches the
accounting capture/revision plus inventory revision as provenance. A newer
measurement, inventory revision, scope change, or sheet dismissal discards an
uncommitted review. Commit-time validation remains authoritative and does not
use an elapsed-time TTL.

Execution is deterministic: reviewed stopped containers, reviewed image
references, then reviewed volumes. It never expands the plan after container
deletion; newly unused dependencies require another Measure and Review loop.
Stopped-container reclamation is opt-in and admits only configurations with a
valid NativeContainers creation-operation UUID, stopped state, no Compose or
Apple plugin/role metadata, a non-builder identifier, and an unchanged
canonical full-configuration encoding. It uses non-force delete and verifies
absence. Reclamation never stops, kills, force-deletes, or mutates a VM.

Container and core-image adapters use bounded, cancellation-closing XPC
requests. Cancellation is a checkpoint before the next candidate, not a
rollback: an accepted mutation is reconciled in cancellation-independent work,
and partial-completion errors retain confirmed removals and remaining exact
identities. Image bytes are Apple's orphan-cleanup report; container and volume
bytes are allocation measured before confirmed removal. Their aggregate is
labeled estimated/reported removed bytes, never measured host free-space gain.

## ADR-038: Reclaim VM host artifacts through category services and exact seals

**Status:** Accepted — 2026-06-21

VM accounting remains read-only. A sibling
`VirtualMachineStorageReclamationManaging` service composes independently
replaceable saved-state, interrupted-residue, and restore-image services,
records the VM measurement and library revisions as review provenance, and
executes only the immutable candidates shown in the confirmation sheet. This
keeps filesystem ownership out of SwiftUI and avoids growing the library actor
into a general cleanup facade.

Committed saved states are planned and discarded by the existing saved-state
store while a per-VM runtime lease is held. A replacement checkpoint cannot
match the reviewed directory identity and complete tree fingerprint. Residue
is limited to exact app-owned transaction names for draft creation, deletion,
clone, import, installation, platform preparation, saved-state transitions,
shared-folder writes, and manifest-proven orphan installation media. The
residue service holds the library operation lock and bundle runtime lock,
rejects links, special files, foreign owners, mount crossings, and changed
metadata, then atomically retires an accepted candidate before deletion.

Cancellation is observed before each candidate and immediately before its
retirement rename. After that rename the mutation is committed and cleanup is
finished without another cancellation checkpoint; partial results retain exact
removed, stale, and failed identities. The feature never starts, stops,
force-stops, or kills a VM and never considers a committed disk. Restore-image
reclamation is a separate opt-in category governed by ADR-039.

Virtualization's RAW attachment remains a one-to-one block mapping. The public
SDK exposes no RAW compaction operation; DiskImageKit exposes ASIF creation and
resize primitives on the newer platform, while truncation explicitly does not
resize the guest filesystem and can destroy data. This change therefore does
not approximate compaction with raw truncation. Compaction remains a separate
format-migration or transactional rewrite decision.

## ADR-039: Lease restore images through preparation and reclaim only reviewed references

**Status:** Accepted — 2026-06-21

Restore-image discovery remains independent, but every local or remote
acquisition now enters through one `RestoreImageAcquiring` facade backed by a
shared `RestoreImageCacheService`. The cache authority owns the private
directory, cache-wide `.operations.lock`, versioned per-artifact marker, and
opaque typed lease. Download and import services transfer bytes only after a
lease exists; the application model commits that lease only after
Virtualization preparation and the VM manifest write have returned. A remote
abort retains its immutable completed file or resumable partial, while a local
import abort removes its private copy. Files already inside the private cache
receive real leases rather than bypassing ownership.

Download identities combine a readable source name with a hash of the source
URL. A completed file is immutable and reused; download promotion never
replaces an existing file in place. Partial and source files are opened with
`O_NOFOLLOW` and validated from their descriptors. Cache recovery takes the
cache lock before loading the current VM-manifest reference set, so a second
process using this version cannot publish a new reference between the decision
and cleanup. The canonical order is cache lock, then VM library access. This is
required because public Virtualization APIs consume local file URLs and expose
no descriptor-pinning API.

Restore-image deletion is the third VM-reclamation category and is off by
default. Planning admits only app-owned, single-link regular IPSWs that have no
active marker and no manifest reference. Abandoned `.ipsw.partial` files must
also be at least seven days old. Execution reacquires the cache lock, reloads
the complete reference set, and revalidates the exact device, inode, size,
allocation, timestamps, and metadata fingerprint before a same-parent rename.
That rename is the commit point; a recognized tombstone lets launch recovery
finish an interrupted deletion. Successful macOS installation clears the
manifest's restore-image reference, while cancelled or failed installation
retains it for retry.

At the time of this decision the location remained under the app's Caches
directory. ADR-040 completes the deferred move to private Application Support
and defines the convergent legacy-reference migration.

## ADR-040: Separate restore-image acquisition from durable-store maintenance

**Status:** Accepted — 2026-06-21

New restore-image downloads and imports live under
`~/Library/Application Support/NativeContainers/Restore Images`, not the
purgeable Caches directory. The store is mode 0700, its artifacts are mode 0600,
and the directory is marked excluded from backup because the large IPSWs are
redownloadable. `RestoreImageAcquiring` now owns acquisition leases only;
`RestoreImageStoreRecoveryService` owns startup recovery and migration, and
`VirtualMachineRestoreImageReferenceStoring` is the library's narrow manifest
boundary. SwiftUI and `AppModel` no longer assemble cache-reference closures.

Launch maintenance recovers the legacy authority, migrates referenced legacy
artifacts, then recovers the durable authority. A dual-root migration holds the
legacy Caches lock and then the Application Support store lock for the whole
operation. It takes short VM-library operation leases for each fresh reference
snapshot and exact replacement. Old releases hold the first store lock through
their manifest commit, while current acquisition holds the second before
entering the library; the library never calls back into either store.

Each unique referenced legacy IPSW is validated as a current-user, single-link
regular file and copyfile-cloned to a UUID-named partial in the durable store.
A versioned phase journal records source and destination filesystem identities,
exclusive promotion, manifest replacement, and completion. The library
preflights every matching manifest under one operation lease, rejects an
unexpected draft reference, clears obsolete stopped references, and atomically
rewrites retryable references to the durable URL. No schema change is needed.

All manifest mutation is idempotent and intentionally non-cancellable once it
begins. Both source and destination remain present while separate bundle
manifests are rewritten, so a hard exit between writes leaves every old and new
URL valid; the next launch resumes from the journal. Completion removes only
the migration control files. It retains the now-unreferenced legacy IPSW rather
than deleting it as a hidden migration side effect. The current review service
owns only the durable store; composite legacy-store review remains a separate
follow-up, and the OS may purge the legacy Caches copy independently.

## ADR-041: Migrate stopped RAW VM disks to ASIF out of place

**Status:** Accepted — 2026-06-21

Disk format is persisted beside `diskImagePath`. The optional schema-1 field is
backward compatible: absence means RAW, while new manifests write RAW
explicitly and conversion writes ASIF. Runtime attachment is delegated to
`AppleVirtualMachineDiskImageService`. RAW uses the URL attachment; macOS 27
ASIF is opened with DiskImageKit and passed through the native disk-image
attachment initializer. Capacity validation uses virtual image geometry, never
the ASIF container's host file length.

Conversion is a dedicated application service. It acquires the per-bundle
runtime lease, requires a stopped macOS VM with no saved state, seals the RAW
filesystem identity, and invokes Apple's documented `diskutil image create from
--format ASIF` command against a sibling hidden partial. The existing host
process executor owns exactly the child PID, sends TERM on cancellation or
timeout, escalates to KILL after a grace period, and confirms exit before the
partial can be removed. This hard watchdog is safe because conversion never
mutates the source. A failed TERM still reaches the KILL point. If KILL delivery
or exit cannot be proven, the service retains the runtime lease and transitions
the journal to `terminationQuarantined` instead of unlinking live output.
Successful KILL with delayed exit confirmation requires an app restart; failed
KILL delivery records the stable `kern.bootsessionuuid` and requires a reboot
before automatic recovery.

A mode-0600 journal records `planned`, `terminationQuarantined`, `converted`,
`promoted`, and `manifestUpdated` phases with source/destination identities and
virtual capacity. ASIF format and geometry are verified before promotion. The
library exposes one narrow commit port that revalidates both sealed regular
files under the still-borrowed maintenance lease and atomically updates the
manifest. Every ordinary runtime or discard lease rejects a pending migration
journal; clone/export/import reject the journal and nested partials before copy.
After the manifest commit, cancellation is ignored while the old RAW source and
journal are retired. Launch recovery removes only proven-quiescent pre-commit
staging/destinations or completes post-commit cleanup, continues past failures
for unrelated VMs, and never guesses across an invalid identity or journal.

DiskImageKit exposes no populated-image converter or compact API, and its
truncate operation does not resize guest content. Raw truncation, same-path
conversion, and in-place resize are therefore prohibited. ADR-042 defines the
separate ASIF-to-ASIF rewrite maintenance action.

## ADR-042: Reclaim standalone ASIF allocation through measured replacement

**Status:** Accepted — 2026-06-21

ASIF reclamation reuses the journaled out-of-place disk replacement coordinator
from ADR-041. Thin migration and rewrite services select an operation policy;
the coordinator owns the maintenance lease, saved-state gate, filesystem seals,
DiskImageKit geometry checks, `diskutil image create from --format ASIF`, exact-PID
TERM-to-KILL behavior, manifest commit, cleanup, and launch recovery. Journal
schema 2 introduced the operation and source/destination formats; schema 3 adds
the source block size so recovery can revalidate geometry. Schemas 1 and 2 remain
decodable with their original semantics, while new journals require the geometry
field. Legacy RAW migration recovery derives the format's required 512-byte block
size; only legacy ASIF rewrites lack recoverable source-geometry metadata.

Rewrite accepts only a stopped VM with no saved state and a standalone ASIF
source. Cache and overlay layers are rejected because their parent and UUID
semantics are not represented by the manifest. Every replacement candidate must
match both virtual capacity and block size. It is promoted to a unique
sibling path, never over the source. The manifest switches and the old source is
retired only when the candidate's sealed filesystem identity reports strictly
fewer allocated bytes. Equal or larger candidates are removed as a successful
measured no-op.

The product calls this action “Rewrite ASIF,” reports only the measured
allocated-byte reduction, and explicitly notes that APFS free-space growth can
differ. It does not claim a public compact primitive, guaranteed reclamation, or
guest-filesystem shrink. Migration and rewrite share one app-scoped maintenance
model so runtime, transfer, discard, and shared-folder controls observe the same
busy state.

## ADR-043: Create missing Compose replicas without authorizing recreation

**Status:** Accepted — 2026-06-21

Create-missing Up is distinct from Compose recreation. The planner accepts only
existing replica labels that form the exact contiguous prefix `1...n`, rejects
extra replicas and all configuration/image drift, and records one command token
for the missing suffix. Existing containers must already have the exact reviewed
named-volume and network attachments.

Before any runtime mutation, NativeContainers parses the reviewed canonical JSON
through an explicit supported-key allowlist. A deterministic execution overlay
replaces every volume and network declaration with `external: true` plus its
frozen runtime name. The pinned Compose client recomputes every service hash from
that overlay; any difference from review aborts before mutation. The overlay is
stored as a mode-0600, single-link, digest-named immutable file below a stable
owner-private per-project directory, so Compose's working-directory and
config-file labels remain stable across repeated Up operations.

Managed resources that are absent are created through Apple resource APIs with
project, logical-resource, Compose-version, and operation labels, then immediately
reconciled through Apple inventory. NativeContainers starts stopped containers in
the reviewed prefix by exact ID and invokes Compose 5.1.4 with `--no-recreate` to
create only the suffix. Final inventory must prove the exact replica set, image
digest/config hash, resource identities, and per-container attachments.

This lane does not permit scale-down or replacement. Socktainer 1.0.0 still lacks
the rename and network connect/disconnect routes required by Compose's replacement
flow, so all recreation remains a blocker.

## ADR-044: Keep menu-bar and login behavior inside the native app control plane

**Status:** Accepted — 2026-06-21

Menu-bar controls reuse the app-scoped `AppModel`, current Apple inventory, and
existing exact-identity lifecycle services. They do not create another poller,
persist a shadow resource database, or call Apple adapters directly from a
view. Rows may retain only transient in-flight button state. Start, graceful
Stop, Restart, and Force Stop therefore have the same serialization,
revalidation, refresh, and error behavior in the menu bar and main window.
Force Stop remains a named destructive action inside the row's secondary menu,
including while graceful Stop is in flight or inventory reports `stopping`.

Because NativeContainers also owns regular Window and Settings scenes, an
app-scoped AppKit controller owns the optional status item and observes the
persisted visibility preference. Removing the item does not terminate the app,
and Settings remains the recovery path for showing it again. A zero-layout
SwiftUI installer captures the environment-provided `OpenWindowAction` and
`OpenSettingsAction` only after the main scene exists, while navigation keeps
the existing `WorkspaceRoute` authority.

Launch at login uses only `SMAppService.mainApp`. A focused protocol and stable
observable model map system status into disabled, enabled, approval-required,
and unavailable states. Registration is not represented as a Boolean preference:
System Settings remains authoritative, revoked approval remains visible, and
non-installable development copies fail closed. NativeContainers does not write
or bootstrap a parallel launch-agent plist.

## ADR-045: Restore terminal workspaces as inert identity-pinned metadata

**Status:** Accepted — 2026-06-21

Terminal presentation uses SwiftUI's data-driven `WindowGroup` rather than a
sheet owned by a resource inspector. Its value is a lightweight unique workspace
UUID plus an exact container or Linux-machine identity, which lets macOS own
detached-window and native window-tab restoration. An app-level workspace adds
up to 12 independently closable terminal tabs. Per-scene restoration stores
only stable tab UUIDs, selection, and optional preset UUIDs; process handles,
pipe descriptors, output, and command history are never encoded.

Restored tabs are deliberately inert. The selected shell is opened automatically
only for a newly requested window; relaunch restoration waits for explicit tab
selection or Start New Shell. This prevents background/login launch from
starting a stopped Linux machine or creating child processes merely because a
window existed previously. Closing a tab or window still uses the terminal
session's HUP-to-KILL shutdown policy, and an unconfirmed kill keeps the tab
visible rather than discarding ownership.

Before any restored or new tab creates a process,
`IdentityPinnedTerminalTargetService` reloads Apple inventory. Containers pin ID
plus creation date; Linux machines pin their complete stable creation identity.
Missing resources and same-name replacements fail before the container-terminal
or machine-login-shell facet runs.

Saved container presets are a separate injected store, not scene or view state.
A versioned `UserDefaults` data payload is bounded to 64 entries and persists
only a preferred or explicit shell, login-shell intent, and absolute guest
working directory. Environment values, arbitrary startup commands, terminal
output, and history are excluded, so the native preferences store never becomes
a secret or transcript database. Preset deletion cannot terminate a live tab;
a later restore falls back visibly to the preferred shell.

## ADR-046: Route macOS guest audio through an output-only Virtio device

**Status:** Accepted for output; microphone policy superseded by ADR-047 — 2026-06-21

A focused Apple audio-device factory owns the Virtualization.framework types;
the SwiftUI configuration surface reports the resulting capability but does not
construct virtual hardware. Every macOS VM configuration contains exactly one
`VZVirtioSoundDeviceConfiguration` with one output stream backed by
`VZHostAudioOutputStreamSink`, which follows the Mac's current default output
device.

NativeContainers does not configure an input stream. The microphone remains
disconnected and the app does not declare `NSMicrophoneUsageDescription` or
request recording access. Microphone support is a separate future product and
privacy decision rather than an implicit side effect of enabling playback.

Adding a virtual device changes restorable hardware topology, so new
configurations emit topology version 3 and record the audio descriptor in the
saved-state fingerprint. Checkpoints from versions 1 and 2 fail compatibility
validation instead of being restored against a different hardware layout.
Virtualization.framework's configuration and save/restore validation remain the
runtime authority. Deterministic construction and fingerprint tests cover this
slice; audible playback still requires an installed local macOS guest.

## ADR-047: Make microphone forwarding explicit, permission-first, and per-VM

**Status:** Accepted — 2026-06-21

Microphone forwarding is disabled by default. A user must choose Connect for a
specific powered-off macOS VM. The audio orchestration service checks or requests
AVFoundation recording authorization before it acquires runtime ownership, so a
denied prompt cannot mutate the manifest, change virtual hardware, or block
another process. The app target carries Apple's required audio-input entitlement
and usage description, but it never prompts merely because a configuration view
appears or a VM with output audio starts.

After authorization, the service acquires the existing per-bundle runtime lease,
requires no saved checkpoint, and commits a revisioned audio configuration in the
VM manifest. The Virtualization factory is the only layer that translates
that setting into `VZVirtioSoundDeviceInputStreamConfiguration` and
`VZHostAudioInputStreamSource`; SwiftUI receives a snapshot and invokes an action.
Disconnecting does not revoke system permission, but it removes the input stream
on the next cold start.

The connection is a host-local privacy choice rather than transferable machine
state. Same-host clones and portable export/import representations erase the
audio opt-in, so every new copy or restored package starts with its microphone
disconnected while the source VM remains unchanged.

Revision zero deliberately emits the same descriptor as the preceding
output-only topology-v3 implementation. Once the setting changes, its monotonic
revision is included in the saved-state fingerprint. An enable-then-disable cycle
therefore cannot make an older checkpoint appear compatible merely because the
visible device list returned to output-only.

## ADR-048: Use app-owned vmnet logical networks for advanced macOS VM networking

**Status:** Accepted — 2026-06-21

macOS VM networking exposes three explicit domain modes. Automatic NAT uses
`VZNATNetworkDeviceAttachment` and remains the portable default. Shared and
host-only modes create public `vmnet_network_ref` objects and attach them through
`VZVmnetNetworkDeviceAttachment`; shared mode provides VM-to-VM, host, and
external connectivity, while host-only omits external connectivity.

One pool owned by the app composition root retains one logical network for each
custom mode and is injected into both installation and runtime configuration
factories. This satisfies Virtualization's same-process requirement and ensures
VMs selecting the same mode join the same logical network. The SwiftUI section
never constructs framework objects or discovers interfaces: it renders a
service snapshot and invokes a typed mode-change action.

Physical bridging is not part of this capability. Apple's bridge attachment
requires `com.apple.vm.networking`, and Xcode does not expose that restricted
entitlement for this target. NativeContainers does not manually edit the
entitlements file or disguise a vmnet shared network as a physical bridge.

Mode changes acquire the existing runtime lease, require the VM to be stopped,
reject any saved checkpoint, and atomically persist a monotonic configuration
revision. The revision is included in the saved-state descriptor so returning to
an earlier visible mode cannot resurrect an older checkpoint. Custom vmnet
objects are recreated when the process relaunches, so shared and host-only
runtime configurations explicitly disable suspend/save-restore. Same-host clones
preserve their selected mode, while portable package preparation clears the
process-local choice back to automatic NAT.

## ADR-049: Own Linux VM shutdown recovery inside the runtime service

**Status:** Accepted — 2026-06-21

General-purpose Linux VMs use a Linux-specific application service rather than
adding guest branches to the macOS runtime coordinator. The service owns one
generation-pinned bundle lease and engine session per VM; the app model owns a
stable observable facade; SwiftUI receives snapshots and invokes typed actions.
Start, pause, resume, stop, ejection, console access, and terminal delegate
events are valid only for the active generation.

A graceful stop request arms a 30-second watchdog. Guest exit remains the
preferred outcome, but expiry automatically requests destructive stop against
that same generation. The service bounds its wait for Virtualization.framework
to report `canStop`, fails visibly if destructive stop never becomes available,
and never publishes a false stopped state. The user can also choose Force Stop
immediately; requests made during start, pause, resume, or installer ejection
queue behind the in-flight callback without releasing ownership. Delegate
guest-stop and error callbacks are authoritative terminal events, and duplicate
callbacks finalize a generation once.

Linux installer media uses XHCI USB mass storage rather than a permanently
attached block device. Successful hot detach precedes manifest completion, and
a persistence failure remains retryable without issuing a second detach. This
keeps VM ownership, framework callbacks, shutdown escalation, and installation
state out of the SwiftUI layer while preserving both automatic recovery and an
explicit kill path.

## ADR-050: Share GUI Linux folders through stopped-only VirtioFS configuration

**Status:** Accepted — 2026-06-21

GUI Linux VMs reuse the guest-neutral shared-directory domain, security-scoped
bookmark adapter, mode-0600 atomic sidecar store, observable app model, and
multiple-directory VirtioFS factory already proven by the macOS lane. Linux
lifecycle policy remains in a separate `LinuxVirtualMachineSharedDirectoryService`
instead of adding guest switches to the shared primitives or the view.

Adding or removing a share acquires the generation-pinned Linux runtime lease
and is accepted only while the bundle is ready to install or stopped. Runtime
acquisition reloads the sidecar while holding bundle ownership, resolves every
bookmark fail-closed, attaches one `VZMultipleDirectoryShare` under the stable
`nativecontainers` tag, and retains security-scoped access until the exact
engine session closes. Portable package preparation strips the host-local
bookmark sidecar, while same-host clones retain it.

Apple's public API configures the VirtioFS device but does not execute commands
inside a Linux guest. NativeContainers therefore presents the exact
`mount -t virtiofs nativecontainers /mnt/nativecontainers` workflow and the
guest-kernel requirement instead of claiming automatic mounting or injecting a
hidden guest agent.

## ADR-051: Edit persistent-machine boot configuration through a focused reconciled service

**Status:** Accepted — 2026-06-21

Persistent Apple Linux-machine configuration crosses a dedicated
`MachineConfigurationManaging` facet rather than expanding the lifecycle
service or placing Apple package types in SwiftUI. A shared snapshot mapper owns
the exact conversion between `MachineSnapshot`, stable app identity, runtime
state, inventory fields, and the mutable CPU, memory, and home-mount domain.
The composition root injects one machine transport and one runtime mutation
coordinator into inventory, lifecycle, process, and configuration services.

Every edit requires a creation timestamp, lists and inspects the exact machine
before mutation, then sends the replacement `MachineConfig` through the bounded
XPC transport. A successful reply is not accepted as proof: the service
re-inspects and compares the complete requested configuration. A failed,
cancelled, or timed-out reply triggers the same reconciliation in a detached
task; a committed value is success, a missing or replaced machine is explicit,
and failed verification reports an unknown outcome. This preserves the app's
identity-safety and cancellation contracts even though Apple 1.0 exposes only
an ID, not a conditional mutation token, so an external replacement race still
cannot be made atomic.

The editor permits Apple’s supported running-machine update and labels it as a
next-restart change; a stopped edit applies on next start. Writable home access
requires a separate explicit confirmation. Disk, kernel, Rosetta, and nested
virtualization controls remain absent until the pinned runtime genuinely
exposes them.

## ADR-052: Model GUI VM disk snapshots as a bounded linear overlay service

**Status:** Accepted 2026-06-21; generalized across GUI guests 2026-06-22

NativeContainers persists macOS and GUI Linux disk checkpoints as guest-scoped
revisioned linear histories rather than exposing DiskImageKit objects to the VM
library or SwiftUI.
Each named checkpoint captures a prefix of canonical bundle-local ASIF overlay
layers, and one additional top layer receives subsequent guest writes. The
history is bounded to eight checkpoints. DiskImageKit exposes stack and overlay
creation but no public merge or flatten primitive, so arbitrary middle-layer
deletion is not offered. Restoring a checkpoint keeps its required prefix,
creates a fresh writable top layer, and prunes every newer checkpoint.

Creation and restore share one transaction engine but acquire the matching
guest runtime lease, require the VM to be stopped with no saved state, recover
only recognized app-owned staging or unreferenced canonical files, and create
the new overlay before one
compare-and-swap-style manifest commit. A failed commit removes the new layer.
After a successful restore, retired-layer deletion is best effort and any
failure is reported as committed cleanup pending; the next snapshot operation
reconciles that residue without rolling back the authoritative manifest.

Each resolver and runtime consume the ordered stack through one focused
disk-image service: the base and historical overlays are read-only and only the
newest overlay is read-write. macOS and Linux saved-state fingerprints cover
the manifest topology and stable identity of every layer. Same-host clone and
portable package workflows retain the complete bundle-local stack and reject
missing, symbolic, extra, or
partial snapshot artifacts. RAW-to-ASIF conversion and standalone-ASIF rewrite
are rejected once snapshot history exists because replacing only the base would
invalidate parent lineage. SwiftUI receives a stable observable snapshot model
and invokes typed create/restore actions; it owns no filesystem or DiskImageKit
state.

## ADR-053: Keep physical USB authorization host-local and generation-pinned

**Status:** Accepted; live activation pending entitlement availability — 2026-06-21

Physical USB passthrough is an ephemeral runtime capability, not VM
configuration data. AccessoryAccess owns system discovery and authorization,
and the app retains its opaque `AAUSBAccessory` references only in the
app-scoped USB service. The manifest, clones, portable packages, and saved-state
metadata never persist a host registry ID or authorization decision. Discovery
starts only after an explicit user action.

Each macOS runtime configuration contains one XHCI controller. The Apple runtime
session wraps that controller behind a framework-free contract and exposes it
only through the runtime coordinator's exact generation target. The USB service
serializes each device's attach/detach state across all VMs, projects
another-VM ownership without revealing framework objects, and unwinds an attach
that completes after its target was replaced. Virtualization's physical
disconnect delegate clears only the matching generation.

Dynamic USB devices are excluded from suspend: the runtime rejects suspension
before pausing while its controller has attachments. Stopping the VM closes the
controller and releases its host references. Adding the base XHCI controller
changes the VZ topology, so the saved-state configuration version advances and
older checkpoints fail compatibility checks instead of reaching restore.

The required macOS 27 capability is
`com.apple.developer.accessory-access.usb`. The installed Xcode MCP
capability action does not yet recognize that new entitlement, and the current
signed app does not contain it. NativeContainers will not edit the entitlement
file behind Xcode's back. The composition root inspects the signed process and
injects a fail-closed unavailable service until Xcode can add and sign the
capability normally. The full adapter, orchestration, model, and UI remain
compiled and deterministically tested in the meantime.

**Recheck checkpoint — 2026-06-23:** Xcode 27 beta 2 build `27A5209h`
ships the AccessoryAccess API and documents the entitlement, but its local
capability and provisioning catalogs cannot issue it. A raw entitlement entry
fails during provisioning, ad-hoc signing is rejected by AMFI as a restricted
entitlement, and certificate-only signing is rejected because no matching
profile authorizes the key. Keep the entitlement absent until a later Xcode or
Developer Portal update can generate an Apple-signed profile containing it.
Activation then requires a successful Xcode build, inspection of the signed
product, and a disposable physical-USB passthrough check. The separate sandbox
USB entitlement does not satisfy this gate.

## ADR-054: Sample host pressure only for new editable resource defaults

**Status:** Accepted — 2026-06-21

NativeContainers treats host power and thermal state as input to creation
defaults, not as authority to mutate a workload. A focused Foundation adapter
maps `ProcessInfo.activeProcessorCount`, `isLowPowerModeEnabled`, and
`thermalState` into a framework-free snapshot. A pure policy service derives
separate container, persistent Linux-machine, and GUI-VM defaults and is
injected through the app composition root.

Normal and fair thermal states preserve the established user-initiated
defaults. Low Power Mode or serious/critical thermal pressure lowers only the
initial editable CPU count, never below one or above the active processor
count. Memory and disk defaults remain unchanged, and the creation form states
why the CPU value was selected. The state is sampled when the sheet is created;
there is no continuous observer, background poller, or mid-edit value rewrite.

Existing and running resources are never resized by this policy. NativeContainers
also does not infer guest idleness from application inactivity, window
visibility, or console attachment. Automatic idle suspension remains deferred
until a public, authoritative guest-activity signal or an explicit guest-side
contract can distinguish an idle VM from unattended work.

## ADR-055: Demand-start optional integrations as one shared service module

**Status:** Accepted — 2026-06-21

NativeContainers keeps launch-critical inventory and VM recovery services eager.
Those paths establish authoritative state and reconcile interrupted durable
operations before the first refresh, so delaying them would change correctness
rather than merely improve startup allocation.

Docker compatibility and Compose are optional, view-initiated lanes. Their live
installers, Socktainer process owner, Docker context, Compose config client,
mutation executor, and operation journal are assembled by one module factory.
Protocol-preserving facades share a single `DemandStartedService` holder and
resolve it only on first use. The holder serializes concurrent first access,
publishes one complete graph, then releases its factory. This prevents duplicate
process ownership and journal authority while keeping `AppServices` mockable.

The holder is synchronous because module construction performs no network,
filesystem mutation, or process launch; those operations remain in async service
methods. A factory must not recursively resolve its own holder. Deterministic
tests prove zero construction before access, exactly one construction across
concurrent resolvers, and shared activation across all three live facades.

## ADR-056: Use system command groups and one route-backed navigation menu

**Status:** Accepted — 2026-06-21

NativeContainers uses SwiftUI's `SidebarCommands` and `ToolbarCommands` for
standard macOS View-menu behavior. App-specific workspace navigation lives in a
separate `NativeContainersCommands` composition value rather than the
`App` declaration or custom key-event monitoring. Command-1 through Command-9
map in visible sidebar order from Overview through macOS virtual machines;
Settings continues to use the system-owned Command-comma scene command.

Every navigation menu item asks `AppModel.canNavigate` before enabling. That
method delegates to the existing `WorkspaceNavigationModel` with the active
reviewed-build lock, so sidebar clicks, Quick Open, notification routing, and
keyboard commands share one authority. No command mutates selection directly,
and no new global event monitor or AppKit responder override exists.

The app target emits Swift localization strings and prefers String Catalogs in
both Xcode and `project.yml`. Xcode maintains the English source inventory.
Alternate accessibility input labels are attached only to controls whose icon
or common spoken name may differ from their visible label; runtime resource
names remain valid Voice Control input. Shipping non-English translations and
workflow-wide VoiceOver/Full Keyboard Access QA remain separate gates rather
than being inferred from catalog extraction.

## ADR-057: Gate menu-bar insertion to verified macOS runtimes

**Status:** Superseded by ADR-089 — 2026-06-23

The SwiftUI `MenuBarExtra` remains the supported menu-bar implementation and
continues to reuse the app-scoped control plane defined by ADR-044. On the
current macOS 27 runtime, inserting that scene continuously invalidates the
SwiftUI app graph and holds the main thread near 100% CPU. Removing the scene or
keeping it registered with a constant-false insertion binding both restore a
normal idle profile; changing its label or command contents does not.

`AppExecutionContext` therefore owns one injectable compatibility boundary in
addition to its hosted-test and Preview detection. macOS 26 may bind insertion
to the persisted preference. macOS 27 and later bind insertion to false and hide
the corresponding App Behavior setting until that runtime has been explicitly
revalidated. Future releases remain disabled by default so an untested OS does
not silently reintroduce the launch loop; raising the compatible major version
is a reviewed code and test change.

The workaround does not add an AppKit status item, another inventory poller, or
a second lifecycle implementation. Main-window commands and all underlying
container actions remain available. The scene and shared quick-control view stay
compiled so support can be restored by changing the narrow policy after Apple
fixes the framework behavior.

## ADR-058: Keep baseline measurement explicit, modular, and non-mutating

**Status:** Accepted — 2026-06-21

Performance measurement is implemented behind a `PerformanceBenchmarking`
application contract and independently injectable scenario and clock protocols.
The runner, not SwiftUI, owns warmups, measured iterations, cancellation,
failure isolation, and report statistics. Settings receives one stable
app-scoped observable model and starts work only from an explicit user action;
launch and ordinary Refresh perform no benchmark work.

The default baseline suite is deliberately host-local and non-mutating: it
loads Apple inventory through the existing read-only service, exercises a
private temporary file that is removed on every exit path, and transfers a
bounded payload through Network.framework on localhost. A timeout races the
network transfer, every loop checks cancellation, and one scenario failure is
reported without suppressing later lanes.

Cold container or VM launch, guest or bind-mount I/O, real image builds,
external-network throughput, and idle-resource sampling are not disguised as
equivalent local measurements. They remain separate opt-in live gates with
their own cleanup and environmental provenance requirements.

## ADR-059: Ship one arm64 hardened product with a nested build worker

**Status:** Accepted — 2026-06-21

NativeContainers distributes as one Apple-silicon macOS app. The one-shot
`NativeContainersBuildWorker` remains a separately compiled tool so image-build
responsibilities and failures stay outside the SwiftUI process, but Xcode embeds
that signed executable exactly once under the app's `Contents/Helpers`
directory. `SKIP_INSTALL=YES` prevents the worker from appearing as a second
archive product.

Both executables use hardened runtime and the same signing team. Capabilities
are assigned by executable instead of inherited for convenience: the app has
only microphone input and virtualization, while the worker has no app
capability. Broad file, network, device, personal-information, printing, Apple
Events, and runtime-exception entitlements are rejected by the artifact
validator. Development-only Xcode signing metadata is tolerated locally but
`get-task-allow` is forbidden for Developer ID validation on either binary.

The archive validator is the executable product contract, not a substitute for
Apple's trust service. A local Apple Development archive can prove layout,
architecture, versioning, nested signing, runtime flags, and entitlements. A
public release additionally requires an externally provisioned Developer ID
Application identity, successful notarization, Gatekeeper acceptance, and a
stapled ticket. Updater, migration, and crash-diagnostic policy remain separate
roadmap work.

## ADR-060: Retain MetricKit reports locally behind an explicit privacy boundary

**Status:** Accepted — 2026-06-21

NativeContainers uses Apple's MetricKit delivery surface instead of installing
a crash handler, injecting another exception runtime, or sending telemetry to
a third party. One adapter subscribes only in the normal app process and maps
MetricKit callbacks into framework-free envelopes. Hosted tests and Xcode
Previews receive an unavailable service so system report collection cannot
alter or delay those process lifecycles.

The app retains Apple's exact JSON because stack and diagnostic detail is the
useful artifact, but treats it as private local data. A dedicated actor writes
only to a backup-excluded mode-0700 root with mode-0600 records, validates
ownership, file type, link count, schema, digest, counts, and JSON before use,
and enforces per-payload, aggregate-byte, record-count, and directory-scan
limits. Corrupt or unsafe records are ignored and surfaced; symbolic roots fail
without changing their targets. The UI displays metadata and category totals,
and raw JSON leaves the private store only through an explicit user-selected
export. Deletion is likewise explicit. There is no background upload endpoint.

The adapter relies on subscriber callbacks rather than reading MetricKit's
session-only `pastPayloads` collections before their documented availability
point. The macOS product reports crash, hang, CPU-exception, disk-write, and
daily metric payloads; it does not pretend the SDK's unavailable-on-macOS
app-launch diagnostic array is present. Release symbolication is paired with
collection at the packaging boundary: every archive must contain app and
worker dSYMs matching the signed executable UUIDs.

## ADR-061: Run local Kubernetes in one identity-pinned Apple machine

**Status:** Accepted — 2026-06-21

NativeContainers implements local Kubernetes as K3s in one persistent Apple
container machine. It does not introduce a Docker VM, a second Linux
virtualization stack, or a host-level Kubernetes daemon. The dedicated machine
is created and managed through the same public Apple machine and process XPC
surfaces as other persistent Linux machines, but it receives no Mac home mount
and its cluster disk is deleted only through an explicit destructive action.

Provisioning is deliberately narrow. A fixed service-owned command runs as UID
0 through Apple's process configuration, installs known prerequisites, verifies
an exact-tag K3s installer against an embedded SHA-256, pins the K3s release,
enables Kubernetes secret encryption, and requires a mode-0600 guest
kubeconfig. The generic privileged command capability is not exposed through
SwiftUI. The private host descriptor stores provenance and the complete Apple
machine identity but no kubeconfig, certificate, client key, or token.

The Apple machine boot model is part of this decision. Alpine runs under
Apple's `vminitd`, so NativeContainers owns a bounded cgroup-v2 preparation and
OpenRC-unit activation step instead of pretending a full OpenRC boot occurred.
The descriptor stores creation dates without ISO-8601 precision loss because a
rounded timestamp would defeat exact-identity recovery. A cluster is not Ready
until flannel and service-account reconciliation have joined the API and node
checks.

Interrupted provisioning is recoverable rather than silently recreated. Retry
addresses only the stored identity; a same-name replacement fails closed.
Start, graceful Stop, explicit Force Stop, and Delete reuse the existing machine
lifecycle authority. Kubeconfig leaves the guest only after an explicit export,
is bounded and structurally validated, and has its loopback server rewritten in
memory to the machine's current dedicated IP. Multi-node HA, external storage,
and a live destructive install remain later product slices rather than claims
of this single-node foundation.

## ADR-062: Project Kubernetes inventory inside the guest

**Status:** Accepted — 2026-06-22

The native Kubernetes browser is read-only and never obtains its own
kubeconfig. `AppleKubernetesClusterService` first reloads the private descriptor,
requires its Ready phase, matches the complete stored Apple machine identity,
and requires that exact machine to be running. It then executes one fixed root
command through the existing bounded Apple process transport; no user text is
interpolated into that command.

Ordinary Pod JSON can contain literal environment values and operational
annotations that the browser neither needs nor should receive. The guest
therefore carries `jq` as a provisioning prerequisite and projects K3s output
before it crosses into the host process. The projection admits only workload
kind/name/namespace and replica counts, pod identity/phase/container counts/node,
and service identity/type/address/ports. It does not emit Pod environment,
annotations, Secret objects, kubeconfig, tokens, or certificate material.

The host treats the projected document as untrusted. Exact section markers are
required once, JSON is decoded into narrow private shapes, each of workloads,
pods, and services is capped at 500 records, nested service ports are capped,
text and numeric bounds are checked, and duplicate natural identities fail the
entire refresh. Transport truncation also fails closed. The observable model
keeps inventory errors separate from cluster lifecycle errors and clears stale
inventory whenever lifecycle or machine identity changes. Workload mutation
and exec remain later reviewed capabilities rather than being smuggled into
this read-only foundation.

Workload projection includes only two additional mutation-safety values:
metadata UID and resourceVersion. UID becomes the stable row identity and the
parser separately rejects duplicate namespace/kind/name tuples. ResourceVersion
is retained as an opaque bounded string so a later scale action can use
Kubernetes' server-enforced current-replica and resource-version preconditions.
Their presence does not itself authorize mutation; the browser remains
read-only until the reviewed execution and confirmation contract lands.

## ADR-063: Read Pod logs through an identity-checked bounded snapshot

**Status:** Accepted — 2026-06-22

Pod logs extend the Kubernetes read lane without exporting kubeconfig or
exposing a generic guest command. The allowlisted inventory adds only each
standard container name and the Pod API UID. A log request must carry that UID
plus namespace, Pod name, and one explicit container name; all four values pass
strict Kubernetes/UUID grammar before they can enter the fixed command.

`AppleKubernetesClusterService` revalidates the exact running Apple machine,
reads the current Pod UID, compares it with the selected inventory identity,
and only then requests a non-following timestamped snapshot. It reads the UID
again after `kubectl logs` and appends a service-owned identity marker; host
decoding accepts output only when that exact suffix matches. The request is
limited to the latest 2,000 lines and 512 KiB plus one byte; the host keeps at
most 512 KiB and reports truncation. The observable sheet model rejects stale
responses after container switches, caches search output outside SwiftUI
`body`, and writes a log file only through an explicit system exporter action.

Kubernetes' Pod log subresource is name-addressed and has no conditional UID
precondition. Bracketing the read with UID checks cannot make the upstream call
atomic, but it does ensure NativeContainers discards output if replacement
occurs before or during the read rather than publishing a same-name Pod's logs.

## ADR-064: Open Pod terminals through an identity-pinned fixed exec lane

**Status:** Accepted — 2026-06-22

Kubernetes Pod terminals reuse the app's native terminal window, Apple process
XPC transport, pipe lifecycle, resize/signal handling, and SwiftTerm surface.
They do not export kubeconfig, invoke a host CLI, expose the cluster machine's
root shell, or accept terminal presets. The restorable target stores the exact
cluster-machine identity plus Pod UID, namespace, Pod name, and explicit
container name. Before process creation, the service requires the private
descriptor to be Ready and its exact machine to be running.

Shell selection is a service-owned discovery step rather than arbitrary user
input. One bounded root command tries only a fixed common-shell allowlist inside
the selected container and reads the Pod UID both before and after the probe.
The resulting terminal-mode Apple child runs the machine init helper as UID 0,
performs another UID preflight, and then replaces itself with explicit-container
`k3s kubectl exec` using stdin, TTY, and a bounded Pod-running wait. Before the
new session is returned, one separate bounded UID read must still match; a
mismatch or unverifiable result closes the session. Only the discovered
allowlisted shell can occupy the command position.

Kubernetes exec is name-addressed and provides no conditional Pod-UID token.
The final UID check therefore cannot prevent replacement in the narrow interval
before the upstream exec begins, and an interactive stream cannot be bracketed
with a useful post-read identity decision. NativeContainers fails closed for
replacement detected during discovery, final preflight, or the immediate
post-launch check and documents the remaining upstream race. Noninteractive
execution follows the separate bounded contract in ADR-078.

## ADR-065: Scale workloads only with server-enforced review preconditions

**Status:** Accepted — 2026-06-22

NativeContainers permits scaling only for Deployments and StatefulSets selected
from its bounded inventory. A review freezes the workload UID, resourceVersion,
namespace, name, kind, current replica count, and requested target. DaemonSets
derive scheduling from nodes and Jobs have completion semantics, so neither is
misrepresented as an ordinary replica slider.

Execution revalidates the Ready descriptor and exact running Apple machine,
then reads the named workload inside the guest. UID, resourceVersion, and current
replicas must still match. The fixed K3s command sends both
`--resource-version` and `--current-replicas` to `kubectl scale`, making those
preconditions authoritative at the API update rather than only advisory host
checks. A post-read must retain the UID, advance resourceVersion, and report the
target replica count before success is returned. Stale reviews fail closed and
the browser reloads authoritative inventory.

This decision does not authorize generic patching, restart, or delete.
Kubernetes documents that `kubectl delete` performs no resource-version check;
a name-only deletion could erase a same-name replacement. Restart requires the
separate optimistic-replace contract in ADR-066; deletion stays blocked until
its conditional identity and user-reviewed cascade/grace contract is
implemented.

## ADR-066: Restart workloads through an optimistic full-object replace

**Status:** Accepted — 2026-06-22

NativeContainers restarts Deployments, StatefulSets, and DaemonSets by changing
the standard `kubectl.kubernetes.io/restartedAt` annotation on the reviewed
workload's Pod template. Jobs are excluded because their Pod template is
immutable. The UI explicitly warns that the controller follows its configured
update strategy and that `OnDelete` does not replace existing Pods
automatically.

The stock `kubectl rollout restart` is not used. It issues a strategic-merge
patch, and Kubernetes patches are last-write-wins rather than optimistic-lock
updates. Instead, the fixed guest command re-reads the complete named object,
requires the reviewed API version, kind, namespace, name, UID, and
resourceVersion, changes only the restart annotation, and sends a full
`kubectl replace`. The unchanged resourceVersion in that object makes a race
fail with conflict at the API server. Success additionally requires the same
UID, a new resourceVersion, and the exact annotation value in the returned
object.

The complete workload object never crosses the Apple process transport. It is
held only in guest shell variables and piped directly back to K3s; host output
contains one private marker with UID, new resourceVersion, and the restart
timestamp. Replace stderr is suppressed inside the guest and becomes a generic
service-owned rejection, so a validating admission response cannot leak object
details. This avoids adding environment values, annotations, or referenced
secret material to the host inventory contract. Workload deletion uses the
separate destructive contract in ADR-067.

## ADR-067: Delete workloads only through preconditioned foreground requests

**Status:** Accepted — 2026-06-22

NativeContainers permits reviewed deletion of Deployments, StatefulSets,
DaemonSets, and Jobs. The destructive sheet identifies the kind, namespace,
and name; requires the exact name to be entered; explains that managed
dependents are deleted; and adds a critical warning for Kubernetes system
namespaces. The product offers neither force deletion nor a grace-period
override.

Ordinary `kubectl delete TYPE/NAME` is forbidden because Kubernetes documents
that it performs no resource-version check. The fixed guest command instead
chooses one API URI from the closed workload-kind set and sends `kubectl delete
--raw` a `DeleteOptions` body. Both UID and resourceVersion are server-enforced
preconditions, and propagation is always `Foreground`. A stale review or
same-name replacement therefore conflicts at the API server before deletion
can affect it.

Delete response details and stderr are suppressed inside the guest. After an
accepted request, a bounded identity-aware poll reports only one of three
outcomes: the reviewed UID is absent, a different same-name UID is present and
untouched, or the reviewed object is still waiting on foreground finalizers.
Transport or API failures during that poll produce no success claim. The host
reloads the bounded inventory after every accepted or rejected request and
never retries by name.

## ADR-068: Measure cold container startup around prepared start-to-running only

**Status:** Accepted — 2026-06-22

The cold-container benchmark is an explicit live gate, not another Settings
baseline. It refuses to fetch its workload image: the selected reference must
already exist in Apple inventory, and the output records that reference,
digest, Apple container version, host OS, three raw samples, median, and P95.
This keeps registry latency and mutable network conditions outside the startup
number without pretending the image tag itself is immutable. Each created
container must retain that preflighted reference and digest before timing.

Every iteration prepares a fresh stopped one-CPU/256-MiB container before the
clock starts. The measured operation calls the production Apple lifecycle
service and ends only after an exact API snapshot reports `running` with a
start timestamp. Container creation, one warmup, stop, KILL fallback, deletion,
and absence verification are outside the timed interval. The scenario freezes
the creation-operation UUID and revalidates it before every lifecycle mutation;
a same-name replacement observed at those boundaries is reported and left
untouched. Apple 1.0 lifecycle routes remain ID-only and expose no conditional
mutation token, so the narrow final validation-to-mutation race is unchanged
and explicitly not claimed away. The benchmark runner
invokes cleanup even after preparation failure, measured failure, clock failure,
or cancellation; a recovered cleanup fault still invalidates that sample, and
an unrecovered fault reports the exact benchmark-owned container ID. Any
cleanup fault aborts the remaining suite rather than allowing another mutating
lane to begin after uncertain teardown.

The gate requires `NATIVECONTAINERS_LIVE_PERFORMANCE=1`, uses one warmup plus
three measured fresh containers, and emits a marker-framed JSON record to the
Xcode test log. It does not set a universal latency threshold: results are
host-session evidence for regression comparison, not a cross-machine product
promise.

## ADR-069: Benchmark guest and VirtioFS I/O as fixed end-to-end live workloads

**Status:** Accepted — 2026-06-22

Guest-root and host-folder I/O are separate mutating live scenarios behind both
`NATIVECONTAINERS_LIVE_PERFORMANCE=1` and
`NATIVECONTAINERS_LIVE_PERFORMANCE_IO=1`. They are never added to the Settings
suite. Both require the already-local reviewed image identity and reuse the
same fresh-container preparation, operation-UUID checks, final measurement
hook, cancellation-independent cleanup, and suite-abort rules as cold startup.

The workload is deliberately closed: `/bin/sh` runs a service-owned script,
accepts only a fixed target selected by the scenario and a bounded integer
payload, writes 16 MiB from `/dev/zero` through BusyBox `dd conv=fsync`, reads
the file immediately to `/dev/null`, and removes it from an exit trap. Output is
bounded and must contain exactly one completion marker. The clock surrounds
Apple process creation, the write and durability flush, immediate read, command
exit, and final container identity confirmation. Throughput counts 32 MiB of
processed data per iteration; it is not presented as a cache-cold disk or raw
device result.

The bind scenario accepts only a reviewed writable host folder mounted at
`/workspace`. The live gate creates that folder under a disposable
`/private/tmp` root, preserves the bookmark/device/inode checks of the product
attachment service, and requires the directory to be empty after all samples.
One warmup and three measured fresh containers run for guest root and bind
storage, after which a marker-framed JSON record carries raw timings,
median/P95, aggregate throughput, payload size, and host/runtime/image
provenance.

## ADR-070: Measure a fixed no-cache build through reviewed OCI publication

**Status:** Accepted — 2026-06-22

The real-build performance lane is gated by both
`NATIVECONTAINERS_LIVE_PERFORMANCE=1` and
`NATIVECONTAINERS_LIVE_PERFORMANCE_BUILD=1`; it is never part of Settings. Its
input is a private disposable context with an 8-MiB zero payload and a fixed
Dockerfile that copies and hashes the payload from an already-local base image
pinned by exact digest. The request allows one current-platform tag, no
secrets, build arguments, or target, disables every cache policy, and sets
`pullLatest` false. This avoids deliberately refreshing a mutable base during
the benchmark without claiming that arbitrary BuildKit internals are offline.

Each iteration prepares the production build plan and reviewed output lease
before timing. The clock wraps `AppleContainerBuildService.build`, so it
includes the embedded worker, Apple BuildKit execution, staged-context
revalidation and transfer, layer creation, OCI export, reviewed publication,
and final file validation. The destination is a unique OCI archive rather than
the Apple image store: the lane measures a real portable image build while
avoiding persistent tag mutation and ambiguous image-deletion ownership. The
result must retain the reviewed build ID, platform, destination, 64-character
lowercase SHA-256 shape, positive byte count, regular-file type, and exact file
size.

The runner removes the archive after every warmup or sample and treats any
cleanup error as suite-fatal. The live postcondition also rejects surviving
staged contexts, app-private artifacts, shared worker exports, output files, or
an unexpected image-store tag.
One warmup and three measurements produce marker-framed JSON containing raw
timings, median/P95, host and Apple runtime versions, exact base provenance,
payload size, cache policy, and output kind. Builder warmth and host load remain
session variables, so no universal latency threshold is asserted.

## ADR-071: Measure cold Apple Linux-machine startup through first-user readiness

**Status:** Accepted — 2026-06-22

Apple's persistent `container machine` environment is the Linux VM startup lane
for performance coverage. It is gated by both
`NATIVECONTAINERS_LIVE_PERFORMANCE=1` and
`NATIVECONTAINERS_LIVE_PERFORMANCE_MACHINE=1`, and it is never part of the
non-mutating Settings suite. The gate requires the selected reference and its
arm64 variant to be present locally, then records the exact image index digest.
Each iteration creates a unique stopped machine with one CPU, minimum memory,
and no home-directory mount. Image resolution/unpack and persistent-machine
creation remain setup, not startup time.

The clock surrounds the production `startMachine` contract. That service boots
the lightweight VM, performs the one-time host-user setup when the fresh
machine is not initialized, and returns only after its own exact-identity
snapshot is running and initialized. The benchmark then performs one additional
snapshot inside the interval and requires the reviewed creation timestamp,
image reference/digest, platform, running state, initialization flag, and start
timestamp. The metric is therefore first usable machine readiness; it is not a
bare hypervisor start or a warm restart. Apple 1.0 lifecycle routes do not
expose an atomic conditional-start token, so the narrow final
validation-to-start race is recorded rather than claimed away.

Cleanup runs outside the clock even under cancellation. It revalidates the
stable creation identity, attempts graceful stop, uses the existing explicitly
authorized backing-container KILL path only when needed, deletes the stopped
machine and persistent storage, and confirms absence. A same-name replacement
fails the suite and is left untouched. One warmup plus three fresh-machine
samples emit raw timing, median/P95, host/runtime/image provenance, CPU, memory,
platform, and the provisioning boundary. This decision does not claim coverage
for an IPSW-installed macOS GUI VM; that remains its own fixture-dependent lane.

## ADR-072: Measure macOS GUI-VM startup on disposable installed clones

**Status:** Accepted — 2026-06-22

The IPSW-backed macOS performance lane is gated by
`NATIVECONTAINERS_LIVE_PERFORMANCE=1` and
`NATIVECONTAINERS_LIVE_PERFORMANCE_MAC_VM=1`; the operator supplies an existing
fixture UUID through `NATIVECONTAINERS_LIVE_PERFORMANCE_MAC_VM_SOURCE`. The
fixture must be an installed, stopped macOS VM with recorded guest OS provenance
and completed first boot. It is never started or modified by the benchmark.
Before each iteration, the gate revalidates its complete manifest and creates a
same-host clone through the production clone service. Clone preparation,
identity regeneration, saved-state inspection, and source validation remain
outside the measured interval.

The clock surrounds the production `MacVirtualMachineRuntimeService.start`
contract and one exact follow-up observation. A valid sample requires a newer
snapshot in `.running`, a non-nil runtime-generation target tied to the clone,
no runtime error, no saved state, and a graphical console for that exact target.
Apple documents `VZVirtualMachine.start()` as starting and booting the guest and
reporting successful startup, while `VZVirtualMachineView` is the surface for
displaying and interacting with graphical content. This metric therefore means
host runtime plus graphical-console readiness. It does not claim that the guest
login screen, a user session, networking, or an application is interactive.

Cleanup runs outside the clock and independently of benchmark cancellation. It
revalidates the clone manifest before any mutation, requests guest shutdown when
available, and falls back to force-stop only for the reviewed runtime generation.
Deletion uses a new conditional library operation that compares the full
manifest while holding the library operation lock before acquiring the runtime
lock and tombstoning the bundle. A changed manifest or runtime generation is
left untouched and fails the gate. Clone absence, source equality, and no
run-prefix residue are required after every iteration. One warmup and three
measured clones emit raw timings, median/P95, host OS, source identity and name,
guest build/version, VM resources, and the explicit readiness boundary.

## ADR-073: Measure verified external HTTPS work from a fresh container

**Status:** Accepted — 2026-06-22

The external-network lane is enabled only by
`NATIVECONTAINERS_LIVE_PERFORMANCE=1` and
`NATIVECONTAINERS_LIVE_PERFORMANCE_NETWORK=1`. NativeContainers intentionally
ships no default internet benchmark target. The operator must provide a stable
HTTPS URL, expected byte count, and lowercase SHA-256 through the corresponding
`NATIVECONTAINERS_LIVE_PERFORMANCE_NETWORK_*` variables. The URL is bounded,
contains no embedded credentials, and rejects obvious loopback, link-local,
private-address, and `.local` targets. The payload must be 1–128 MiB. This is a
fixture integrity boundary, not a claim that DNS can never resolve an otherwise
valid hostname to private infrastructure.

Each iteration creates and starts a unique digest-pinned Apple container before
the clock begins. The measured production process-XPC command uses the local
Alpine BusyBox surface to resolve the endpoint, negotiate HTTPS with certificate
checking intact, request `Cache-Control: no-cache`, download to a fixed
guest-root file, count the bytes, calculate SHA-256, and emit one bounded
verification record. NativeContainers compares both values and reconfirms the
container's authoritative running identity before the sample ends. The byte
count is the throughput numerator. DNS, TLS, HTTP, guest storage, hashing, and
command transport are all in the denominator; this is deliberately not called
raw network or link throughput. The cache request also cannot prove that every
remote intermediary performed a cache miss.

An exit trap removes the guest file on success, failure, or cancellation. The
benchmark runner then gracefully stops, force-stops only the operation-owned
container when needed, deletes it, and verifies run-prefix absence outside the
clock. One warmup and three measurements emit raw timings, median/P95, aggregate
throughput, host and Apple runtime versions, exact image provenance, endpoint
authority without query data, expected bytes/digest, cache request, and
verification mode. Fixture drift fails the lane while preserving the same
cancellation-independent cleanup contract as the other mutating benchmarks.

## ADR-074: Measure idle containers with authoritative paired stats

**Status:** Accepted — 2026-06-22

The final performance lane is gated by
`NATIVECONTAINERS_LIVE_PERFORMANCE=1` and
`NATIVECONTAINERS_LIVE_PERFORMANCE_IDLE=1`. Its fixture is a fresh stopped
container created from an already-local, digest-pinned image with one CPU,
256 MiB of memory, no attachments, and `/bin/sleep 3600` as its only workload.
Creation and startup happen before timing. A two-second settling period also
stays outside the clock; the operator may select a 1–300 second sampling window
with `NATIVECONTAINERS_LIVE_PERFORMANCE_IDLE_SECONDS`, defaulting to ten.

The measured interval begins before the first production `stats` request and
ends after the second request plus an authoritative running-state recheck. CPU
usage is a cumulative microsecond counter, so each sample records its monotonic
delta and derives one-vCPU normalized utilization from the actual measured wall
duration. Network receive/transmit and block read/write are likewise paired
cumulative deltas. A counter family may be absent only from both snapshots;
partial availability or regression invalidates the sample. Current memory at
both boundaries, the unchanged 256-MiB limit, and final process count are
required snapshots rather than cumulative values.

This lane describes the container/runtime accounting surface, not total host
RSS, energy, or every Apple service process, and it asserts no universal idle
threshold. Host activity, thermal state, runtime warmth, stats-RPC overhead, and
kernel variance remain provenance-sensitive. One warmup plus three fresh
containers emit raw durations and counters, normalized CPU percentages,
median/P95 CPU, peak final memory, host/runtime/image provenance, command, and
settling/sampling configuration. Cleanup remains outside timing and must stop,
delete, and prove absence of every operation-owned fixture even after failure or
cancellation.

## ADR-075: Keep remote build caches typed and keep SSH gated on a session API

**Status:** Superseded by ADR-090 — 2026-06-23

NativeContainers exposes one optional remote registry-cache profile in each
immutable image-build review. It is not a free-form `cache-from`/`cache-to`
surface. The review accepts an explicit lowercase registry domain and OCI
repository, canonicalizes an omitted tag to `latest`, rejects digest references,
and requires the cache image to differ from every reviewed output image. The
closed access choices are import-only and import-and-export; export is further
bounded to BuildKit's `min` or `max` mode. The confirmation identifies the
remote mutation and warns that max mode publishes intermediate-stage layers.
Cache-export errors are never ignored.

Protocol v6 carries only the canonical reference and those two enums. The
worker revalidates that shape, then and only then lowers it to BuildKit registry
cache strings. Raw CSV, arbitrary attributes, local paths, and credentials are
not accepted. The privacy-sensitive reference appears in the immediate review
but is omitted from persistent build history. A fixed local cache and a remote
profile may be combined because BuildKit supports multiple import/export
locations; no-cache and a remote profile are mutually exclusive.

The pinned Apple 1.0 `Builder.BuildConfig` provides raw cache arrays but no
registry-auth session and no SSH field or BuildKit session-attachable provider.
NativeContainers therefore neither moves Keychain credentials into the worker
request nor pretends that the builder container's `SSH_AUTH_SOCK` implements
Dockerfile SSH mounts. Treating keys as ordinary build secrets or copying them
into a layer is prohibited. Remote caches are limited to endpoints the builder
can already access, live import/export remains gated on an operator-owned
disposable registry, and build-time SSH forwarding remains open until Apple
publishes a supported session contract.

## ADR-076: Version user data by authority and retain per-store rollback

**Status:** Accepted — 2026-06-22

NativeContainers product data begins at schema 1. The marketing version does
not double as a data version, and installing a new binary does not authorize a
filesystem-wide rewrite. Durable authorities are classified before a release:
VM bundles, restore images, folder bookmarks, and presets are authoritative;
history, descriptors, diagnostics, and operation journals are resumable or
inspectable; build staging, compatibility binaries, and caches are replaceable;
Apple runtime state, Keychain credentials, system permission state, exported
files, and user-selected folders are external. An app migration may revalidate
an external authority but never mutates it as an upgrade side effect.

Every future schema step must preflight the exact source, quiesce through the
store's normal mutation lock, seal only the files it can change into a private
rollback generation, transform in staging, validate through the production
reader, and atomically commit after identity revalidation. A durable journal
distinguishes pre-commit cleanup from post-commit restoration after hard exit.
Committed multi-store steps roll back in reverse order; ambiguous identity drift
fails closed. Rollback generations survive at least one successful new-build
launch and are retired later through bounded identity-checked cleanup.

An older binary may open only schemas its reader explicitly supports. If a new
format is not backward-readable, the release runbook restores the retained
generation before reinstalling the old binary; a downgrade is not itself a data
recovery mechanism. Release 0.1.0 establishes the inventory and performs no
whole-app migration. The release gate runs a static drift validator against the
current schema constants, storage roots, preference keys, Keychain boundary,
roadmap, and distribution instructions. A future schema-changing release remains
blocked until its migration, crash recovery, rollback fixtures, and exact-commit
Xcode test evidence exist.

## ADR-077: Separate semantic source enforcement from live accessibility evidence

**Status:** Accepted — 2026-06-22

NativeContainers management actions use standard SwiftUI controls. A selectable
resource summary is a plain semantic button, while lifecycle, menu, and
destructive actions remain sibling controls. The selection button publishes its
selected state and, where a dynamic name could otherwise be ambiguous, the
visible resource name as an accessibility input label. Raw tap gestures are not
accepted as an activation mechanism in management views. Icon-only controls
retain a semantic title or an explicit localized accessibility label, and layout
uses leading/trailing rather than fixed left/right alignment.

A repository source validator preserves those structural decisions, String
Catalog settings, the accessibility matrix, and the split roadmap state. It is
deliberately not an accessibility conformance test. Source inspection cannot
establish the realized accessibility tree, focus order, announcement timing,
keyboard behavior, translation quality, or interaction with a signed product.

Public release therefore requires exact-release-candidate evidence for every
management workflow using VoiceOver and Full Keyboard Access, plus Voice
Control, visual accessibility settings, pseudolocalization, and reviewed
shipping translations. Until that matrix is complete, only the source contract
is closed; end-to-end accessibility and non-English localization remain open.

## ADR-078: Run Pod commands through bounded argv and bracketed identity

**Status:** Accepted — 2026-06-22

One-shot Kubernetes Pod commands reuse the app-owned K3s service and Apple's
machine process-XPC transport. They do not export kubeconfig, invoke a host
`kubectl`, expose the cluster machine's root shell, allocate a PTY, or persist
command text or output. A typed request carries the selected Pod API UID,
the exact Apple machine identity, namespace, Pod name, explicit container name,
one executable, up to 128 arguments, and a 1–300 second timeout. Executable,
per-argument, and aggregate byte limits bound the guest command frame.

Kubernetes defines exec as `COMMAND [args...]` after `--`. NativeContainers
therefore adds no implicit shell. It shell-quotes each typed value only while
lowering argv into the fixed root wrapper, so quotes, substitutions, separators,
and whitespace remain argument data rather than host-script syntax. The wrapper
requires the exact current Apple machine, reads and compares the Pod UID, calls
explicit-container `k3s kubectl exec` without stdin or TTY, then reads the UID
again. A service-owned suffix binds the expected UID to the remote exit status;
the host accepts only that exact final marker and preserves nonzero command exit
as a result rather than misclassifying it as transport failure.

Stdout and stderr remain in the sheet model and retain at most the newest 1 MiB
per stream. Cancellation kills the app-owned Apple process transport and rejects
late results. Kubernetes exec remains name-addressed and supplies no conditional
UID token or remote-process identity, so the two UID reads cannot make the call
atomic and cancellation cannot claim rollback or confirmed remote termination.
Replacement detected before or after the call fails closed; the remaining
upstream race is documented instead of hidden.

## ADR-079: Extend VM identity transactions across macOS and Linux guests

**Status:** Accepted — 2026-06-22

GUI Linux virtual machines use the same stopped-only clone/export/import
transaction graph as macOS rather than a second filesystem implementation. The
source runtime lease is selected by guest, while copyfile transfer, source
snapshot revalidation, portability scrubbing, cancellation cleanup, atomic
publication, and hard-exit partial recovery remain guest-neutral.

The identity policy is guest-specific. macOS preserves or regenerates its
opaque `VZMacMachineIdentifier`. Linux preserves or regenerates the opaque
`VZGenericMachineIdentifier` stored in its platform directory and also treats
the manifest MAC as network identity. A Linux clone or copy import receives a
new locally administered MAC before copying. Because Apple's random-MAC API
does not guarantee uniqueness, planning rejects library collisions and commit
checks the normalized MAC again alongside the generic machine identifier.
Preserve import rejects a collision in either value.

Linux staged-bundle validation requires a writable disk and EFI variable store,
a valid generic identifier and MAC, no attached installation medium, no macOS
platform or snapshot state, and no host bookmark sidecar in portable mode.
Same-host clone retains shared-folder capability; portable export removes it.
The native Linux row exposes Clone and Export only while the installed guest is
stopped and unowned, and the existing import sheet offers identity-preserving
restore or fresh-identity copy without learning platform internals.

## ADR-080: Share app-owned vmnet topology across GUI guest families

**Status:** Accepted — 2026-06-22

ADR-048's automatic NAT, shared, and host-only modes now apply to both macOS and
GUI Linux VMs. `VZVmnetNetworkDeviceAttachment` belongs to Virtualization's
common network-device surface, and Apple's vmnet shared/host modes describe
guest interfaces without constraining the guest platform. NativeContainers
therefore keeps one process-owned logical network per custom mode and injects
the same focused device factory into macOS installation/runtime and Linux
runtime configuration factories. A macOS and Linux guest selecting shared mode
join the same logical network rather than isolated guest-specific pools.

Persistence remains guest-specific. Each mode change acquires that guest's
generation-pinned stopped runtime lease, revalidates the manifest observed by
the lease, advances the existing network revision, and atomically writes the
manifest. macOS still rejects a saved checkpoint and fingerprints the revision;
Linux has no saved-memory lane and needs no synthetic checkpoint rule. The
shared SwiftUI mode selector receives only a snapshot, a guest-specific lock
message, and a typed action.

Custom vmnet objects remain process-local and changes apply on the next cold
start. Same-host clones preserve the explicit mode. Portable export/import
clears it to automatic NAT for both guest families, while retaining Linux's
stable MAC separately. Physical bridging remains excluded because the target
does not carry its restricted entitlement.

## ADR-081: Treat VM compute edits as cold, identity-pinned configuration

**Status:** Accepted — 2026-06-22

Virtual CPU count and memory size are common Virtualization.framework
configuration inputs for macOS and Linux guests. NativeContainers therefore
uses one guest-neutral compute value, limits snapshot, observable model, and
SwiftUI editor. The composition root reads Apple's host-specific
`VZVirtualMachineConfiguration` bounds once and injects the same immutable
limits into guest-specific services.

Persistence remains behind each guest's generation-pinned runtime lease. A
mutation re-reads the exact manifest observed by the lease, validates the
requested CPU and MiB-aligned memory against current host limits, preserves disk
capacity, and atomically writes the bundle. Linux permits any value within the
host bounds while stopped or ready to install. Both guests reject saved state
because CPU and memory participate in their configuration fingerprints.

The macOS restore-image preparation result now retains Apple's minimum
supported CPU count and memory size in optional manifest fields. Subsequent
edits cannot cross those floors. Existing bundles lack that historical
requirement evidence, so their current allocation becomes the conservative
floor rather than guessing a lower supported value. Clone and portable transfer
preserve both allocation and floors; bundle preparation and commit validation
reject partial, unaligned, guest-incompatible, or allocation-exceeding floor
metadata. Disk capacity is displayed but cannot be changed by this editor:
virtual-disk growth and shrink policy require their own transactional storage
workflow and must not be disguised as a manifest edit.

## ADR-082: Keep VM display names separate from guest identity

**Status:** Accepted — 2026-06-22

NativeContainers treats a virtual machine's mutable display name as app-owned
manifest metadata. Renaming never changes the manifest UUID, canonical bundle
path, macOS or Linux machine identifier, Linux MAC address, storage artifacts,
or runtime configuration. This preserves clone, transfer, saved-state, and
external-reference identity while giving both guest families ordinary
post-creation name management.

The shared name model stages edits, rejects an empty normalized label, preserves
the user's draft across inventory refreshes, and refreshes inventory only after
persistence succeeds. Guest-specific services acquire the existing stopped
runtime lease; persistence revalidates the name observed by that lease and
atomically updates only `name` and `updatedAt`. macOS saved state remains valid
because no configuration fingerprint input changes. Active runtime ownership,
state transitions, and disk maintenance still block the mutation.

## ADR-083: Extend single-use saved state to validated GUI Linux configurations

**Status:** Accepted — 2026-06-22

Virtualization.framework exposes save and restore on guest-neutral
`VZVirtualMachine`; `VZVirtualMachineConfiguration.validateSaveRestoreSupport()`
is the authoritative capability gate. The installed documentation specifies
paused-only save and stopped-only restore, and a focused Xcode-run check proves
that NativeContainers' installed EFI Linux configuration passes the validation.
GUI Linux suspend is therefore enabled per constructed configuration instead of
being rejected by guest family.

macOS and Linux adapters share one actor-isolated transaction store and the
same `SavedState` format. The store pins the exact runtime lease, synchronizes a
hidden partial before atomic publication, binds metadata to the host OS and a
guest-supplied configuration fingerprint, consumes restore through a tombstone,
and removes interrupted transactions during inspection. Restore remains
single-use on success or failure so writable storage cannot advance and later
replay stale memory.

Linux owns a distinct topology descriptor and fingerprint. It covers CPU,
memory, disk geometry/path/format, generic machine identity, writable disk and
EFI/NVRAM file identities, optional installer identity, stable MAC and network
revision, graphics/audio/input/entropy/balloon devices, SPICE clipboard, and
VirtioFS share revision and source identities. Name is deliberately excluded.
Compute, network, and shared-folder mutations acquire their existing Linux
lease and reject any available or incompatible checkpoint. Installer ejection
marks the live generation unsavable until a cold restart because the detached
runtime topology no longer matches the immutable launch descriptor.

The Linux runtime mirrors the generation-pinned macOS state machine: Suspend
pauses, saves, and powers off; Start restores to paused and resumes; live Resume
discards a retained checkpoint first; Start Fresh and Discard are explicit
destructive choices; Force Stop can queue while callbacks quiesce. Storage
reclamation uses a guest-aware router so Linux checkpoints are validated and
removed only under Linux runtime leases. Saved state remains same-host and is
stripped from clone and portable-transfer paths.

## ADR-084: Grow stopped GUI VM disks through a forward-only DiskImageKit transaction

**Status:** Accepted — 2026-06-22

Virtual-disk capacity is storage state, not an ordinary manifest or compute
setting. NativeContainers exposes one guest-neutral grow service for stopped
macOS and GUI Linux VMs on macOS 27. It takes the existing guest-specific
runtime lease, rejects saved state, compares the manifest with live DiskImageKit
geometry, and seals the exact app-owned single-link regular file before
mutation. Standalone RAW and ASIF images open explicitly read-write. A macOS or
GUI Linux snapshot stack opens every non-active layer read-only and mutates only
the active overlay after exact ordered stack validation. Cache layers, shrink,
misalignment, and an implicit read-only fallback fail closed.

Growth is an in-place image mutation, so rollback by shrinking is unsafe. A
mode-0600 `.DiskImageResize.json` journal therefore records a forward-only
`planned -> imageExtended -> manifestUpdated` transaction. The resized file and
each journal phase are fully synchronized. If a hard exit lands after extension
but before the phase write, recovery accepts only the original file node at the
exact requested geometry, seals its new identity, and continues. The VM library
then revalidates guest, paths, format, runtime generation, old/new capacity, and
the post-growth file identity before atomically growing the manifest. Cleanup
after that commit is idempotent; ambiguous identity or geometry is never
guessed. Resize becomes non-cancellable once the journal is published.

Ordinary runtime, disk replacement, discard, clone, export, and import reject a
pending growth journal. A separate resize recovery lease is the only exception,
and launch recovery continues across independent bundles while reporting locks
and invalid journals. Snapshot history remains usable: every new or restored
active layer uses `overlay(blockCount:)` with the manifest's current capacity,
so restoring a checkpoint captured before growth cannot shrink the virtual
device. NativeContainers intentionally does not resize a guest partition or
filesystem and offers no shrink action; the native UI states that follow-up
explicitly.

## ADR-085: Treat VM memory ballooning as cooperative generation-scoped runtime state

**Status:** Accepted — 2026-06-22

Both macOS and GUI Linux configurations already include exactly one
`VZVirtioTraditionalMemoryBalloonDeviceConfiguration`. NativeContainers now
adapts the corresponding runtime device through one guest-neutral controller
and snapshot, but leaves mutation in each guest runtime service. A request must
name the exact live generation, no lifecycle transition may be in flight, and
the service accepts it only while the VM is running, matching Apple's documented
contract. Stale generations, paused guests, missing or ambiguous devices,
unaligned targets, and values outside the validated floor and configured
ceiling fail closed.

The floor is guest-aware. Linux retains at least the greater of Apple's host
minimum and 1 GiB. A prepared macOS guest retains its restore image's persisted
minimum supported memory; an older bundle without that evidence conservatively
uses its current configured allocation and therefore offers no unsafe reduction.
The native menu derives stable full, 75%, 50%, and minimum presets, omitting any
percentage below the floor. Lower targets produce an explicit cooperative
notice rather than a reclaimed-memory claim.

The requested target is not added to the manifest or app preferences. Apple's
device initializes a cold session at the configured memory size, so a fresh
boot restores full allocation. After saved-state restore, snapshots read the
current device target instead of inventing a separate app value. Automatic
memory-pressure control remains out of scope until an authoritative feedback
signal can distinguish a request from pages the guest actually returned.

## ADR-086: Present each graphical VM in one typed restorable window

**Status:** Accepted — 2026-06-22

Graphical VM runtime controls are independent workspace content, not a modal
sheet owned by the VM inventory. NativeContainers presents them with a
data-driven SwiftUI `WindowGroup` whose value contains only the manifest UUID
and immutable guest family. Apple's value presentation brings an existing
window for the same request to the front, so repeated Open actions cannot create
competing `VZVirtualMachineView` attachments for one guest. macOS also owns
window restoration and native window tabbing.

The restored value is identity, not runtime state. Each window resolves the
current canonical manifest and dispatches to the matching macOS or Linux view,
which reuses `AppModel`'s stable per-VM runtime model. A missing VM or guest
mismatch fails closed into an inert unavailable view. No virtual-machine object,
view adaptor, console generation, saved-state choice, or auto-start intent is
encoded, so relaunch cannot boot or resume a guest merely because its window
was previously open.

Console closure remains presentation cleanup rather than lifecycle authority.
The `VZVirtualMachineView` dismantle path detaches its adaptor, while stop,
Force Stop, suspend, and saved-state transitions continue through the exact
generation-pinned runtime service. This preserves long-running guest ownership
across window closure without maintaining a second console or lifecycle model.

## ADR-087: Export stopped container filesystems through private identity-pinned staging

**Status:** Accepted — 2026-06-22

Apple container 1.0.0 exposes a public root-filesystem export, so
NativeContainers uses that client directly instead of spawning the CLI or
copying files out one path at a time. The upstream request is ID-only and the
server accepts only a stopped container. A domain request therefore freezes the
container ID plus creation timestamp, and the service requires that exact
identity to remain stopped immediately before and after Apple's export. A drift
or unavailable record discards the private result and publishes nothing. This
narrows the external replacement race without claiming atomicity that Apple's
route does not provide.

Apple never receives the user's destination. It writes to one UUID-named,
mode-0700 operation directory under an owner-controlled app staging root while
NativeContainers holds an advisory lock. Once the XPC request is accepted, its
detached operation is allowed to settle even if the caller cancels; only then
does cancellation remove staging. The next export removes recognized unlocked
residue but preserves every locked operation, covering both ordinary
cancellation and hard-process-exit recovery.

Publication is create-new-only. The service holds and revalidates the selected
parent directory descriptor, rejects any existing final entry or symlink,
validates the staged tar as a nonempty owner-owned single-link regular file,
copies it into an exclusive hidden sibling while computing SHA-256, flushes it,
and commits with `RENAME_EXCL` plus parent `fsync`. It reports a retained partial
completion if only the final directory flush fails. The resulting restricted-
PAX tar contains the EXT4 root filesystem only; external volumes, bind mounts,
runtime/VM state, replacement, and an unsupported import path remain explicit
non-features.

## ADR-088: Require Apple’s signed system runtime for the container lane

**Status:** Superseded by ADR-090 — 2026-06-23

NativeContainers distributes the app and its private build worker, not a fork of
Apple’s container runtime. The container and persistent-machine lanes require
Apple `container` 1.0.0 installed from Apple’s signed package under
`/usr/local`. The app links the matching 1.0.0 Swift clients and treats Apple’s
runtime inventory, service configuration, package receipt, executables, and
user data as external authorities.

This boundary follows the upstream product. Apple’s signed installer places the
CLI, API server, four service/plugin executables, configuration, update script,
and uninstaller under `/usr/local` with administrator authorization. Its public
`ClientHealthCheck`, `ContainerClient`, image/volume clients, and
`MachineClient` connect to fixed `com.apple.container.*` Mach services; the
upstream `system start` command registers the same fixed API-server label.
Changing only an app root or install root does not namespace that protocol.
Embedding an isolated copy would therefore require NativeContainers to own and
continuously rebase a fork of the clients, launchd graph, runtime plugins,
updater, signing, and compatibility surface. That is not the shipped product.
The pinned evidence is Apple’s 1.0.0
[installation contract](https://github.com/apple/container/blob/1.0.0/README.md#initial-install),
[installer layout](https://github.com/apple/container/blob/1.0.0/Makefile),
[service launcher](https://github.com/apple/container/blob/1.0.0/Sources/ContainerCommands/System/SystemStart.swift),
and fixed-label
[container](https://github.com/apple/container/blob/1.0.0/Sources/Services/ContainerAPIService/Client/ContainerClient.swift),
[health](https://github.com/apple/container/blob/1.0.0/Sources/Services/ContainerAPIService/Client/ClientHealthCheck.swift),
and
[machine](https://github.com/apple/container/blob/1.0.0/Sources/Services/MachineAPIService/Client/MachineClient.swift)
clients.

The app may help an already-authorized user recover the official runtime, but
it never downloads an installer, elevates privileges, invokes `installer`,
updates, downgrades, uninstalls, or re-signs Apple code. Overview links to the
exact Apple 1.0.0 release. Before invoking the fixed CLI, the app requires a
root-owned, single-link, non-group/world-writable executable at
`/usr/local/bin/container` whose code signature matches Apple’s reviewed team
and signing identifier. It accepts only the pinned semantic version, runs
`system start --enable-kernel-install`, bounds output and execution time, and
then verifies both the container API health endpoint and machine API endpoint.

The app archive validator rejects Apple runtime executable names anywhere in
the bundle. A separate source-contract validator keeps the package version,
installer receipt, executable path, release URL, signing identity, docs, and
archive rule aligned. Upgrading the supported Apple runtime is an explicit
product change: update the package pins and contract together, review upstream
protocol changes, run deterministic coverage, repeat the live container,
machine, build, Compose, and Kubernetes gates, and produce a new signed release
candidate.

## ADR-089: Host menu-bar controls in an AppKit status item

**Status:** Accepted — 2026-06-23

The macOS 27 SwiftUI `MenuBarExtra` scene repeatedly invalidates the app graph
and can hold the main thread near 100% CPU. Disabling that scene restored idle
behavior but made a completed product control unavailable on the current host.
NativeContainers therefore removes `MenuBarExtra` and owns one
`NSStatusItem`/`NSPopover` pair through an app-scoped MainActor controller. The
popover hosts the existing `MenuBarQuickControlsView` in `NSHostingController`;
it does not duplicate inventory, lifecycle, routing, or error authority.

AppKit activation begins only from a SwiftUI installer after the main Window
scene exists. Constructing `NativeContainersApp` performs no status-bar work,
and hosted tests and Previews remain blocked by `AppExecutionContext`. This
ordering also prevents UserDefaults/AppKit initialization reentrancy. Visibility
changes are serialized, and the status item is installed or removed from the
same persisted App Behavior preference on every supported macOS release.

The installer captures SwiftUI's `OpenWindowAction` and `OpenSettingsAction` and
passes narrow closures to the controller. Container rows still navigate through
`AppModel` and exact `WorkspaceRoute` values before opening the unique main
window. The status item retains no resource snapshot of its own, and its popover
receives the shared model only when presented. ADR-057 remains the historical
record of the macOS 27 regression and disabled-scene mitigation, but its runtime
gate is superseded by this bridge.

## ADR-090: Offer one verified NativeContainers runtime beside Apple’s runtime

**Status:** Accepted — 2026-06-23

NativeContainers maintains two exact sibling forks: Apple `container` 1.0.0 as
`1.0.0-nc.2`, and `container-builder-shim` 0.12.0 as `0.12.0-nc.2`. The app and
its private build worker link the exact `container` fork tag. The runtime keeps
the upstream `com.apple.container.*` Mach service names and protocol shapes so
the signed Socktainer bridge remains compatible, but this also makes simultaneous
Apple and NativeContainers service graphs invalid. Activation first verifies the
target package receipt, version, artifact digests, code-signing team and
identifiers, builder digest metadata, and launch-service executable paths. It
then stops and proves absence of the current graph before starting the other;
unknown or mixed owners fail closed. A failed transition stops the candidate and
restarts the previously verified installation.

The fork is a separate, manually installed system package rooted at
`/Library/Application Support/NativeContainers/Runtime/1.0.0-nc.2`. The app
does not download it, elevate, invoke Installer, or modify Apple’s `/usr/local`
payload. Release packaging signs runtime executables with team `6UHAW5UAT4`,
signs the component package with the matching Developer ID Installer identity,
submits it for notarization, staples it, and verifies the installed receipt and
payload before activation. Source staging or an Apple Development signature is
never enough to enable conditional features.

The runtime owns a separate user-data root at
`~/Library/Application Support/NativeContainers/Container Runtime`. A one-time
migration may run only while both graphs are stopped. It clone-or-copies images,
volumes, networks, kernels, configuration, and machines into an exclusive
staging root, excludes sockets, PIDs, launch plists, and logs, validates source
stability and the staged copy, synchronizes it, and publishes with one atomic
rename. Apple’s source remains unchanged. Rollback stops the fork and restarts
Apple’s unchanged installation; it never deletes either data root.

The package carries the exact Linux/arm64 builder-shim OCI archive from source
revision `f66f1680fe6b74d814fb5527247e7d81227fcecb`, whose archive SHA-256 is
`d872daa5ff4534aeb18fb747e015e56cef1cd1b584e05d725b72b624b41a7680`.
Runtime startup imports it
only when absent and requires image digest
`sha256:b3574dc6b867fc91d1ed1d2941c74811961e2645ffa4c1fc68c19ae69e5fdbff`;
builder startup rechecks the resolved image-manifest digest, never ImageStore's
synthetic top-level index digest, and has no registry fallback. The package's
root-owned `etc/container/config.toml` pins the same native reference and is
verified at SHA-256
`15d02e3707d200579e23f03cf883bc8980a9dc4bfc3ea4f6e09224b17737892a`
before native activation.

This fork adds two conditional capabilities. Versioned machine routes create,
list, restore, clone, and delete at most eight named snapshots per stopped
machine under generation and catalog-revision preconditions. Snapshot bundles
capture the EXT4 root filesystem, machine and boot configuration, and
initialization state. Restore uses a recoverable predecessor swap; clones obtain
a new ID, remain stopped and non-default, and disconnect external home mounts.
External home contents, logs, runtime memory, and attached external resources
are excluded. Build protocol v7 separately carries only the reviewed SSH agent
ID `default`. The app revalidates the socket device and inode before builder
preparation and execution, while the runtime and builder shim register an SSH
session attachable only for opted-in builds. Private-key files and key bytes are
never accepted.

## ADR-091: Seal local Compose configs and secrets into reviewed execution

**Status:** Accepted implementation; execution blocked — 2026-06-23

Local Docker Compose does not require Engine config or secret objects for the
target source forms. NativeContainers therefore prepares project-local file
configs and secrets, reviewed environment-backed configs and secrets, and
literal config content through a two-stage API while keeping their execution
blocked:
`discoverInputRequirements(...)` returns only requirements and safe metadata;
`review(..., inputs:)` consumes required environment values into an in-memory
vault and returns the ordinary immutable project plan. External resources,
drivers, templates, paths outside the project, and user labels in the reserved
`com.nativecontainers.compose.*` namespace are rejected.

File traversal is descriptor-relative and no-follow. Every component must be
owned by the current user and not group/world writable; inputs must be
single-link regular files. Secrets reuse the build-secret count and byte limits;
configs are capped at 1 MiB each and 4 MiB total. File-backed uid/gid/mode values
receive Docker Compose’s local ignored warning. Environment and literal forms
remain Compose-owned and retain those requested attributes.

The vault seals each resource and each service’s effective grants with HMAC-SHA256
using a device-only Keychain key. Plans, labels, and journals contain only opaque
seals; environment values and direct secret hashes do not persist. Reviewed file
bytes are copied to a stable mode-0400 input store and the final canonical overlay
uses those paths. Environment values enter only the bounded Compose child, whose
raw diagnostics are suppressed for sensitive executions. The overlay adds
`com.nativecontainers.compose.input-seal` and computes exact reviewed service
hashes after the final labels and input rewrites. Execution must reproduce those
hashes exactly.

Fresh projects and contiguous create-missing replicas may consume the reviewed
inputs only after the runtime gate below passes. A changed seal on an existing
service is a replacement requirement, so the plan reports the existing
recreation blocker instead of silently starting or reusing stale containers.

Signed Socktainer 1.0.0 fails both local Compose delivery paths. File-backed
sources become host-file bind mounts, but Apple host mounts require the source to
be a directory, so container creation rejects the stable input file. Literal
configs and reviewed environment configs/secrets reach Compose's pre-start
archive injection, but the bridge returns that the container root filesystem is
unavailable. Converting file sources to strings is not exact: files may contain
arbitrary non-UTF-8 or NUL bytes, bind mounts differ from copied rootfs content,
and Docker Compose's file-backed attribute behavior differs from injected forms.
Starting the workload before injection would also expose the entrypoint to
missing inputs. The production decoder therefore emits a signed-bridge blocker;
only an explicit test gate exercises the dormant implementation and negative
live fixture.

Configs, secrets, recreation, aliases, health checks, and restart policies remain
blocked until one exact signed Socktainer release passes their live semantic
conformance contracts; partial current-main behavior does not change those
claims.

## ADR-092: Gate native Windows ARM64 support on signed guest tools

**Status:** Accepted experimental implementation — 2026-06-23

Windows 11 ARM64 uses the existing generic-EFI Virtualization.framework runtime
instead of introducing another hypervisor or a converted appliance format. The
app accepts normal local Microsoft ISO media, streams a private copy while
hashing it, mounts only that copy read-only for inspection, and requires an
ARM64 EFI boot manager plus the boot and install WIM payloads. The manifest
retains the media provenance and checksum without increasing the bundle schema.

The persistent system disk is NVMe and setup media is read-only USB mass
storage. VirtIO graphics, network, sound, entropy, balloon and vsock devices
keep the runtime aligned with the companion open-source Windows driver stack.
All guest-neutral GUI VM lifecycle, storage, snapshot, network, clone, transfer,
saved-state, folder and metadata services remain shared; Windows-specific
branches are limited to platform artifacts, device configuration, security and
guest integration.

Virtualization.framework exposes no public virtual TPM. The setup answer disk
therefore bypasses only the TPM check, never CPU, memory, storage or Secure
Boot. The current bootable mode defaults Secure Boot off. A visible toggle
exposes the prepared production mode, which uses persistent Secure Boot NVRAM
on macOS 27 and later, but enabling it blocks both creation and runtime start.

The app does not embed mutable driver binaries. A bundled release contract
names one immutable HTTPS `NCTools.iso`, exact SHA-256 and byte count. Download
uses private partial staging and a versioned managed cache. Production VM
creation and boot remain hard-gated until the contract independently asserts
both Microsoft driver signing and a completed stock-ISO Secure Boot validation.
The current contract asserts neither, so experimental source and test coverage
do not become a product support claim by accident.

The companion repository owns the ARM64 drivers, VirtIO sound WaveRT adapter,
guest service/user agent, packaging and signing evidence. It pins upstream
virtio-win and Microsoft SysVAD revisions and preserves their notices rather
than copying untracked snapshots. See `docs/WINDOWS_SUPPORT.md` for the exact
release and verification boundary.
