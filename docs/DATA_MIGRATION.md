# User-data migration and rollback

NativeContainers treats an application update and a user-data migration as
separate events. Installing a new binary does not authorize a best-effort
rewrite of every file the app can reach. A release may change durable data only
through a reviewed, versioned migration that preserves a tested rollback path.

The current product data schema is **1**. Release `0.1.0` establishes this
baseline and performs no whole-application data migration.

## Ownership classes

### Authoritative app-owned data

These records represent user-created state. A migration must preserve them or
stop before commit.

| Authority | Current location or key | Current schema | Rollback unit |
| --- | --- | ---: | --- |
| macOS and GUI Linux VM library | `~/Library/Application Support/NativeContainers/Virtual Machines` | VM manifest v1 plus independently versioned shared-folder and saved-state metadata | One stopped bundle; copy metadata and changed small artifacts before manifest replacement. Disk payloads are never duplicated merely to change metadata. |
| macOS restore images | `~/Library/Application Support/NativeContainers/Restore Images` | Store layout plus operation journals | One exact image and journal. The completed Caches-to-Application-Support migration deliberately retains the old artifact. |
| Container host-folder selections | `~/Library/Application Support/NativeContainers/Container Host Directories/v1` | Manifest v1 | One operation manifest, including its security-scoped bookmarks. |
| Terminal presets | `UserDefaults` key `terminal.presets.v1` | Envelope v1 | One encoded envelope copied before replacement. |
| Menu-bar preference | `UserDefaults` key `app.menuBarExtra.isInserted` | Scalar | Preserve the prior scalar or remove a newly introduced key. |

Security-scoped bookmarks are opaque data. A migration may copy them byte for
byte, validate that decoding still succeeds, or ask the user to reselect a
folder. It must not synthesize a bookmark or silently broaden access.

### Resumable and inspectable app-owned data

These stores are useful but do not authorize mutation of the resources they
describe. Corrupt or newer records are quarantined or left untouched rather
than guessed into a current shape.

| Authority | Current location | Current schema | Recovery rule |
| --- | --- | ---: | --- |
| Image-build history | `~/Library/Application Support/NativeContainers/Build History/v1` | Envelope v1 | Preserve accepted records; isolate unsupported or corrupt records. History failure never changes a build result. |
| Kubernetes cluster descriptor | `~/Library/Application Support/NativeContainers/Kubernetes` | Descriptor v1 | Preserve exact machine identity and provenance. The descriptor contains no kubeconfig or cluster credential. |
| Compose mutation journal | `~/Library/Application Support/NativeContainers-Compose-Operations` | Journal v3 with read-only v2 recovery | Never convert an in-flight record into executable current intent. Legacy v2 remains manual-only. |
| Field diagnostics | `~/Library/Application Support/NativeContainers/FieldDiagnostics` | Envelope v1 | Preserve valid bounded MetricKit payloads when practical; a bad record is isolated and never uploaded. |

### Replaceable or operation-scoped data

These locations can be recreated from verified inputs. They are excluded from
rollback snapshots unless a specific migration uses one as its transaction
journal.

- `~/Library/Application Support/NativeContainers/Build Contexts`
- `~/Library/Application Support/NativeContainers/Build Artifacts`
- `~/Library/Application Support/NativeContainers/Compose/Projects`
- `~/Library/Application Support/NativeContainers/Compatibility/Socktainer`
- `~/Library/Application Support/NativeContainers/Compatibility/DockerCompose`
- the namespaced app-owned BuildKit cache beneath Apple's builder export root
- `/private/tmp/nativecontainers-<uid>` socket workspaces

Replacement still requires the existing path, owner, type, and boundary checks.
"Replaceable" never means that a migration may follow links, cross mounts, or
delete an unknown sibling.

### External authorities

The following data is observed or referenced by NativeContainers but is not
owned by an app-update migration:

- Apple's `com.apple.container` runtime inventory, images, volumes, networks,
  machines, builder bundle, and service configuration;
- Apple’s signed `container` installer payload and package receipt under `/usr/local`;
- registry credentials in Apple's shared Keychain security domain;
- the product-specific Docker CLI context, the user's Docker configuration, and
  the `~/.socktainer` compatibility socket/process workspace;
