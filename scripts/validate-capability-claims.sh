#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
cd "$repository_root"

fail() {
  echo "capability claim validation failed: $1" >&2
  exit 1
}

require_literal() {
  file=$1
  value=$2
  label=$3
  rg --fixed-strings --quiet -- "$value" "$file" \
    || fail "$label is missing from $file"
}

forbid_literal() {
  file=$1
  value=$2
  label=$3
  if rg --fixed-strings --quiet -- "$value" "$file"; then
    fail "$label remains in $file"
  fi
}

require_literal NativeContainers/App/MenuBarQuickControlsController.swift \
  'NSStatusBar.system.statusItem' \
  "AppKit menu-bar status item"
forbid_literal NativeContainers/App/NativeContainersApp.swift \
  'MenuBarExtra(' \
  "macOS 27-incompatible MenuBarExtra scene"
require_literal docs/FEATURE_MATRIX.md \
  'AppKit `NSStatusItem`/`NSPopover`' \
  "menu-bar availability contract"

require_literal NativeContainers/App/Composition/AppCompositionRoot.swift \
  'com.apple.developer.accessory-access.usb' \
  "signed-process USB entitlement gate"
require_literal NativeContainers/App/Composition/AppCompositionRoot.swift \
  'Physical USB is blocked in this build' \
  "user-visible USB activation blocker"
forbid_literal NativeContainers/NativeContainers.entitlements \
  'com.apple.developer.accessory-access.usb' \
  "USB entitlement while the feature matrix still marks activation blocked"
require_literal docs/FEATURE_MATRIX.md \
  '| Physical USB passthrough | AccessoryAccess discovery + generation-pinned VZ XHCI controller service + app-scoped observable model | Blocked |' \
  "blocked USB product status"

for fixture in \
  compose-recreation \
  compose-network-aliases \
  compose-healthchecks \
  compose-restart-policy \
  compose-configs \
  compose-secrets
do
  require_literal NativeContainers/Services/Compose/SocktainerComposeConformanceService.swift \
    "id: \"$fixture\"" \
    "explicit Compose gap $fixture"
done
require_literal NativeContainers/Domain/ComposeBridgeConformanceModels.swift \
  'case upstreamBlocked' \
  "upstream-blocked Compose status"

for requirement in \
  containerStartup \
  idleContainerMemory \
  postStressMemory \
  bindMountIO \
  postgreSQLDurability \
  imagePullBuildAndDisk \
  containerNetworking \
  recovery
do
  require_literal NativeContainers/Domain/PerformanceBenchmarkModels.swift \
    "case $requirement" \
    "performance-contract requirement $requirement"
done
require_literal docs/ROADMAP.md \
  '[ ] Complete product-contract performance benchmark coverage.' \
  "open complete-performance roadmap item"
require_literal docs/FEATURE_MATRIX.md \
  'None of the eight performance-contract requirements is fully covered yet' \
  "performance coverage qualification"

require_literal docs/FEATURE_MATRIX.md \
  '| Persistent Apple-machine snapshots/backups | None | Upstream blocked |' \
  "Apple-machine snapshot blocker"
require_literal docs/FEATURE_MATRIX.md \
  '| Build-time SSH forwarding | None | Upstream blocked |' \
  "build-time SSH blocker"

echo "capability claim validation passed"
