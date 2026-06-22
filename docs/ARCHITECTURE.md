# Architecture

## Principles

1. Use Apple’s public container and virtualization surfaces as the runtime.
2. Keep Apple package types at adapter boundaries so the app’s domain model is
   stable when the actively developed packages change.
3. Never put macOS VMs inside the container runtime abstraction. Container
   micro-VMs, persistent Linux development machines, and general-purpose
   Virtualization.framework VMs have different lifecycles.
4. Keep privileged work out of the GUI process. Installation, DNS resolver
   changes, and service management use the signed Apple installer/runtime or a
   narrowly scoped helper in a later phase.
5. Make every destructive operation explicit and test the state transitions.

## Composition and startup

`AppServices` is the dependency value consumed by `AppModel`; the live graph is
assembled separately under `App/Composition`. Launch-critical container
inventory and VM installation/disk/store recovery remain eager because the
first authoritative refresh depends on them.

Docker compatibility and Compose are one optional integration module behind
protocol-preserving facades. `DemandStartedService` protects a synchronous,
side-effect-free module factory with a lock, publishes the completed graph only
once, and releases the factory afterward. The three facades resolve that same
holder, so concurrent first access cannot create duplicate Socktainer process
owners, Docker Compose installers, or operation journals. Merely constructing
`AppModel` or running its initial inventory/VM-recovery path does not allocate
that optional graph; opening and loading Docker settings or the Compose
workspace does.

## Runtime lanes

```mermaid
flowchart LR
    UI["SwiftUI management app"] --> Model["@MainActor app model"]
    Model --> ContainerPort["ContainerManaging"]
    Model --> BuildPort["ImageBuilding"]
    Model --> HistoryPort["ImageBuildHistoryStoring"]
    Model --> VMPort["VirtualMachineManaging"]
    Model --> DefaultPort["WorkloadCreationDefaultsProviding"]
    DefaultPort --> HostState["ProcessInfo host state"]
    ContainerPort --> AppleClient["apple/container Swift clients"]
    AppleClient --> XPC["Apple container XPC services"]
    BuildPort --> Recorder["Best-effort history recorder"]
    Recorder --> Stage["Private reviewed context"]
    Recorder --> HistoryPort
    HistoryPort --> HistoryStore["Private atomic JSON records"]
    Stage --> Worker["Signed one-shot build worker"]
    Worker --> BuildKit["Apple ContainerBuild + shared BuildKit VM"]
    BuildKit --> Artifact["Isolated OCI artifact"]
    Artifact --> AppleClient
    XPC --> CZ["Containerization package"]
    CZ --> VZ1["Virtualization.framework micro-VM per container"]
    VMPort --> Library["VM bundle library"]
    VMPort --> VZ2["Virtualization.framework"]
    VZ2 --> Console["VZVirtualMachineView"]
```

### Host resource-default lane

Creation defaults cross a synchronous `WorkloadCreationDefaultsProviding`
port. `ProcessInfoHostResourceStateProvider` is the only type that reads
Foundation's active-processor, Low Power Mode, and thermal-state values;
`HostResourceDefaultService` maps that small domain snapshot into separate
container, persistent Linux-machine, and GUI-VM defaults. The service performs
no observation or background work until a creation sheet requests a snapshot.

Low Power Mode and serious or critical thermal pressure reduce only the
initial CPU values in a newly opened sheet. The draft remains editable, memory
and disk defaults remain stable, and no existing or running workload is
reconfigured. Fair thermal state does not throttle a user-initiated creation.
App inactivity, a closed window, and an unattached console are not authoritative
guest-idle signals, so they never trigger suspension.

### Container lane

The app consumes the library products published by `apple/container` 1.0.0,
initially:

- `ContainerAPIClient` for health, lifecycle, logs, stats, images, and volumes.
- `ContainerResource` for Apple’s snapshots/configuration values at the adapter.
- `MachineAPIClient` for persistent Linux development machines.

The adapter maps those values into small `Sendable`, `Codable`, `Equatable`
domain records. The rest of the app does not import Apple’s client products.
This keeps UI tests fast and isolates package source changes.

The installed Apple services remain the authority for runtime state. The app
does not create a second database of containers, images, networks, or volumes.

Image inventory remains cheap: the global refresh reads reference, digest,
media type, and index-descriptor size only. Selecting an image resolves its OCI
index, manifests, and configs lazily. Mutations cross a narrower `ImageManaging`
adapter and use immutable review plans. Tag replacement, deletion, and prune
therefore re-fetch current references, digests, container usage, and protected
builder/vminit images immediately before acting.

Volume and network mutations cross the parallel `InfrastructureManaging`
facet. Create plans pin absence plus an operation UUID stored in a namespaced
resource label. Delete and prune plans pin the complete intrinsic
configuration identity and every referring container configuration, including
stopped containers. Execution uses the shared runtime mutation coordinator,
re-fetches immediately before mutation, and treats built-in networks and new
references as hard stops. Apple remains the final atomic in-use authority.

Persistent Linux machines cross separate `MachineCreating`,
`MachineLifecycleManaging`, `MachineConfigurationManaging`,
`MachineCommandRunning`, and `MachineTerminalOpening` facets.
`AppleMachineManagementService` owns the
reviewed workflow and shared mutation lease, while
`AppleMachineRuntimeClient` contains Apple package types,
`AppleMachineImagePreparationService` prepares standard OCI-rootfs machines
through public image fetch/unpack APIs without the CLI-oriented flags helper,
`AppleMachineXPCTransport` bounds machine requests with fresh watchdog-closed
connections. `AppleLinuxMachineSnapshotMapper` is the single adapter from
Apple snapshots to app identity, state, inventory, and mutable configuration.
`AppleLinuxMachineConfigurationService` shares the runtime mutation lease,
requires a stable creation identity, re-inspects immediately before Apple’s
ID-only `setConfig` route, and reconciles the persisted CPU, memory, and home
mount in a cancellation-independent task before reporting success. Running
machines may be edited, but the UI accurately says the new boot configuration
takes effect after restart. `AppleLinuxMachineProcessTargetResolver` invokes readiness and
then re-inspects the complete stable machine identity to capture its fresh
per-boot backing-container ID. `AppleLinuxMachineProcessService` constructs
Apple's `/sbin.machine/init -s` configuration with the persisted mapped user
and machine home, then delegates commands and terminals to shared runtime
process/session services. Creation is cancellable; once durable
state exists, failure or cancellation attempts a graceful stop and then KILLs
only the revalidated backing container. Force Stop requires explicit
authorization and confirms exit. Delete revalidates the complete creation
identity immediately before Apple’s ID-only route, but Apple 1.0 exposes no
conditional delete token, so a narrow external same-name replacement race
remains.

### Kubernetes lane

Kubernetes is one application-owned cluster backed by one persistent Apple
container machine, not a hidden Docker or Virtualization.framework runtime.
`AppleKubernetesClusterService` composes the existing machine creation,
lifecycle, inventory, process-target, and bounded process-execution facets. The
machine receives no host-home mount. Cluster data, containerd state, and local
volumes remain inside its dedicated persistent disk and share the machine's
exact identity and lifecycle.

Provisioning executes as UID 0 through Apple's runtime-process XPC route; the UI
does not expose a generic privileged shell. The service installs only bounded
apk/apt prerequisites, downloads the installer from the exact K3s release tag,
compares it with an embedded SHA-256 before execution, pins
`INSTALL_K3S_VERSION`, and relies on the official installer's release checksum
verification for the binary. On Alpine, Apple's machine boots under `vminitd`
rather than OpenRC as PID 1, so the app prevents installer auto-enable, prepares
the unified cgroup hierarchy through one service-owned root command, and starts
the generated OpenRC unit explicitly. The same bounded activation runs after a
machine restart; systemd images use their generated unit. K3s enables secret
encryption and writes a mode-0600 kubeconfig. Readiness requires the API, a
Ready node, flannel state, default service-account reconciliation, and the
protected kubeconfig rather than treating the first `/readyz` response as the
whole cluster being usable.

A backup-excluded mode-0700 host store retains only the schema, operation ID,
exact Apple machine identity, approved distribution provenance, phase, and
creation time. It preserves the Date's binary precision because that timestamp
participates in identity comparison. It contains no cluster token, client key,
certificate, or kubeconfig. An interrupted install remains explicitly
retryable against the same identity. A replacement with the same name is
surfaced as stale and never addressed. Delete gracefully stops and removes only
the exact machine; Force Stop uses the existing identity-pinned authorization
path.