- user-selected Compose projects and shared host directories;
- launch-on-login state owned by `SMAppService`;
- notification, microphone, USB-accessory, and other system permission state;
- exported `.nativevm`, OCI, tar, kubeconfig, log, and diagnostic files.

A migration may revalidate an external identity. It may not start, stop, delete,
retag, log out, move, or rewrite an external authority as a side effect of app
upgrade.

## Required migration protocol

Every future product-data schema increment must use these phases:

1. **Preflight** — identify the exact source schema and product version; reject
   unknown newer schemas, links, special files, foreign ownership, invalid
   bounds, active runtime leases, and insufficient free space.
2. **Quiesce** — acquire the same store/runtime lock used by normal mutations.
   A migration never races a build, VM operation, Compose operation, or restore
   download.
3. **Prepare rollback** — copy or clone only the files that the step can change
   into a private, versioned sibling transaction. Record device/inode, hashes or
   complete metadata fingerprints, source and target schema, app build, and the
   ordered step identifier. User-selected external paths and credentials are
   never copied.
4. **Transform in staging** — write a new file or bundle sibling. In-place
   mutation is prohibited unless the format API is itself transactional and its
   recovery contract is documented.
5. **Validate** — decode through the production reader, enforce size/count and
   ownership bounds, and prove all unchanged large artifacts retain their exact
   identity.
6. **Commit** — revalidate the reviewed source and atomically rename or swap the
   staged generation. Synchronize the changed file and parent directory. There
   is no cancellation point after the first committed swap.
7. **Recover or roll back** — on launch, an unfinished journal either removes a
   pre-commit staging generation or restores the sealed prior generation. An
   ambiguous or identity-drifted transaction fails closed and remains available
   for support inspection.
8. **Retain then retire** — retain the rollback generation through at least one
   successful launch of the new build. Retirement is a separate bounded,
   identity-checked cleanup; failure to retire is a warning, not data loss.

Multi-store migrations are ordered transactions, not one filesystem-wide
rename. Each committed store step is recorded durably before the next starts.
If a later step fails, the coordinator rolls back committed reversible steps in
reverse order. A step that cannot be reversed must be split or the release must
provide an explicit export/restore workflow before it is allowed to ship.

## Downgrade and rollback policy

- A binary may open data only when its reader explicitly supports that exact
  schema. Unknown newer schemas are left untouched with a clear incompatibility
  error.
- Additive decoding does not by itself raise the product-data schema. Removing,
  renaming, reinterpreting, or rewriting durable fields does.
- A migration declares the oldest product-data schema that remains readable.
  If the prior release cannot read the committed result, the rollback
  generation must be retained and the release runbook must restore it before
  reinstalling the prior binary.
- VM disks, restore images, and external Apple runtime resources are not rolled
  back merely because the app binary is. Their manifests or references are
  restored only through their store-specific transaction.
- A failed migration must not initialize an empty replacement store, reset
  preferences, delete a newer record, or continue into ordinary mutations.
- Support may copy a retained transaction for diagnosis, but cleanup remains a
  product operation with the same identity checks; users are never instructed
  to delete a broad Application Support directory.

## Release checklist

For every release that changes durable data:

1. Increment the affected store schema and, when compatibility changes across
   stores, the product data schema in this document.
2. Add fixtures for every supported source version, malformed/newer inputs,
   cancellation before commit, hard exit at every journal phase, identity
   drift, full disk, rollback failure, and successful retirement.
3. Prove the prior release can still read the new format, or exercise restoration
   of the retained rollback generation before testing the prior binary.
4. Run `scripts/validate-data-migration-contract.sh` and the full Xcode test
   suite on the exact release commit.
5. Archive a migration inventory and rollback result with the release evidence.
   Never include credentials, bookmark payloads, user paths, VM disk contents,
   or diagnostic payloads in CI logs.
6. Update `docs/STATUS.md`, `docs/FEATURE_MATRIX.md`, `docs/ROADMAP.md`, and the
   relevant ADR before notarization submission.

No current migration is inferred from a marketing-version change alone. Until
a tested step and recovery journal exist, a schema-changing release remains
blocked.
