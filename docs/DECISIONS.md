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
the Engine operations required for one Compose behavior. Missing operations
make that fixture unsupported; known semantic gaps such as network aliases,
health checks, restart policies, configs, and secrets cannot become supported
merely because create/inspect routes exist. Project lifecycle is a distinct
policy-blocked fixture until a reviewed Compose model supplies desired replicas,
orphan handling, volume intent, and frozen resource identities.

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

Build requests and protocol-v5 control frames carry one closed cache mode:
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

Because NativeContainers also owns regular Window and Settings scenes, its
`MenuBarExtra` uses an explicit persistent insertion binding. Removing the extra
does not terminate the app, and Settings remains the recovery path for showing
it again. Main-window navigation uses SwiftUI's environment-provided
`OpenWindowAction` and the existing `WorkspaceRoute` authority.

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

## ADR-052: Model macOS disk snapshots as a bounded linear overlay service

**Status:** Accepted — 2026-06-21

NativeContainers persists macOS disk checkpoints as a revisioned linear
history rather than exposing DiskImageKit objects to the VM library or SwiftUI.
Each named checkpoint captures a prefix of canonical bundle-local ASIF overlay
layers, and one additional top layer receives subsequent guest writes. The
history is bounded to eight checkpoints. DiskImageKit exposes stack and overlay
creation but no public merge or flatten primitive, so arbitrary middle-layer
deletion is not offered. Restoring a checkpoint keeps its required prefix,
creates a fresh writable top layer, and prunes every newer checkpoint.

Creation and restore acquire the ordinary macOS runtime lease, require the VM
to be stopped with no saved state, recover only recognized app-owned staging or
unreferenced canonical files, and create the new overlay before one
compare-and-swap-style manifest commit. A failed commit removes the new layer.
After a successful restore, retired-layer deletion is best effort and any
failure is reported as committed cleanup pending; the next snapshot operation
reconciles that residue without rolling back the authoritative manifest.

The resolver and runtime consume the ordered stack through a focused disk-image
service: the base and historical overlays are read-only and only the newest
overlay is read-write. Saved-state fingerprints cover the manifest topology and
stable identity of every layer. Same-host clone and portable package workflows
retain the complete bundle-local stack and reject missing, symbolic, extra, or
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

**Status:** Accepted — 2026-06-21

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
