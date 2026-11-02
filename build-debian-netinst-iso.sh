#!/bin/bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        build-debian-netinst-iso.sh
# Revision:    r11
# Modified:    2026-08-24
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/debian-netinst-customizer
# Description: Creates a customized Debian amd64 netinst ISO using the newest stock Debian
#              netinst ISO and customization files stored under ./config. Downloads and caches
#              Debian source ISOs and verification metadata under ./source, retains inspectable
#              intermediate build files under ./work, and writes completed images to ./output.
#
#              The customized ISO includes automated ext4 and XFS installation entries
#              in the UEFI GRUB boot menu.
#
# Requirements:
#              curl
#              xorriso
#
# Optional:
#              gpgv + debian-keyring
#                                   Authenticates Debian's signed SHA256SUMS file.
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
#              source/13.6.0/debian-13.6.0-amd64-netinst.iso
#                  -> output/debian-13.6.0-amd64-netinst-custom260820.iso
#                  -> output/debian-13.6.0-amd64-netinst-custom260820.iso.sha256
#                  -> work/debian-13.6.0-amd64-netinst-custom260820/
# ------------------------------------------------------------------------------------------

set -euo pipefail

DEBIAN_MAJOR_VERSION=13
DEBIAN_CODENAME="trixie"
DEBIAN_ISO_BASE_URL="https://get.debian.org/cdimage/release/current/amd64/iso-cd"

# Build tag appended to customized ISO filenames. Override at runtime with OUTPUT_TAG=<tag>.
OUTPUT_TAG="${OUTPUT_TAG:-custom}"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"
SOURCE_DIR="${ROOT_DIR}/source"
WORK_DIR="${ROOT_DIR}/work"
OUTPUT_DIR="${ROOT_DIR}/output"

PRESEED_FILE="${CONFIG_DIR}/preseed.cfg"
OEM_DIR="${CONFIG_DIR}/OEM"

REQUIRED_OEM_FILES=(
    "debian.sources"
    "update-login-banner.sh"
    "update-login-banner.service"
)

TEMP_DIR=""
TEMP_ISO=""

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

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is not installed."
    echo "Install it with: sudo apt install curl"
    exit 1
fi

if ! command -v xorriso >/dev/null 2>&1; then
    echo "ERROR: xorriso is not installed."
    echo "Install it with: sudo apt install xorriso"
    exit 1
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
echo


# ------------------------------------------------------------------------------------------
# Prepare per-output working directory and remove previous output/build files
# ------------------------------------------------------------------------------------------

mkdir -p "${BUILD_WORK_DIR}"

rm -f "${OUTPUT_ISO}"
rm -f "${OUTPUT_SHA256_FILE}"
rm -f "${GRUB_FILE}"
rm -f "${MD5_FILE}"


# ------------------------------------------------------------------------------------------
# Verify expected Debian Installer files exist
# ------------------------------------------------------------------------------------------

iso_file_exists()
{
    local iso="$1"
    local path="$2"

    xorriso \
        -indev "${iso}" \
        -ls "${path}" \
        >/dev/null 2>&1
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

GRUB_MD5="$(md5sum "${GRUB_FILE}" | awk '{print $1}')"
PRESEED_MD5="$(md5sum "${PRESEED_FILE}" | awk '{print $1}')"

printf '%s  ./boot/grub/grub.cfg\n' "${GRUB_MD5}" >> "${MD5_FILE}"
printf '%s  ./preseed.cfg\n' "${PRESEED_MD5}" >> "${MD5_FILE}"

find "${OEM_DIR}" -type f -print0 | sort -z | while IFS= read -r -d '' FILE; do
    OEM_RELATIVE_PATH="${FILE#${OEM_DIR}/}"
    HASH="$(md5sum "${FILE}" | awk '{print $1}')"

    printf '%s  ./OEM/%s\n' "${HASH}" "${OEM_RELATIVE_PATH}" >> "${MD5_FILE}"
done


# ------------------------------------------------------------------------------------------
# Build customized ISO
# ------------------------------------------------------------------------------------------

echo
echo "Building customized ISO..."

xorriso \
    -indev "${SOURCE_ISO}" \
    -outdev "${OUTPUT_ISO}" \
    -map "${PRESEED_FILE}" /preseed.cfg \
    -map "${GRUB_FILE}" /boot/grub/grub.cfg \
    -map "${MD5_FILE}" /md5sum.txt \
    -map "${OEM_DIR}" /OEM \
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
