#!/bin/bash
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Given a test image, a firmware version, and 5 modified firmware binaries
# this script will generate 5 auto update payloads with incremented OS
# and firmware versions.  The payloads can then be applied one after another
# to test firmware update and kernel version increments.

find_common_sh() {
  local thisdir="$(dirname "$(readlink -f "$0")")"
  local common_paths=(/usr/lib/crosutils "${thisdir}")
  local path

  SCRIPT_ROOT="${common_paths[0]}"
  for path in "${common_paths[@]}"; do
    if [ -r "${path}/common.sh" ]; then
      SCRIPT_ROOT="${path}"
      break
    fi
  done
}

find_common_sh
. "${SCRIPT_ROOT}/common.sh" || exit 1

cleanup() {
  "${SCRIPTS_DIR}/mount_gpt_image.sh" -u -r "$ROOT_FS_DIR" -s "$STATEFUL_FS_DIR"
}

# Need to be inside the chroot to load chromeos-common.sh
assert_inside_chroot

DEFINE_string board "$FLAGS_board" "Board for which the image was built" b
DEFINE_string image "$FLAGS_image" "Location of the test image file" i
DEFINE_string firmware_ver "$FLAGS_firmware_ver" "New firmware version" f
DEFINE_string updated_fm "$FLAGS_updated_fm" \
  "Folder path to updated firmware bin files" u

# Parse command line
FLAGS "$@" || exit 1
eval set -- "$FLAGS_ARGV"

WORKING_DIR=/tmp/key_increment_working_folder
BIOS_WORKING_DIR="${WORKING_DIR}/bios"
IMAGE_DIR=$(dirname "${FLAGS_image}")
IMAGE_NAME=$(basename "${FLAGS_image}")
ROOT_FS_DIR="${IMAGE_DIR}/rootfs"
STATEFUL_FS_DIR="${IMAGE_DIR}/stateful"

[[ $FLAGS_updated_fm == */ ]] && FLAGS_updated_fm="${FLAGS_updated_fm%?}"

# Check we have all 5 new firmware binaries
FM_VER_PREFIX=${FLAGS_firmware_ver%?}
info "Checking ${FLAGS_updated_fm} for binaries..."
info "Using pattern: ${FLAGS_board}_${FM_VER_PREFIX}1.bin"

for i in 1 2 3 4 5
do
  BIN_FILE="${FLAGS_updated_fm}/${FLAGS_board}_${FM_VER_PREFIX}$i.bin"
  if [ ! -f ${BIN_FILE} ]; then
    die_notrace "Unable to locate ${BIN_FILE} firmware binary, exiting."
  fi
done

trap cleanup EXIT

cleanup EXIT

if [ -d $WORKING_DIR ]; then
  rm -rf $WORKING_DIR
fi

mkdir ${WORKING_DIR}
mkdir ${BIOS_WORKING_DIR}

info "Copying ${FLAGS_image} to ${WORKING_DIR}"
cp $FLAGS_image $WORKING_DIR

# Pull out the shellball we want to use
"$SCRIPTS_DIR/mount_gpt_image.sh" -i "$IMAGE_NAME" -f "$WORKING_DIR" \
  -r "$ROOT_FS_DIR" -s "$STATEFUL_FS_DIR"

IMAGE_UPDATER="${ROOT_FS_DIR}/usr/sbin/chromeos-firmwareupdate"
WORKING_UPDATER="${BIOS_WORKING_DIR}/chromeos-firmwareupdate"

for i in 1 2 3 4 5
do
  cp ${IMAGE_UPDATER} ${WORKING_UPDATER}-test$i
  chmod 755 ${WORKING_UPDATER}-test$i

  NEW_VER="${FLAGS_board}_${FM_VER_PREFIX}${i}"
  FM_VER="Google_${NEW_VER}"
  info "Updating the firmware version to ${FM_VER}"
  sed -i "/^TARGET_FWID=/c TARGET_FWID=${FM_VER}" "${WORKING_UPDATER}-test$i"
  # Resign the provided firmware binaries
  PROVIDED_BIN="${FLAGS_updated_fm}/${NEW_VER}.bin"
  SIGNED_BIN="${BIOS_WORKING_DIR}/${NEW_VER}_signed.bin"

  info "Resigning ${PROVIDED_BIN} to ${SIGNED_BIN}"
  cd ~/trunk/src/platform/vboot_reference/scripts/image_signing
  ./resign_firmwarefd.sh \
    "${PROVIDED_BIN}" \
    "${SIGNED_BIN}" \
    ../../tests/devkeys/firmware_data_key.vbprivk \
    ../../tests/devkeys/firmware.keyblock \
    ../../tests/devkeys/dev_firmware_data_key.vbprivk \
    ../../tests/devkeys/dev_firmware.keyblock \
    ../../tests/devkeys/kernel_subkey.vbpubk 1 0
  cd "${BIOS_WORKING_DIR}"
  mkdir work
  ./chromeos-firmwareupdate-test$i --sb_extract work/

  info "Copying new bios ${SIGNED_BIN} into ${WORKING_UPDATER}-test$i"
  sudo cp ${SIGNED_BIN} work/bios.bin
  ./chromeos-firmwareupdate-test$i --sb_repack work/
  rm -r work