Status reads bounded version, node, and pod summaries from `k3s kubectl`.
Resource inventory is a separate explicit read path available only for a Ready
descriptor whose exact current Apple machine is running. A fixed guest command
uses `jq` to project Deployment, StatefulSet, DaemonSet, Job, Pod, and Service
JSON down to identity, counts, phases, nodes, container names, addresses, and
ports before the payload crosses Apple's process transport. Pod records retain
the API UID, while workload records retain UID and resourceVersion, so a
same-name replacement is a new SwiftUI identity and a future reviewed scale can
carry a server-enforced version precondition. The host parser caps each resource
family at 500, rejects duplicate UIDs or natural identities and malformed
values, and sorts stable records for SwiftUI. Pod
environment, annotations, images, and Kubernetes secret payloads are not
represented in the projected document or domain model.

`KubernetesClusterModel` owns the separately cancellable inventory state and
clears it across lifecycle or identity changes. The browser is read-only,
searches cached prepared arrays rather than filtering in `body`, and uses
stable runtime identities for native lists. Pod rows can load one explicit
standard container's latest 2,000 lines through the same exact-machine path.
The service validates the UID, namespace, Pod name, and container name; checks
that the current Pod UID still matches; and then asks `kubectl logs` for at
most 512 KiB plus one truncation-detection byte with timestamps. A second UID
read and service-owned output marker must also match before any log snapshot is
accepted, so replacement during the name-addressed read fails closed. Search
uses cached prepared text, container switches discard stale asynchronous
responses, and export remains user-initiated.

Deployment and StatefulSet rows additionally expose a reviewed scale sheet;
DaemonSets and Jobs do not. The request freezes UID, resourceVersion, namespace,
name, kind, and current/target replica counts. The fixed guest command re-reads
the object, rejects any identity/version/current-count drift, and calls
`kubectl scale` with both server-enforced resource-version and current-replica
preconditions. It then re-reads the exact UID, requires a new resourceVersion
and the target count, and returns one marker-framed result. The model reloads
the bounded inventory after success and refreshes it after rejected stale
reviews; scaling never exposes a generic guest command or host kubeconfig.

Deployment, StatefulSet, and DaemonSet rows also expose a reviewed restart
sheet; Jobs remain excluded because their Pod template is immutable. The fixed
guest command reads the complete exact object, verifies API version, kind,
namespace, name, UID, and resourceVersion, and changes only the standard
`kubectl.kubernetes.io/restartedAt` Pod-template annotation. It removes status
and managed-field response metadata, then submits the full object through
`kubectl replace`, preserving Kubernetes' resourceVersion optimistic lock. The
response must retain the exact identity, advance resourceVersion, and echo the
restart annotation before success is returned. Full workload JSON—including
any environment values—stays inside the guest and is never returned to the
host; replace stderr is suppressed in-guest and mapped to a service-owned
rejection, while success returns only marker fields. The review warns that
configured `OnDelete` strategies do not replace existing Pods automatically.

Every workload row also exposes an explicit deletion review. The user must type
the exact workload name, and system namespaces receive an additional critical
warning. Deletion never uses the ordinary name-only kubectl path. A fixed,
kind-specific API URI receives a raw DeleteOptions body containing both the
reviewed UID and resourceVersion preconditions plus `Foreground` propagation;
force mode and grace-period overrides are absent. K3s rejects any replacement
or intervening update before deletion begins. The guest suppresses response
details, then polls the same endpoint identity to distinguish completed
deletion, a safe same-name replacement, and work still waiting on finalizers.
Only that bounded outcome marker reaches the host, and the browser reloads the
authoritative inventory in every case.

The log sheet can open a terminal for the selected standard container. Its
restorable target carries the exact cluster-machine identity, Pod API UID,
namespace, Pod name, and container name. The terminal service requires the
stored Ready descriptor and exact running machine, discovers only a bounded
allowlist of common shells through the fixed root-command lane, and brackets
that discovery with Pod UID reads. It then resolves the machine's fresh
per-boot backing container and starts `/sbin.machine/init -s` as UID 0 with a
terminal-mode Apple process. The only guest command is a final in-process UID
preflight followed by explicit-container `k3s kubectl exec` with stdin, TTY,
and a bounded Pod-running wait. While that PTY is starting, a separate bounded
UID read must still match or the new session is immediately closed. Kubernetes
exec remains name-addressed, so replacement in the narrow interval after a UID
check cannot be made atomic with the current upstream API and is documented
rather than hidden.

Kubeconfig is read only after an explicit export action, validated and bounded
in memory, rewritten from guest loopback to the current dedicated machine IP,
and handed to the system file exporter. NativeContainers never persists the
secret document on the host.

Container creation attachments cross a separate `ContainerAttachmentManaging`
facet. The SwiftUI draft freezes complete volume and network configuration
identities, ordered network selection, normalized guest mount paths, and logical
Unix-socket publications. `AppleContainerAttachmentService` re-lists current
infrastructure and every container configuration under creation's mutation
lease, rejects stale or newly used volumes, preserves the reviewed primary
network, and constructs Apple's mount/network/socket values directly. Empty
legacy requests still resolve Apple's current built-in network, while the UI
always reviews that choice explicitly.

`ApplePublishedSocketWorkspace` is the only service allowed to turn a logical
socket publication into a host path. It uses an operation-labeled, mode-0700
directory under `/private/tmp/nativecontainers-<uid>`, atomically creates and
`lstat`-validates every directory, enforces a conservative macOS Unix-socket
path limit, refuses occupied leaves, and revalidates the exact lexical boundary
before every start. A missing private directory can be safely reconstructed
from the persisted operation identity; stop removes the socket and failed
creation or container deletion removes only that operation directory.

Host-directory sharing remains a reviewed attachment rather than a raw path on
the creation request. `ContainerHostDirectoryBookmarkService` owns
security-scoped bookmark creation and resolution, rejects a symbolic-link leaf,
pins the selected device/inode across canonical path resolution, and retains
the security-scope lease for the full create or start operation.
`AppleContainerHostDirectoryService` turns only those resolved selections into
Apple `Filesystem.virtiofs` values. A private mode-0700 manifest root with
mode-0600 atomic records preserves the reviewed bookmark and exact guest path;
every later start compares the persisted attachment to the container's current
configuration before opening access. Read-only is the default and write access
is an explicit per-folder choice. Cleanup removes only the operation-owned
manifest after failed creation or container deletion.

SSH-agent forwarding follows Apple's native configuration path.
`AppleContainerSSHAgentService` accepts only an absolute `SSH_AUTH_SOCK` that
is currently a Unix-domain socket, freezes its device/inode during review, and
revalidates the same environment and identity before creation and every start.
The creation and lifecycle services pass that one dynamic environment entry to
Apple while setting `ContainerConfiguration.ssh`; they never synthesize a
guest mount. A missing, replaced, or non-socket source fails closed instead of
silently starting without the reviewed agent.

Apple's host alias is global resolver and packet-filter state, not a container
configuration field. `AppleContainerHostAccessService` therefore performs
read-only discovery of exact root-owned resolver, `pf.conf`, and anchor files.
Creation can require one reviewed configured-on-disk identity, but the GUI does
not execute `sudo`, claim PF is currently loaded, or broaden privileges. A
future mutating helper remains a separately signed and notarized service.

Infrastructure, Linux-machine, and runtime-process XPC requests use fresh
connections with cancellation-triggered close and operation-specific close
watchdogs. Machine requests cap at 35 seconds; process create/start uses a
ten-second bound and signal/resize uses two seconds. Process wait connections
have no fixed lifetime deadline so valid shells can remain open, but task
cancellation closes them; setup and one-shot command services impose their own
deadlines and confirmed KILL behavior. Wait and output-drain completion recheck
caller cancellation before returning, so a KILL-induced exit cannot race into a
normal command result. A timeout never implies rollback:
mutations reconcile live state before reporting an outcome. A focused image
service performs public fetch and unpack operations before any machine exists.
Apple 1.0 delete calls accept only a name, not an expected revision, so
narrow external same-name replacement races remain documented rather than
hidden.

Cancellation reconciliation, owned-resource rollback, and inventory refresh
run in fresh tasks so the cancellation that closed the original connection
cannot also cancel recovery. Container rollback uses a dedicated bounded XPC
client: it sends `KILL`, issues force deletion, retries with bounded backoff,
and verifies absence without holding the global mutation lease.

