# Feature matrix

This is the product contract for “OrbStack-class,” with exact public-API gaps
called out rather than papered over.

| Capability | Native implementation | Phase | Constraint |
| --- | --- | --- | --- |
| OCI pull/push/list/tag/prune | Apple image services | M1 | Reviewed exact-platform pull/push, rich inspect, safe tag/delete, and prune are live; public push smoke is intentionally prohibited |
| Dockerfile/Containerfile builds | Apple `ContainerBuild` + shared BuildKit VM | M2 | Reviewed exact-platform builds are live through a signed worker; image-store, OCI-image archive, root-filesystem tar, and root-filesystem folder outputs are typed, while 1.0.0 still requires Dockerfiles below 16 KiB and lacks structured progress/cache-only prune |
| Build output publication | Reviewed host destination service + private artifact stores | M2 | User destinations never enter the worker protocol; file replacement is explicit and exact, folder outputs must be new, publication is cancellation-aware and atomic, and root-filesystem outputs are single-platform pending broader upstream proof |
| Build secrets | Reviewed file-descriptor vault + Apple BuildKit secret payload | M2 | Private files outside the context stream once over worker stdin; plans and Codable control frames contain no bytes, and secret-build diagnostics are suppressed |
| Build history | App-owned recording decorator + private file store | M2 | Typed running/terminal outcomes and output kinds, live-launch-aware crash reconciliation, token-gated cross-process refresh, coalesced slow-I/O updates, corruption/schema isolation, fail-closed bounded scans, and 200-record terminal retention are live; destinations, paths, logs, error text, secret metadata, and option values are not persisted |
| Shared builder/cache maintenance | Container service XPC + exact snapshot adapter | M2 | Stable status, whole-bundle allocation, reviewed Stop/Force Stop, and stopped-only reset are live; external CLI activity is not observable |
| Container lifecycle | `ContainerClient` | M1 | Foundation start/stop/delete is wired |
| Unified resource navigation | Typed workspace routes + inventory-derived search catalog | M1 | Command-K Quick Open and Overview links target exact resources in one main window; authoritative deletion falls back safely, transient failures preserve the pending route, localized kind names are searchable, and active build plans retain their navigation lock |
| Exec, logs, copy, inspect, stats | `ContainerClient` + SwiftTerm | M1 | Non-interactive exec and native interactive PTY are live |
| Volumes and named networks | Apple services | M1 | Reviewed create/delete/prune, capacity versus allocated usage, built-in protection, and configured-container use checks are live; Apple 1.0 has no conditional delete token |
| Container storage/network/socket attachments | Focused attachment service + Apple configuration types | M1 | Exact reviewed named-volume identities, ordered networks, and private operation-scoped Unix sockets are live and revalidated before mutation/start |
| Container-to-host alias | Read-only resolver/PF discovery | Partial | Exact configured-on-disk state can be selected and a fixed privileged command is shown; the GUI does not mutate or claim active PF state, and a signed helper remains future work |
| Direct container IP and published ports | Apple vmnet/socket forwarders | M1 | Dedicated IPs and TCP/UDP ranges are inventoried; TCP host publications offer explicit revalidated HTTP/HTTPS opening; no exact shared host loopback |
| Docker CLI and Engine API | Pinned Socktainer install/process/context services | M2 | Settings-managed verified install, Apple API health, HTTP readiness, exact-PID TERM-to-KILL and Force Stop, crash-residue recovery, and non-activating `nativecontainers` context are live; Engine coverage remains partial API v1.51 |
| Docker Compose | Optional Docker CLI bridge + conformance/topology/live-fixture services | M2 | A real Compose client now creates a canonical service/volume/network through Socktainer and Apple inventory, with bounded commands and Apple-native force cleanup proven; aliases remain partial, health/restart/config/secret parity is unsupported, and user-project lifecycle stays blocked pending a product-owned client and reviewed desired-state parser |
| Registry credentials | Apple Keychain client | M1 | Login/list/logout live; stored secrets never leave Keychain |
| Rosetta `linux/amd64` applications | Apple Containerization | M1 | ARM Linux guest; not an x86 VM |
| Persistent Linux dev machines | Bounded machine/process XPC transports + focused lifecycle, process-target, command, terminal, and inventory services | M3 | Native create, first-boot provisioning, start, graceful stop, identity-pinned KILL, stopped-only delete, CPU/memory, reviewed home mounts, mapped-user shell commands, and interactive PTY are live; Apple 1.0 deletion is ID-only, configuration editing remains future work, and boot forwards host `SSH_AUTH_SOCK` when present even with no home mount |
| Shared-kernel/project density | Experimental `LinuxPod` | M5 | Opt-in only after upstream stabilization |
| Kubernetes | k3s in a dedicated Linux machine | M5 | Separate lifecycle and storage plan |
| macOS restore/install | Focused restore cache, bundle resolver, staged media, durable/cross-process operation leases, configuration factory, and `VZMacOSInstaller` session | M4 | Download/preparation are live; install UI, progress, supported cancellation, retry-safe staged cleanup, interruption recovery, and deterministic tests are complete, while a real install still awaits the Virtualization entitlement and local-IPSW smoke gate |
| macOS display/input | Generation-keyed `VZVirtualMachineView` / `VZVirtualMachineViewAdaptor` bridge | M4 | Native console, automatic display reconfiguration, explicit system-key capture, and stale-view detachment are implemented; live use awaits the entitlement gate |
| VM pause/resume/stop/recovery | App-scoped runtime coordinator + per-VM advisory lease + `VZVirtualMachine` delegate | M4 | Start/pause/resume/graceful stop/destructive stop are state-validated; terminal events release ownership exactly once, caller cancellation never abandons an accepted start, and a generation-pinned 30-second watchdog force-stops a hung graceful shutdown |
| VM shared folders | Modular bookmark, sidecar, lease-orchestration, and VirtioFS services | M4 | Persistent read-only/read-write shares, private capability storage, stopped-only inspector editing, saved-state fingerprinting, and one macOS automount device are implemented; live guest mount verification awaits the entitlement and an installed guest |
| VM audio | Virtio sound | M4 | Microphone privacy configuration needed |
| Same-host suspend/resume | Modular runtime/saved-state services + VZ save/restore | M4 | Transactional, configuration-bound, lease-pinned, single-use restore and explicit Start Fresh/Discard are implemented with deterministic tests; saved state is not portable and live verification awaits the Virtualization entitlement |
| Efficient disk snapshots/clones | DiskImageKit overlays | M5 | macOS 27; shallow layer stacks |
| Physical USB passthrough | AccessoryAccess + VZ USB | M5 | macOS 27 and user-granted entitlement |
| Linux GPU/Metal passthrough | None | Unavailable | No public Apple API |
| Intel macOS guests on Apple silicon | None | Unavailable | Unsupported architecture |
| Full guest-memory reclamation | Virtio balloon | Partial | Cooperative, not guaranteed |

## Performance gates

Every implementation milestone should record:

- cold and warm container startup;
- 1, 10, and 50 idle-container resident memory;
- memory retained after guest stress and idle-stop;
- bind-mount metadata and sequential I/O;
- PostgreSQL durability/fsync behavior;
- image pull/build time and allocated disk growth;
- NAT/direct-IP latency and throughput;
- sleep/wake and crash-recovery behavior.

Optimizations belong behind measured regressions. The Apple runtime’s existing
optimized kernel, sparse ext4 images, APFS clone-on-write roots, dedicated IPs,
and launchd-managed helpers are the starting point, not code to replace.
