# Current status

Updated: 2026-06-20.

## Verified

- Xcode project generated and open as scheme `NativeContainers` on `My Mac`.
- Exact `apple/container` 1.0.0 package resolves and compiles.
- Build-for-testing succeeds with no warnings.
- Fifty-six deterministic Swift Testing cases pass. Three opt-in integration
  tests cover live provisioning, interactive PTY, and image-reference behavior.
- The app launches through Xcode and stops cleanly.
- The SwiftUI overview and split container inspector render successfully in
  Xcode Preview in light mode.
- A live Xcode snippet called `AppleContainerService.loadInventory()` against
  the installed XPC services and returned the 1.0.0 server plus live container,
  image, volume, and machine counts.
- VM draft creation uses a staging directory, atomic manifest write, sparse disk
  allocation, and final rename; tests verify reload and cleanup.
- The macOS VM preparation sheet discovers Apple’s latest supported IPSW,
  accepts a local IPSW, reports compatibility requirements, and drives a
  resumable cache download with bounded progress. HTTP 206 ranges are validated,
  HTTP 200 responses safely restart stale partials, cancellation preserves the
  partial file, and completion atomically promotes it.
- Local restore-image validation now uses `VZMacOSRestoreImage.image(from:)`.
  Hardware model data, a fresh machine identifier, and matching auxiliary
  storage are created in a staging directory, validated as a set, atomically
  promoted into the VM bundle, and then committed to the manifest. Tests prove
  both successful reload and rollback on partial failure.
- Container detail inspection uses Apple’s direct API client for configuration,
  disk usage, one-shot CPU/memory/network/block/process statistics, stdout, and
  boot logs. Log reads are bounded to the newest 512 KiB per stream.
- Container start, stop, delete, selection, and refresh actions are wired into
  the native management UI.
- Native sheets now pull OCI images for the current platform and create
  containers with validated names, native/Intel platform selection, CPU/memory,
  OCI arguments and environment,
  working directory, TCP/UDP port publishing, SSH-agent forwarding, init,
  read-only root, persistence, and create-only/create-and-start behavior.
- Provisioning reports image, unpack, kernel, runtime-image, create, and start
  progress. It tags each operation for ambiguous-XPC reconciliation and removes
  an operation-owned container if startup fails.
- A live Xcode test-host smoke created a stopped Alpine container through the
  app’s direct Swift service, verified its state/resources, deleted it, and
  verified cleanup.
- Running-container inspectors now sample statistics every two seconds, retain
  a bounded 60-sample in-memory history, calculate allocation-normalized CPU
  usage, and can pause live work immediately through structured task
  cancellation.
- Log following reuses bounded tails rather than unbounded memory, with source
  selection, case-insensitive line filtering, match counts, and native text-file
  export. Lifecycle controls include five-second graceful stop, restart, and
  explicit force stop.
- The native exec sheet runs non-interactive commands through
  `ContainerClient.createProcess`, concurrently drains stdout/stderr into
  independently bounded 1 MiB tails, enforces cancellation and timeouts by
  killing the child process, and reports exit status and duration.
- Bidirectional file transfer uses Apple’s `copyIn`/`copyOut` clients with native
  file/folder pickers, absolute guest-path validation, parent creation, and
  security-scoped URL handling.
- A live Xcode snippet started a disposable Alpine container, captured exec
  output, copied a file in, read it inside, copied it back out, verified the
  round trip, and cleaned all container and host artifacts.
- Running containers now expose an interactive terminal backed directly by
  `ContainerClient.createProcess` with terminal mode enabled. Raw bytes flow
  through bounded, lossless backpressure into a pinned SwiftTerm 1.13.0 AppKit
  surface; input, resize, Control-C/Control-D, explicit signals, title, working
  directory, scrollback, copy, and paste are wired without a CLI subprocess.
- Terminal shutdown closes stdin, sends hangup, allows a short graceful exit,
  and escalates to kill. Output recovery retains only the newest configured
  bytes, while the live stream preserves every byte. The pipe reader uses
  `poll` plus one POSIX `read` so short interactive bursts are delivered before
  EOF rather than waiting to fill a large Foundation read request.
- Input writes are ordered on a dedicated queue, nonblocking, cancellation-aware,
  and protected from `SIGPIPE` without changing process-wide signal handling.
  Descriptor reads and closure share one lifetime lock, resize bursts are
  coalesced, a replacement shell performs a full emulator reset, and an
  unconfirmed kill remains visible and retryable instead of dismissing the
  terminal as though shutdown succeeded.
- A live Xcode test-host smoke created and started a disposable Alpine
  container, opened a native PTY, verified the requested `33×91` geometry,
  round-tripped canonical stdin, delivered Control-C, observed a clean child
  exit, and removed the container.
- The image screen now uses a stable-reference split inspector. OCI indexes are
  resolved lazily into platform variants with real manifest/layer sizes,
  execution configuration, environment, labels, aliases, usage, and partial
  inspection warnings; the former descriptor-size label is no longer presented
  as total compressed image size.
- Tagging normalizes through Apple’s configured registry and requires explicit
  confirmation before moving an existing tag to another digest. Deletion plans
  show aliases and consuming containers, block in-use or Apple infrastructure
  images, and revalidate the exact digest immediately before mutation.
- Dangling and all-unused prune modes show the exact reviewed candidate set,
  exclude active and Apple-managed images, revalidate every reference/digest,
  perform one store-wide orphan cleanup, and report actual reclaimed bytes plus
  partial failures. Cancellation refreshes inventory and triggers best-effort
  cleanup after any partial batch.
- A live Apple-service smoke pulled Alpine, created a unique local tag, resolved
  its real OCI variant/configuration, deleted only that alias, verified removal,
  and left no containers or temporary image references behind.

## Known configuration issue

Apple documentation and SDK headers require
`com.apple.security.virtualization`. Xcode MCP’s entitlement action returned
“This entitlement does not exist” for that documented key and explicitly
forbids a manual workaround. The app therefore builds and the container lane is
live, but constructing a VM is intentionally not claimed as runtime-verified
until the entitlement can be added through a functioning Xcode capability
surface. Official Apple sources confirm this is a normal Boolean entitlement;
no developer-team or provisioning-profile change should be needed.

## Next implementation slice

1. Add native registry login/logout/list and image push workflows.
2. Add an isolated native `ContainerBuild` worker and builder lifecycle.
3. Add volume/network lifecycle and open-in-browser helpers.
4. Add the entitlement through a functioning Xcode capability surface, then
   implement and live-verify macOS installation and VM lifecycle.
5. Spike a pinned Socktainer process and a product-specific Docker context.