done

# Get the OS version
LSB_RELEASE="${ROOT_FS_DIR}/etc/lsb-release"
CHROMEOS_VER=$(grep ^"CHROMEOS_RELEASE_VERSION" ${LSB_RELEASE} | cut -d = -f 2-)
CHROMEOS_VER_PREFIX=${CHROMEOS_VER%?}
CHROMEOS_TRACK=$(grep ^"CHROMEOS_RELEASE_TRACK" ${LSB_RELEASE} | cut -d = -f 2-)

cleanup

# Make a copy of the key directories
KEYS_DIR="${WORKING_DIR}/keys"
mkdir "${KEYS_DIR}"
cd ~/trunk/src/platform/vboot_reference
cp tests/devkeys/* "${KEYS_DIR}"
cp scripts/keygeneration/* "${KEYS_DIR}"

# Enable firmware update
scripts/image_signing/tag_image.sh --from="${WORKING_DIR}/${IMAGE_NAME}" \
  --update_firmware 1

# Make a directory to store the new payloads
PAYLOAD_DIR="${WORKING_DIR}/payloads"
mkdir "${PAYLOAD_DIR}"

# Create a copy of the test image that will be convert to a payload.
for i in 1 2 3 4 5
do
  NEW_IMAGE_NAME="chromiumos-key-image-${CHROMEOS_VER_PREFIX}${i}.bin"
  cp "${WORKING_DIR}/${IMAGE_NAME}" "${WORKING_DIR}/${NEW_IMAGE_NAME}"
  "$SCRIPTS_DIR/mount_gpt_image.sh" -i "$NEW_IMAGE_NAME" -f "$WORKING_DIR" \
    -r "$ROOT_FS_DIR" -s "$STATEFUL_FS_DIR"

  info "Copying ${WORKING_UPDATER}-test${i} to ${IMAGE_UPDATER}"
  sudo cp ${WORKING_UPDATER}-test${i} ${IMAGE_UPDATER}
  NEW_CHROME_VERSION=${CHROMEOS_VER_PREFIX}${i}

  info "Updating chrome version to ${NEW_CHROME_VERSION}"
  sudo sed -i "s/${CHROMEOS_VER}/${NEW_CHROME_VERSION}/g" \
    "${ROOT_FS_DIR}/etc/lsb-release"
  sudo sed -i 's/tools/omaha.sandbox/g' "${ROOT_FS_DIR}/etc/lsb-release"

  info "Contents of the new lsb-release file"
  more "${ROOT_FS_DIR}/etc/lsb-release"
  cleanup
  # TODO run create_new_keys.sh
  SIGNED_IMAGE_NAME="chromiumos-key-image-${CHROMEOS_VER_PREFIX}${i}_signed.bin"

  info "Resigning the image to ${SIGNED_IMAGE_NAME}..."
  cd ~/trunk/src/platform/vboot_reference
  sudo scripts/image_signing/sign_official_build.sh \
    ssd "${WORKING_DIR}/${NEW_IMAGE_NAME}" \
    "${KEYS_DIR}" \
    "${WORKING_DIR}/${SIGNED_IMAGE_NAME}" \
    "${KEYSDIR}/key.versions"

  info "Generating payload..."
  cros_generate_update_payload --image="${WORKING_DIR}/${SIGNED_IMAGE_NAME}" \
    --output="${PAYLOAD_DIR}/chromeos_${CHROMEOS_VER_PREFIX}${i}\
_${FLAGS_board}_testimage-channel_full_test.bin-000${i}.signed"
done

info "All payloads are available at ${PAYLOAD_DIR}"

