#!/bin/bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        build-debian-netinst-iso.sh
# Revision:    r13
# Modified:    2026-11-09
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/debian-netinst-customizer
# Description: Creates a customized Debian amd64 netinst ISO using the newest stock Debian
#              netinst ISO and customization files stored under ./config. Optionally builds and
#              integrates a Trixie-compatible VLAN-aware netcfg installer component. Downloads
#              and caches verified source material under ./source, retains inspectable build
#              files under ./work, and writes completed images to ./output.
#
#              Interactive prompts and command-line/environment controls select VLAN support,
#              missing-package installation, the netcfg build backend, and the output tag. The
#              customized ISO includes automated ext4 and XFS entries in the UEFI GRUB menu.
#
# Requirements:
#              Required Debian packages are detected at startup and may be installed with APT
#              after confirmation. Docker, when selected for the optional netcfg backport, must
#              already be installed and usable.
#
# Output:      Same filename as the source ISO with "-<tag>YYMMDD" appended, plus a SHA256
#              checksum file for the customized ISO. The build tag defaults to "custom" and may
#              be overridden with the OUTPUT_TAG environment variable.
#
# Project:
#              config/    Customization inputs (preseed.cfg and OEM/)
#              source/    Cached stock Debian ISOs and Debian verification metadata
#              work/      Per-output intermediate files retained for inspection
#              output/    Completed customized ISOs and SHA256 checksum files
#
# Example:
#              source/13.7.0/debian-13.7.0-amd64-netinst.iso
#                  -> output/debian-13.7.0-amd64-netinst-custom261109.iso
#                  -> output/debian-13.7.0-amd64-netinst-custom261109.iso.sha256
#                  -> work/debian-13.7.0-amd64-netinst-custom261109/
# ------------------------------------------------------------------------------------------

set -euo pipefail

DEBIAN_MAJOR_VERSION=13
DEBIAN_CODENAME="trixie"
DEBIAN_ISO_BASE_URL="https://get.debian.org/cdimage/release/current/amd64/iso-cd"

# Build tag appended to customized ISO filenames. Override at runtime with OUTPUT_TAG=<tag>.
OUTPUT_TAG="${OUTPUT_TAG:-custom}"

# These may be selected by command-line option, environment, or interactive prompt.
ENABLE_VLAN_NETCFG="${ENABLE_VLAN_NETCFG:-}"
NETCFG_BUILD_BACKEND="${NETCFG_BUILD_BACKEND:-auto}"
INSTALL_MISSING="${INSTALL_MISSING_PACKAGES:-ask}"
NON_INTERACTIVE=false
FORCE_NETCFG_REBUILD=false
NETCFG_BACKPORT_VERSION="1.206+deb13vlan1"
NETCFG_BACKPORT_SHA256="e51168e8df3bf17ee80a12ac6cc9501c7e635d5cf0b562ea92806a6973eb90c6"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"
SOURCE_DIR="${ROOT_DIR}/source"
WORK_DIR="${ROOT_DIR}/work"
OUTPUT_DIR="${ROOT_DIR}/output"
NETCFG_BACKPORT_UDEB="${ROOT_DIR}/work/netcfg-backport/${NETCFG_BACKPORT_VERSION}/netcfg_${NETCFG_BACKPORT_VERSION}_amd64.udeb"
NETCFG_BACKPORT_BUILDER="${ROOT_DIR}/tools/build-netcfg-backport.sh"

PRESEED_FILE="${CONFIG_DIR}/preseed.cfg"
OEM_DIR="${CONFIG_DIR}/OEM"

REQUIRED_OEM_FILES=(
    "debian.sources"
    "update-login-banner.sh"
    "update-login-banner.service"
)

TEMP_DIR=""
TEMP_ISO=""

usage()
{
    cat <<'EOF'
Usage: ./build-debian-netinst-iso.sh [options]

Options:
  --vlan                         Include the Trixie VLAN-capable netcfg backport.
  --no-vlan                      Use the stock Debian 13 netcfg component.
  --netcfg-backend auto|local|docker
                                 Select how the backport is built (default: auto).
  --rebuild-netcfg               Force a fresh netcfg backport build.
  --output-tag TAG               Set the output filename tag (default: custom).
  --install-missing              Install missing apt packages without asking.
  --no-install                   Never offer to install missing packages.
  --non-interactive              Disable all prompts.
  -h, --help                     Show this help.

Environment equivalents:
  ENABLE_VLAN_NETCFG=true|false
  NETCFG_BUILD_BACKEND=auto|local|docker
  OUTPUT_TAG=custom
  INSTALL_MISSING_PACKAGES=ask|yes|no

With no VLAN option or environment setting, an interactive run asks whether
to include VLAN support. A non-interactive run defaults to the stock component.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vlan)
            ENABLE_VLAN_NETCFG=true
            shift
            ;;
        --no-vlan)
            ENABLE_VLAN_NETCFG=false
            shift
            ;;
        --netcfg-backend)
            [[ $# -ge 2 ]] || { echo "ERROR: --netcfg-backend requires a value." >&2; exit 2; }
            NETCFG_BUILD_BACKEND="$2"
            shift 2
            ;;
        --rebuild-netcfg)
            FORCE_NETCFG_REBUILD=true
            shift
            ;;
        --output-tag)
            [[ $# -ge 2 ]] || { echo "ERROR: --output-tag requires a value." >&2; exit 2; }
            OUTPUT_TAG="$2"
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

case "${NETCFG_BUILD_BACKEND}" in
    auto|local|docker) ;;
    *) echo "ERROR: netcfg backend must be auto, local, or docker." >&2; exit 2 ;;
esac

case "${INSTALL_MISSING}" in
    ask|yes|no) ;;
    *) echo "ERROR: INSTALL_MISSING_PACKAGES must be ask, yes, or no." >&2; exit 2 ;;
esac

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

if [[ -z "${ENABLE_VLAN_NETCFG}" ]]; then
    if [[ "${NON_INTERACTIVE}" == true || ! -t 0 ]]; then
        ENABLE_VLAN_NETCFG=false
        echo "Non-interactive build: using stock Debian netcfg (pass --vlan to include VLAN support)."
    elif ask_yes_no "Include interactive VLAN configuration in the Debian 13 installer?" yes; then
        ENABLE_VLAN_NETCFG=true
    else
        ENABLE_VLAN_NETCFG=false
    fi
fi

case "${ENABLE_VLAN_NETCFG}" in
    true|false) ;;
    *) echo "ERROR: ENABLE_VLAN_NETCFG must be either true or false." >&2; exit 2 ;;
esac

