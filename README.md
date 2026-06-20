# NativeContainers

NativeContainers is a native macOS management app for Apple’s open-source
`container` stack and Virtualization framework. The product goal is the fast,
polished container and virtual-machine workflow people expect from OrbStack,
implemented on Apple’s supported APIs and open-source runtime.

This repository is intentionally split into two runtime lanes:

- Linux containers and Linux development machines use Apple’s
  [`container`](https://github.com/apple/container) services and public Swift
  client libraries.
- General Linux and macOS virtual machines use
  [`Virtualization.framework`](https://developer.apple.com/documentation/virtualization)
  directly, including `VZVirtualMachineView` for native guest display.

The app targets Apple silicon and macOS 26 or newer. The current development
host is macOS 27 with Xcode 27; Apple `container` 1.0.0 is installed and its
services are running.

## Status

Foundation work is underway. See:

- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Feature matrix](docs/FEATURE_MATRIX.md)
- [Research notes](docs/RESEARCH.md)
- [Architecture decisions](docs/DECISIONS.md)
- [Current status](docs/STATUS.md)

## Build

The Xcode project is generated from `project.yml` so project configuration is
reviewable:

```sh
xcodegen generate
open NativeContainers.xcodeproj
```

Build and test with the `NativeContainers` scheme on `My Mac`.

The deterministic suite runs without mutating the local runtime. To run the
reversible live provisioning and PTY smokes, set
`NATIVECONTAINERS_LIVE_TESTS=1` for the test action. They create uniquely named
Alpine containers, verify native lifecycle and interactive-terminal behavior,
and delete every test resource.
