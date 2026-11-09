# VLAN-enabled Debian Installer netcfg backport

## Status

Milestones M0 through M2 are complete. The implementation is a Trixie-native build
of Debian Installer `netcfg` 1.206 with a small, auditable patch series and an
opt-in ISO integration path. The installed system continues to use Debian 13
(Trixie) packages only.

Baseline:

- Repository revision inspected: `f50069be19ec4d77a534eb7fdad5503fd861a094`
- Source image: `debian-13.7.0-amd64-netinst.iso`
- Source image SHA-256:
  `a7ef94ac2fb9a7fec454552abd629b7cc9d5155c886165a45649f5ce6167e355`
- Stock Trixie installer component: `netcfg_1.197_amd64.udeb`
- VLAN-capable upstream source selected: `netcfg` 1.206
- Upstream source tarball SHA-256:
  `75a954694be464732fd815b2f4af2a4546b7a34848e592924a17f6350e165399`

The M0 findings below record the decision made before ISO integration. The M1
implementation and validation results are recorded at the end of this file.

## Existing image architecture

`build-debian-netinst-iso.sh` verifies and caches an official Debian 13
netinst image, injects `/preseed.cfg` and `/OEM`, adds ext4 and XFS entries to
the UEFI GRUB menu, updates `/md5sum.txt`, and remasters with xorriso boot-image
replay. It does not modify the installer initrd.

The custom entries use `auto=true priority=high`, while standard Debian
Installer entries remain present. The preseed selects an interface
automatically, uses network autoconfiguration, and requests
`netcfg/target_network_config=ifupdown`. Hostname, domain, root password, and
installation disk remain interactive.

The netinst boot initrd does not contain `netcfg`. It contains `anna` and the
CD-ROM retriever. The image's `/.disk/udeb_include` names `netcfg`, and `anna`
retrieves it using:

- `/dists/trixie/main/debian-installer/binary-amd64/Packages.gz`
- `/pool/main/n/netcfg/netcfg_1.197_amd64.udeb`

This layout permits a coherent pool and package-index replacement without
rebuilding the initrd.

## Compatibility decision

The official Forky `netcfg_1.206_amd64.udeb` is not a safe drop-in. Its
declared minimum dependencies include `libc6-udeb (>= 2.43)`,
`libdebconfclient0-udeb (>= 0.283)`, and
`libdebian-installer4-udeb (>= 0.128)`. The inspected Trixie image provides
2.41, 0.280, and 0.125 respectively.

The 1.206 executable uses the same library SONAMEs as 1.197 and introduces no
new undefined dynamic symbols relative to 1.197. Its amd64 source build
dependencies are also available in Trixie. A clean rebuild against Trixie is
therefore feasible and avoids importing Forky installer libraries or weakening
udeb dependency metadata.

The build must run in a clean Debian Trixie environment. LMDE 7 is an
acceptable host, but host packages must not determine the final artifact.

## Upstream VLAN behavior

VLAN support was merged in `netcfg` 1.204. Versions 1.205 and 1.206 add Hurd
build fixes, translations, and wording improvements; the Linux VLAN behavior
is otherwise the 1.204 implementation.

For a wired interface, upstream `netcfg`:

1. Selects the physical interface.
2. Optionally asks for a VLAN ID.
3. Creates `<parent>.<id>` using `ip link add ... type vlan id ...`.
4. Runs DHCP or static configuration on the VLAN interface.
5. Writes installer network state to `/etc/network/interfaces`.
6. Copies that file into the target using its base-installer hook.

Wireless interfaces take the wireless path and do not enter the VLAN state.
The Trixie installer provides the BusyBox `ip` applet and its NIC module udeb
contains the 802.1Q kernel module.

Trixie's `ifupdown` 0.8.44+deb13u1 natively recognizes dotted VLAN interface
names and depends on Trixie's `iproute2`. The legacy `vlan` package is not
required. The package is priority `important`, and the existing preseed
explicitly selects ifupdown target configuration.

## Required local patches

