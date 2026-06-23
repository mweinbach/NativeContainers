# Distribution

NativeContainers ships as one Apple-silicon macOS application. The signed
`NativeContainersBuildWorker` executable is embedded once at
`Contents/Helpers/NativeContainersBuildWorker`; it is not installed as a
separate product. Apple’s container runtime is a separately installed,
Apple-signed system prerequisite and is never copied into the app bundle.

## Product contract

- Deployment target: macOS 26 on Apple silicon.
- Architectures: `arm64` only for the app and build worker.
- Version source: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
  `project.yml` and the generated Xcode target settings.
- Hardened runtime: enabled for both signed executables.
- App capabilities: microphone input and virtualization only.
- Build-worker capabilities: none. Development-only signing metadata may be
  injected by Xcode, but the worker must not inherit app capabilities.
- Archive layout: one app under `Products/Applications`, with exactly one
  embedded build worker, no independently installed worker product, and no
  Apple container runtime executables.
- Symbols: the archive contains app and build-worker dSYMs whose UUIDs match
  their corresponding signed executables.
- Container-lane prerequisite: Apple `container` 1.0.0 installed from Apple’s
  signed `com.apple.container-installer` package at `/usr/local`, with the CLI
  signed as `com.apple.container.cli` by team `UPBK2H6LZM`.

## Apple runtime prerequisite

Install Apple `container` 1.0.0 from the
[official signed release](https://github.com/apple/container/releases/tag/1.0.0)
before using containers, images, builds, persistent Apple Linux machines,
Compose, or Kubernetes. Apple’s package installer requires administrator
authorization and owns the CLI, API server, plugins, update/uninstall scripts,
package receipt, and system runtime data.

NativeContainers does not embed, install, update, or re-sign Apple runtime executables.
If the API services are unavailable, Overview links to the exact Apple release
and offers **Start Apple Runtime**. That action validates the root-owned,
single-link, non-group/world-writable CLI and its Apple team/signing identifier,
requires exact version 1.0.0, runs
`container system start --enable-kernel-install`, and verifies both container
and machine endpoints before refreshing inventory. It does not request
administrator privileges or invoke Apple’s installer/updater.

Any future Apple runtime version change must update the Swift package pin,
runtime source contract, docs, and live compatibility evidence in one release.
Run the drift gate before building an archive:

```sh
scripts/validate-runtime-distribution-contract.sh
```

## Create and validate a local archive

1. Validate the external Apple runtime distribution contract:

   ```sh
   scripts/validate-runtime-distribution-contract.sh
   ```

2. Validate the source accessibility contract and release evidence matrix:

   ```sh
   scripts/validate-accessibility-contract.sh
   ```

   This source check does not close the live assistive-technology gate in
   [`ACCESSIBILITY_QA.md`](ACCESSIBILITY_QA.md).

3. Validate that the durable-store inventory and schema contract still match
   source:

   ```sh
   scripts/validate-data-migration-contract.sh
   ```

4. Select the shared `NativeContainers` scheme and `Any Mac (arm64)`.
5. Choose **Product > Archive**. If Xcode offers to add Intel to the custom
   architecture list, choose **Build** to keep the Apple-silicon product
   contract.
6. Validate the resulting archive:

   ```sh
   scripts/validate-distribution-artifact.sh \
     "$HOME/Library/Developer/Xcode/Archives/<date>/NativeContainers <timestamp>.xcarchive"
   ```

The validator rejects a missing or duplicated worker, embedded Apple runtime
payload, non-arm64 code, invalid versions or signatures, a missing
hardened-runtime flag, mismatched signing teams, missing app capabilities, or
any stale broad capability on either executable. Archive mode also rejects
missing or mismatched release symbols.

## User-data compatibility

The product-wide migration and rollback rules are in
[`DATA_MIGRATION.md`](DATA_MIGRATION.md). Version 0.1.0 establishes product data
schema 1 and performs no whole-app migration. Any release that changes a durable
schema must ship the ordered migration, hard-exit recovery, retained rollback
generation, downgrade evidence, and updated contract on the exact release
commit. A marketing-version change alone never authorizes data mutation.

## Developer ID and notarization

A public release requires a valid **Developer ID Application** identity for the
configured team. An Apple Development identity is sufficient for local archive
verification but is not a release identity.

1. Confirm the Developer ID Application certificate and private key are
   available in the signing keychain.
2. Use Xcode Organizer's Developer ID distribution flow to sign the app,
   submit it to Apple's notarization service, export the accepted product, and
   staple the ticket. Do not disable hardened runtime or add signing
   exceptions to make submission pass.
3. Run the strict release gate against the exported, stapled app:

   ```sh
   scripts/validate-distribution-artifact.sh --developer-id \
     "/path/to/NativeContainers.app"
   ```

Strict mode additionally requires Developer ID Application authority, rejects
`get-task-allow` on both executables, runs Gatekeeper assessment, and validates
the stapled ticket. Follow Apple's current
[notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
for account and submission details.

## Current signing prerequisite

The local keychain currently has an Apple Development identity but no Developer
ID Application identity. Local archive readiness is verified; public signing,
notarization, and stapling remain pending until that credential is provisioned.
