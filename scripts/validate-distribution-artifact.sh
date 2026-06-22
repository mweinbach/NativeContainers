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
  app="$input/Products/Applications/NativeContainers.app"
  [[ -d "$app" ]] || fail "archive does not contain Products/Applications/NativeContainers.app"

  worker_count=$(
    find "$input/Products" -type f -name NativeContainersBuildWorker -print | wc -l | tr -d " "
  )
  [[ "$worker_count" == "1" ]] ||
    fail "archive must contain exactly one embedded build worker; found $worker_count"
else
  app=$input
fi

[[ "$app" == *.app && -d "$app" ]] || fail "expected a NativeContainers app bundle"

executable="$app/Contents/MacOS/NativeContainers"
worker="$app/Contents/Helpers/NativeContainersBuildWorker"
[[ -f "$executable" ]] || fail "main executable is missing"
[[ -f "$worker" ]] || fail "embedded build worker is missing"

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
entitlements=$(mktemp)
trap 'rm -f "$entitlements"' EXIT
codesign -d --entitlements "$entitlements" "$app" 2>/dev/null

get_task_allow=$(
  plutil -extract com.apple.security.get-task-allow raw -o - "$entitlements" 2>/dev/null ||
    print false
)

if $developer_id_required; then
  [[ "$app_authority" == "Developer ID Application:"* ]] ||
    fail "Developer ID mode requires a Developer ID Application signature; found: $app_authority"
  [[ "$get_task_allow" != "true" ]] ||
    fail "Developer ID artifact contains com.apple.security.get-task-allow"
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
