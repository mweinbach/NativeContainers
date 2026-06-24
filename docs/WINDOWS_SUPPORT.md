# Windows 11 ARM64 support

NativeContainers has an experimental Windows 11 ARM64 virtual-machine lane
built directly on Apple's `Virtualization.framework`. It accepts normal
Microsoft ARM64 ISO media and retains an exact hashed copy. Because
Virtualization exposes USB mass storage rather than an optical drive, preparation
also builds a UEFI-bootable FAT32 mirror of the ISO. The oversized
`sources/install.wim` is losslessly split into `install.swm`, `install2.swm`,
and any later parts in the same `sources` directory, which Windows Setup supports
for [FAT32 installation media](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/split-a-windows-image--wim--file-to-span-across-multiple-dvds?view=windows-11).
It does not depend on a prebuilt Windows disk.

Secure Boot is off by default in the current bootable mode. The creation UI
exposes a Secure Boot toggle so the product boundary is explicit, but enabling
it disables creation. A second runtime guard prevents an imported or older
Secure Boot manifest from starting. NativeContainers will not weaken that
boundary: the bundled guest-tools contract must name a Microsoft-signed driver
ISO, pass exact size and SHA-256 verification, and mark the stock Windows Secure
Boot installation as release-validated before the Secure Boot path can create
or start a VM.

## Implemented host path

- The importer opens a local regular `.iso` without following a symbolic link,
  streams it into a mode-0600 bundle artifact, verifies that the source did not
  change during the copy, and records its SHA-256 and byte count.
- The copied image is mounted read-only with `diskutil`. Inspection requires a
  nonempty ARM64 PE boot manager at `efi/boot/bootaa64.efi`, plus `boot.wim` and
  `install.wim`.
- Preparation creates a private GPT/FAT32 USB image, copies every ordinary ISO
  file except `install.wim`, and rejects links, special files, duplicate install
  images, or any other file that exceeds FAT32's limit. `wimlib-imagex` splits
  `install.wim` into parts capped at 3,800 MiB; every output part is revalidated
  before the image is committed.
- Preparation creates persistent generic machine identity, a random locally
  administered MAC address, a 32-byte guest-agent secret, EFI NVRAM, a sparse
  VM disk, and the bootable FAT32 setup image in one recoverable bundle
  transaction.
- The same per-VM secret is delivered as a raw 32-byte file on that temporary
  bootable setup image. Guest-tools installation moves it into an ACL-restricted SYSTEM
  location before setup media is ejected; the manifest never contains it.
- The current default leaves Secure Boot disabled and is the only mode allowed
  to create and start a Windows VM.
- The prepared production mode enrolls Apple's default Secure Boot signatures
  and enables Secure Boot with the default platform key on macOS 27 or newer.
  Its creation and runtime gates stay closed until release validation succeeds;
  the enrollment, signed-tools and persisted-NVRAM framework remains in place
  behind that gate.
- The setup disk contains one compatibility exception:
  `BypassTPMCheck`. It does not bypass CPU, RAM, storage, or Secure Boot checks.
  Windows minimums remain 2 CPUs, 4 GiB RAM, and 64 GiB disk.
- The runtime uses EFI, a generic platform, an NVMe system disk, the read-only
  bootable FAT32 installer and verified tools media over USB, VirtIO graphics,
  networking, sound, entropy, ballooning and vsock, plus USB keyboard and
  absolute pointer devices. The exact source ISO remains available for
  provenance but is not attached as a raw disk.
- Windows reuses the generation-pinned VM lifecycle, console, networking,
  compute, disk growth, snapshots, same-host clone, portable transfer, saved
  state, metadata and shared-folder services already used by GUI Linux VMs.
  Windows labels and guidance are guest-specific.
- Finishing installation ejects all removable setup media from the running
  guest and future boots. Guest-tools media then resolves only through the
  verified managed cache.

