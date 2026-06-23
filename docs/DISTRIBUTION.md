# Distribution

NativeContainers ships as one Apple-silicon macOS application. The signed
`NativeContainersBuildWorker` executable is embedded once at
`Contents/Helpers/NativeContainersBuildWorker`; it is not installed as a
separate product. Runtime payloads are never copied into the app bundle. The
ordinary lane uses Apple’s separately installed signed runtime; conditional
machine snapshots and build SSH use a separately distributed NativeContainers
runtime package that the app also does not install.

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
- Runtime prerequisite: either Apple `container` 1.0.0 from signed package
  `com.apple.container-installer` under `/usr/local`, or the separately signed,
  notarized, and stapled NativeContainers `1.0.0-nc.2` package under
  `/Library/Application Support/NativeContainers/Runtime/1.0.0-nc.2`. Only one
  compatible service graph may be active.

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

## NativeContainers runtime package

The sibling `container` fork is pinned at `1.0.0-nc.2` and the sibling
`container-builder-shim` fork at `0.12.0-nc.2` revision
`f66f1680fe6b74d814fb5527247e7d81227fcecb`. The package owns only its
versioned NativeContainers install root and carries a Linux/arm64 OCI archive
with SHA-256
`d872daa5ff4534aeb18fb747e015e56cef1cd1b584e05d725b72b624b41a7680` whose
required image digest is
`sha256:b3574dc6b867fc91d1ed1d2941c74811961e2645ffa4c1fc68c19ae69e5fdbff`.
The digest gate resolves through Apple ImageStore's synthetic indirect index and
compares the underlying image-manifest descriptor.
The package also installs the root-owned `etc/container/config.toml` with exact
SHA-256 `15d02e3707d200579e23f03cf883bc8980a9dc4bfc3ea4f6e09224b17737892a`;
activation verifies it before connecting to the native service graph.
It retains Apple-compatible Mach service names, so installation does not start
or register it and activation is mutually exclusive with Apple’s graph.

Build the fork binaries through Xcode, then run its fail-closed release packaging
script with the exact prebuilt binary directory, verified builder OCI archive,
Developer ID Application identity, Developer ID Installer identity, notary
keychain profile, output directory, and an explicit
`NativeRuntimeReleaseContract.json` output path. The script stages only reviewed paths,
signs and verifies every runtime executable, builds and signs package
`com.nativecontainers.runtime`, submits it with `notarytool --wait`, staples it,
and verifies the package signature and ticket. Only after those code-signature
checks does it generate and canonically reverify the six signed-binary SHA-256
values plus the exact runtime/builder identity consumed by the app. The app
never invokes this script or Installer.

The checked-in app resource is deliberately a schema-0 fail-closed placeholder.
For a coordinated Developer ID release, point the runtime packaging command's
contract output at `NativeContainers/Resources/NativeRuntimeReleaseContract.json`
before archiving and sign the app only after the generated schema-1 contract is
present. Do not hand-edit or synthesize this file. A source/development archive
with the placeholder continues to support the verified official Apple runtime,
but cannot enable machine snapshots or build SSH.

After manual installation, NativeContainers verifies the package receipt,
version, artifact digests, signing team/identifiers, builder metadata, service
executable paths, and active launch graph before enabling snapshots or build
SSH. Source builds, ad-hoc signatures, and Apple Development signatures do not
satisfy this gate.

## Create and validate a local archive

1. Validate the dual-runtime distribution contract:

   ```sh
   scripts/validate-runtime-distribution-contract.sh
   ```

2. Validate that availability and coverage claims still match source:

   ```sh
   scripts/validate-capability-claims.sh
   ```

3. Validate the source accessibility contract and release evidence matrix:

   ```sh
   scripts/validate-accessibility-contract.sh
   ```

   This source check does not close the live assistive-technology gate in
   [`ACCESSIBILITY_QA.md`](ACCESSIBILITY_QA.md).

4. Validate that the durable-store inventory and schema contract still match
   source:

   ```sh
   scripts/validate-data-migration-contract.sh
   ```

5. Select the shared `NativeContainers` scheme and `Any Mac (arm64)`.
6. Choose **Product > Archive**. If Xcode offers to add Intel to the custom
   architecture list, choose **Build** to keep the Apple-silicon product
   contract.
7. Validate the resulting archive:

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
ID Application or Developer ID Installer identity, and no
`NativeContainers-notary` keychain profile. Local archive readiness can be
verified; public app signing and the separate runtime package’s signing,
notarization, and stapling remain pending until those credentials are
provisioned.
