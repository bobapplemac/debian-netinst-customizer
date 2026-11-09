#!/bin/bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        build-netcfg-backport.sh
# Revision:    r1
# Modified:    2026-11-09
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/debian-netinst-customizer/tools/build-netcfg-backport.sh
# Description: Builds and verifies the VLAN-capable Debian Installer netcfg backport for Debian
#              13 Trixie. Authenticates pinned upstream source, applies the local patch series,
#              builds in either a clean rootless Trixie sbuild environment or a Debian Trixie
#              Docker container, and rejects artifacts that do not match the pinned result.
#
#              Auto mode prefers an existing usable Docker installation and otherwise uses the
#              local sbuild backend. Missing local packages may be installed with APT after
#              confirmation. Docker is never installed automatically.
#
# Requirements:
#              Local backend: Debian 13, LMDE 7, or a compatible APT-based system with
#              unprivileged user namespaces. Required packages are detected at startup.
#              Docker backend: an existing, usable Docker command and daemon.
#
# Output:      work/netcfg-backport/1.206+deb13vlan1/ containing the verified amd64 udeb,
#              checksum, source package, build information, changes, and build log.
#
# Project:
#              patches/netcfg/    Auditable source patch series
#              source/netcfg/     Cached authenticated upstream source
#              source/build-chroots/  Cached rootless Trixie sbuild environment
#              work/netcfg-backport/  Verified build artifacts
#
# Example:
#              ./tools/build-netcfg-backport.sh --backend local
#              ./tools/build-netcfg-backport.sh --backend docker --rebuild
# ------------------------------------------------------------------------------------------

set -euo pipefail

NETCFG_UPSTREAM_VERSION="1.206"
NETCFG_BACKPORT_VERSION="1.206+deb13vlan1"
NETCFG_DSC_SHA256="53df857fd42e32ca62ac3d49d2843ed071244dd050e2a31f3a874ed1eea8fa9b"
NETCFG_SOURCE_SHA256="75a954694be464732fd815b2f4af2a4546b7a34848e592924a17f6350e165399"
NETCFG_UDEB_SHA256="e51168e8df3bf17ee80a12ac6cc9501c7e635d5cf0b562ea92806a6973eb90c6"
DEBIAN_SNAPSHOT="20261109T000000Z"
DEBIAN_MIRROR="https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}"
DOCKER_IMAGE="debian-netinst-netcfg-backport:trixie"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${ROOT_DIR}/source/netcfg/${NETCFG_UPSTREAM_VERSION}"
PATCH_DIR="${ROOT_DIR}/patches/netcfg"
ARTIFACT_DIR="${ROOT_DIR}/work/netcfg-backport/${NETCFG_BACKPORT_VERSION}"
CHROOT_DIR="${ROOT_DIR}/source/build-chroots"
CHROOT_TARBALL="${CHROOT_DIR}/trixie-amd64-${DEBIAN_SNAPSHOT}-sbuild.tar.zst"
DSC_FILE="${CACHE_DIR}/netcfg_${NETCFG_UPSTREAM_VERSION}.dsc"
SOURCE_FILE="${CACHE_DIR}/netcfg_${NETCFG_UPSTREAM_VERSION}.tar.xz"
UPSTREAM_BASE_URL="https://deb.debian.org/debian/pool/main/n/netcfg"
UDEB_ARTIFACT="${ARTIFACT_DIR}/netcfg_${NETCFG_BACKPORT_VERSION}_amd64.udeb"

BUILD_BACKEND="${NETCFG_BUILD_BACKEND:-auto}"
INSTALL_MISSING="${INSTALL_MISSING_PACKAGES:-ask}"
NON_INTERACTIVE=false
FORCE_REBUILD=false
TEMP_DIR=""

usage()
{
    cat <<'EOF'
Usage: tools/build-netcfg-backport.sh [options]

Options:
  --backend auto|local|docker  Select the build backend (default: auto).
  --install-missing           Install missing local build packages without asking.
  --no-install                Never offer to install missing packages.
  --non-interactive           Disable all prompts.
  --rebuild                   Rebuild even when the verified udeb already exists.
  -h, --help                  Show this help.

Environment equivalents:
  NETCFG_BUILD_BACKEND=auto|local|docker
  INSTALL_MISSING_PACKAGES=ask|yes|no

Auto mode prefers Docker when a working Docker daemon is available. Otherwise
it uses a rootless local Trixie sbuild environment.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)
            [[ $# -ge 2 ]] || { echo "ERROR: --backend requires a value." >&2; exit 2; }
            BUILD_BACKEND="$2"
            shift 2
            ;;
        --install-missing)
            INSTALL_MISSING=yes
            shift
            ;;
        --no-install)
            INSTALL_MISSING=no
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "${BUILD_BACKEND}" in
    auto|local|docker|direct) ;;
    *) echo "ERROR: Build backend must be auto, local, or docker." >&2; exit 2 ;;
