# Roadmap

The goal is broad workflow parity, not a pixel-for-pixel clone. Each milestone
must leave a usable, test-backed product slice.

## M0 — Verified native foundation

- [x] Native macOS app and unit-test targets build in Xcode.
- [ ] Add the required Virtualization entitlement through Xcode.
- [x] Direct Apple client adapter reports container system health.
- [x] Live inventories for containers, images, volumes, and Linux machines.
- [x] Stable domain models and mockable service protocols.
- [x] Extract inventory, creation, lifecycle, inspection/tooling, terminal,
      attachment, image, volume/network/browser, machine, XPC, and
      owned-resource recovery logic into focused services behind an explicit
      composition root.
- [x] Persistent VM bundle library with schema versioning and atomic writes.
- [x] SwiftUI management shell with useful empty/error/loading states.
- [x] Diagnostics screen records runtime and package versions.

## M1 — Daily container management

- [x] Container start, stop, and delete from the native management UI.
- [x] Validated create-only/create-and-start flow with progress and rollback.
- [x] Five-second graceful stop, force stop, and restart controls.
- [x] Bounded stdout and boot-log inspection.
- [x] Bounded log follow, search, and native file export.
- [x] One-shot CPU, memory, disk, network, block-I/O, and process statistics.
- [x] Two-second live statistics sampling and bounded in-memory history.
- [x] Bounded non-interactive exec console and file copy in/out.
- [x] Interactive PTY terminal with resize, input, and signal forwarding.
- [x] Image pull with byte/item progress.
- [x] Reviewed platform/transport/concurrency selection for standalone pulls.
- [x] Lazy multi-platform image inspect and safe tag/delete flows.
- [x] Reviewed dangling/all-unused prune with mutation-time revalidation.
- [x] Reviewed native image push with digest/platform/transport revalidation.
- [x] Reviewed volume and network create/inspect/delete/prune flows.
- [x] TCP/UDP host-port publishing on Apple’s built-in network and DNS.
- [x] Explicit HTTP/HTTPS open-in-browser for revalidated TCP host publications.
- [x] Reviewed named-volume/network attachment selection and private
      operation-scoped Unix-socket publishing.
- [x] Read-only host-access discovery with an explicit privileged setup-command
      handoff.
- [ ] Signed and notarized privileged helper for optional host-access mutation.
- [x] Registry login/list/logout through Apple’s shared Keychain domain.

## M2 — Developer workflow and Docker compatibility

- [x] Reviewed Dockerfile/Containerfile build workflow through Apple’s public
      builder API and an isolated signed worker.
- [ ] Build secrets, SSH forwarding, cache import/export, alternate outputs,
      history, and explicit builder-cache management.
- [ ] Version-pinned Socktainer service and product-specific Docker context.
- [ ] Compose parser and lifecycle coordinator, with conformance fixtures.
- [ ] Automatic project detection and per-project status.
- [ ] SSH agent forwarding and safe host-directory sharing.
- [ ] Native notifications and menu-bar quick controls.
- [ ] Shell discovery and fallback beyond `/bin/sh`.
- [ ] Detachable terminal windows, tabs, saved shell presets, and session
      restoration.

## M3 — Linux machines

- [ ] Create and manage Apple container machines.
- [ ] CPU, memory, disk, home-mount, kernel, Rosetta, and nested-virtualization
      configuration.
- [ ] Terminal access and command runner.
- [ ] Persistent machine snapshots/backups where the Apple runtime supports it.
- [ ] Optional general-purpose GUI Linux VMs through Virtualization.framework.

## M4 — macOS VMs

- [x] Discover latest supported restore image and validate selected local IPSWs.
- [x] Download with resumable progress and integrity/error handling.
- [x] Create bundle, disk, auxiliary storage, hardware model, and identifier.
- [ ] Install macOS with progress and cancellation-safe cleanup.
- [ ] Start, pause, resume, request stop, force stop, and save/restore.
- [ ] Native console with automatic display reconfiguration and system-key
      capture controls.
- [ ] Shared directories, clipboard, audio, networking, and USB configuration
      where public APIs support the guest.
- [ ] Clone, export/import, backup, and reclaim disk space.

## M5 — Optimization and polish

- [ ] Launch-on-login and demand-started services.
- [ ] Battery/thermal-aware defaults and idle suspension.
- [ ] Sparse image compaction and transparent disk-usage accounting.
- [ ] Accessibility, localization, keyboard navigation, and command menus.
- [ ] Signed/notarized packaging, updater, migration, crash diagnostics.
- [ ] Performance benchmarks for cold start, warm start, I/O, network, build,
      and idle resource use.

## Public-API constraint log

Potential parity gaps are tracked rather than hidden:

- Apple’s container stack is OCI/Docker-image and Dockerfile compatible but has
  no Docker Engine API. Docker CLI/Compose requires a separate bridge.
- Bridged networking and some low-level VM controls can require restricted
  entitlements; NAT is the safe public default.
- GPU acceleration, host integration, snapshots, and dynamic device changes
  differ between Linux and macOS guests and across host OS versions.
- Exact shared-loopback networking, arbitrary Linux GPU passthrough, portable
  macOS saved-state files, and complete guest-memory reclamation are not
  available through current public APIs.