`AppCompositionRoot` constructs one live service graph and shares the same
runtime mutation coordinator across container, infrastructure, and image-build
mutations. `AppModel` depends on named narrow facets through `AppServices`, not
the complete runtime adapter. `AppleRuntimeInventoryService`,
`AppleInfrastructureService`, `AppleContainerCreationService`,
`AppleContainerAttachmentService`, `ApplePublishedSocketWorkspace`,
`AppleContainerHostDirectoryService`, `ContainerHostDirectoryBookmarkService`,
`FileContainerHostDirectoryManifestStore`, `AppleContainerSSHAgentService`,
`AppleContainerHostAccessService`,
`AppleContainerLifecycleService`, `AppleContainerInspectionService`,
`AppleContainerShellService`, `AppleContainerToolService`,
`AppleContainerTerminalService`,
`AppleRuntimeCommandExecutor`, `AppleImageService`,
`AppleMachineManagementService`, `AppleLinuxMachineProcessService`,
`AppleOwnedContainerRecoveryService`, and `AppleXPCRequestClient` own their
focused vertical slices. The legacy `AppleContainerService` is a forwarding-only
compatibility facade and owns no runtime behavior.

Browser opening is intentionally outside the service mutation layer. The
service re-fetches the same container creation identity, its running state, and
the exact current TCP publication;
SwiftUI then offers explicit HTTP and HTTPS choices through `openURL`. Wildcard
listeners map to family-matched loopback and `URLComponents` handles IPv6.

Registry credentials use Apple Containerization’s `KeychainHelper` with the
runtime’s exact `com.apple.container.registry` security domain. The settings
model lists host, user, and timestamps only; stored passwords never leave
Keychain. A newly entered secret lives in a secure field just long enough to
ping the registry and save. Registry mutations are serialized and revalidate
the full reviewed metadata immediately before save/delete. Transport is not a
Keychain attribute, so every transfer resolves it separately and must reconfirm
plain-text HTTP.

Interactive terminals remain in this lane. The app asks the bounded
`AppleContainerProcessXPCClient` for a terminal-mode child, transfers duplicated
pipe descriptors through Apple’s XPC boundary, and streams the resulting bytes
into SwiftTerm. Transport and rendering are separate: the service owns process,
descriptor, signal, resize, retention, and cancellation semantics; the AppKit
surface owns VT parsing, drawing, keyboard input, selection, and terminal
protocol replies.

Container shell choice is a separate injectable service shared by terminal and
exec tooling. It derives ordered candidates from the container process
configuration, probes each candidate as a bounded non-terminal child, and
returns a typed source plus executable. Automatic terminal requests are resolved
before they reach the process launcher, so the launcher accepts only an explicit
executable. Persistent Linux machines intentionally bypass this policy and keep
using Apple’s machine init helper for the configured login shell.

Terminal presentation is another boundary rather than state inside resource
detail views. Container, Linux-machine, and Kubernetes-Pod actions open a lightweight,
`Codable`/`Hashable` target in a data-driven SwiftUI `WindowGroup`; the system
owns detached-window restoration and native macOS window tabbing. Each window
owns a bounded app-level tab workspace whose `SceneStorage` payload contains
only its workspace UUID, stable tab UUIDs, selected tab, and optional preset
UUIDs. Live process objects and output never cross restoration. A restored
window is inert until explicit interaction, preventing relaunch from starting a
stopped machine or creating a shell unexpectedly.

`IdentityPinnedTerminalTargetService` reloads canonical Apple inventory for
container and ordinary Linux-machine tabs and compares the complete persisted
Linux-machine identity or the container ID plus creation date. Pod targets route
to the Kubernetes authority, which independently revalidates the cluster
descriptor, machine, and Pod identity. Missing or same-name replacement targets
fail before process creation. `TerminalPresetStore` is a separate bounded persistence
facet backed by the system preferences authority. Its versioned payload stores
only validated shell selection, login-shell intent, and an absolute guest
working directory; environment, arbitrary startup commands, terminal output,
and history are excluded. Pod targets never accept presets or custom startup
commands. Views coordinate windows and tab selection but never
call Apple container or machine adapters directly.

Native builds cross a narrower `ImageBuilding` boundary. Review first copies
the local context beneath a mode-0700 app-owned boundary, preserves the source
POSIX modes that BuildKit exposes to `COPY`, and records a metadata-and-content
fingerprint, Dockerfile and ignore hashes, canonical target tags and current
digests, exact platforms, builder resources, and build flags. A code-signed
one-shot helper owns Apple’s `ContainerBuild.Builder` and its otherwise
unclosable NIO/gRPC lifetime. Before and after dialing, it revalidates the exact
reviewed builder descriptor, creation identity, image digest, DNS configuration,
and socket. It produces an OCI archive under a unique staging reference but
never mutates final tags.

`AppleContainerBuildService` is only the stable facade and single-flight owner.
It composes an `ImageBuildPlanning` service for validation and immutable review,
an `ImageBuildExecuting` service for worker and publication orchestration, and
an `ImageBuildLifecycleManaging` service for discard and cancellation-independent
cleanup. The phases share the same injected staging, secret, artifact, output,
and image-store boundaries, so product wiring stays one call while tests can
replace any phase without constructing the Apple runtime.

Build caching crosses two additional focused boundaries. The worker-owned
`AppOwnedBuildCacheStore` serializes the fixed local profile, validates a fresh
OCI cache export, and atomically moves it from disposable `staging` into a
tokenized `prepared` handoff before releasing the cross-process lease. Its
receipt binds the build ID, opaque token, directory identity, OCI metadata
hashes, and a deterministic metadata tree covering every entry without exposing
a cache path or raw BuildKit string. After private-artifact validation, the host-owned
`ImageBuildCacheFinalizing` service reopens that exact prepared generation and
atomically swaps it into `current`. Inspection may recover abandoned staging
but cannot delete a live prepared handoff; explicit discard/reset owns immediate
cleanup and recovery reclaims handoffs older than 24 hours. Cache status/reset remains a separate `AppOwnedBuildCacheManaging`
service from Apple builder lifecycle.

Build secrets cross a separate `ImageBuildSecretManaging` boundary. The review
request contains file selections, but the immutable plan contains only a
canonical ID, privacy-sensitive path, and byte count. The service rejects invalid or
duplicate IDs, sources inside the build context, links, non-regular files,
foreign owners, multiple links, and any group/world access. It keeps the
security scope and an `O_NOFOLLOW` descriptor open, with device, inode, mode,
owner, link count, size, mtime, and ctime frozen until execution or discard.
Those descriptors are pinned before context staging, which refuses to copy any
matching device/inode and revalidates the review afterward. After shared-builder
preparation, consumption revalidates both path and descriptor, streams with
`pread`, clears its bounded buffer, and destroys the one-shot lease as soon as
the committed pipe envelope is written.

Build history is deliberately outside Apple’s runtime inventory. A
`RecordingImageBuildService` decorates the native `ImageBuilding` service and
best-effort records a running attempt before execution and one typed terminal
outcome afterward. History failure never changes a build result. The separate
`ImageBuildHistoryStoring` actor owns schema-versioned, per-record atomic files,
bounded terminal retention, corruption isolation, live update streams, and
abandoned-launch running-to-interrupted reconciliation guarded by live process
leases. Local notifications plus a cheap directory-token poll keep every visible
model current across app processes; known foreign-running leases are checked for
lock release, slow-load refreshes are coalesced, and unreadable-record warnings
remain latched until explicit clearing. Graceful release removes the current
lease. A separate private-directory service owns descriptor-relative
`openat`/`renameat`/`unlinkat`, bounded enumeration, advisory locking,
nonblocking type checks, ACL removal, file and directory synchronization, and
crash-temp scavenging. History persists only the context display name,
fingerprints and hashes, tags, platforms, option keys and flags, secret count,
timestamps, typed status, digest or retained partial-import references/digests,
typed output kind, and typed failure category. Output destinations, full paths,
argument and label values, secret IDs and paths, logs, and error text never
cross this persistence boundary.

Canonical Dockerfile and ignore paths are checked as strict descendants by
path component, not textual prefix. This accepts directory URLs normalized with
or without a trailing separator while rejecting the context itself and sibling
paths that merely share its name prefix.

