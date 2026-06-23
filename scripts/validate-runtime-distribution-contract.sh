#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
cd "$repository_root"

contract_source="NativeContainers/Services/Containers/AppleContainerRuntimeSetupService.swift"

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

project_version=$(
  awk '
    /^  AppleContainer:$/ { in_dependency = 1; next }
    in_dependency && /exactVersion:/ {
      gsub(/.*exactVersion:[[:space:]]*/, "")
      gsub(/"/, "")
      print
      exit
    }
  ' project.yml
)
source_version=$(
  sed -n 's/.*static let requiredVersion = "\([^"]*\)".*/\1/p' \
    "$contract_source" | head -n 1
)

test -n "$project_version" || fail "AppleContainer exactVersion is not declared"
test -n "$source_version" || fail "runtime requiredVersion is not declared"
test "$project_version" = "$source_version" \
  || fail "project pins Apple container $project_version but runtime requires $source_version"

require_literal "$contract_source" \
  'static let packageIdentifier = "com.apple.container-installer"' \
  "official installer receipt identifier"
require_literal "$contract_source" \
  'static let executableURL = URL(filePath: "/usr/local/bin/container")' \
  "official installer executable path"
require_literal "$contract_source" \
  "https://github.com/apple/container/releases/tag/$source_version" \
  "version-pinned official release URL"
require_literal "$contract_source" \
  'static let signingIdentifier = "com.apple.container.cli"' \
  "official CLI signing identifier"
require_literal "$contract_source" \
  'static let teamIdentifier = "UPBK2H6LZM"' \
  "official CLI signing team"

require_literal README.md \
  "Apple \`container\` $source_version" \
  "README runtime prerequisite"
require_literal docs/DECISIONS.md \
  'ADR-088: Require Apple’s signed system runtime for the container lane' \
  "accepted runtime distribution decision"
require_literal docs/ARCHITECTURE.md \
  "official Apple \`container\` $source_version installation" \
  "architecture runtime authority"
require_literal docs/DISTRIBUTION.md \
  'NativeContainers does not embed, install, update, or re-sign Apple runtime executables.' \
  "distribution runtime boundary"
require_literal docs/DATA_MIGRATION.md \
  "Apple’s signed \`container\` installer payload and package receipt under \`/usr/local\`" \
  "external runtime migration authority"
require_literal docs/ROADMAP.md \
  'Explicit external-runtime distribution contract' \
  "completed runtime distribution roadmap item"
require_literal docs/FEATURE_MATRIX.md \
  'Official signed Apple system runtime prerequisite' \
  "feature matrix runtime distribution row"
require_literal scripts/validate-distribution-artifact.sh \
  'embedded_runtime_payloads' \
  "artifact embedded-runtime rejection"

echo "runtime distribution contract validation passed for Apple container $source_version"
