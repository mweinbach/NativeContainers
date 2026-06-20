# Current status

Updated: 2026-06-20.

## Verified

- Xcode project generated and open as scheme `NativeContainers` on `My Mac`.
- Exact `apple/container` 1.0.0 package resolves and compiles.
- Build-for-testing succeeds with no warnings.
- Six Swift Testing cases are discovered; the complete suite passes after the
  manifest date round-trip fix.
- The app launches through Xcode and stops cleanly.
- The SwiftUI overview renders successfully in Xcode Preview in light mode.
- A live Xcode snippet called `AppleContainerService.loadInventory()` against
  the installed XPC services and returned the 1.0.0 server plus live container,
  image, volume, and machine counts.
- VM draft creation uses a staging directory, atomic manifest write, sparse disk
  allocation, and final rename; tests verify reload and cleanup.

## Known configuration issue

Apple documentation and SDK headers require
`com.apple.security.virtualization`. Xcode MCP’s entitlement action returned
“This entitlement does not exist” for that documented key and explicitly
forbids a manual workaround. The app therefore builds and the container lane is
live, but constructing a VM is intentionally not claimed as runtime-verified
until the entitlement can be added through a functioning Xcode capability
surface.

## Next implementation slice

1. Resolve/add the Virtualization entitlement through Xcode and validate a
   minimal configuration.
2. Add container logs, one-shot stats, and detailed inspection.
3. Implement local/latest IPSW selection, resumable download, and transactional
   macOS VM preparation.
4. Spike a pinned Socktainer process and a product-specific Docker context.