The worker returns a typed artifact, never a user destination. Guest-visible
file exports are descriptor-validated, copied into a host-private mode-0400
artifact, and bound to byte count and SHA-256. Local-directory exports cross a
separate private tree store that rejects special files, preserves modes and
symlinks, and fingerprints names, kinds, modes, link targets, and contents. A
focused output service pins the reviewed host parent, revalidates destination
and artifact identities, copies to a hidden sibling with cancellation points,
and commits atomically. Existing files require explicit authorization and a
post-swap identity check; directory outputs must be new. Post-commit failures
retain and report the output rather than deleting it.

Image-store builds additionally revalidate before import, reconcile ambiguous
import/tag XPC failures by re-listing committed state, verify snapshots, and tag
under the same mutation coordinator as image CRUD. Alternate outputs never
mutate the image store. Build execution is cancellation-aware single-flight,
while the long solve stays outside the global mutation lock.

Builder maintenance crosses a separate `ContainerBuilderManaging` service
boundary. Read-only inspection reports stable runtime state and whole-bundle
allocation. Stop, explicit `KILL`, and stopped-only deletion are prepared from
the shared snapshot adapter used by the build worker, then execute under the
image-build lock followed by the global runtime lock. Execution revalidates the
runtime root, creation date, complete pinned identity, and configuration before
the XPC call. Because an XPC mutation may commit before its reply fails,
reconciliation runs in a fresh uncancelled task. Deletion additionally requires
both inventory and the exact builder bundle path to be absent; the service never
manually removes an orphaned bundle or the separate builder-export directory.

Worker protocol v5 reserves stdout for capped length-prefixed control frames
and adds typed output/cache requests and artifact receipts without host destinations.
Its exact-length stdin decoder reads one metadata-only JSON request followed by
a bounded binary secret envelope and final commit marker, then leaves stdin open
as the parent-lifetime lease; secret bytes never enter Codable state, argv,
environment, an app-side `Data`, or a temporary file. Secret-enabled solves force
Apple `Builder.BuildConfig.quiet`, drain
stderr without retaining it, and replace worker failures with a fixed notice.
Ordinary builds retain the bounded plain BuildKit log. The parent consumes
short stdout frames with POSIX `read`, so progress is delivered before worker
exit and cancellation can escalate TERM to KILL while BuildKit is still active.
Cleanup removes both
guest-visible and private artifacts in a cancellation-independent task,
including builds canceled while queued. Context and worker isolation prevent
stale review data and leaked process resources; they do not claim to sandbox a
compromised BuildKit implementation.

The app-owned local cache is a separate focused service. Its wire mode is a
closed enum; raw BuildKit cache strings exist only in the worker adapter. One
cancellation-aware cross-process lease protects a private versioned namespace
across import, solve, export, and artifact isolation. Each solve exports into a
fresh staging generation. The worker validates it and returns only a typed
staged receipt after the primary artifact is private and digest-bound. After the
worker terminal frame arrives, the app revalidates the artifact and a host-side
cache finalizer reacquires the lease, revalidates staging, and atomically swaps
it into `current`. Failed, cancelled, killed, or disconnected workers therefore
cannot replace the last committed generation; lifecycle cleanup or the next
lease scavenges abandoned staging. A committed generation remains valid if a
later image-store or destination publication step fails.
Inspection/reset use the same lock and never mutate Apple's builder container or
unrelated `<appRoot>/builder` exports.

Both sides use POSIX pipe reads for short framed traffic. Foundation’s counted
pipe read can wait for the entire requested buffer or until EOF; the input lease
is intentionally open, and the worker stays alive during a solve, so using it
would deadlock request dispatch or buffer progress until the build had ended.

During foundation development the GUI connects to a matching installed Apple
`container` 1.0.0 service. A distributable product must embed a version-matched,
namespaced build of Apple’s Apache-licensed services and helpers so it can
coexist with the standalone CLI and cannot drift across an incompatible XPC
protocol. The UI adapter stays the same across those deployment modes.

Docker CLI and Compose compatibility are a separate service boundary. Apple’s
core project intentionally exposes OCI/Dockerfile compatibility rather than the
Docker Engine HTTP API. `DockerCompatibilityService` composes a pinned
`SocktainerInstallService`, an exact-process `SocktainerProcessService`, and a
CLI-backed `DockerContextService`; none of those capabilities enter the native
container service graph.

The installer accepts only Socktainer 1.0.0’s reviewed HTTPS asset after its
SHA-256 and Developer ID team both match. Start requires a live Apple 1.0.0 API
server and a real `/_ping` response with Docker API 1.51. The process layer owns
one exact PID and socket inode, escalates TERM to KILL, exposes an immediate
Force Stop, synchronously cleans up on app termination, and offers explicit
stale-socket removal only after three failed listener probes and unchanged
identity. Docker context setup uses supported `docker context create/update`
commands, strips shell context/host overrides for the operation, and confirms
that the user’s active context did not change.

Compose bridge conformance is another independent pure service facet.
`SocktainerComposeConformanceService` evaluates an immutable manifest pinned to
Socktainer 1.0.0, Docker Engine API 1.51, and release revision `876c2fc`.
Each fixture names the exact Engine operations it requires and separately
records semantic limitations or application-policy blocks. Missing operations
fail closed, and new operation cases are not accepted implicitly. The resulting
report is visible in Settings but is explicitly source-pinned evidence rather
than a live Compose execution result. It does not start the bridge, inspect
Apple inventory, or authorize project mutation.

`SocktainerComposeLiveConformanceService` is a separate opt-in execution
boundary. A private workspace facet writes one fixed Alpine fixture with unique,
grammar-validated container, volume, and network names. The runner validates the
Compose model, starts it through the isolated `nativecontainers` context, and
accepts success only after canonical service/volume/network associations appear
through `AppleRuntimeInventoryService` and `ComposeTopologyService`. Every host
command has a deadline; `FoundationHostCommandExecutor` escalates TERM to KILL
and confirms exit when the client hangs.

Cleanup runs in a detached, non-cancellation-inheriting task. It first executes
the reviewed model’s `down --volumes --remove-orphans --timeout 3`. If that
fails, a pure planner accepts only the fixture’s exact names plus canonical
labels, freezes Apple configuration identities, and revalidates each identity
before an Apple-native cleanup facet force-stops/deletes the container and
deletes reviewed network and volume plans. Absence is polled through Apple
inventory before cancellation or the original error is returned. The runner
remains a conformance boundary rather than a user-project mutation action.

`DockerComposeClientInstallService` is the product-owned client boundary. A
release value pins Docker Compose 5.1.4’s official Darwin arm64 binary and SLSA
provenance identities. Separate downloader and validator facets enforce bounded
HTTPS acquisition, private regular-file invariants, both SHA-256 digests, the
thin arm64 Mach-O header, and exact provenance subject/source/builder semantics.
The actor stages and revalidates both artifacts before publishing provenance and
then the executable into a versioned mode-0700 Application Support directory.
It never mutates Docker CLI plugin paths and exposes a checked executable URL
only while the complete installation validates. `AppServices` injects this
facet into the app-scoped Docker compatibility model; Settings observes and
installs it without merging client ownership into Socktainer process ownership.

Compose observability is a separate pure service boundary, not a second runtime
and not part of Socktainer process ownership. `AppleRuntimeInventoryService`
preserves container labels verbatim alongside the existing volume and network
labels. One `ComposeTopologyService` derives a deterministic topology from each
completed inventory refresh and publishes it through `AppModel`. The service is
injectable and synchronous, so previews and tests can replace it without
starting Apple services or the Docker bridge.

Canonical membership requires the Compose project-name grammar plus exact
`com.docker.compose.*` evidence: project and valid service for containers,
project and valid logical-volume name for volumes, and project and valid
logical-network name for non-built-in networks. Project-only containers are
retained as excluded evidence but cannot change counts, observed state, reverse
associations, or lifecycle affordances. Anonymous volumes, invalid optional
labels, built-in networks, and cross-project consumers become visible evidence
notices. Typed associations retain logical Compose keys separately from runtime
resource names. Working-directory and config-file metadata is accepted only
from canonical service containers; conflicting values remain visible rather
than being resolved implicitly. All project views are read-only and link back
to authoritative resource screens. Generic volume prune preserves any resource
with a reserved Compose label.