cleanup()
{
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi

    if [[ -n "${TEMP_ISO}" && -f "${TEMP_ISO}" ]]; then
        rm -f "${TEMP_ISO}"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


# ------------------------------------------------------------------------------------------
# Verify prerequisites and build inputs
# ------------------------------------------------------------------------------------------

REQUIRED_HOST_PACKAGES=(curl xorriso gpgv debian-keyring)
REQUIRED_HOST_COMMANDS=(curl xorriso gpgv)

if [[ "${ENABLE_VLAN_NETCFG}" == true ]]; then
    REQUIRED_HOST_PACKAGES+=(dpkg gzip)
    REQUIRED_HOST_COMMANDS+=(dpkg-deb gzip)
fi

MISSING_HOST_ITEMS=()
for COMMAND in "${REQUIRED_HOST_COMMANDS[@]}"; do
    if ! command -v "${COMMAND}" >/dev/null 2>&1; then
        MISSING_HOST_ITEMS+=("${COMMAND}")
    fi
done
if [[ ! -f /usr/share/keyrings/debian-role-keys.pgp &&
      ! -f /usr/share/keyrings/debian-role-keys.gpg ]]; then
    MISSING_HOST_ITEMS+=(debian-keyring)
fi

MISSING_HOST_PACKAGES=()
if command -v dpkg-query >/dev/null 2>&1; then
    for PACKAGE in "${REQUIRED_HOST_PACKAGES[@]}"; do
        if [[ "$(dpkg-query -W -f='${db:Status-Status}' "${PACKAGE}" 2>/dev/null || true)" != installed ]]; then
            MISSING_HOST_PACKAGES+=("${PACKAGE}")
        fi
    done
fi

if (( ${#MISSING_HOST_ITEMS[@]} > 0 || ${#MISSING_HOST_PACKAGES[@]} > 0 )); then
    if (( ${#MISSING_HOST_ITEMS[@]} > 0 )); then
        echo "Missing commands or keyring files required by the ISO builder:"
        printf '  %s\n' "${MISSING_HOST_ITEMS[@]}"
    fi
    if (( ${#MISSING_HOST_PACKAGES[@]} > 0 )); then
        echo "Missing Debian packages required by the ISO builder:"
        printf '  %s\n' "${MISSING_HOST_PACKAGES[@]}"
    fi

    INSTALL=false
    if [[ "${INSTALL_MISSING}" == yes ]]; then
        INSTALL=true
    elif [[ "${INSTALL_MISSING}" == ask ]] && ask_yes_no "Install the required packages with apt?" no; then
        INSTALL=true
    fi

    if [[ "${INSTALL}" != true ]]; then
        echo "ERROR: Required ISO build tools are missing." >&2
        echo "Install: ${REQUIRED_HOST_PACKAGES[*]}" >&2
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
    "${APT_PREFIX[@]}" apt-get install -y "${REQUIRED_HOST_PACKAGES[@]}"
fi

for COMMAND in "${REQUIRED_HOST_COMMANDS[@]}"; do
    command -v "${COMMAND}" >/dev/null 2>&1 || { echo "ERROR: Required command still missing: ${COMMAND}" >&2; exit 1; }
done

if [[ "${ENABLE_VLAN_NETCFG}" == true ]]; then
    if [[ ! -x "${NETCFG_BACKPORT_BUILDER}" ]]; then
        echo "ERROR: netcfg backport builder is missing or not executable:" >&2
        echo "  ${NETCFG_BACKPORT_BUILDER}" >&2
        exit 1
    fi

    NETCFG_BUILD_ARGS=(--backend "${NETCFG_BUILD_BACKEND}")
    case "${INSTALL_MISSING}" in
        yes) NETCFG_BUILD_ARGS+=(--install-missing) ;;
        no) NETCFG_BUILD_ARGS+=(--no-install) ;;
    esac
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        NETCFG_BUILD_ARGS+=(--non-interactive)
    fi
    if [[ "${FORCE_NETCFG_REBUILD}" == true ]]; then
        NETCFG_BUILD_ARGS+=(--rebuild)
    fi

    echo "Preparing the VLAN-capable Debian 13 netcfg backport..."
    "${NETCFG_BACKPORT_BUILDER}" "${NETCFG_BUILD_ARGS[@]}"

    if [[ ! -f "${NETCFG_BACKPORT_UDEB}" ]]; then
        echo "ERROR: VLAN-capable netcfg backport was not produced:" >&2
        echo "  ${NETCFG_BACKPORT_UDEB}" >&2
        exit 1
    fi

    ACTUAL_NETCFG_SHA256="$(sha256sum "${NETCFG_BACKPORT_UDEB}" | awk '{print $1}')"
    if [[ "${ACTUAL_NETCFG_SHA256}" != "${NETCFG_BACKPORT_SHA256}" ]]; then
        echo "ERROR: VLAN-capable netcfg backport failed SHA256 verification."
        echo "  Expected: ${NETCFG_BACKPORT_SHA256}"
        echo "  Actual:   ${ACTUAL_NETCFG_SHA256}"
        exit 1
    fi

    if [[ "$(dpkg-deb -f "${NETCFG_BACKPORT_UDEB}" Version)" != "${NETCFG_BACKPORT_VERSION}" ]]; then
        echo "ERROR: VLAN-capable netcfg backport has an unexpected package version."
        exit 1
    fi
fi

if [[ ! -f "${PRESEED_FILE}" ]]; then
    echo "ERROR: preseed.cfg was not found:"
    echo "  ${PRESEED_FILE}"
    exit 1
fi

if [[ ! -d "${OEM_DIR}" ]]; then
    echo "ERROR: OEM directory was not found:"
    echo "  ${OEM_DIR}"
    exit 1
fi

for FILE in "${REQUIRED_OEM_FILES[@]}"; do
    if [[ ! -f "${OEM_DIR}/${FILE}" ]]; then
        echo "ERROR: Required OEM file was not found:"
        echo "  ${OEM_DIR}/${FILE}"
        exit 1
    fi
done

# Ensure the installed APT sources remain pinned to the Debian release this build targets.
if ! awk -v codename="${DEBIAN_CODENAME}" '
    $1 == "Suites:" {
        seen = 1

        for (i = 2; i <= NF; i++) {
            if ($i != codename &&
                $i != codename "-updates" &&
                $i != codename "-security") {
                bad = 1
            }
        }
    }

    END {
        exit !(seen && !bad)
    }
' "${OEM_DIR}/debian.sources"; then
    echo "ERROR: OEM/debian.sources contains suites that do not match Debian ${DEBIAN_MAJOR_VERSION} (${DEBIAN_CODENAME})."
    exit 1
fi

validate_preseed_format()
{
    local file="$1"
    local raw_line=""
    local line=""
    local logical_line=""
    local line_number=0
    local logical_start=0
    local continued=false
    local owner=""
    local question=""
    local type=""
    local value=""
    local valid=true

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        line_number=$((line_number + 1))

        # Remove CR and ignore comment-only lines.
        line="${raw_line%$'\r'}"

        if [[ "${line}" =~ ^[[:space:]]*# ]]; then
            line=""
        fi

        if [[ -z "${logical_line}" ]]; then
            logical_start=${line_number}
        fi

        # Join preseed continuation lines before validating the logical entry.
        if [[ "${line}" == *\\ ]]; then
            logical_line+="${line%\\}"
            continued=true
            continue
        fi

        logical_line+="${line}"
        continued=false

        # Ignore blank/comment-only logical lines.
        if [[ "${logical_line}" =~ ^[[:space:]]*$ ]]; then
            logical_line=""
            logical_start=0
            continue
        fi

        owner=""
        question=""
        type=""
        value=""
        read -r owner question type value <<< "${logical_line}"

        if [[ -z "${owner}" || -z "${question}" || -z "${type}" ]]; then
            echo "ERROR: Invalid preseed entry beginning on line ${logical_start}:"
            echo "  ${logical_line}"
            valid=false
        else
            case "${type}" in
                select|boolean|string|multiselect|note|password|text|title|seen)
                    ;;
                *)
                    echo "ERROR: Unknown preseed type '${type}' on line ${logical_start}:"
                    echo "  ${logical_line}"
                    valid=false
                    ;;
            esac
        fi

        logical_line=""
        logical_start=0
    done < "${file}"

    if [[ "${continued}" == true ]]; then
        echo "ERROR: Unterminated preseed line continuation beginning on line ${logical_start}."
        valid=false
    fi

    [[ "${valid}" == true ]]
}

echo "Validating preseed.cfg format..."

if ! validate_preseed_format "${PRESEED_FILE}"; then
    echo "ERROR: preseed.cfg format validation failed."
    exit 1
fi

TEMP_DIR="$(mktemp -d)"
REMOTE_SHA256SUMS_FILE="${TEMP_DIR}/SHA256SUMS"
REMOTE_SHA256SUMS_SIGN_FILE="${TEMP_DIR}/SHA256SUMS.sign"

mkdir -p "${SOURCE_DIR}" "${WORK_DIR}" "${OUTPUT_DIR}"


# ------------------------------------------------------------------------------------------
# Find newest local Debian amd64 netinst ISO for the configured major version
# ------------------------------------------------------------------------------------------

LOCAL_ISO_PATH="$(
    find "${SOURCE_DIR}" -mindepth 2 -maxdepth 2 -type f \
        -name 'debian-*-amd64-netinst.iso' \
        -printf '%f\t%p\n' \
    | awk -F '\t' -v major="${DEBIAN_MAJOR_VERSION}" \
        '$1 ~ ("^debian-" major "(\\.[0-9]+)*-amd64-netinst\\.iso$")' \
    | sort -t $'\t' -k1,1V \
    | tail -n 1 \
    | cut -f2-
)"

LOCAL_ISO=""

if [[ -n "${LOCAL_ISO_PATH}" ]]; then
    LOCAL_ISO="$(basename "${LOCAL_ISO_PATH}")"
fi


# ------------------------------------------------------------------------------------------
# Check Debian for the newest amd64 netinst ISO
# ------------------------------------------------------------------------------------------

echo "Checking for the latest Debian amd64 netinst ISO..."

REMOTE_AVAILABLE=false
REMOTE_ISO=""
REMOTE_SHA256=""

if curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --retry 3 \
    --retry-all-errors \
    --retry-delay 2 \
    --output "${REMOTE_SHA256SUMS_FILE}" \
    "${DEBIAN_ISO_BASE_URL}/SHA256SUMS"; then

    REMOTE_AVAILABLE=true

    # Authenticate SHA256SUMS when Debian's CD signing keyring is available locally.
    if curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        --retry-all-errors \
        --retry-delay 2 \
        --output "${REMOTE_SHA256SUMS_SIGN_FILE}" \
        "${DEBIAN_ISO_BASE_URL}/SHA256SUMS.sign"; then

        DEBIAN_CD_KEYRING=""

        for KEYRING in \
            /usr/share/keyrings/debian-role-keys.pgp \
            /usr/share/keyrings/debian-role-keys.gpg; do

            if [[ -f "${KEYRING}" ]]; then
                DEBIAN_CD_KEYRING="${KEYRING}"
                break
            fi
        done

        if command -v gpgv >/dev/null 2>&1 && [[ -n "${DEBIAN_CD_KEYRING}" ]]; then
            echo "Verifying Debian SHA256SUMS signature..."

            if ! gpgv \
                --keyring "${DEBIAN_CD_KEYRING}" \
                "${REMOTE_SHA256SUMS_SIGN_FILE}" \
                "${REMOTE_SHA256SUMS_FILE}" \
                >/dev/null 2>&1; then

                echo "ERROR: Debian SHA256SUMS signature verification failed."
                exit 1
            fi

            echo "Debian SHA256SUMS signature verified."
        else
            echo "WARNING: Debian SHA256SUMS signature was not authenticated."
            echo "         Install gpgv and debian-keyring to enable signature verification."
        fi
    else
        echo "WARNING: Could not download SHA256SUMS.sign; continuing with SHA256SUMS obtained over HTTPS."
    fi

    REMOTE_ISO="$(
        awk '$2 ~ /^debian-[0-9]+(\.[0-9]+)*-amd64-netinst\.iso$/ { print $2 }' \
            "${REMOTE_SHA256SUMS_FILE}" \
        | sort -V \
        | tail -n 1
    )"

    if [[ -z "${REMOTE_ISO}" ]]; then
        echo "ERROR: Could not determine the latest Debian amd64 netinst ISO."
        exit 1
    fi

    REMOTE_VERSION="${REMOTE_ISO#debian-}"
    REMOTE_VERSION="${REMOTE_VERSION%-amd64-netinst.iso}"
    REMOTE_MAJOR_VERSION="${REMOTE_VERSION%%.*}"

    if [[ "${REMOTE_MAJOR_VERSION}" != "${DEBIAN_MAJOR_VERSION}" ]]; then
        echo "ERROR: Debian's current release is ${REMOTE_VERSION}, but this build configuration"
        echo "       is intended for Debian ${DEBIAN_MAJOR_VERSION} (${DEBIAN_CODENAME})."
        echo "       Review the preseed and OEM configuration before updating the version pin."
        exit 1
    fi

    REMOTE_SHA256="$(
        awk -v file="${REMOTE_ISO}" '$2 == file { print $1; exit }' \
            "${REMOTE_SHA256SUMS_FILE}"
    )"

    if [[ -z "${REMOTE_SHA256}" ]]; then
        echo "ERROR: Could not determine the SHA256 checksum for ${REMOTE_ISO}."
        exit 1
    fi

    REMOTE_SOURCE_DIR="${SOURCE_DIR}/${REMOTE_VERSION}"
    mkdir -p "${REMOTE_SOURCE_DIR}"

    cp "${REMOTE_SHA256SUMS_FILE}" "${REMOTE_SOURCE_DIR}/SHA256SUMS"

    if [[ -f "${REMOTE_SHA256SUMS_SIGN_FILE}" ]]; then
        cp "${REMOTE_SHA256SUMS_SIGN_FILE}" "${REMOTE_SOURCE_DIR}/SHA256SUMS.sign"
    fi
else
    if [[ -z "${LOCAL_ISO}" ]]; then
        echo "ERROR: Could not check Debian for the latest ISO and no local Debian ${DEBIAN_MAJOR_VERSION} netinst ISO was found."
        exit 1
    fi

    echo "WARNING: Could not check Debian for the latest ISO."
    echo "         Continuing with the newest local Debian ${DEBIAN_MAJOR_VERSION} netinst ISO:"
    echo "  ${LOCAL_ISO}"
fi


# ------------------------------------------------------------------------------------------
# Download the current ISO when necessary
# ------------------------------------------------------------------------------------------

DOWNLOAD_ISO=false

if [[ "${REMOTE_AVAILABLE}" == true ]]; then
    if [[ -z "${LOCAL_ISO}" ]]; then
        echo "No local Debian ${DEBIAN_MAJOR_VERSION} amd64 netinst ISO was found."
        DOWNLOAD_ISO=true
    elif [[ "${LOCAL_ISO}" == "${REMOTE_ISO}" ]]; then
        LOCAL_SHA256="$(sha256sum "${LOCAL_ISO_PATH}" | awk '{ print $1 }')"

        if [[ "${LOCAL_SHA256}" == "${REMOTE_SHA256}" ]]; then
            echo "Local ISO is already current and verified:"
            echo "  ${LOCAL_ISO}"
        else
            echo "Local ISO has the current filename but failed SHA256 verification:"
            echo "  ${LOCAL_ISO}"
            echo "Re-downloading the ISO."
            DOWNLOAD_ISO=true
        fi
    else
        NEWEST_ISO="$(printf '%s\n%s\n' "${LOCAL_ISO}" "${REMOTE_ISO}" | sort -V | tail -n 1)"

        if [[ "${NEWEST_ISO}" == "${REMOTE_ISO}" ]]; then
            echo "Newer Debian netinst ISO available:"
            echo "  Local:  ${LOCAL_ISO}"
            echo "  Remote: ${REMOTE_ISO}"
            DOWNLOAD_ISO=true
        else
            echo "Local ISO is newer than the current Debian release:"
            echo "  Local:  ${LOCAL_ISO}"
            echo "  Remote: ${REMOTE_ISO}"
        fi
    fi
fi

if [[ "${DOWNLOAD_ISO}" == true ]]; then
    TARGET_ISO="${SOURCE_DIR}/${REMOTE_VERSION}/${REMOTE_ISO}"
    TEMP_ISO="${TEMP_DIR}/${REMOTE_ISO}.part"

    mkdir -p "$(dirname "${TARGET_ISO}")"

    rm -f "${TEMP_ISO}"

    echo "Downloading:"
    echo "  ${DEBIAN_ISO_BASE_URL}/${REMOTE_ISO}"

    curl \
        --fail \
        --location \
        --retry 3 \
        --retry-all-errors \
        --retry-delay 2 \
        --output "${TEMP_ISO}" \
        "${DEBIAN_ISO_BASE_URL}/${REMOTE_ISO}"

    ACTUAL_SHA256="$(sha256sum "${TEMP_ISO}" | awk '{ print $1 }')"

    if [[ "${ACTUAL_SHA256}" != "${REMOTE_SHA256}" ]]; then
        echo "ERROR: SHA256 verification failed for ${REMOTE_ISO}."
        echo "  Expected: ${REMOTE_SHA256}"
        echo "  Actual:   ${ACTUAL_SHA256}"
        exit 1
    fi

    mv "${TEMP_ISO}" "${TARGET_ISO}"
    TEMP_ISO=""

    echo "Download verified:"
    echo "  ${TARGET_ISO}"

    LOCAL_ISO="${REMOTE_ISO}"
    LOCAL_ISO_PATH="${TARGET_ISO}"
fi

# When building offline, verify the cached ISO against cached Debian checksum metadata when available.
if [[ "${REMOTE_AVAILABLE}" == false ]]; then
    LOCAL_VERSION="${LOCAL_ISO#debian-}"
    LOCAL_VERSION="${LOCAL_VERSION%-amd64-netinst.iso}"
    LOCAL_SOURCE_DIR="$(dirname "${LOCAL_ISO_PATH}")"
    LOCAL_SHA256SUMS_FILE="${LOCAL_SOURCE_DIR}/SHA256SUMS"
    LOCAL_SHA256SUMS_SIGN_FILE="${LOCAL_SOURCE_DIR}/SHA256SUMS.sign"

    if [[ -f "${LOCAL_SHA256SUMS_FILE}" ]]; then
        if [[ -f "${LOCAL_SHA256SUMS_SIGN_FILE}" ]]; then
            DEBIAN_CD_KEYRING=""

            for KEYRING in \
                /usr/share/keyrings/debian-role-keys.pgp \
                /usr/share/keyrings/debian-role-keys.gpg; do

                if [[ -f "${KEYRING}" ]]; then
                    DEBIAN_CD_KEYRING="${KEYRING}"
                    break
                fi
            done

            if command -v gpgv >/dev/null 2>&1 && [[ -n "${DEBIAN_CD_KEYRING}" ]]; then
                echo "Verifying cached Debian SHA256SUMS signature..."

                if ! gpgv \
                    --keyring "${DEBIAN_CD_KEYRING}" \
                    "${LOCAL_SHA256SUMS_SIGN_FILE}" \
                    "${LOCAL_SHA256SUMS_FILE}" \
                    >/dev/null 2>&1; then

                    echo "ERROR: Cached Debian SHA256SUMS signature verification failed."
                    exit 1
                fi
            fi
        fi

        CACHED_SHA256="$(awk -v file="${LOCAL_ISO}" '$2 == file { print $1; exit }' "${LOCAL_SHA256SUMS_FILE}")"

        if [[ -n "${CACHED_SHA256}" ]]; then
            ACTUAL_SHA256="$(sha256sum "${LOCAL_ISO_PATH}" | awk '{ print $1 }')"

            if [[ "${ACTUAL_SHA256}" != "${CACHED_SHA256}" ]]; then
                echo "ERROR: Cached ISO failed SHA256 verification:"
                echo "  ${LOCAL_ISO_PATH}"
                exit 1
            fi

            echo "Cached ISO SHA256 verified."
        else
            echo "WARNING: Cached SHA256SUMS does not contain ${LOCAL_ISO}; continuing without checksum verification."
        fi
    else
        echo "WARNING: No cached SHA256SUMS was found for ${LOCAL_ISO}; continuing without checksum verification."
    fi
fi

SOURCE_ISO="${LOCAL_ISO_PATH}"
SOURCE_FILENAME="$(basename "${SOURCE_ISO}" .iso)"
SOURCE_VERSION="${LOCAL_ISO#debian-}"
SOURCE_VERSION="${SOURCE_VERSION%-amd64-netinst.iso}"
SOURCE_MAJOR_VERSION="${SOURCE_VERSION%%.*}"

if [[ "${SOURCE_MAJOR_VERSION}" != "${DEBIAN_MAJOR_VERSION}" ]]; then
    echo "ERROR: Selected source ISO is Debian ${SOURCE_VERSION}, but this build configuration"
    echo "       is intended for Debian ${DEBIAN_MAJOR_VERSION} (${DEBIAN_CODENAME})."
    exit 1
fi

BUILD_DATE="$(date +%y%m%d)"
OUTPUT_FILENAME="${SOURCE_FILENAME}-${OUTPUT_TAG}${BUILD_DATE}"
OUTPUT_ISO="${OUTPUT_DIR}/${OUTPUT_FILENAME}.iso"
OUTPUT_SHA256_FILE="${OUTPUT_ISO}.sha256"
BUILD_WORK_DIR="${WORK_DIR}/${OUTPUT_FILENAME}"
GRUB_FILE="${BUILD_WORK_DIR}/grub.cfg"
MD5_FILE="${BUILD_WORK_DIR}/md5sum.txt"
NETCFG_PACKAGES_FILE="${BUILD_WORK_DIR}/Packages"
NETCFG_PACKAGES_GZ_FILE="${BUILD_WORK_DIR}/Packages.gz"
NETCFG_RELEASE_FILE="${BUILD_WORK_DIR}/Release"
NETCFG_POOL_DIR="/pool/main/n/netcfg"
NETCFG_INDEX_DIR="/dists/${DEBIAN_CODENAME}/main/debian-installer/binary-amd64"
NETCFG_INDEX_PATH="${NETCFG_INDEX_DIR}/Packages"
NETCFG_INDEX_GZ_PATH="${NETCFG_INDEX_PATH}.gz"
NETCFG_RELEASE_PATH="/dists/${DEBIAN_CODENAME}/Release"
NETCFG_NEW_FILENAME="netcfg_${NETCFG_BACKPORT_VERSION}_amd64.udeb"
NETCFG_NEW_ISO_PATH="${NETCFG_POOL_DIR}/${NETCFG_NEW_FILENAME}"
NETCFG_OLD_ISO_PATH=""

echo
echo "Source ISO:"
echo "  ${SOURCE_ISO}"
echo
echo "Preseed:"
echo "  ${PRESEED_FILE}"
echo
echo "Output ISO:"
echo "  ${OUTPUT_ISO}"
echo

echo "Working files:"
echo "  ${BUILD_WORK_DIR}"

if [[ "${ENABLE_VLAN_NETCFG}" == true ]]; then
    echo
    echo "VLAN-capable netcfg:"
    echo "  ${NETCFG_BACKPORT_UDEB}"
fi
echo


# ------------------------------------------------------------------------------------------
# Prepare per-output working directory and remove previous output/build files
# ------------------------------------------------------------------------------------------

mkdir -p "${BUILD_WORK_DIR}"

rm -f "${OUTPUT_ISO}"
rm -f "${OUTPUT_SHA256_FILE}"
rm -f "${GRUB_FILE}"
rm -f "${MD5_FILE}"
rm -f "${NETCFG_PACKAGES_FILE}"
rm -f "${NETCFG_PACKAGES_GZ_FILE}"
rm -f "${NETCFG_RELEASE_FILE}"


# ------------------------------------------------------------------------------------------
# Verify expected Debian Installer files exist
# ------------------------------------------------------------------------------------------

iso_file_exists()
{
    local iso="$1"
    local path="$2"
    local match=""

    match="$(xorriso \
        -indev "${iso}" \
        -find "${path}" -maxdepth 0 -type f -exec echo \
        2>/dev/null)"

    [[ -n "${match}" ]]
}

if ! iso_file_exists "${SOURCE_ISO}" "/install.amd/vmlinuz"; then
    echo "ERROR: /install.amd/vmlinuz was not found in the source ISO."
    exit 1
fi

if ! iso_file_exists "${SOURCE_ISO}" "/install.amd/initrd.gz"; then
    echo "ERROR: /install.amd/initrd.gz was not found in the source ISO."
    exit 1
fi


# ------------------------------------------------------------------------------------------
# Extract GRUB configuration and checksum list
# ------------------------------------------------------------------------------------------

echo "Extracting GRUB configuration..."

xorriso \
    -osirrox on \
    -indev "${SOURCE_ISO}" \
    -extract /boot/grub/grub.cfg "${GRUB_FILE}"

echo "Extracting checksum list..."

xorriso \
    -osirrox on \
    -indev "${SOURCE_ISO}" \
    -extract /md5sum.txt "${MD5_FILE}"

chmod u+w "${GRUB_FILE}" "${MD5_FILE}"


# ------------------------------------------------------------------------------------------
# Prepare the optional VLAN-capable netcfg pool and package-index replacement
# ------------------------------------------------------------------------------------------

if [[ "${ENABLE_VLAN_NETCFG}" == true ]]; then
    echo "Preparing VLAN-capable netcfg package index..."

    xorriso \
        -osirrox on \
        -indev "${SOURCE_ISO}" \
        -extract "${NETCFG_INDEX_GZ_PATH}" "${NETCFG_PACKAGES_GZ_FILE}" \
        -extract "${NETCFG_RELEASE_PATH}" "${NETCFG_RELEASE_FILE}" \
        >/dev/null 2>&1

    gzip -cd "${NETCFG_PACKAGES_GZ_FILE}" > "${NETCFG_PACKAGES_FILE}"
    chmod u+w "${NETCFG_PACKAGES_FILE}" "${NETCFG_PACKAGES_GZ_FILE}" "${NETCFG_RELEASE_FILE}"

    NETCFG_OLD_FILENAME="$(
        awk '
            BEGIN { RS = "" }
            $1 == "Package:" && $2 == "netcfg" {
                count++
                lines = split($0, line, "\n")
                for (i = 1; i <= lines; i++) {
                    if (line[i] ~ /^Filename: /) {
                        sub(/^Filename: /, "", line[i])
                        print line[i]
                    }
                }
            }
            END { if (count != 1) exit 1 }
        ' "${NETCFG_PACKAGES_FILE}"
    )"

    if [[ -z "${NETCFG_OLD_FILENAME}" ]]; then
        echo "ERROR: Could not identify the stock netcfg udeb in the installer package index."
        exit 1
    fi

    NETCFG_OLD_ISO_PATH="/${NETCFG_OLD_FILENAME}"
    NETCFG_NEW_INDEX_FILENAME="${NETCFG_NEW_ISO_PATH#/}"
    NETCFG_NEW_SIZE="$(stat -c '%s' "${NETCFG_BACKPORT_UDEB}")"
    NETCFG_NEW_INSTALLED_SIZE="$(dpkg-deb -f "${NETCFG_BACKPORT_UDEB}" Installed-Size)"
    NETCFG_NEW_DEPENDS="$(dpkg-deb -f "${NETCFG_BACKPORT_UDEB}" Depends)"
    NETCFG_NEW_MD5="$(md5sum "${NETCFG_BACKPORT_UDEB}" | awk '{print $1}')"
    NETCFG_NEW_SHA256="$(sha256sum "${NETCFG_BACKPORT_UDEB}" | awk '{print $1}')"
    TEMP_PACKAGES="${TEMP_DIR}/Packages"

    awk \
        -v version="${NETCFG_BACKPORT_VERSION}" \
        -v installed_size="${NETCFG_NEW_INSTALLED_SIZE}" \
        -v depends="${NETCFG_NEW_DEPENDS}" \
        -v filename="${NETCFG_NEW_INDEX_FILENAME}" \
        -v size="${NETCFG_NEW_SIZE}" \
        -v md5="${NETCFG_NEW_MD5}" \
        -v sha256="${NETCFG_NEW_SHA256}" '
        BEGIN { RS = "" }

        {
            is_netcfg = ($1 == "Package:" && $2 == "netcfg")
            if (is_netcfg)
                replaced++

            lines = split($0, line, "\n")
            for (i = 1; i <= lines; i++) {
                if (is_netcfg && line[i] ~ /^Version: /)
                    line[i] = "Version: " version
                else if (is_netcfg && line[i] ~ /^Installed-Size: /)
                    line[i] = "Installed-Size: " installed_size
                else if (is_netcfg && line[i] ~ /^Depends: /)
                    line[i] = "Depends: " depends
                else if (is_netcfg && line[i] ~ /^Filename: /)
                    line[i] = "Filename: " filename
                else if (is_netcfg && line[i] ~ /^Size: /)
                    line[i] = "Size: " size
                else if (is_netcfg && line[i] ~ /^MD5sum: /)
                    line[i] = "MD5sum: " md5
                else if (is_netcfg && line[i] ~ /^SHA256: /)
                    line[i] = "SHA256: " sha256

                print line[i]
            }
            print ""
        }

        END { if (replaced != 1) exit 1 }
    ' "${NETCFG_PACKAGES_FILE}" > "${TEMP_PACKAGES}"

    mv "${TEMP_PACKAGES}" "${NETCFG_PACKAGES_FILE}"
    gzip -n -9 -c "${NETCFG_PACKAGES_FILE}" > "${NETCFG_PACKAGES_GZ_FILE}"

    update_release_checksums()
    {
        local release_file="$1"
        local relative_path="$2"
        local payload_file="$3"
        local payload_size=""
        local payload_md5=""
        local payload_sha1=""
        local payload_sha256=""
        local payload_sha512=""
        local updated_release="${TEMP_DIR}/Release"

        payload_size="$(stat -c '%s' "${payload_file}")"
        payload_md5="$(md5sum "${payload_file}" | awk '{print $1}')"
        payload_sha1="$(sha1sum "${payload_file}" | awk '{print $1}')"
        payload_sha256="$(sha256sum "${payload_file}" | awk '{print $1}')"
        payload_sha512="$(sha512sum "${payload_file}" | awk '{print $1}')"

        awk \
            -v path="${relative_path}" \
            -v size="${payload_size}" \
            -v md5="${payload_md5}" \
            -v sha1="${payload_sha1}" \
            -v sha256="${payload_sha256}" \
            -v sha512="${payload_sha512}" '
            /^MD5Sum:/ { section = "md5"; print; next }
            /^SHA1:/ { section = "sha1"; print; next }
            /^SHA256:/ { section = "sha256"; print; next }
            /^SHA512:/ { section = "sha512"; print; next }

            $3 == path {
                if (section == "md5") value = md5
                else if (section == "sha1") value = sha1
                else if (section == "sha256") value = sha256
                else if (section == "sha512") value = sha512
                else exit 1

                printf " %s %8d %s\n", value, size, path
                updated++
                next
            }

            { print }

            END { if (updated != 4) exit 1 }
        ' "${release_file}" > "${updated_release}"

        mv "${updated_release}" "${release_file}"
    }

    update_release_checksums \
        "${NETCFG_RELEASE_FILE}" \
        "${NETCFG_INDEX_GZ_PATH#/dists/${DEBIAN_CODENAME}/}" \
        "${NETCFG_PACKAGES_GZ_FILE}"
fi


# ------------------------------------------------------------------------------------------
# Create custom GRUB menu entries
# ------------------------------------------------------------------------------------------

CUSTOM_GRUB="${TEMP_DIR}/custom-grub.cfg"

printf '%s\n' \
    "menuentry 'Automated Install - ext4' {" \
    '    set background_color=black' \
    '    linux /install.amd/vmlinuz auto=true priority=high ipv6.disable=1 preseed/file=/cdrom/preseed.cfg partman/default_filesystem=ext4 --- quiet' \
    '    initrd /install.amd/initrd.gz' \
    '}' \
    '' \
    "menuentry 'Automated Install - XFS' {" \
    '    set background_color=black' \
    '    linux /install.amd/vmlinuz auto=true priority=high ipv6.disable=1 preseed/file=/cdrom/preseed.cfg partman/default_filesystem=xfs --- quiet' \
    '    initrd /install.amd/initrd.gz' \
    '}' \
    '' \
    > "${CUSTOM_GRUB}"


# ------------------------------------------------------------------------------------------
# Insert custom entries before the first existing GRUB menu entry
# ------------------------------------------------------------------------------------------

TEMP_GRUB="${TEMP_DIR}/grub.cfg"

awk -v custom="${CUSTOM_GRUB}" '
    BEGIN {
        inserted = 0
    }

    /^menuentry / && !inserted {
        while ((getline line < custom) > 0)
            print line

        close(custom)
        inserted = 1
    }

    {
        print
    }

    END {
        if (!inserted) {
            while ((getline line < custom) > 0)
                print line

            close(custom)
        }
    }
' "${GRUB_FILE}" > "${TEMP_GRUB}"

mv "${TEMP_GRUB}" "${GRUB_FILE}"


# ------------------------------------------------------------------------------------------
# Update ISO checksums
# ------------------------------------------------------------------------------------------

# Remove old checksums for files we replace or generate.
sed -i \
    -e '\|  \./boot/grub/grub.cfg$|d' \
    -e '\|  \./preseed.cfg$|d' \
    -e '\|  \./OEM/|d' \
    -e '\|  \./isolinux/boot.cat$|d' \
    "${MD5_FILE}"

if [[ "${ENABLE_VLAN_NETCFG}" == true ]]; then
    sed -i \
        -e "\|  \./${NETCFG_OLD_FILENAME}$|d" \
        -e "\|  \./${NETCFG_NEW_INDEX_FILENAME}$|d" \
        -e "\|  \./${NETCFG_INDEX_GZ_PATH#/}$|d" \
        -e "\|  \./${NETCFG_RELEASE_PATH#/}$|d" \
        "${MD5_FILE}"
fi

GRUB_MD5="$(md5sum "${GRUB_FILE}" | awk '{print $1}')"
PRESEED_MD5="$(md5sum "${PRESEED_FILE}" | awk '{print $1}')"

printf '%s  ./boot/grub/grub.cfg\n' "${GRUB_MD5}" >> "${MD5_FILE}"
printf '%s  ./preseed.cfg\n' "${PRESEED_MD5}" >> "${MD5_FILE}"

find "${OEM_DIR}" -type f -print0 | sort -z | while IFS= read -r -d '' FILE; do
    OEM_RELATIVE_PATH="${FILE#${OEM_DIR}/}"
    HASH="$(md5sum "${FILE}" | awk '{print $1}')"

    printf '%s  ./OEM/%s\n' "${HASH}" "${OEM_RELATIVE_PATH}" >> "${MD5_FILE}"
done

if [[ "${ENABLE_VLAN_NETCFG}" == true ]]; then
    printf '%s  ./%s\n' "$(md5sum "${NETCFG_BACKPORT_UDEB}" | awk '{print $1}')" "${NETCFG_NEW_INDEX_FILENAME}" >> "${MD5_FILE}"
    printf '%s  ./%s\n' "$(md5sum "${NETCFG_PACKAGES_GZ_FILE}" | awk '{print $1}')" "${NETCFG_INDEX_GZ_PATH#/}" >> "${MD5_FILE}"
    printf '%s  ./%s\n' "$(md5sum "${NETCFG_RELEASE_FILE}" | awk '{print $1}')" "${NETCFG_RELEASE_PATH#/}" >> "${MD5_FILE}"
fi


# ------------------------------------------------------------------------------------------
# Build customized ISO
# ------------------------------------------------------------------------------------------

echo
echo "Building customized ISO..."

NETCFG_XORRISO_ARGS=()

if [[ "${ENABLE_VLAN_NETCFG}" == true ]]; then
    NETCFG_XORRISO_ARGS=(
        -rm "${NETCFG_OLD_ISO_PATH}" --
        -map "${NETCFG_BACKPORT_UDEB}" "${NETCFG_NEW_ISO_PATH}"
        -map "${NETCFG_PACKAGES_GZ_FILE}" "${NETCFG_INDEX_GZ_PATH}"
        -map "${NETCFG_RELEASE_FILE}" "${NETCFG_RELEASE_PATH}"
    )
fi

xorriso \
    -indev "${SOURCE_ISO}" \
    -outdev "${OUTPUT_ISO}" \
    -map "${PRESEED_FILE}" /preseed.cfg \
    -map "${GRUB_FILE}" /boot/grub/grub.cfg \
    -map "${MD5_FILE}" /md5sum.txt \
    -map "${OEM_DIR}" /OEM \
    "${NETCFG_XORRISO_ARGS[@]}" \
    -boot_image any replay \
    -compliance no_emul_toc \
    -padding included


# ------------------------------------------------------------------------------------------
# Verify output
# ------------------------------------------------------------------------------------------

echo
echo "Verifying customized ISO..."

VERIFY_PRESEED="${TEMP_DIR}/verify-preseed.cfg"
VERIFY_GRUB="${TEMP_DIR}/verify-grub.cfg"
VERIFY_OEM_DIR="${TEMP_DIR}/verify-oem"

mkdir -p "${VERIFY_OEM_DIR}"

xorriso \
    -osirrox on \
    -indev "${OUTPUT_ISO}" \
    -extract /preseed.cfg "${VERIFY_PRESEED}" \
    >/dev/null 2>&1

if ! cmp -s "${PRESEED_FILE}" "${VERIFY_PRESEED}"; then
    echo "ERROR: preseed.cfg verification failed."
    exit 1
fi

xorriso \
    -osirrox on \
    -indev "${OUTPUT_ISO}" \
    -extract /boot/grub/grub.cfg "${VERIFY_GRUB}" \
    >/dev/null 2>&1

if ! cmp -s "${GRUB_FILE}" "${VERIFY_GRUB}"; then
    echo "ERROR: GRUB configuration verification failed."
    exit 1
fi

if ! grep -Fq "menuentry 'Automated Install - ext4'" "${VERIFY_GRUB}"; then
    echo "ERROR: Automated ext4 GRUB menu entry was not found in the output ISO."
    exit 1
fi

if ! grep -Fq "menuentry 'Automated Install - XFS'" "${VERIFY_GRUB}"; then
    echo "ERROR: Automated XFS GRUB menu entry was not found in the output ISO."
    exit 1
fi

for FILE in "${REQUIRED_OEM_FILES[@]}"; do
    VERIFY_OEM_FILE="${VERIFY_OEM_DIR}/${FILE}"

    xorriso \
        -osirrox on \
        -indev "${OUTPUT_ISO}" \
        -extract "/OEM/${FILE}" "${VERIFY_OEM_FILE}" \
        >/dev/null 2>&1

    if ! cmp -s "${OEM_DIR}/${FILE}" "${VERIFY_OEM_FILE}"; then
        echo "ERROR: OEM/${FILE} verification failed."
        exit 1
    fi
done

if [[ "${ENABLE_VLAN_NETCFG}" == true ]]; then
    VERIFY_NETCFG_UDEB="${TEMP_DIR}/verify-netcfg.udeb"
    VERIFY_NETCFG_PACKAGES="${TEMP_DIR}/verify-Packages"
    VERIFY_NETCFG_PACKAGES_GZ="${TEMP_DIR}/verify-Packages.gz"
    VERIFY_NETCFG_RELEASE="${TEMP_DIR}/verify-Release"
    VERIFY_MD5_FILE="${TEMP_DIR}/verify-md5sum.txt"

    xorriso \
        -osirrox on \
        -indev "${OUTPUT_ISO}" \
        -extract "${NETCFG_NEW_ISO_PATH}" "${VERIFY_NETCFG_UDEB}" \
        -extract "${NETCFG_INDEX_GZ_PATH}" "${VERIFY_NETCFG_PACKAGES_GZ}" \
        -extract "${NETCFG_RELEASE_PATH}" "${VERIFY_NETCFG_RELEASE}" \
        -extract /md5sum.txt "${VERIFY_MD5_FILE}" \
        >/dev/null 2>&1

    if ! cmp -s "${NETCFG_BACKPORT_UDEB}" "${VERIFY_NETCFG_UDEB}"; then
        echo "ERROR: VLAN-capable netcfg udeb verification failed."
        exit 1
    fi

    gzip -cd "${VERIFY_NETCFG_PACKAGES_GZ}" > "${VERIFY_NETCFG_PACKAGES}"

    if ! cmp -s "${NETCFG_PACKAGES_FILE}" "${VERIFY_NETCFG_PACKAGES}" ||
       ! cmp -s "${NETCFG_PACKAGES_GZ_FILE}" "${VERIFY_NETCFG_PACKAGES_GZ}" ||
       ! cmp -s "${NETCFG_RELEASE_FILE}" "${VERIFY_NETCFG_RELEASE}" ||
       ! cmp -s "${MD5_FILE}" "${VERIFY_MD5_FILE}"; then
        echo "ERROR: VLAN-capable netcfg package metadata verification failed."
        exit 1
    fi

    if ! gzip -cd "${VERIFY_NETCFG_PACKAGES_GZ}" | cmp -s "${VERIFY_NETCFG_PACKAGES}" -; then
        echo "ERROR: Compressed installer package index does not match Packages."
        exit 1
    fi

    if iso_file_exists "${OUTPUT_ISO}" "${NETCFG_OLD_ISO_PATH}"; then
        echo "ERROR: Stock netcfg udeb is still present in the customized ISO."
        exit 1
    fi

    if [[ "$(dpkg-deb -f "${VERIFY_NETCFG_UDEB}" Version)" != "${NETCFG_BACKPORT_VERSION}" ]]; then
        echo "ERROR: Customized ISO contains an unexpected netcfg version."
        exit 1
    fi

    if ! awk -v version="${NETCFG_BACKPORT_VERSION}" -v filename="${NETCFG_NEW_INDEX_FILENAME}" '
        BEGIN { RS = "" }
        $1 == "Package:" && $2 == "netcfg" {
            found++
            lines = split($0, line, "\n")
            for (i = 1; i <= lines; i++) {
                if (line[i] == "Version: " version) version_ok = 1
                if (line[i] == "Filename: " filename) filename_ok = 1
            }
        }
        END { if (found != 1 || !version_ok || !filename_ok) exit 1 }
    ' "${VERIFY_NETCFG_PACKAGES}"; then
        echo "ERROR: Installer package index does not select netcfg ${NETCFG_BACKPORT_VERSION}."
        exit 1
    fi

    verify_release_checksum()
    {
        local section="$1"
        local relative_path="$2"
        local payload_file="$3"
        local expected_hash=""
        local expected_size=""

        expected_size="$(stat -c '%s' "${payload_file}")"
        case "${section}" in
            MD5Sum) expected_hash="$(md5sum "${payload_file}" | awk '{print $1}')" ;;
            SHA1) expected_hash="$(sha1sum "${payload_file}" | awk '{print $1}')" ;;
            SHA256) expected_hash="$(sha256sum "${payload_file}" | awk '{print $1}')" ;;
            SHA512) expected_hash="$(sha512sum "${payload_file}" | awk '{print $1}')" ;;
        esac

        awk -v wanted_section="${section}:" \
            -v path="${relative_path}" \
            -v hash="${expected_hash}" \
            -v size="${expected_size}" '
            /^[A-Za-z0-9]+:$/ { current_section = $1 }
            current_section == wanted_section && $3 == path {
                found++
                if ($1 != hash || $2 != size) bad = 1
            }
            END { if (found != 1 || bad) exit 1 }
        ' "${VERIFY_NETCFG_RELEASE}"
    }

    for SECTION in MD5Sum SHA1 SHA256 SHA512; do
        if ! verify_release_checksum \
            "${SECTION}" \
            "${NETCFG_INDEX_GZ_PATH#/dists/${DEBIAN_CODENAME}/}" \
            "${VERIFY_NETCFG_PACKAGES_GZ}"; then
            echo "ERROR: Release checksum verification failed for ${SECTION}."
            exit 1
        fi
    done
fi


# ------------------------------------------------------------------------------------------
# Generate checksum for customized ISO
# ------------------------------------------------------------------------------------------

(
    cd "${OUTPUT_DIR}"
    sha256sum "$(basename "${OUTPUT_ISO}")" > "$(basename "${OUTPUT_SHA256_FILE}")"
)

if ! (
    cd "${OUTPUT_DIR}"
    sha256sum -c "$(basename "${OUTPUT_SHA256_FILE}")" >/dev/null
); then
    echo "ERROR: Final customized ISO SHA256 verification failed."
    exit 1
fi

echo
echo "Build complete:"
echo "  ${OUTPUT_ISO}"
echo "  ${OUTPUT_SHA256_FILE}"
echo
echo "Working files retained for inspection:"
echo "  ${GRUB_FILE}"
echo "  ${MD5_FILE}"

if [[ "${ENABLE_VLAN_NETCFG}" == true ]]; then
    echo "  ${NETCFG_PACKAGES_FILE}"
    echo "  ${NETCFG_PACKAGES_GZ_FILE}"
    echo "  ${NETCFG_RELEASE_FILE}"
fi