The development path resolves `wimlib-imagex` first from a future app-bundled
`WindowsTools` resource and then from the standard Apple silicon or Intel
Homebrew locations. A production distribution must pin, license, package, and
verify that helper in the app bundle rather than depending on a mutable host
installation.

## Guest tools and drivers

The companion source repository is
`NativeContainersWindowsGuestTools` (locally at
`/Users/mweinbach/Projects/AppleContainers/NativeContainersWindowsGuestTools`).
Its release artifact is `NCTools.iso`. The source boundary covers:

- ARM64 VirtIO PCI transport dependencies, vsock, graphics, input, network,
  balloon, entropy and VirtioFS integration;
- a NativeContainers `viosnd` WaveRT audio driver, based on the OASIS VirtIO
  sound protocol and Microsoft's SysVAD architecture;
- a least-privilege Windows service and per-user agent for authenticated host
  integration; and
- deterministic packaging, manifest generation, signing checks and ISO layout.

The repository pins the upstream
[`virtio-win`](https://github.com/virtio-win/kvm-guest-drivers-windows) and
[`Windows-driver-samples`](https://github.com/microsoft/Windows-driver-samples)
source revisions instead of silently downloading moving branches. Upstream
licenses and notices remain intact.

Windows kernel drivers require Microsoft dashboard signing for the retail
Secure Boot path. Microsoft recommends HLK-tested dashboard signing for release
drivers; attestation signing is a testing offering and does not make a driver
Windows Certified. NativeContainers therefore keeps both conditions explicit
in its release contract rather than inferring trust from a downloadable file.

## Release contract

`NativeContainers/Resources/WindowsGuestToolsReleaseContract.json` is the only
production input. A release is usable only when all of these are true:

1. the schema version is supported;
2. `isMicrosoftSigned` is true;
3. `isWindowsSecureBootValidated` is true;
4. the artifact URL is HTTPS;
5. the lowercase SHA-256 and positive byte count are present; and
6. the downloaded regular file matches both values exactly.

Downloads first land in a private partial file. Only a verified artifact is
renamed into the versioned Application Support cache. A corrupt cached artifact
is removed and reacquired. When the Secure Boot path is enabled in a future
release, VM creation happens only after this gate, so a failed tools release
leaves no draft VM behind.

## Verification status

The supplied `Win11_25H2_English_Arm64_v2.iso` has a live, read-only media test
that pins its 7,994,415,104-byte size, SHA-256
`638aa2c88e94385b00f4f178d071e3df0b7d9e335577a83bd533b7f2eb65adf0`,
volume label, ARM64 boot manager and WIM layout, then proves the source size and
modification date are unchanged. A separate opt-in lane copies that exact ISO,
creates and validates the 8,137-MiB FAT32 installer with real split WIM parts,
starts it through Virtualization, presents the native console for 45 seconds,
passes pause/resume, force-stops, and proves exact temporary-bundle cleanup.
Deterministic tests cover media rejection, copy integrity, boot-media
replication and splitting, setup-answer policy, bundle round trips, runtime
device configuration, production gating and managed-cache recovery.

An installed Windows desktop, Microsoft-signed custom drivers, HLK results,
host/guest agent interoperability, shared-folder mapping, clipboard, sound,
networking, suspend/restore and the complete Secure Boot release boot are not
yet claimed. The absence of a public Virtualization.framework vTPM device is
also explicit; the narrow TPM setup exception is the compatibility boundary.

## Production release checklist

- Build every kernel and user-mode component for ARM64 with the pinned Windows
  SDK and WDK.
- Run static analysis, Driver Verifier, applicable HLK playlists and the
  repository's protocol/integration tests.
- Submit the exact packages for Microsoft signing and verify every returned
  catalog and binary.
- Build `NCTools.iso`, generate its release manifest, and independently verify
  its bytes and signatures.
- Install the stock pinned Windows ISO with Secure Boot enabled, with no test
  signing or Secure Boot bypass, and complete the device/integration matrix.
- Publish the immutable HTTPS artifact, update the app contract with its exact
  digest and byte count, and set both production booleans only in that commit.