The backport should carry a minimal patch series on top of the pristine 1.206
source:

1. **Scoped prompt priority.** Upstream submits `netcfg/use_vlan` at medium
   priority, so it is hidden by the custom entries' `priority=high`. Add an
   internal preseedable gate that promotes only this question to high for the
   custom automated entries. Standard Debian entries retain upstream's
   expert-mode behavior. The default answer remains false.
2. **Invalid-ID handling.** Add a real translated error template, use one
   consistent template name, and fetch the updated `netcfg/vlan_id` value
   after every reprompt. The upstream 1.204-1.206 code references mismatched,
   absent template names and does not fetch the new value inside its retry
   loop.
3. **Clean ifupdown output.** Remove the duplicate physical-parent
   `iface ... manual` stanza emitted for VLAN DHCP configuration.

The valid range remains 1 through 4094. Invalid, empty, and nonnumeric values
must produce an error and reprompt without creating an interface.

## Integration design

Milestone M1 implements the following sequence:

1. Pin and verify the official 1.206 source input.
2. Apply the documented patch series in a clean Trixie build environment.
3. Assign an explicit local Trixie backport version.
4. Verify the built udeb's control metadata and ELF requirements against the
   source ISO.
5. Place the udeb in the ISO pool and replace its entry in `Packages.gz` (the
   netinst image does not carry the uncompressed index).
6. Update all corresponding MD5, SHA-1, SHA-256, and SHA-512 records in the
   image's Trixie `Release` file.
7. Update `/md5sum.txt` for every replaced or added image file.
8. Remaster using the existing xorriso boot-image replay path.
9. Extract the result and verify component version, hashes, indexes,
   dependencies, prompt configuration, and boot metadata.

Integration should initially be opt-in. The stock 1.197 component and existing
build path remain the rollback mechanism.

## Rejected alternatives

- Copying the Forky udeb is rejected because its declared installer-library
  dependencies do not match Trixie.
- Using a Forky installer with a Trixie target is rejected because it enlarges
  the cross-suite compatibility and support surface.
- A separate pre-network dialog and scripting implementation remains a last
  resort because it would duplicate netcfg's interface selection, DHCP/static
  state machine, cleanup, backtracking, and persistence behavior.

## Validation status

Completed during M0:

- Preseed syntax validation.
- Shell syntax validation of the current builder.
- Source and existing custom ISO checksum verification.
- Payload comparison for preseed, GRUB, OEM, and retained checksum files.
- Readability checks of both ISO files.
- Comparison of source and custom hybrid boot metadata.
- Inspection of the initrd, udeb pool, package indexes, kernel modules,
  upstream source tags, binary dependencies, and Trixie ifupdown behavior.

Completed during M1:

- Authenticated and hash-pinned the official `netcfg` 1.206 source.
- Built `netcfg_1.206+deb13vlan1_amd64.udeb` in a clean, rootless Trixie sbuild
  environment pinned to the 2026-11-09 Debian snapshot.
- Passed all 29 upstream and local unit tests.
- Produced byte-identical udebs in the native proof build and clean sbuild;
  SHA-256 is
  `e51168e8df3bf17ee80a12ac6cc9501c7e635d5cf0b562ea92806a6973eb90c6`.
- Verified Trixie-compatible udeb dependencies: libc6-udeb 2.41,
  libdebconfclient0-udeb 0.280, and libdebian-installer4-udeb 0.125 minimums.
- Replaced the pool component and compressed installer package index in an
  opt-in ISO build, updated all four `Release` checksum sections and
  `/md5sum.txt`, and verified the extracted results.
- Replayed and retained the source image's hybrid boot configuration.

Completed during M2 on a disposable VM:

- Booted the modified installer and completed a tagged VLAN 35 installation.
- Confirmed the default untagged path and invalid-ID reprompt behavior.
- Confirmed DHCP on `ens18.35` with no IPv4 address on the physical parent.
- Confirmed `/etc/network/interfaces` persistence, VLAN recreation, and the
  default route through the VLAN after reboot.