Reviewed Compose mutation uses a separate typed contract. The planner emits an
ordered list of container, network, and volume actions plus exact preservation
identities; declared services, one-offs, and true orphans never share an
untyped deletion bucket. `AppleComposeProjectMutationExecutor` only coordinates
the journal and shared runtime lock. `ComposeContainerActionService`,
`ComposeResourceActionService`, `ComposeUpCommandService`, and
`ComposePostconditionVerifier` own the independently testable mutation and proof
boundaries.

Fresh and create-missing Up execute the pinned private Compose client from an
immutable, digest-named configuration beneath a stable private per-project
directory. Before runtime mutation, a deterministic overlay converts every
reviewed volume and network to an exact external reference, reruns Compose's
service-hash proof, and requires the hashes to match the reviewed source model.
NativeContainers creates missing managed resources through Apple APIs, starts
the exact reviewed contiguous replica prefix, then uses `--no-recreate` only to
create the missing suffix. Existing and final attachments are checked against
Apple inventory. Unknown canonical keys, non-prefix replica sets, and resource
identity drift fail closed.

Compose 5.1.4 still has a replacement flow that deletes the old container before
a rename that Socktainer 1.0.0 does not implement. Configuration/image drift and
other recreation remain blocked; create-missing never authorizes replacement or
scale-down.

Crash recovery journals contain only opaque ordered step tokens. Schema v3
requires every completed token to be the next reviewed step and requires all
steps before postcondition verification. Schema v2 files remain readable as
redacted, manual-only evidence but cannot authorize execution. Exact network
deletion is ID based. Named-volume deletion revalidates a frozen configuration
identity and empty consumers immediately before Apple's name-only delete and
confirms that both the old ID and runtime name are absent afterward; this is an
app-level safety boundary, not a runtime CAS primitive.

`LiveComposeProjectLifecycleSmokeTests` is an independent, doubly gated wire
proof. It assembles the production renderer, planner, lifecycle coordinator,
journal, execution services, Apple inventory, pinned Compose client, and an
isolated Socktainer context for Up, Stop, Start, and Down. Cleanup runs in a
detached task, revalidates fixture labels and identities before native deletion,
and removes recovery evidence only after Apple inventory proves absence.

### General VM lane

VMs live as self-contained bundles in Application Support. Each bundle owns:

- a versioned JSON manifest;
- disk images;
- macOS auxiliary storage when applicable;
- serialized hardware model and machine identifier data;
- EFI variable storage, generic machine identity, and copied installer media
  for EFI Linux guests;
- an optional mode-0600 host-local shared-folder capability sidecar;
- saved machine state and thumbnails when supported.

Bundle-owned artifact paths are relative, allowing a bundle to be moved or
backed up as one unit. The one host-local exception is an optional absolute
restore-image URL while installation remains retryable. Runtime-only objects
such as `VZVirtualMachine` never go into the manifest.

GUI Linux preparation follows the same storage boundary without borrowing the
macOS installer model. `LinuxPlatformArtifactPreparer` composes a
security-scoped, no-follow, change-detecting ISO copier with Apple generic
machine-identity and EFI-variable-store creation. `VirtualMachineLibrary`
creates those artifacts in a hidden per-operation directory, validates every
required regular file, promotes the directory as one unit, and only then
commits `LinuxVirtualMachineConfiguration` to the manifest. Any copy,
identity, validation, promotion, or manifest failure removes both staging and
promoted artifacts while leaving the draft manifest intact.

`VirtualMachineBundleArtifactResolver` is the shared path-containment and
regular-file boundary used by both macOS and Linux bundle resolvers.
`AppleLinuxVirtualMachineConfigurationFactory` consumes only a resolved Linux
bundle and validates an EFI configuration with a writable Virtio disk,
read-only USB installer media on an XHCI controller, persistent NAT MAC address,
Virtio graphics, host audio output, USB input, entropy, memory ballooning, and
optional SPICE clipboard.

`LinuxVirtualMachineCreationService` composes draft creation and platform
preparation as one application transaction. A preparation failure rolls back
the draft; a rollback failure preserves both errors. `AppModel` publishes the
returned manifest directly and retains one stable runtime model per VM, so a
view transition never owns a machine session.

`LinuxVirtualMachineRuntimeService` owns one generation-pinned runtime lease and
engine session per Linux VM. Start, pause, resume, graceful stop, destructive
stop, installer ejection, console lookup, and terminal delegate events all
target that generation. A graceful stop arms a 30-second watchdog; if the guest
does not exit, the service waits only a bounded interval for the framework's
destructive-stop capability and then force-stops that same session. Force Stop
is also an explicit UI action and can queue safely while start, pause, resume,
or ejection is completing. Delegate stop/error events are authoritative, and
exactly-once finalization prevents a stale callback from releasing a replacement
session.

Linux shared folders reuse the guest-neutral directory domain, bookmark,
sidecar-store, observable-model, and VirtioFS-device primitives. A
`LinuxVirtualMachineSharedDirectoryService` adds only Linux lifecycle policy:
it acquires the generation-pinned Linux runtime lease and permits persistence
only while the bundle is ready to install or stopped. Runtime configuration
resolves every security-scoped bookmark, attaches one
`VZMultipleDirectoryShare` under the stable `nativecontainers` tag, and retains
the access lease until that exact engine session closes. SwiftUI renders the
service snapshot and the exact guest mount command; it never owns bookmarks or
scripts the guest.

Installer media is a USB mass-storage device so the running engine can detach
it through the XHCI controller after installation. Only a successful detach is
persisted as installation completion, and a persistence retry never detaches the
same device twice. The shared `VirtualMachineConsole` abstraction presents the
generation's `VZVirtualMachineViewAdaptor`; guest-specific SwiftUI row,
configuration, and runtime views remain separate behind small guest dispatchers.

Downloaded macOS IPSWs are intentionally outside the bundle boundary so
multiple VMs can reuse one multi-gigabyte installer. New downloads and local
imports live in the mode-0700, backup-excluded
`~/Library/Application Support/NativeContainers/Restore Images` store. The
manifest records its selected local URL, while the hardware model, machine
identifier, and auxiliary storage derived from that image remain bundle-owned
and are promoted transactionally.

Locally selected IPSWs are copied while the file picker's security scope is
active. The importer streams cancellable chunks to a mode-0600 partial file and
promotes only a complete copy, so later installation never depends on an
expired external-file grant. A versioned ownership marker and store-wide
advisory lock let launch recovery remove an orphaned private import while
preserving any image a persisted manifest references.

`RestoreImageStoreRecoveryService` owns launch maintenance independently from
acquisition. It first recovers the old Caches authority, asks
`RestoreImageStoreMigrationService` to clone every still-referenced legacy IPSW
into Application Support, and then recovers the durable authority. Migration
holds the legacy-store lock and then the durable-store lock across the whole
operation, taking short VM-library operation leases for fresh reference reads
and exact replacement. A phase journal makes copy, promotion, manifest-URL
replacement, and marker cleanup idempotent. Each manifest write is atomic; the
old and new regular files both remain present through any partial rewrite, so a
crash cannot leave a prepared VM naming missing media. The unreferenced legacy
copy remains in Caches for a future composite review service or system purging
rather than being deleted as a side effect of migration.

The VM library owns only durable bundle state. A strict bundle resolver turns a
prepared manifest into verified regular-file URLs. For each attempt the library
creates an operation-scoped sparse disk and auxiliary-storage copy. A dedicated
installation service validates that staged configuration, acquires an
operation-ID lease, and delegates to a main-actor installer session. Success
renames the staged directory and atomically points the manifest at it; failure,
cancellation, or relaunch recovery removes the staged media and returns the
pristine prepared VM to a retryable state. Completion and recovery can mutate
the manifest only while the expected lease remains current. A library-wide
advisory lock extends that ownership boundary across app processes, and VM
discard first atomically renames a bundle to a hidden tombstone so interrupted
recursive cleanup cannot poison inventory reads. Runtime-only
`VZVirtualMachine`, `VZMacOSInstaller`, progress observation, and cancellation
state never enter persistence.

Disk format is an explicit manifest concern. Schema-1 manifests may omit
`diskImageFormat`, which decodes as RAW for backward compatibility; new and
migrated manifests persist the format. `AppleVirtualMachineDiskImageService`
owns format-aware inspection and attachment. RAW capacity comes from its block
mapping, while macOS 27 ASIF capacity comes from `DiskImage.size`; the runtime
never compares an ASIF container's host file length with guest capacity.

