#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
cd "$repository_root"

views="NativeContainers/Views"
catalog="NativeContainers/Resources/Localizable.xcstrings"
contract="docs/ACCESSIBILITY_QA.md"

fail() {
  echo "accessibility contract validation failed: $1" >&2
  exit 1
}

require_literal() {
  file=$1
  value=$2
  label=$3
  rg --fixed-strings --quiet -- "$value" "$file" \
    || fail "$label is missing from $file"
}

if rg --quiet -- '\.onTapGesture\b|\bTapGesture[[:space:]]*\(' "$views"; then
  rg -n -- '\.onTapGesture\b|\bTapGesture[[:space:]]*\(' "$views" >&2
  fail "management views contain raw tap activation"
fi

directional_alignment='\.frame\([^\n]*alignment:[[:space:]]*\.(left|right)\b|\.multilineTextAlignment\(\.(left|right)\b'
if rg --quiet -- "$directional_alignment" "$views"; then
  rg -n -- "$directional_alignment" \
    "$views" >&2
  fail "management views contain fixed left/right alignment"
fi

for file in \
  NativeContainers/Views/ContainersView.swift \
  NativeContainers/Views/ImagesView.swift \
  NativeContainers/Views/LinuxMachinesView.swift \
  NativeContainers/Views/LinuxVirtualMachineRow.swift \
  NativeContainers/Views/MacVirtualMachineRow.swift \
  NativeContainers/Views/TerminalWorkspaceView.swift
do
  require_literal "$file" 'Button(action: onSelect)' "semantic selection button"
done

for file in \
  NativeContainers/Views/LinuxVirtualMachineRow.swift \
  NativeContainers/Views/MacVirtualMachineRow.swift
do
  require_literal "$file" '.accessibilityInputLabels([Text(machine.name)])' \
    "visible VM-name input label"
  require_literal "$file" '.accessibilityHint("Selects this virtual machine")' \
    "VM selection hint"
  require_literal "$file" '.accessibilityValue(isSelected ? "Selected" : "Not selected")' \
    "VM selection value"
done

require_literal NativeContainers/Views/RootView.swift '.accessibilityInputLabels([' \
  "app-shell alternate input labels"
require_literal NativeContainers/Views/ResourceQuickOpenView.swift \
  '.accessibilityInputLabels([LocalizedStringKey(entry.title)])' \
  "Quick Open visible-name input label"
require_literal project.yml 'SWIFT_EMIT_LOC_STRINGS: YES' \
  "Swift localization extraction setting"
require_literal project.yml 'LOCALIZATION_PREFERS_STRING_CATALOGS: YES' \
  "String Catalog preference"
require_literal "$catalog" '"Selects this virtual machine"' \
  "VM selection hint catalog entry"

for section in \
  'Source contract' \
  'Live test setup' \
  'Workflow matrix' \
  'Evidence record'
do
  require_literal "$contract" "$section" "accessibility contract section: $section"
done

require_literal docs/ROADMAP.md 'Source-level accessibility contract' \
  "completed source accessibility roadmap gate"
require_literal docs/ROADMAP.md 'live VoiceOver/Full Keyboard Access' \
  "open live accessibility roadmap gate"
require_literal docs/FEATURE_MATRIX.md 'source accessibility validator' \
  "feature-matrix source gate"
require_literal README.md '[Accessibility quality gate](docs/ACCESSIBILITY_QA.md)' \
  "README accessibility contract link"
require_literal docs/DISTRIBUTION.md 'scripts/validate-accessibility-contract.sh' \
  "distribution accessibility validation step"

echo "accessibility contract validation passed"
