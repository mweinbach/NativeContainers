#!/bin/zsh

set -euo pipefail

usage() {
  print -u2 "usage: $0 [--developer-id] <NativeContainers.app|archive.xcarchive>"
}

fail() {
  print -u2 "error: $1"
  exit 1
}

note() {
  print "ok: $1"
}

developer_id_required=false
if [[ "${1:-}" == "--developer-id" ]]; then
  developer_id_required=true
  shift
fi

[[ $# -eq 1 ]] || {
  usage
  exit 64
}

input=$1
[[ -e "$input" ]] || fail "artifact does not exist: $input"

if [[ "$input" == *.xcarchive ]]; then
  archive=$input
  app="$input/Products/Applications/NativeContainers.app"
  [[ -d "$app" ]] || fail "archive does not contain Products/Applications/NativeContainers.app"

  worker_count=$(
    find "$input/Products" -type f -name NativeContainersBuildWorker -print | wc -l | tr -d " "
  )
  [[ "$worker_count" == "1" ]] ||
    fail "archive must contain exactly one embedded build worker; found $worker_count"
else
  archive=
  app=$input
fi

[[ "$app" == *.app && -d "$app" ]] || fail "expected a NativeContainers app bundle"

executable="$app/Contents/MacOS/NativeContainers"
worker="$app/Contents/Helpers/NativeContainersBuildWorker"
[[ -f "$executable" ]] || fail "main executable is missing"
[[ -f "$worker" ]] || fail "embedded build worker is missing"

if [[ -n "$archive" ]]; then
  app_dsym="$archive/dSYMs/NativeContainers.app.dSYM/Contents/Resources/DWARF/NativeContainers"
  worker_dsym="$archive/dSYMs/NativeContainersBuildWorker.dSYM/Contents/Resources/DWARF/NativeContainersBuildWorker"
  [[ -f "$app_dsym" ]] || fail "archive is missing the NativeContainers app dSYM"
  [[ -f "$worker_dsym" ]] || fail "archive is missing the build-worker dSYM"

  binary_uuid() {
    xcrun dwarfdump --uuid "$1" | sed -n 's/^UUID: \([^ ]*\).*/\1/p'
  }

  [[ "$(binary_uuid "$executable")" == "$(binary_uuid "$app_dsym")" ]] ||
    fail "NativeContainers app dSYM UUID does not match its executable"
  [[ "$(binary_uuid "$worker")" == "$(binary_uuid "$worker_dsym")" ]] ||
    fail "build-worker dSYM UUID does not match its executable"
  note "archive contains matching app and build-worker dSYMs"
fi

for binary in "$executable" "$worker"; do
  architectures=$(lipo -archs "$binary")
  [[ "$architectures" == "arm64" ]] ||
    fail "${binary:t} must be arm64-only; found: $architectures"
done
note "main executable and helper are arm64-only"

version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
build=$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")
[[ "$version" == <->.<->.<-> ]] || fail "invalid marketing version: $version"
[[ "$build" == <-> ]] || fail "invalid build number: $build"
note "bundle version is $version ($build)"

codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$worker"
note "app and embedded helper signatures verify"

signature_details() {
  codesign -d --verbose=4 "$1" 2>&1
}

app_signature=$(signature_details "$app")
worker_signature=$(signature_details "$worker")

print -r -- "$app_signature" | grep -q "flags=.*runtime" ||
  fail "app signature does not enable hardened runtime"
print -r -- "$worker_signature" | grep -q "flags=.*runtime" ||
  fail "build worker signature does not enable hardened runtime"
note "app and embedded helper enable hardened runtime"

app_team=$(print -r -- "$app_signature" | sed -n 's/^TeamIdentifier=//p')
worker_team=$(print -r -- "$worker_signature" | sed -n 's/^TeamIdentifier=//p')
[[ -n "$app_team" && "$app_team" == "$worker_team" ]] ||
  fail "app and worker signing teams differ"
note "nested code shares signing team $app_team"

app_authority=$(print -r -- "$app_signature" | sed -n 's/^Authority=//p' | head -n 1)
app_entitlements=$(mktemp)
worker_entitlements=$(mktemp)
trap 'rm -f "$app_entitlements" "$worker_entitlements"' EXIT
codesign -d --entitlements - --xml "$app" >"$app_entitlements" 2>/dev/null
codesign -d --entitlements - --xml "$worker" >"$worker_entitlements" 2>/dev/null

entitlement_exists() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1
}

entitlement_is_true() {
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || print false)" == "true" ]]
}

entitlement_is_true "$app_entitlements" com.apple.security.device.audio-input ||
  fail "app signature is missing the audio-input entitlement"
entitlement_is_true "$app_entitlements" com.apple.security.virtualization ||
  fail "app signature is missing the virtualization entitlement"

forbidden_entitlements=(
  com.apple.security.app-sandbox
  com.apple.security.assets.movies.read-write
  com.apple.security.assets.music.read-write
  com.apple.security.assets.pictures.read-write
  com.apple.security.automation.apple-events
  com.apple.security.cs.allow-dyld-environment-variables
  com.apple.security.cs.allow-jit
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.debugger
  com.apple.security.cs.disable-executable-page-protection
  com.apple.security.cs.disable-library-validation
  com.apple.security.device.bluetooth
  com.apple.security.device.camera
  com.apple.security.device.usb
  com.apple.security.files.downloads.read-write
  com.apple.security.files.user-selected.read-write
  com.apple.security.network.client
  com.apple.security.network.server
  com.apple.security.personal-information.addressbook
  com.apple.security.personal-information.calendars
  com.apple.security.personal-information.location
  com.apple.security.personal-information.photos-library
  com.apple.security.print
)

for entitlement in $forbidden_entitlements; do
  entitlement_exists "$app_entitlements" "$entitlement" &&
    fail "app signature contains unexpected entitlement: $entitlement"
  entitlement_exists "$worker_entitlements" "$entitlement" &&
    fail "build worker signature contains unexpected entitlement: $entitlement"
done

for entitlement in com.apple.security.device.audio-input com.apple.security.virtualization; do
  entitlement_exists "$worker_entitlements" "$entitlement" &&
    fail "build worker signature contains app-only entitlement: $entitlement"
done
note "app and build-worker entitlements are constrained to their required capabilities"

get_task_allow=$(
  /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" \
    "$app_entitlements" 2>/dev/null ||
    print false
)
worker_get_task_allow=$(
  /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" \
    "$worker_entitlements" 2>/dev/null ||
    print false
)

if $developer_id_required; then
  [[ "$app_authority" == "Developer ID Application:"* ]] ||
    fail "Developer ID mode requires a Developer ID Application signature; found: $app_authority"
  [[ "$get_task_allow" != "true" ]] ||
    fail "Developer ID artifact contains com.apple.security.get-task-allow"
  [[ "$worker_get_task_allow" != "true" ]] ||
    fail "Developer ID build worker contains com.apple.security.get-task-allow"
  spctl --assess --type execute --verbose=4 "$app"
  xcrun stapler validate "$app"
  note "Developer ID, Gatekeeper, and stapled-ticket checks passed"
else
  note "signature authority is $app_authority"
  if [[ "$get_task_allow" == "true" ]]; then
    print "note: get-task-allow is expected for a development artifact"
  fi
  print "note: rerun with --developer-id for Gatekeeper and stapled-ticket enforcement"
fi