`VirtualMachineDiskImageMigrationService` owns RAW-to-ASIF conversion rather
than the VM library actor or SwiftUI. It takes the same stopped-VM runtime lease
used by lifecycle/configuration mutations, requires no saved state, seals the
source identity, and runs the documented `/usr/sbin/diskutil image create from
--format ASIF` command into a sibling hidden partial. The converter inherits the
host-process service's exact-PID TERM-to-KILL cancellation contract. A durable
`planned -> converted -> promoted -> manifestUpdated` journal makes every hard
exit recoverable; `terminationQuarantined` records the exceptional case where
process exit could not be proven. A failed SIGKILL is pinned to the current host
boot and cannot recover until a reboot proves quiescence. Ordinary runtime and
discard leases reject every pending migration journal, while the migration
service alone owns a maintenance lease that can recover it. Clone, export, and
import reject migration journals and nested partials before copying.
DiskImageKit validates format and logical geometry before the library performs
one narrow atomic manifest commit; only then does uncancelled cleanup retire the
RAW source. Launch recovery continues across per-VM failures, rolls back safe
pre-commit artifacts, or completes post-commit cleanup. Neither migration nor
recovery truncates or resizes a guest filesystem.

macOS disk snapshots use a separate service boundary from replacement and
saved-state checkpoints. A revisioned manifest value records a bounded linear
history of named checkpoints and canonical `Snapshots/<UUID>.asif` layers. The
snapshot service acquires the normal stopped-VM runtime lease, rejects any
saved state, recovers only recognized unreferenced private artifacts, creates a
DiskImageKit overlay through a hidden partial, and commits the new manifest only
after promotion. Commit failure removes the unreferenced layer; restore commits
the retained prefix plus a fresh writable layer before best-effort retirement
of newer layers. A later operation safely retries any post-commit residue.

The bundle resolver maps every persisted layer in manifest order. Runtime disk
attachment opens the base and frozen layers read-only and only the top overlay
read-write. The configuration descriptor and saved-state fingerprint include
the snapshot revision, ordered paths, and each layer's stable file identity, so
an older memory checkpoint cannot resume against changed disk history. Clone,
export, and import copy the bundle-local stack, while staged-bundle validation
requires the snapshot directory to contain exactly the referenced regular
files. Disk conversion and standalone-ASIF rewrite remain disabled while a
snapshot stack exists. DiskImageKit exposes stacking but no public merge or
flatten operation, so arbitrary deletion is prohibited; restoring an earlier
checkpoint is the bounded reclamation path.

### Field-diagnostics lane

The normal app registers one `MXMetricManagerSubscriber` at launch behind a
`FieldDiagnosticManaging` application port. `AppExecutionContext` suppresses
that system subscription in hosted tests and Xcode Previews, where the process
is not a real MetricKit delivery host. The framework adapter converts callback
objects immediately into framework-free payload envelopes; the rest of the app
does not import MetricKit.

`FieldDiagnosticStore` owns raw JSON persistence as a separate actor. Its root
is mode 0700, records are mode 0600 and backup-excluded, and symbolic roots,
symbolic records, hard links, corrupt envelopes, digest drift, unbounded
category counts, oversized payloads, and excessive directory scans fail
closed. Deduplication uses a digest over payload kind, reporting interval,
bounded category counts, and exact JSON. Retention is capped at 30 payloads and
20 MiB, and the store exposes only metadata until the user explicitly exports
one report through the system file exporter. No automatic upload path exists.

The Settings model observes store updates, summarizes the macOS-supported
crash, hang, CPU-exception, and disk-write categories plus daily metrics, and
supports explicit refresh, export, and destructive local deletion. Release
symbol ownership remains outside the runtime app: the archive validator
requires app and build-worker dSYMs whose UUIDs match the corresponding signed
executables.

### UI lane

The SwiftUI shell uses a `NavigationSplitView` with separate screens for:

- Overview
- Containers
- Images
- Volumes
- Linux Machines
- macOS VMs
- Settings and diagnostics

An `@MainActor @Observable` app model owns prepared, stable-identity view data.
Feature views take narrow values. AppKit bridges are intentionally narrow:
`NSViewRepresentable` wraps SwiftTerm’s `TerminalView` for container shells and
`VZVirtualMachineView` for VM display. SwiftUI remains the source of truth for
selection and lifecycle commands.

The main scene installs one focused `NativeContainersCommands` value rather
than embedding menu construction in the app declaration. Apple's
`SidebarCommands` and `ToolbarCommands` own standard View-menu behavior.
An app-specific Navigate menu maps Command-1 through Command-9 onto the same
`WorkspaceRoute` and `AppModel.canNavigate` boundary used by the sidebar and
Quick Open, so a reviewed build disables every conflicting menu command instead
of creating a keyboard escape around the navigation lock. Settings remains the
system-provided Command-comma scene command.

SwiftUI string extraction is enabled for the app target and persisted in the
XcodeGen source configuration. The English `Localizable.xcstrings` catalog is
the source inventory; literal SwiftUI labels remain deferred localization
resources, while runtime resource identities remain verbatim user/runtime data.
Toolbar actions publish alternate accessibility input labels for Voice Control
and Full Keyboard Access, and Quick Open resource buttons publish the visible
resource name as an input label.

The menu-bar control is a `MenuBarExtra` scene over that same app model, not a
second control plane. It reads the already sorted Apple inventory, keeps only
per-row transient button state, and routes Start, graceful Stop, Restart, and
explicit Force Stop through the existing exact-identity lifecycle methods.
Force Stop remains reachable while graceful Stop is in flight or inventory is
already `stopping`; duplicate destructive requests are suppressed per row.
Opening a resource reuses the main window's `WorkspaceRoute`; failures remain
on the shared error channel. A persistent `AppStorage` preference controls only
menu-bar insertion. `AppExecutionContext` is the single runtime gate for that
insertion binding: hosted tests and Previews never insert the persistent scene,
macOS 26 remains enabled, and macOS 27 or later receives a constant-false
binding while the App Behavior toggle is hidden. This keeps the scene's control
plane intact without triggering the verified macOS 27 SwiftUI app-graph
invalidation loop; support on later releases requires an explicit revalidation
and policy-version bump. Launch-at-login policy is separate: an injectable
focused service maps `SMAppService.mainApp` into typed disabled, enabled,
approval-required, and unavailable states. The app never installs a custom
launch agent or treats registration as proof of user approval.

Native user notifications follow the same dependency boundary. A focused
`AppNotificationManaging` service maps `UNUserNotificationCenter` into typed
authorization and delivery-channel snapshots, installs its delegate before any
notification work, and owns property-list-safe response payloads. Settings
requests alert and sound permission only from an explicit user action; launch
never triggers the system prompt. Image builds, restore-image preparation, and
macOS installation publish generic terminal success or failure events without
embedding raw errors, paths, logs, or secrets. Cancellation stays silent, and
delivery failure cannot change the underlying operation result. Foreground
presentation is suppressed, while a response loads authoritative inventory and
reuses `WorkspaceRoute`, falling back to the safe top-level route when an exact
VM no longer exists.

Performance baselines are another focused service graph rather than timing code
inside Settings. `PerformanceBenchmarking` is the app-facing contract;
`PerformanceBenchmarkService` owns warmup/measured iteration policy, a
monotonic injectable clock, per-scenario failure isolation, cancellation, and
median/P95/aggregate-throughput reports. Per-iteration preparation and cleanup
run outside the timed interval; cleanup still runs in a cancellation-independent
task, and any cleanup failure invalidates the sample and aborts later lanes.
Three narrow Settings scenarios call the existing read-only Apple inventory service,
write/synchronize/read/remove a private temporary file, and perform a bounded
localhost TCP transfer through Network.framework. The app-scoped observable
model owns only progress, the last completed report, and cancellation. Nothing
starts automatically during launch or inventory refresh.

Cold Apple-container startup is a separate opt-in live scenario, never part of
the Settings suite. It requires an already-local image, creates a stopped
one-CPU/256-MiB container before each timing interval, and measures only the
existing lifecycle service's start through an authoritative running snapshot.
The created configuration must retain the preflighted reference and digest.
One warmup and three fresh-container samples are emitted as provenance-bearing
JSON. Graceful stop, bounded KILL fallback, exact deletion, and an empty
run-prefix inventory check happen outside the measured interval. Every mutation
revalidates the creation-operation UUID; a same-name replacement aborts cleanup
and is never modified. Guest and
bind-mount I/O, real builds, external traffic, VM startup, and idle-resource
sampling remain separate opt-in lanes because they mutate runtime state or
depend materially on the host environment.