esac

case "${INSTALL_MISSING}" in
    ask|yes|no) ;;
    *) echo "ERROR: INSTALL_MISSING_PACKAGES must be ask, yes, or no." >&2; exit 2 ;;
esac

if [[ "${BUILD_BACKEND}" == direct && "${NETCFG_BUILD_CONTAINER:-false}" != true ]]; then
    echo "ERROR: The direct backend is reserved for the managed Docker container." >&2
    exit 2
fi

cleanup()
{
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ask_yes_no()
{
    local prompt="$1"
    local default="$2"
    local answer=""
    local suffix="[y/N]"

    if [[ "${default}" == yes ]]; then
        suffix="[Y/n]"
    fi

    if [[ "${NON_INTERACTIVE}" == true || ! -t 0 ]]; then
        [[ "${default}" == yes ]]
        return
    fi

    read -r -p "${prompt} ${suffix} " answer
    case "${answer}" in
        y|Y|yes|YES) return 0 ;;
        n|N|no|NO) return 1 ;;
        '') [[ "${default}" == yes ]] ;;
        *) echo "Please answer yes or no."; ask_yes_no "${prompt}" "${default}" ;;
    esac
}

verify_sha256()
{
    local file="$1"
    local expected="$2"
    local actual=""

    actual="$(sha256sum "${file}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "ERROR: SHA-256 verification failed for ${file}." >&2
        echo "  Expected: ${expected}" >&2
        echo "  Actual:   ${actual}" >&2
        exit 1
    fi
}

artifact_is_valid()
{
    [[ -f "${UDEB_ARTIFACT}" ]] || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    command -v dpkg-deb >/dev/null 2>&1 || return 1
    [[ "$(sha256sum "${UDEB_ARTIFACT}" | awk '{print $1}')" == "${NETCFG_UDEB_SHA256}" ]] || return 1
    [[ "$(dpkg-deb -f "${UDEB_ARTIFACT}" Version)" == "${NETCFG_BACKPORT_VERSION}" ]]
}

if [[ "${FORCE_REBUILD}" == false ]] && artifact_is_valid; then
    echo "Reusing verified netcfg backport:"
    echo "  ${UDEB_ARTIFACT}"
    exit 0
fi

