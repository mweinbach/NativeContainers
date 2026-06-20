# Roadmap

The goal is broad workflow parity, not a pixel-for-pixel clone. Each milestone
must leave a usable, test-backed product slice.

## M0 — Verified native foundation

- [x] Native macOS app and unit-test targets build in Xcode.
- [ ] Add the required Virtualization entitlement through Xcode.
- [x] Direct Apple client adapter reports container system health.
- [x] Live inventories for containers, images, volumes, and Linux machines.
- [x] Stable domain models and mockable service protocols.
- [x] Persistent VM bundle library with schema versioning and atomic writes.
- [x] SwiftUI management shell with useful empty/error/loading states.
- [x] Diagnostics screen records runtime and package versions.

## M1 — Daily container management

- [ ] Container start, graceful stop, kill, restart, and delete.
- [ ] Logs with follow/search/export.
- [ ] Live CPU, memory, disk, network, and process statistics.
- [ ] Exec terminal and file copy in/out.
- [ ] Image pull, build, tag, push, inspect, and prune.
- [ ] Volume and network create/inspect/delete flows.
- [ ] Port/socket publishing, host access, local DNS, and open-in-browser.
- [ ] Registry authentication through Keychain-backed Apple APIs.

## M2 — Developer workflow and Docker compatibility

- [ ] Dockerfile/Containerfile build workflow through Apple’s builder.
- [ ] Version-pinned Socktainer service and product-specific Docker context.
- [ ] Compose parser and lifecycle coordinator, with conformance fixtures.
- [ ] Automatic project detection and per-project status.
- [ ] SSH agent forwarding and safe host-directory sharing.
- [ ] Native notifications and menu-bar quick controls.

## M3 — Linux machines

- [ ] Create and manage Apple container machines.
- [ ] CPU, memory, disk, home-mount, kernel, Rosetta, and nested-virtualization
      configuration.
- [ ] Terminal access and command runner.
- [ ] Persistent machine snapshots/backups where the Apple runtime supports it.
- [ ] Optional general-purpose GUI Linux VMs through Virtualization.framework.

## M4 — macOS VMs

- [ ] Discover latest supported restore image and inspect local IPSWs.
- [ ] Download with resumable progress and integrity/error handling.
- [ ] Create bundle, disk, auxiliary storage, hardware model, and identifier.
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
