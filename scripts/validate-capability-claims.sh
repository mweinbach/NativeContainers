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
forbid_literal NativeContainers/NativeContainers.entitlements \
  'com.apple.security.device.usb' \
  "sandbox USB entitlement while physical USB activation is blocked"
forbid_literal project.yml \
  'com.apple.developer.accessory-access.usb' \
  "unprovisioned AccessoryAccess entitlement in the project specification"
forbid_literal project.yml \
  'com.apple.security.device.usb' \
  "unrelated sandbox USB entitlement in the project specification"
forbid_literal NativeContainers.xcodeproj/project.pbxproj \
  'ENABLE_RESOURCE_ACCESS_USB' \
  "generated sandbox USB build setting"
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
require_literal NativeContainers/Services/Compose/ComposeProjectLifecycleService.swift \
  'func discoverInputRequirements(' \
  "two-stage Compose input discovery API"
require_literal NativeContainers/Services/Compose/ComposeProjectInputVault.swift \
  'actor ComposeProjectInputVault' \
  "in-memory Compose review vault"
require_literal NativeContainers/Services/Compose/ComposeContainerLifecyclePlanner.swift \
  'container.labels[ComposeLabelKey.inputSeal] != inputSeal' \
  "stale Compose input recreation blocker"
require_literal NativeContainers/Services/Compose/SocktainerComposeConformanceService.swift \
  'sourceRevision: "5bdafa7"' \
  "completed NativeContainers bridge conformance pin"
require_literal NativeContainers/Services/Compose/SocktainerComposeConformanceService.swift \
  'passedScenarioIDs: Set(SocktainerComposeSemanticScenarioCatalog.all.map(\.id))' \
  "complete NativeContainers bridge semantic evidence"
require_literal NativeContainers/App/Composition/OptionalIntegrationServiceModule.swift \
  'allowsNativeContainersForkFeatures: false' \
  "production upstream Compose feature gate"
require_literal NativeContainers/App/Composition/OptionalIntegrationServiceModule.swift \
  'allowsNativeContainersForkRecreation: false' \
  "production upstream Compose recreation gate"
require_literal NativeContainers/Domain/ComposeProjectActions.swift \
  'case replace' \
  "typed Compose replacement action"
require_literal NativeContainers/Domain/ComposeProjectActions.swift \
  'case scaleDown' \
  "typed Compose scale-down action"
require_literal docs/FEATURE_MATRIX.md \
  '| Docker Compose | Review/input-vault/planning/revalidation/journal/mutation services + private official client + exact NativeContainers bridge fork | Conditional M2 |' \
  "conditional complete Compose claim"
require_literal docs/FEATURE_MATRIX.md \
  '| Docker CLI and Engine API | Pinned Socktainer install/process/context services + exact NativeContainers bridge fork | Conditional M2 |' \
  "conditional local Engine subset claim"

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
  '[x] Complete product-contract performance benchmark coverage.' \
  "completed performance roadmap item"
require_literal docs/FEATURE_MATRIX.md \
  'all eight contract requirements have executable coverage' \
  "complete performance coverage qualification"
require_literal docs/FEATURE_MATRIX.md \
  '| NAT/direct-IP latency and throughput | Complete |' \
  "completed network-performance contract"
require_literal NativeContainers/Services/Performance/PerformanceBenchmarkScenarios.swift \
  'actor ImagePullDiskGrowthPerformanceBenchmarkScenario' \
  "image-pull disk-growth benchmark"
require_literal NativeContainers/Services/Performance/PerformanceBenchmarkScenarios.swift \
  'actor NATDirectNetworkPerformanceBenchmarkScenario' \
  "NAT/direct-IP benchmark"
require_literal NativeContainers/Services/Performance/PerformanceBenchmarkScenarios.swift \
  'actor HostSleepWakePerformanceBenchmarkScenario' \
  "host sleep-wake recovery benchmark"
require_literal NativeContainers/Services/Performance/PerformanceBenchmarkScenarios.swift \
  'actor IsolatedAppProcessCrashRecoveryBenchmarkCycle' \
  "isolated app crash-recovery benchmark"
require_literal NativeContainers/Services/Performance/PerformanceBenchmarkScenarios.swift \
  'actor AppleRuntimeCrashRecoveryBenchmarkCycle' \
  "runtime crash-recovery benchmark"

require_literal docs/FEATURE_MATRIX.md \
  '| Persistent Apple-machine snapshots/backups | Versioned fork Machine API + crash-safe snapshot catalog/store + native Snapshots UI | Conditional M3 |' \
  "conditional Apple-machine snapshot claim"
require_literal docs/FEATURE_MATRIX.md \
  '| Build-time SSH forwarding | Reviewed agent configuration + protocol-v7 worker + NativeContainers `container`/builder-shim forks | Conditional M2 |' \
  "conditional build-time SSH claim"
require_literal NativeContainers/Services/Machines/Linux/AppleMachineRuntimeClient.swift \
  'struct NativeContainersLinuxMachineSnapshotRuntimeVerifier' \
  "snapshot active-runtime gate"
require_literal NativeContainers/Services/Images/ImageBuild/ImageBuildPlanningService.swift \
  'struct NativeContainersImageBuildRuntimeCapabilityVerifier' \
  "build SSH active-runtime gate"
require_literal NativeContainers/Services/RuntimeDistribution/NativeRuntimeProductionVerifier.swift \
  'struct ProductionActiveNativeRuntimeVerifier' \
  "verified native runtime origin"

echo "capability claim validation passed"
