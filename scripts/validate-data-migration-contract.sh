#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
cd "$repository_root"

contract="docs/DATA_MIGRATION.md"

fail() {
  echo "data migration contract validation failed: $1" >&2
  exit 1
}

require_literal() {
  file=$1
  value=$2
  label=$3
  rg --fixed-strings --quiet -- "$value" "$file" \
    || fail "$label is missing from $file"
}

require_regex() {
  file=$1
  value=$2
  label=$3
  rg --quiet -- "$value" "$file" \
    || fail "$label is missing from $file"
}

test -f "$contract" || fail "$contract does not exist"

require_literal project.yml 'MARKETING_VERSION: "0.1.0"' "current marketing version"
require_literal "$contract" 'The current product data schema is **1**.' \
  "product data schema baseline"

require_literal NativeContainers/Domain/VirtualMachineModels.swift \
  'static let currentSchemaVersion = 1' "VM manifest schema"
require_literal NativeContainers/Domain/VirtualMachineSharedDirectoryModels.swift \
  'static let currentSchemaVersion = 1' "VM shared-folder schema"
require_literal NativeContainers/Domain/MacVirtualMachineSavedStateModels.swift \
  'static let currentSchemaVersion = 1' "VM saved-state schema"
require_literal NativeContainers/Domain/KubernetesClusterModels.swift \
  'static let currentSchemaVersion = 1' "Kubernetes descriptor schema"
require_literal NativeContainers/Services/Containers/ContainerHostDirectoryManifestStore.swift \
  'static let currentSchemaVersion = 1' "container host-folder schema"
require_literal NativeContainers/Services/Containers/TerminalPresetStore.swift \
  'private static let schemaVersion = 1' "terminal preset schema"
require_literal NativeContainers/Services/Images/ImageBuild/ImageBuildHistoryStore.swift \
  'static let currentSchemaVersion = 1' "build history schema"
require_literal NativeContainers/Services/Diagnostics/FieldDiagnosticStore.swift \
  'static let currentSchemaVersion = 1' "field diagnostic schema"
require_literal NativeContainers/Services/Compose/ComposeOperationJournalRecordCodec.swift \
  'static let schemaVersion = 3' "Compose journal schema"
require_literal NativeContainersShared/Cache/AppOwnedBuildCacheValidator.swift \
  'guard index.schemaVersion == 2' "app-owned BuildKit cache schema"

require_literal NativeContainers/Services/Machines/Virtual/VirtualMachineBundleStore.swift \
  '.appending(path: "Virtual Machines", directoryHint: .isDirectory)' \
  "VM library root"
require_literal NativeContainers/Services/Images/Restore/RestoreImageCacheService.swift \
  '.appending(path: "Restore Images", directoryHint: .isDirectory)' \
  "restore image root"
require_literal NativeContainers/Services/Containers/ContainerHostDirectoryManifestStore.swift \
  '.appending(path: "Container Host Directories", directoryHint: .isDirectory)' \
  "container host-folder root"
require_literal NativeContainers/Services/Images/ImageBuild/ImageBuildHistoryStore.swift \
  '.appending(path: "Build History", directoryHint: .isDirectory)' \
  "build history root"
require_literal NativeContainersShared/Context/BuildContextFileSystem.swift \
  '.appending(path: "Build Contexts", directoryHint: .isDirectory)' \
  "build context root"
require_literal NativeContainersShared/Storage/PrivateBuildArtifactStore.swift \
  '.appending(path: "Build Artifacts", directoryHint: .isDirectory)' \
  "build artifact root"
require_literal NativeContainers/Services/Kubernetes/KubernetesClusterDescriptorStore.swift \
  '.appending(path: "Kubernetes", directoryHint: .isDirectory)' \
  "Kubernetes descriptor root"
require_literal NativeContainers/Services/Diagnostics/FieldDiagnosticStore.swift \
  '.appending(path: "FieldDiagnostics", directoryHint: .isDirectory)' \
  "field diagnostic root"
require_literal NativeContainers/Services/Compatibility/SocktainerProcessService.swift \
  '.appending(path: ".socktainer", directoryHint: .isDirectory)' \
  "Socktainer compatibility workspace"
require_literal NativeContainers/App/Composition/OptionalIntegrationServiceModule.swift \
  'path: "NativeContainers-Compose-Operations"' "Compose journal root"
require_literal NativeContainers/Services/Containers/TerminalPresetStore.swift \
  'private static let standardKey = "terminal.presets.v1"' \
  "terminal preset preference key"
require_literal NativeContainers/App/AppPreferences.swift \
  'static let menuBarExtraInserted = "app.menuBarExtra.isInserted"' \
  "menu-bar preference key"
require_literal NativeContainers/Services/Images/Registry/AppleRegistryService.swift \
  'KeychainHelper(securityDomain: Constants.keychainID)' \
  "external registry Keychain authority"

for phrase in \
  'Authoritative app-owned data' \
  'Resumable and inspectable app-owned data' \
  'Replaceable or operation-scoped data' \
  'External authorities' \
  'Required migration protocol' \
  'Downgrade and rollback policy' \
  'Release checklist'
do
  require_literal "$contract" "$phrase" "contract section: $phrase"
done

require_regex docs/ROADMAP.md '\[x\].*user-data ownership, migration, and rollback' \
  "completed roadmap migration contract"
require_literal docs/DISTRIBUTION.md 'scripts/validate-data-migration-contract.sh' \
  "distribution migration validation step"
require_literal README.md '[User-data migration and rollback](docs/DATA_MIGRATION.md)' \
  "README migration contract link"
require_literal "$contract" '`~/.socktainer` compatibility socket/process workspace' \
  "external Socktainer workspace classification"

echo "data migration contract validation passed"
