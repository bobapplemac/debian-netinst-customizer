# Debian Netinst Customizer

A small build system for creating customized Debian netinst ISOs from the current official Debian installer image.

The project automatically downloads and verifies the latest supported Debian netinst ISO, injects a preseed configuration and OEM files, adds custom GRUB installation entries, verifies the generated image, and retains useful build artifacts for inspection.

## Features

- Automatically checks for the latest Debian netinst ISO
- Downloads and caches official Debian source ISOs
- Verifies downloaded ISOs with SHA-256 checksums
- Optionally verifies Debian's signed checksum files with `gpgv` and `debian-keyring`
- Supports offline builds from previously cached source ISOs
- Validates preseed file formatting before building
- Injects `preseed.cfg` and additional OEM files into the ISO
- Adds automated ext4 and XFS installation entries to the UEFI GRUB menu
- Preserves the standard Debian Installer entries as a fallback
- Verifies the customized ISO after creation
- Generates a SHA-256 checksum for the completed ISO
- Retains per-build GRUB and checksum files for inspection

## Project Layout

```text
debian-netinst-customizer/
├── build-debian-netinst-iso.sh
├── config/
│   ├── preseed.cfg
│   └── OEM/
│       ├── debian.sources
│       ├── update-login-banner.sh
│       └── update-login-banner.service
├── source/
│   └── <debian-version>/
│       ├── debian-<version>-amd64-netinst.iso
│       ├── SHA256SUMS
│       └── SHA256SUMS.sign
├── work/
│   └── <output-name>/
│       ├── grub.cfg
│       └── md5sum.txt
└── output/
    ├── <customized-netinst>.iso
    └── <customized-netinst>.iso.sha256
```

The `source/`, `work/`, and `output/` directories are created automatically as needed.

## Requirements

Required:

- Bash
- `curl`
- `xorriso`

On Debian-based systems:

```bash
sudo apt install curl xorriso
```

Optional:

- `gpgv`
- `debian-keyring`

These allow the build script to authenticate Debian's signed `SHA256SUMS` metadata in addition to verifying the ISO checksum.

```bash
sudo apt install gpgv debian-keyring
```

## Usage

Clone the repository:

```bash
git clone https://github.com/<username>/debian-netinst-customizer.git
cd debian-netinst-customizer
```

Review and customize:

```text
config/preseed.cfg
config/OEM/
```

Then run:

```bash
./build-debian-netinst-iso.sh
```

The completed ISO and its SHA-256 checksum will be written to:

```text
output/
```

For example:

```text
output/debian-13.6.0-amd64-netinst-ajm260824.iso
output/debian-13.6.0-amd64-netinst-ajm260824.iso.sha256
```

## Customization

### Preseed

`config/preseed.cfg` controls the automated Debian installation.

The supplied configuration is designed to remain interactive for selected values such as:

- Hostname
- Domain name
- Root password
- Target installation disk

Comments in the preseed file show how those values can instead be given defaults or fully preseeded.

The root filesystem type is selected from the custom GRUB menu and passed to Debian Installer using:

```text
partman/default_filesystem=ext4
```

or:

```text
partman/default_filesystem=xfs
```

### OEM Files

Files under:

```text
config/OEM/
```

are copied into the generated ISO under:

```text
/OEM/
```

They can be referenced from `preseed.cfg`, including from `preseed/late_command`, to perform additional post-install configuration.

The supplied build configuration expects:

```text
debian.sources
update-login-banner.sh
update-login-banner.service
```

Modify the script's `REQUIRED_OEM_FILES` list if your project uses a different set of required files.

## Source ISO Caching

Official Debian source ISOs and verification metadata are cached by Debian version:

```text
source/<version>/
```

When a newer supported Debian release becomes available, the script downloads and verifies it automatically.

If Debian cannot be reached, the newest cached ISO can be used for an offline build. When cached `SHA256SUMS` metadata is available, the cached ISO is verified before use.

## Working Files

Intermediate files useful for inspection are retained per generated ISO:

```text
work/<output-name>/
```

This currently includes the modified:

```text
grub.cfg
md5sum.txt
```

Transient files used only during the build and verification process are created in a temporary directory and removed automatically.

## Debian Version

The build script is intentionally pinned to a Debian major release and codename.

Before changing the configured Debian version, review the preseed configuration, package repositories, and OEM customization files for compatibility with the new release.

## License

This project is licensed under the Zero-Clause BSD License (`0BSD`).