Workspace navigation is a separate focused slice. `WorkspaceRoute` represents
both top-level destinations and exact resource identities. A pure
`WorkspaceResourceCatalog` derives searchable entries from the current Apple
inventory and VM library without persisting a second index. The main-actor
`WorkspaceNavigationModel` owns the active route, prepared search results, and
Quick Open presentation. Inventory replacement reconciles a missing exact
resource back to its safe top-level destination only after that resource's
service completed an authoritative refresh. A transient runtime failure may
clear visible entries, but it preserves the pending exact route so recovery can
restore the same selection. Localized resource-kind titles join stable runtime
identities and familiar CLI aliases in the search index. Overview links, list
selection, sidebar state, and Command-K therefore use one route, while a
reviewed or active build still locks every path away from Builds. The app uses
one unique main `Window`, matching this app-scoped navigation ownership rather
than sharing presentation state across an implied multi-window group.

## Persistence and safety

- Inventory refreshes are read-only and can run concurrently.
- Lifecycle mutations are serialized per resource identifier.
- Writes use temporary files plus atomic replacement.
- VM creation is staged so cancellation cannot leave a valid-looking partial
  bundle.
- VM installation validates staged media before taking its lease, rejects stale
  lease completion, and treats a persisted lease with no live session as
  interrupted. Installer cancellation uses `Progress.cancel()` only after
  installation has started and waits for termination; pause and force-stop are
  forbidden during installation because Virtualization.framework defines them
  as unsafe.
- Installed macOS VMs use an app-scoped runtime coordinator and a short-held
  library mutation lock to acquire a per-bundle runtime lease. Runtime state is
  ephemeral except for the narrow first-boot transaction described below. Every
  session has a fresh generation; lifecycle commands, destructive stop
  authorization, and console attachment must match it. Delegate stop/error
  events are the authoritative terminal signal and release the disk lease
  exactly once.
- macOS guest provisioning is split across four focused boundaries. Restore
  preparation returns a typed guest OS identity for the manifest; a pure policy
  gates the feature to macOS 27-or-later hosts and guests with an unclaimed first
  boot and no saved state; a first-boot service owns only the
  pending-to-launching-to-started persistence transition; and the Apple runtime
  adapter is the only layer that creates VZMacGuestProvisioningOptions. The form
  model retains the password only for the visible sheet and clears it on
  cancellation, dismissal, or accepted start. A start error rolls launching back
  to pending; a process crash leaves launching in place so the app fails closed
  instead of risking a second credential submission after an ambiguous boot.
- A graceful stop request leaves the VM in a stopping state with an explicit
  Force Stop action. Force Stop wraps Apple's destructive stop API and does not
  claim the VM stopped when the framework reports an error. A service-owned,
  generation-pinned watchdog invokes that same path after a 30-second graceful
  shutdown timeout. Its wait for Apple’s `canStop` capability is bounded and a
  terminal delegate event cancels it immediately; view lifetime and caller
  cancellation never arm or cancel it.
- macOS VM suspension is split across three focused layers: the runtime service
  owns the generation-safe lifecycle state machine, the saved-state service
  sequences Virtualization.framework callbacks, and the saved-state store owns
  filesystem transactions. Save transactions hold a borrow on the runtime lease,
  write into a hidden partial directory, fully synchronize the state and metadata,
  then atomically publish `SavedState`. Restore atomically renames that directory
  to a single-use tombstone before invoking Virtualization.framework; every
  attempted restore consumes it, and crash recovery deletes restore tombstones
  instead of replaying them.
- Saved-state metadata binds the checkpoint to a shared configuration descriptor,
  opaque platform artifact digests, and writable disk/auxiliary-storage identity.
  The descriptor also supplies the deterministic locally administered MAC used by
  the live VZ configuration, avoiding Apple's random default. Starting fresh and
  resuming a live paused session explicitly discard an older checkpoint before
  writable storage can advance.
- macOS guest audio is produced by a focused Apple device factory, not by the
  SwiftUI configuration view. Host output is always present through
  `VZHostAudioOutputStreamSink`. A manifest-backed audio configuration service
  owns the opt-in microphone flag, acquires the existing runtime lease, rejects
  saved-state conflicts, and requests recording permission before persistence.
  Only then does the factory add `VZHostAudioInputStreamSource`. Revision zero
  preserves the original output-only topology-v3 fingerprint; later revisions
  remain in the fingerprint so disconnecting cannot resurrect an older
  checkpoint. Clone and portable-manifest constructors erase the host-local
  opt-in, so copied or imported VMs require a fresh Connect action. The app model
  and view receive only snapshots and actions.
- macOS VM networking follows the same boundary. A manifest-backed domain value
  selects automatic NAT, shared, or host-only attachment; a lease-aware service
  owns stopped-only persistence and rejects saved-state conflicts; an app-owned
  pool creates and retains one `vmnet_network_ref` per custom mode; and a focused
  factory is the only layer that constructs `VZNATNetworkDeviceAttachment` or
  `VZVmnetNetworkDeviceAttachment`. The composition root shares the pool between
  installation and runtime factories so every VM in the process joins the same
  logical network for its selected mode. SwiftUI receives only the current mode
  and invokes service actions.
- Shared and host-only vmnet networks are process-owned and recreated after app
  relaunch. Their runtime configurations therefore report save/restore as
  unsupported rather than persisting guest memory against a vanished logical
  network. Every mode change advances a revision included in the saved-state
  descriptor, so toggling back cannot validate an older checkpoint. Same-host
  clones retain the selected mode; portable package preparation clears it to
  automatic NAT. Physical bridging is deliberately excluded because its
  restricted entitlement is not available through the target capability
  surface.
- Physical USB is a separate host-local service lane. AccessoryAccess owns
  discovery and system authorization; a focused Apple adapter parses only the
  stable registry ID and standard device descriptor needed by the domain. The
  orchestration service owns the accessory references, global single-VM
  attachment state, and per-machine snapshots. It asks the runtime coordinator
  for a USB controller only by exact
  `MacVirtualMachineRuntimeTarget`, so a replacement generation can never
  inherit or detach the prior generation's devices. A late successful attach is
  immediately unwound if the target changed.
- Every macOS VM configuration contains one XHCI controller, while the
  macOS-27-only passthrough adapter is created only for a compatible runtime
  session. Physical disconnect callbacks clear the matching generation's
  attachment; stopping closes the controller and releases all host-local
  references. Dynamic devices are never written to the VM manifest, clone, or
  portable package. Suspend is rejected before pausing while a device is
  attached, and the saved-state runtime-configuration version advances for the
  new XHCI topology. SwiftUI receives a prepared snapshot and invokes typed
  discover, attach, and detach actions.
- Live composition first reads the signed process's
  `com.apple.developer.accessory-access.usb` entitlement. If either macOS 27 or
  the capability is absent, it injects an unavailable implementation with a
  user-facing reason. This keeps the beta capability boundary in composition
  and leaves the domain, model, and UI deterministic.
- Force Stop remains available during start, save, and restore. A generation-pinned
  monitor issues destructive stop as soon as Virtualization.framework reports that
  stop is available, even if the original callback is still pending. The UI reports
  that the VM is stopped but cleanup is pending, and the runtime lease is never
  released until the save/restore callback and persistence cleanup quiesce.
- Shared-directory configuration is a separate private sidecar inside the VM
  bundle. One guest-neutral observable model calls a narrow management contract;
  macOS and Linux services add their own lifecycle policy. The library owns
  monotonic atomic persistence, the bookmark service owns security-scoped
  access, and guest-specific Apple factories create either the single macOS
  automount device or the single Linux `nativecontainers` device. Runtime
  acquisition locks the bundle before reading the sidecar, and each engine
  session closes its access lease explicitly. Portable package preparation
  removes the host capability sidecar; same-host clones preserve it.
