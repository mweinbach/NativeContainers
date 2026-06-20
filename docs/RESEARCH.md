# Research notes

Last updated: 2026-06-20.

## Host baseline

- Apple silicon host running macOS 27.0.
- Xcode 27.0 beta (`27A5194q`), macOS 27 SDK, Swift 6.4 compiler.
- Apple `container` CLI 1.0.0 is installed at `/usr/local/bin/container`.
- `container system status --format json` reports the 1.0.0 API server running.
- The live container, image, and machine inventories were empty at kickoff.

## Apple container stack

Primary sources:

- [`apple/container` 1.0.0](https://github.com/apple/container/tree/1.0.0)
- [`apple/container` API docs](https://apple.github.io/container/documentation/)
- [`apple/containerization` 0.33.3](https://github.com/apple/containerization/tree/0.33.3)
- [Containerization API docs](https://apple.github.io/containerization/documentation/)

Verified architecture:

- The Containerization package runs each Linux container in its own lightweight
  Virtualization.framework VM, using an optimized kernel and a minimal init
  service communicating over vsock.
- Containers can receive dedicated IP addresses, avoiding mandatory per-port
  forwarding for host access.
- The stack consumes and produces OCI images, pulls from standard registries,
  builds Dockerfiles/Containerfiles through BuildKit, supports volumes,
  networks, statistics, logs, copy, exec, registries, and persistent
  `container machine` Linux environments.
- Release 1.0.0 publishes Swift library products including
  `ContainerAPIClient`, `ContainerResource`, `MachineAPIClient`, and related
  service clients. Those are preferable to scraping CLI table output.
- The runtime is supported on macOS 26+ and Apple silicon.

The package remains an actively evolving open-source surface. Pinning an exact
release and isolating it behind an adapter are both deliberate.

## Virtualization.framework

The installed Apple documentation confirms:

- A process using Virtualization APIs needs the
  `com.apple.security.virtualization` entitlement.
- `VZMacOSRestoreImage.latestSupported` discovers the newest restore image the
  current host supports; local images can be loaded explicitly.
- The restore image’s most featureful supported configuration supplies the
  compatible hardware model and CPU/memory requirements.
- A macOS VM must persist its hardware model, machine identifier, auxiliary
  storage, and main disk together.
- `VZVirtualMachineConfiguration.validate()` is the preflight gate.
- Save/restore support has its own configuration validation and is not assumed
  for every configuration.
- `VZVirtualMachineView` is the native interactive display. It supports
  automatic display reconfiguration and optional capture of system keys.
- Shared directories use VirtioFS. Linux clipboard integration uses the SPICE
  agent and requires guest support.

## Docker wording

“Docker support” has several meanings and the product will distinguish them:

1. Docker/OCI image interoperability — present.
2. Dockerfile builds — present.
3. Docker CLI and Engine API compatibility — not established by the 1.0.0
   public docs reviewed so far.
4. Docker Compose behavior — requires either a supported engine compatibility
   endpoint or a native Compose coordinator.

The UI and marketing must not collapse those four claims into one.

