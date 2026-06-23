#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
cd "$repository_root"

official_source="NativeContainers/Services/Containers/AppleContainerRuntimeSetupService.swift"
models_source="NativeContainers/Services/RuntimeDistribution/NativeRuntimeDistributionModels.swift"
production_source="NativeContainers/Services/RuntimeDistribution/NativeRuntimeProductionContracts.swift"
verifier_source="NativeContainers/Services/RuntimeDistribution/NativeRuntimeProductionVerifier.swift"
setup_source="NativeContainers/Services/RuntimeDistribution/VerifiedDualRuntimeSetupService.swift"
worker_source="NativeContainersBuildWorker/ContainerBuilderController.swift"
release_contract="NativeContainers/Resources/NativeRuntimeReleaseContract.json"
runtime_manifest_fixture="NativeContainersTests/Infrastructure/Fixtures/NativeRuntimeManifest-1.0.0-nc.2.json"
resolved_packages="NativeContainers.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

fail() {
  echo "runtime distribution contract validation failed: $1" >&2
  exit 1
}

require_literal() {
  file=$1
  value=$2
  label=$3
  rg --fixed-strings --quiet -- "$value" "$file" \
    || fail "$label is missing from $file"
}

require_literal project.yml \
  'url: https://github.com/mweinbach/container.git' \
  "NativeContainers container fork URL"
require_literal project.yml \
  'exactVersion: 1.0.0-nc.2' \
  "exact NativeContainers runtime client tag"
require_literal "$resolved_packages" \
  '"location" : "https://github.com/mweinbach/container.git"' \
  "resolved NativeContainers container fork"
require_literal "$resolved_packages" \
  '"revision" : "3abca3683c9dd81d1ce3a1b20c13688b2e0888e6"' \
  "resolved signed-contract runtime revision"

require_literal "$official_source" \
  'static let requiredVersion = "1.0.0"' \
  "official runtime version"
require_literal "$official_source" \
  'static let packageIdentifier = "com.apple.container-installer"' \
  "official installer receipt identifier"
require_literal "$official_source" \
  'static let executableURL = URL(filePath: "/usr/local/bin/container")' \
  "official installer executable path"
require_literal "$official_source" \
  'static let signingIdentifier = "com.apple.container.cli"' \
  "official CLI signing identifier"
require_literal "$official_source" \
  'static let teamIdentifier = "UPBK2H6LZM"' \
  "official CLI signing team"

require_literal "$production_source" \
  'static let officialRuntimeVersion = "1.0.0"' \
  "official production manifest version"
require_literal "$production_source" \
  'static let nativeRuntimeVersion = "1.0.0-nc.2"' \
  "NativeContainers production manifest version"
require_literal "$production_source" \
  'static let nativePackageIdentifier = "com.nativecontainers.runtime"' \
  "NativeContainers package receipt identifier"
require_literal "$production_source" \
  'filePath: "/Library/Application Support/NativeContainers/Runtime/1.0.0-nc.2"' \
  "isolated NativeContainers install root"
require_literal "$models_source" \
  'static let nativeContainersTeamIdentifier = "6UHAW5UAT4"' \
  "NativeContainers signing team"
require_literal "$models_source" \
  'shimVersion: "0.12.0-nc.2"' \
  "builder shim version"
require_literal "$models_source" \
  'sourceRevision: "f66f1680fe6b74d814fb5527247e7d81227fcecb"' \
  "builder shim source revision"
require_literal "$models_source" \
  'imageDigest: "sha256:b3574dc6b867fc91d1ed1d2941c74811961e2645ffa4c1fc68c19ae69e5fdbff"' \
  "builder image digest"
require_literal "$production_source" \
  'container-builder-shim-0.12.0-nc.2.oci.tar' \
  "builder OCI archive filename"
require_literal "$production_source" \
  'sha256: "d872daa5ff4534aeb18fb747e015e56cef1cd1b584e05d725b72b624b41a7680"' \
  "builder OCI archive SHA-256"
require_literal "$production_source" \
  'path: "etc/container/config.toml"' \
  "root-owned runtime configuration"
require_literal "$production_source" \
  'digest: "15d02e3707d200579e23f03cf883bc8980a9dc4bfc3ea4f6e09224b17737892a"' \
  "root-owned runtime configuration SHA-256"
require_literal "$production_source" \
  'sha256: "b63f13be79466249c65db03befe38415057aa18b201bebc2d5e36609954344c4"' \
  "runtime manifest SHA-256"
require_literal "$worker_source" \
  'image = try await ClientImage.get(' \
  "native builder local-only lookup"
require_literal "$worker_source" \
  'resolvedManifestDigest = try await image.resolvedDigest()' \
  "native builder resolved manifest digest gate"

runtime_manifest_digest=$(shasum -a 256 "$runtime_manifest_fixture" | awk '{print $1}')
test "$runtime_manifest_digest" = \
  "b63f13be79466249c65db03befe38415057aa18b201bebc2d5e36609954344c4" \
  || fail "runtime manifest fixture digest does not match the published nc.2 manifest"

require_literal "$verifier_source" \
  'struct BundledNativeRuntimeReleaseContractLoader' \
  "signed app release-contract loader"
require_literal "$verifier_source" \
  'Set(contract.signedBinarySHA256.keys) == Set(signedBinaryPaths)' \
  "closed signed-binary digest set"
require_literal "$setup_source" \
  'NativeRuntimeLaunchGraphClassifier' \
  "pre-connection active-origin classifier"
require_literal "$setup_source" \
  'NativeRuntimeDistributionVerifying' \
  "pre-connection package verifier"
require_literal "$release_contract" \
  '"schemaVersion": 0' \
  "fail-closed source release-contract placeholder"
require_literal "$release_contract" \
  'release-packaging-must-replace-this-placeholder' \
  "release packaging replacement marker"

require_literal README.md \
  'separately packaged NativeContainers runtime `1.0.0-nc.2`' \
  "README conditional runtime prerequisite"
require_literal docs/DECISIONS.md \
  'ADR-090: Offer one verified NativeContainers runtime beside Apple’s runtime' \
  "dual-runtime architecture decision"
require_literal docs/DECISIONS.md \
  '**Status:** Superseded by ADR-090' \
  "superseded official-only runtime decision"
require_literal docs/ARCHITECTURE.md \
  'Runtime distribution is a separate verified boundary.' \
  "architecture runtime boundary"
require_literal docs/DISTRIBUTION.md \
  '## NativeContainers runtime package' \
  "separate runtime package contract"
require_literal docs/DISTRIBUTION.md \
  'NativeContainers does not embed, install, update, or re-sign Apple runtime executables.' \
  "official runtime distribution boundary"
require_literal docs/DATA_MIGRATION.md \
  '### NativeContainers runtime clone migration' \
  "one-time cloned migration contract"
require_literal docs/FEATURE_MATRIX.md \
  '| Container runtime distribution | Official Apple runtime + separately packaged NativeContainers `1.0.0-nc.2` fork + mutually exclusive activation |' \
  "feature matrix dual-runtime row"
require_literal scripts/validate-distribution-artifact.sh \
  'embedded_runtime_payloads' \
  "app artifact embedded-runtime rejection"

echo "runtime distribution contract validation passed for Apple 1.0.0 and NativeContainers 1.0.0-nc.2"
