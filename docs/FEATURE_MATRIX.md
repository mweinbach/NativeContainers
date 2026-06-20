# Feature matrix

This is the product contract for “OrbStack-class,” with exact public-API gaps
called out rather than papered over.

| Capability | Native implementation | Phase | Constraint |
| --- | --- | --- | --- |
| OCI pull/push/list/tag/prune | Apple image services | M1 | Foundation lists live images |
| Dockerfile/Containerfile builds | Apple BuildKit VM | M1 | 1.0.0 has a known 16 KiB Dockerfile limit |
| Container lifecycle | `ContainerClient` | M1 | Foundation start/stop/delete is wired |
| Exec, logs, copy, inspect, stats | `ContainerClient` + SwiftTerm | M1 | Non-interactive exec and native interactive PTY are live |
| Volumes and named networks | Apple services | M1 | Preserve sparse ext4/APFS clone optimizations |
| Direct container IP and published ports | Apple vmnet/socket forwarders | M1 | No exact shared host loopback |
| Docker CLI and Engine API | Socktainer compatibility service | M2 | Partial API v1.51 today |
| Docker Compose | Docker CLI through compatibility service | M2 | Compatibility matrix required |
| Registry credentials | Apple Keychain client | M1 | Never mirror secrets in app state |
| Rosetta `linux/amd64` applications | Apple Containerization | M1 | ARM Linux guest; not an x86 VM |
| Persistent Linux dev machines | `MachineClient` | M2 | Foundation inventory/lifecycle is wired |
| Shared-kernel/project density | Experimental `LinuxPod` | M5 | Opt-in only after upstream stabilization |
| Kubernetes | k3s in a dedicated Linux machine | M5 | Separate lifecycle and storage plan |
| macOS restore/install | `VZMacOSRestoreImage` / `VZMacOSInstaller` | M4 | Download/preparation live; install awaits entitlement |
| macOS display/input | `VZVirtualMachineView` | M4 | Native AppKit bridge already scaffolded |
| VM pause/resume/stop/recovery | `VZVirtualMachine` | M4 | Validate state before each action |
| VM shared folders | VirtioFS | M4 | Guest support and scoped host access |
| VM audio | Virtio sound | M4 | Microphone privacy configuration needed |
| Same-host suspend/resume | VZ save/restore | M4 | Saved state is not portable |
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