docker_is_usable()
{
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

if [[ "${BUILD_BACKEND}" == auto ]]; then
    if docker_is_usable; then
        if ask_yes_no "Docker is available. Build netcfg in Docker?" yes; then
            BUILD_BACKEND=docker
        else
            BUILD_BACKEND=local
        fi
    else
        BUILD_BACKEND=local
    fi
fi

if [[ "${BUILD_BACKEND}" == docker ]]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: Docker is not installed. Install it yourself or use --backend local." >&2
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: Docker is installed, but its daemon is not accessible." >&2
        echo "Use --backend local or correct Docker access; this script will not install Docker." >&2
        exit 1
    fi

    echo "Building the Trixie netcfg build image..."
    docker build \
        --file "${ROOT_DIR}/tools/Dockerfile.netcfg-backport" \
        --tag "${DOCKER_IMAGE}" \
        "${ROOT_DIR}/tools"

    DOCKER_ARGS=(
        run --rm
        --user "$(id -u):$(id -g)"
        --env HOME=/tmp/netcfg-builder
        --env NETCFG_BUILD_CONTAINER=true
        --volume "${ROOT_DIR}:/workspace"
        --workdir /workspace
        "${DOCKER_IMAGE}"
        ./tools/build-netcfg-backport.sh
        --backend direct
        --non-interactive
    )
    if [[ "${FORCE_REBUILD}" == true ]]; then
        DOCKER_ARGS+=(--rebuild)
    fi

    docker "${DOCKER_ARGS[@]}"
    exit 0
fi

LOCAL_PACKAGES=(
    curl devscripts debhelper debian-keyring
    build-essential fakeroot patch binutils xz-utils gzip
    po-debconf libiw-dev check libsubunit-dev
    libdebconfclient0-dev libdebian-installer4-dev
)

REQUIRED_COMMANDS=(
    awk curl dpkg-buildpackage dpkg-deb dpkg-parsechangelog dpkg-source
    dscverify patch readelf sha256sum
)
if [[ "${BUILD_BACKEND}" == local ]]; then
    LOCAL_PACKAGES+=(sbuild mmdebstrap zstd)
    REQUIRED_COMMANDS+=(sbuild sbuild-createchroot)
fi

MISSING_COMMANDS=()
for COMMAND in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "${COMMAND}" >/dev/null 2>&1; then
        MISSING_COMMANDS+=("${COMMAND}")
    fi
done

MISSING_PACKAGES=()
if command -v dpkg-query >/dev/null 2>&1; then
    for PACKAGE in "${LOCAL_PACKAGES[@]}"; do
        if [[ "$(dpkg-query -W -f='${db:Status-Status}' "${PACKAGE}" 2>/dev/null || true)" != installed ]]; then
            MISSING_PACKAGES+=("${PACKAGE}")
        fi
    done
fi

if (( ${#MISSING_COMMANDS[@]} > 0 || ${#MISSING_PACKAGES[@]} > 0 )); then
    if (( ${#MISSING_COMMANDS[@]} > 0 )); then
        echo "Missing commands required for the ${BUILD_BACKEND} build:"
        printf '  %s\n' "${MISSING_COMMANDS[@]}"
    fi
    if (( ${#MISSING_PACKAGES[@]} > 0 )); then
        echo "Missing Debian packages required for the ${BUILD_BACKEND} build:"
        printf '  %s\n' "${MISSING_PACKAGES[@]}"
    fi

    INSTALL=false
    if [[ "${INSTALL_MISSING}" == yes ]]; then
        INSTALL=true
    elif [[ "${INSTALL_MISSING}" == ask ]] && ask_yes_no "Install the required build packages with apt?" no; then
        INSTALL=true
    fi

    if [[ "${INSTALL}" != true ]]; then
        echo "ERROR: Required build tools are missing." >&2
        echo "Install: ${LOCAL_PACKAGES[*]}" >&2
        exit 1
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "ERROR: Automatic package installation requires apt-get." >&2
        exit 1
    fi

    APT_PREFIX=()
    if [[ ${EUID} -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || { echo "ERROR: sudo is required to install packages." >&2; exit 1; }
        APT_PREFIX=(sudo)
    fi

    "${APT_PREFIX[@]}" apt-get update
    "${APT_PREFIX[@]}" apt-get install -y "${LOCAL_PACKAGES[@]}"
fi

for COMMAND in "${REQUIRED_COMMANDS[@]}"; do
    command -v "${COMMAND}" >/dev/null 2>&1 || { echo "ERROR: Required command still missing: ${COMMAND}" >&2; exit 1; }
done

download_if_missing()
{
    local url="$1"
    local destination="$2"
    local expected="$3"
    local partial="${destination}.part"

    if [[ -f "${destination}" ]]; then
        verify_sha256 "${destination}" "${expected}"
        return
    fi

    rm -f "${partial}"
    curl --fail --location --retry 3 --retry-all-errors --retry-delay 2 \
        --output "${partial}" "${url}"
    verify_sha256 "${partial}" "${expected}"
    mv "${partial}" "${destination}"
}

mkdir -p "${HOME}" "${CACHE_DIR}" "${ARTIFACT_DIR}" "${CHROOT_DIR}"

download_if_missing \
    "${UPSTREAM_BASE_URL}/netcfg_${NETCFG_UPSTREAM_VERSION}.dsc" \
    "${DSC_FILE}" \
    "${NETCFG_DSC_SHA256}"
download_if_missing \
    "${UPSTREAM_BASE_URL}/netcfg_${NETCFG_UPSTREAM_VERSION}.tar.xz" \
    "${SOURCE_FILE}" \
    "${NETCFG_SOURCE_SHA256}"

echo "Authenticating upstream source..."
dscverify "${DSC_FILE}"

TEMP_DIR="$(mktemp -d)"
SOURCE_BUILD_DIR="${TEMP_DIR}/source"
RESULT_DIR="${TEMP_DIR}/result"
mkdir -p "${RESULT_DIR}"

dpkg-source -x "${DSC_FILE}" "${SOURCE_BUILD_DIR}"

while IFS= read -r -d '' PATCH_FILE; do
    echo "Applying $(basename "${PATCH_FILE}")..."
    patch --directory="${SOURCE_BUILD_DIR}" --strip=1 < "${PATCH_FILE}"
done < <(find "${PATCH_DIR}" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z)

ACTUAL_VERSION="$(dpkg-parsechangelog -l"${SOURCE_BUILD_DIR}/debian/changelog" -SVersion)"
if [[ "${ACTUAL_VERSION}" != "${NETCFG_BACKPORT_VERSION}" ]]; then
    echo "ERROR: Patched source version is ${ACTUAL_VERSION}; expected ${NETCFG_BACKPORT_VERSION}." >&2
    exit 1
fi

echo "Creating source package..."
(
    cd "${SOURCE_BUILD_DIR}"
    dpkg-buildpackage -us -uc -S
)

BACKPORT_DSC="${TEMP_DIR}/netcfg_${NETCFG_BACKPORT_VERSION}.dsc"
if [[ ! -f "${BACKPORT_DSC}" ]]; then
    echo "ERROR: Backport source package was not created." >&2
    exit 1
fi

if [[ "${BUILD_BACKEND}" == local ]]; then
    if [[ ! -f "${CHROOT_TARBALL}" ]]; then
        CHROOT_BUILD_DIR="/tmp/netcfg-sbuild-${DEBIAN_SNAPSHOT}-$$"
        if [[ -e "${CHROOT_BUILD_DIR}" ]]; then
            echo "ERROR: Refusing to reuse temporary chroot path ${CHROOT_BUILD_DIR}." >&2
            exit 1
        fi

        echo "Creating clean Trixie sbuild environment from ${DEBIAN_MIRROR}..."
        sbuild-createchroot \
            --chroot-mode=unshare \
            --arch=amd64 \
            --no-deb-src \
            --make-sbuild-tarball="${CHROOT_TARBALL}" \
            trixie \
            "${CHROOT_BUILD_DIR}" \
            "${DEBIAN_MIRROR}"
    fi

    echo "Building netcfg ${NETCFG_BACKPORT_VERSION} in clean Trixie sbuild..."
    (
        cd "${RESULT_DIR}"
        sbuild \
            --chroot-mode=unshare \
            --chroot="${CHROOT_TARBALL}" \
            --dist=trixie \
            --arch=amd64 \
            --enable-network \
            --no-run-lintian \
            "${BACKPORT_DSC}"
    )
else
    echo "Building netcfg ${NETCFG_BACKPORT_VERSION} in the Trixie container..."
    (
        cd "${SOURCE_BUILD_DIR}"
        dpkg-buildpackage -us -uc -b
    )
    find "${TEMP_DIR}" -maxdepth 1 -type f -exec cp -t "${RESULT_DIR}" '{}' +
fi

UDEB_FILE="${RESULT_DIR}/netcfg_${NETCFG_BACKPORT_VERSION}_amd64.udeb"
if [[ ! -f "${UDEB_FILE}" ]]; then
    echo "ERROR: Expected netcfg udeb was not produced." >&2
    exit 1
fi

verify_sha256 "${UDEB_FILE}" "${NETCFG_UDEB_SHA256}"

if [[ "$(dpkg-deb -f "${UDEB_FILE}" Version)" != "${NETCFG_BACKPORT_VERSION}" ]]; then
    echo "ERROR: Built udeb has an unexpected version." >&2
    exit 1
fi

UDEB_ROOT="${TEMP_DIR}/udeb-root"
UDEB_CONTROL="${TEMP_DIR}/udeb-control"
mkdir -p "${UDEB_ROOT}" "${UDEB_CONTROL}"
dpkg-deb -x "${UDEB_FILE}" "${UDEB_ROOT}"
dpkg-deb -e "${UDEB_FILE}" "${UDEB_CONTROL}"

for TEMPLATE in netcfg/ask_vlan netcfg/use_vlan netcfg/vlan_id netcfg/invalid_vlan; do
    if ! grep -Fqx "Template: ${TEMPLATE}" "${UDEB_CONTROL}/templates"; then
        echo "ERROR: Built udeb is missing debconf template ${TEMPLATE}." >&2
        exit 1
    fi
done

if readelf --version-info "${UDEB_ROOT}/usr/bin/netcfg" | grep -Eq 'GLIBC_2\.(4[2-9]|[5-9][0-9])'; then
    echo "ERROR: Built netcfg requires a glibc version newer than Trixie." >&2
    exit 1
fi

install -m 0644 "${UDEB_FILE}" "${ARTIFACT_DIR}/"
for PATTERN in \
    "netcfg_${NETCFG_BACKPORT_VERSION}_amd64.buildinfo" \
    "netcfg_${NETCFG_BACKPORT_VERSION}_amd64.changes" \
    '*.build'; do
    find "${RESULT_DIR}" -maxdepth 1 -type f -name "${PATTERN}" \
        -exec install -m 0644 '{}' "${ARTIFACT_DIR}/" ';'
done
install -m 0644 "${TEMP_DIR}/netcfg_${NETCFG_BACKPORT_VERSION}.dsc" "${ARTIFACT_DIR}/"
install -m 0644 "${TEMP_DIR}/netcfg_${NETCFG_BACKPORT_VERSION}.tar.xz" "${ARTIFACT_DIR}/"

sha256sum "${UDEB_ARTIFACT}" > "${UDEB_ARTIFACT}.sha256"

echo
echo "Verified backport artifact:"
echo "  ${UDEB_ARTIFACT}"