- VM cloning is a separate application service rather than another filesystem
  method on the UI model. The library-backed transaction store owns begin,
  commit, and abort, holding the library mutation lease and source runtime lease
  across the copy. A pluggable bundle copier rejects symbolic links, asks
  Darwin `copyfile` for recursive clone-on-write with sparse-copy fallback,
  cross-mount refusal, no-follow semantics, and a cancellation callback on each
  fallback write. It then strips runtime locks, owner records, installation
  partials, every saved-state transaction, and the source microphone opt-in,
  then atomically replaces the staged
  `VZMacMachineIdentifier` through a focused generator. Commit independently
  validates required artifacts, shared-directory state, transient absence, and
  a valid identifier distinct from the source before one final rename publishes
  the clone. Cancellation returns `COPYFILE_QUIT`, keeps the review sheet in a
  cancelling state until transaction cleanup completes, and always aborts the
  partial. Startup recovery removes hidden clone partials left by a hard exit.
- Clone, export, and import share one policy-driven bundle-preparation service
  instead of maintaining three filesystem implementations. A focused inspector
  rejects symbolic links, hard links, mount-crossing copies, and special files;
  the sanitizer removes runtime/install/save transactions; the identity policy
  either preserves a round-trip-valid `VZMacMachineIdentifier` or replaces it
  through the generator; and a portability policy removes the cached restore
  URL, host-local shared-folder bookmark capabilities, microphone opt-in, and
  process-local vmnet mode.
- Portable export briefly takes the library mutation lock only to resolve and
  pin a stopped source, then retains the per-VM runtime lease while a
  security-scoped destination-parent lease spans the cancellable copy. It stages
  a hidden sibling package, rechecks that the source metadata did not change,
  refuses replacement, and publishes with one same-directory rename. The
  SwiftUI sheet cannot be dismissed while cancellation is waiting for copyfile
  and partial cleanup.
- Portable import holds a library-owned begin/commit/abort transaction while it
  copies into a hidden `.Import-*.partial` package. Restore mode preserves both
  the manifest UUID and Apple platform identity and rejects either collision;
  copy mode generates both identities anew. Commit revalidates every
  manifest-relative artifact, portable-state absence, and platform-identity
  uniqueness immediately before the UUID-named bundle is atomically published.
  Launch recovery removes import partials left by a hard exit.
- Storage accounting is an independent read-only service graph. The Apple lane
  sends the pinned `systemDiskUsage` XPC request through the app's bounded,
  cancellation-closing request client and validates every count and byte
  relationship before mapping it into app-domain values. The VM lane asks the
  library actor for one canonical root/manifest snapshot, then performs one
  utility-priority descriptor-relative traversal with `openat`, `fstatat`, and
  `AT_SYMLINK_NOFOLLOW`. It includes hidden install/import/clone/deletion
  partials, refuses mount crossings, deduplicates hard links by device/inode,
  and buckets canonical `.nativevm` packages without rescanning each bundle.
  Caller cancellation explicitly cancels the detached scan, which checks at
  every directory entry; leaving Overview invokes the same cancellation path.
  The `StorageUsageService` facade and stable `StorageOverviewModel` keep the
  two lanes independently replaceable, concurrent, and error-isolated. A
  failed lane retains its prior snapshot, and neither lane participates in
  ordinary inventory refresh. Apple category sums are labeled as sums, while
  VM allocation is labeled filesystem-reported because APFS clone sharing does
  not expose unique per-bundle physical ownership.
- Apple-runtime reclamation is a sibling mutation graph, not a method on the
  accounting model. One aggregate service prepares and executes exact plans
  through focused container, image, and volume ports. Planning records the
  accounting capture/revision and inventory revision as provenance, while live
  adapters independently discover candidates. Execution is serialized in the
  fixed order containers, images, then volumes; it never adds resources made
  eligible by an earlier removal. Containers are opt-in and limited to stopped,
  UUID-owned NativeContainers configurations whose canonical full-configuration
  seal still matches. Compose, builder, machine, Apple-role/plugin, active,
  unknown, and unowned containers are excluded, and reclamation never invokes
  Stop, KILL, force-delete, or VM mutation. Image and container requests use
  fresh bounded cancellation-closing XPC connections; volume operations retain
  the same bounded infrastructure client. Each accepted mutation is reconciled
  independently of caller cancellation, and partial results preserve exact
  removals before the next candidate is abandoned. After execution, ordinary
  inventory and only the Apple accounting lane refresh; the unrelated VM
  filesystem scan remains on demand.
- VM reclamation is a separate sibling graph with a thin
  `VirtualMachineStorageReclamationManaging` coordinator over three category
  services. The saved-state service acquires the existing per-VM runtime lease
  and delegates exact checkpoint retirement to the saved-state store. The
  residue service owns only a strict top-level allowlist, takes the library
  operation lock plus the bundle runtime lock, and uses a reusable
  descriptor-relative inspector to seal device, inode, ownership, link count,
  timestamps, allocation, and the complete metadata tree. Symbolic links, hard
  links, special files, ownership changes, mount crossings, replacements, and
  unrecognized hidden entries fail closed. Execution revalidates immediately
  before an atomic same-parent rename, then finishes deletion without another
  cancellation checkpoint; any surviving tombstone remains in an existing
  recovery-recognized namespace. The restore-image service is off by default
  and shares the durable-store authority with download and import; launch
  recovery composes that authority with the legacy Caches authority and the
  migration service. A store authority takes its operation lock before loading
  VM references;
  only unreferenced regular IPSWs and seven-day-old partials are reviewable.
  Execution reloads references and exact file identity before a same-parent
  tombstone rename. The app model binds plans to the VM accounting and library
  revisions and refreshes only VM inventory plus the VM accounting lane after
  accepted work. Disk images are never candidates, and no reclamation service
  invokes Start, Stop, Force Stop, or KILL.
- Restore-image acquisition is exposed to application state as one
  `RestoreImageAcquiring` facade. A shared cache actor issues typed leases to
  independent HTTP-download and local-import services, persists a versioned
  ownership marker, and holds its cross-process lock through platform
  preparation and manifest commit. Remote cancellation keeps resumable bytes;
  failed local import removes its private copy; completed downloads are
  immutable URL-hash identities and are never replaced in place. Recovery,
  preparation, and reclamation use cache-before-library lock order. A
  successful installer commit clears the manifest reference, while a failed or
  cancelled install retains it for retry.
- Build contexts are staged without following links and re-fingerprinted before
  and after the BuildKit solve; exported archives are copied into a private,
  digest-bound host artifact; final tags are revalidated immediately before
  mutation.
- Build history uses an ACL-free mode-0700 current-user directory and ACL-free
  mode-0600 atomic records through a verified directory descriptor. Corrupt or
  special records are isolated without blocking, newer schemas are retained,
  live-launch leases prevent false interruption, bounded scans fail closed, and
  retention happens after the replacement is durable while bounding terminal
  records.
- Image-build and builder-management workspace models have app-level identity.
  Reviewed plans and active operations lock navigation away from Builds, while
  the owning view exposes cancellation for every locked asynchronous action.
- Named attachments are revalidated after review. Published sockets can only
  occupy a private operation directory, are checked before each start, and are
  removed on stop/delete or owned creation rollback.
- Credentials stay in Keychain through Apple’s registry client facilities.
- No container or VM is deleted without a confirmation that names the affected
  disks and snapshots.

## Distribution boundary

The distributable product is one arm64 macOS application with one signed
`NativeContainersBuildWorker` nested under `Contents/Helpers`. The worker is a
build dependency with `SKIP_INSTALL=YES`; it is never emitted as a second
installable archive product. Both executables enable hardened runtime and share
one signing team.

Capabilities stay at the narrowest executable boundary. The app carries only
microphone input and virtualization. The worker carries no app capability.
`scripts/validate-distribution-artifact.sh` verifies architecture, version,
layout, nested signatures, hardened runtime, team identity, and capability
allowlists before an archive can advance. Its strict mode also enforces
Developer ID Application authority, absence of `get-task-allow`, Gatekeeper
acceptance, and a stapled notarization ticket.

Signing credentials and notarization state are external release inputs, not
repository configuration. A local Apple Development archive proves product
layout and signing mechanics but does not claim public distribution readiness.
The complete operator flow is recorded in `docs/DISTRIBUTION.md`.

## Compatibility policy

- App deployment target: macOS 26.
- Host architecture: Apple silicon.
- `apple/container`: pin exact release 1.0.0 initially.
- Client and server builds must match until Apple adds API negotiation.
- Direct `containerization`: inherited from the pinned `container` release;
  avoid adding a second version to the dependency graph.
- Virtualization API use is verified against the installed SDK with Xcode
  documentation search, the compiler, and runtime checks.
