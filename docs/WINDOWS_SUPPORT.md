# Windows 11 ARM64 support

NativeContainers has an experimental Windows 11 ARM64 virtual-machine lane
built directly on Apple's `Virtualization.framework`. It accepts normal
Microsoft ARM64 ISO media; it does not convert the ISO, extract an installation
image, or depend on a prebuilt Windows disk.

Production creation is deliberately unavailable today. NativeContainers will
not weaken that boundary: the bundled guest-tools contract must name a
Microsoft-signed driver ISO, pass exact size and SHA-256 verification, and mark
the stock Windows Secure Boot installation as release-validated before the
production path can create a VM.

## Implemented host path

- The importer opens a local regular `.iso` without following a symbolic link,
  streams it into a mode-0600 bundle artifact, verifies that the source did not
  change during the copy, and records its SHA-256 and byte count.
- The copied image is mounted read-only with `diskutil`. Inspection requires a
  nonempty ARM64 PE boot manager at `efi/boot/bootaa64.efi`, plus `boot.wim` and
  `install.wim`.
- Preparation creates persistent generic machine identity, a random locally
  administered MAC address, a 32-byte guest-agent secret, EFI NVRAM, a sparse
  VM disk, and a small FAT setup disk in one recoverable bundle transaction.
- The same per-VM secret is delivered as a raw 32-byte file on that temporary
  setup disk. Guest-tools installation moves it into an ACL-restricted SYSTEM
  location before setup media is ejected; the manifest never contains it.
- Production mode enrolls Apple's default Secure Boot signatures and enables
  Secure Boot with the default platform key. It requires macOS 27 or newer.
  Development mode leaves Secure Boot disabled so locally test-signed drivers
  can be brought up without pretending they are production-safe.
- The setup disk contains one compatibility exception:
  `BypassTPMCheck`. It does not bypass CPU, RAM, storage, or Secure Boot checks.
  Windows minimums remain 2 CPUs, 4 GiB RAM, and 64 GiB disk.
- The runtime uses EFI, a generic platform, an NVMe system disk, read-only USB
  installer/setup/tools media, VirtIO graphics, networking, sound, entropy,
  ballooning and vsock, plus USB keyboard and absolute pointer devices.
- Windows reuses the generation-pinned VM lifecycle, console, networking,
  compute, disk growth, snapshots, same-host clone, portable transfer, saved
  state, metadata and shared-folder services already used by GUI Linux VMs.
  Windows labels and guidance are guest-specific.
- Finishing installation ejects all removable setup media from the running
  guest and future boots. Guest-tools media then resolves only through the
  verified managed cache.

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
is removed and reacquired. Production VM creation happens only after this gate,
so a failed tools release leaves no draft VM behind.

## Verification status

The supplied `Win11_25H2_English_Arm64_v2.iso` has a live, read-only media test
that pins its 7,994,415,104-byte size, SHA-256
`638aa2c88e94385b00f4f178d071e3df0b7d9e335577a83bd533b7f2eb65adf0`,
volume label, ARM64 boot manager and WIM layout, then proves the source size and
modification date are unchanged. Deterministic tests cover media rejection,
copy integrity, setup-answer policy, bundle round trips, runtime device
configuration, production gating and managed-cache recovery.

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
