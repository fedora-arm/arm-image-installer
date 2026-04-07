#!/bin/bash
# Verify disk image structure and contents without booting
# Mounts the image and checks for expected customizations

set -e -o pipefail

# Verify bash version (need 3.0+ for [[ ]])
if [ -z "$BASH_VERSION" ] || [ "${BASH_VERSION%%.*}" -lt 3 ]; then
    echo "Error: This script requires bash 3.0 or later"
    exit 1
fi

IMAGE_FILE=""
VERIFY_SSH_KEY=""
VERIFY_RESIZE=0
VERIFY_NOROOT=0
VERIFY_WIFI=""
VERIFY_IGNITION=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <image-file>

Verify disk image structure and contents without booting.

Options:
    --verify-ssh-key FILE    Verify SSH public key was added to authorized_keys
    --verify-resize          Verify root partition was resized
    --verify-noroot          Verify root password was cleared
    --verify-wifi SSID       Verify Wi-Fi configuration exists
    --verify-ignition FILE   Verify ignition config was embedded on boot partition
    -h, --help               Show this help

Examples:
    $0 test-server.img
    $0 --verify-ssh-key ~/.ssh/test.pub --verify-resize test-custom.img
    $0 --verify-ignition ignition.ign test-iot.img
EOF
    exit 1
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --verify-ssh-key)
            if [ -z "$2" ] || [ "${2:0:1}" = "-" ]; then
                echo "Error: --verify-ssh-key requires an argument"
                usage
            fi
            VERIFY_SSH_KEY="$2"
            shift 2
            ;;
        --verify-resize)
            VERIFY_RESIZE=1
            shift
            ;;
        --verify-noroot)
            VERIFY_NOROOT=1
            shift
            ;;
        --verify-wifi)
            if [ -z "$2" ] || [ "${2:0:1}" = "-" ]; then
                echo "Error: --verify-wifi requires an argument"
                usage
            fi
            VERIFY_WIFI="$2"
            shift 2
            ;;
        --verify-ignition)
            if [ -z "$2" ] || [ "${2:0:1}" = "-" ]; then
                echo "Error: --verify-ignition requires an argument"
                usage
            fi
            VERIFY_IGNITION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Error: Unknown option: $1"
            usage
            ;;
        *)
            IMAGE_FILE="$1"
            shift
            ;;
    esac
done

if [ -z "$IMAGE_FILE" ]; then
    echo "Error: No image file specified"
    usage
fi

if [ ! -f "$IMAGE_FILE" ]; then
    echo "Error: Image file not found: $IMAGE_FILE"
    exit 1
fi

echo "= Verifying image: $IMAGE_FILE"

# Check for required tools
for tool in fdisk losetup file blkid pvs lvs vgchange; do
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: Required tool '$tool' not found"
        exit 1
    fi
done

# Verify we're running as root (needed for losetup/mount)
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Basic file checks
echo "= Checking basic image properties..."
FILE_TYPE=$(file "$IMAGE_FILE")
echo "= File type: $FILE_TYPE"

if ! echo "$FILE_TYPE" | grep -qE "DOS/MBR boot sector|block special"; then
    echo "Warning: Image doesn't appear to be a disk image"
fi

IMAGE_SIZE=$(stat -c "%s" "$IMAGE_FILE" 2>/dev/null || stat -f "%z" "$IMAGE_FILE" 2>/dev/null || echo "0")
echo "= Image size: $(numfmt --to=iec-i --suffix=B $IMAGE_SIZE 2>/dev/null || echo ${IMAGE_SIZE} bytes)"

if [ "$IMAGE_SIZE" -lt 1000000000 ]; then
    echo "Error: Image seems too small (${IMAGE_SIZE} bytes)"
    exit 1
fi

# Check partition table
echo "= Checking partition table..."
fdisk -l "$IMAGE_FILE" > /tmp/fdisk-output.txt 2>&1 || true

if ! grep -q "Disklabel type:" /tmp/fdisk-output.txt; then
    echo "Error: Could not read partition table"
    cat /tmp/fdisk-output.txt
    exit 1
fi

echo "= Partition table:"
cat /tmp/fdisk-output.txt

# Set up loop device
echo "= Setting up loop device..."
LOOP_DEVICE=$(losetup -f -P --show "$IMAGE_FILE" 2>&1)
LOSETUP_EXIT=$?

if [ $LOSETUP_EXIT -ne 0 ] || [ -z "$LOOP_DEVICE" ]; then
    echo "Warning: Failed to create loop device (losetup exit: $LOSETUP_EXIT)"
    echo "Error output: $LOOP_DEVICE"

    # If any verification flags were requested, we can't proceed without mounting
    if [ -n "$VERIFY_SSH_KEY" ] || [ $VERIFY_NOROOT -eq 1 ] || [ -n "$VERIFY_WIFI" ] || [ $VERIFY_RESIZE -eq 1 ] || [ -n "$VERIFY_IGNITION" ]; then
        echo "Error: Cannot verify customizations without mounting the image"
        echo "This may happen in virtualized environments without loop device support"
        exit 1
    fi

    # For basic verification without mounting, just check what we can
    echo "= Running basic verification without mounting..."
    echo "= Verification Summary:"
    echo "  ✓ Image file is valid disk image"
    echo "  ✓ Partition table is readable"
    echo "  - Could not mount image to verify filesystem"
    echo "= Basic verification passed (limited)"
    exit 0
fi

echo "= Loop device: $LOOP_DEVICE"

cleanup() {
    echo "= Cleaning up..."
    if [ -n "$MOUNT_POINT" ] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    if [ -n "$BOOT_MOUNT" ] && mountpoint -q "$BOOT_MOUNT" 2>/dev/null; then
        umount "$BOOT_MOUNT" 2>/dev/null || true
    fi
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
    if [ -n "$BOOT_MOUNT" ] && [ -d "$BOOT_MOUNT" ]; then
        rmdir "$BOOT_MOUNT" 2>/dev/null || true
    fi
    # Deactivate LVM volume group if it was activated
    if [ -n "$LVM_NAME" ] && [ -n "$LOOP_DEVICE" ] && [ -n "$ROOT_PARTITION" ]; then
        vgchange --devicesfile "" --devices "$LOOP_DEVICE" --devices "$ROOT_PARTITION" -a n "$LVM_NAME" > /dev/null 2>&1 || true
    fi
    if [ -n "$LOOP_DEVICE" ]; then
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
    rm -f /tmp/fdisk-output.txt
}

trap cleanup EXIT INT TERM

# Wait for partition devices to appear
sleep 2

# Find root partition (usually p3 or p2)
ROOT_PARTITION=""
for part in "${LOOP_DEVICE}p3" "${LOOP_DEVICE}p2"; do
    if [ -b "$part" ]; then
        ROOT_PARTITION="$part"
        break
    fi
done

if [ -z "$ROOT_PARTITION" ]; then
    echo "Error: Could not find root partition"
    ls -la "${LOOP_DEVICE}"* || true
    exit 1
fi

echo "= Root partition: $ROOT_PARTITION"

# Check if this is an LVM partition
LVM_NAME=""
LV_NAME=""
ROOTLV=""
PART_TYPE=$(blkid -p -s TYPE -o value "$ROOT_PARTITION" 2>/dev/null || echo "")

if [ "$PART_TYPE" = "LVM2_member" ]; then
    echo "= Detected LVM partition, activating volume group..."

    # Get volume group name
    LVM_NAME=$(pvs --devicesfile "" --devices "$LOOP_DEVICE" --devices "$ROOT_PARTITION" -o vg_name --noheadings "$ROOT_PARTITION" 2>/dev/null | tr -d ' ')

    if [ -z "$LVM_NAME" ]; then
        echo "Error: Could not determine LVM volume group name"
        exit 1
    fi

    echo "= Volume Group: $LVM_NAME"

    # Get logical volume name
    LV_NAME=$(lvs --devicesfile "" --devices "$LOOP_DEVICE" --devices "$ROOT_PARTITION" -o lv_name --noheadings "$LVM_NAME" 2>/dev/null | tr -d ' ')

    if [ -z "$LV_NAME" ]; then
        echo "Error: Could not determine LVM logical volume name"
        exit 1
    fi

    echo "= Logical Volume: $LV_NAME"

    # Activate the volume group
    if ! vgchange --devicesfile "" --devices "$LOOP_DEVICE" --devices "$ROOT_PARTITION" -a y "$LVM_NAME" > /dev/null 2>&1; then
        echo "Error: Failed to activate volume group $LVM_NAME"
        exit 1
    fi

    # Set the actual device to mount
    ROOTLV="/dev/$LVM_NAME/$LV_NAME"
    echo "= Will mount LVM volume: $ROOTLV"
else
    echo "= Partition type: $PART_TYPE (not LVM)"
    ROOTLV="$ROOT_PARTITION"
fi

# Check partition/volume size if --verify-resize is set
if [ $VERIFY_RESIZE -eq 1 ]; then
    echo "= Verifying filesystem was resized..."

    if [ -n "$ROOTLV" ] && [ "$PART_TYPE" = "LVM2_member" ]; then
        # For LVM, check the logical volume size
        FS_SIZE=$(blockdev --getsize64 "$ROOTLV" 2>/dev/null || echo "0")
        FS_SIZE_GB=$((FS_SIZE / 1024 / 1024 / 1024))
        echo "= LVM logical volume size: ${FS_SIZE_GB}GB ($(numfmt --to=iec-i --suffix=B $FS_SIZE 2>/dev/null || echo ${FS_SIZE} bytes))"
    else
        # For regular partitions, check partition size
        FS_SIZE=$(blockdev --getsize64 "$ROOT_PARTITION" 2>/dev/null || echo "0")
        FS_SIZE_GB=$((FS_SIZE / 1024 / 1024 / 1024))
        echo "= Root partition size: ${FS_SIZE_GB}GB ($(numfmt --to=iec-i --suffix=B $FS_SIZE 2>/dev/null || echo ${FS_SIZE} bytes))"
    fi

    # For a resized 20GB image, root filesystem should be at least 15GB
    if [ "$FS_SIZE_GB" -ge 15 ]; then
        echo "= ✓ Filesystem was resized (${FS_SIZE_GB}GB)"
    else
        echo "= ✗ Filesystem does not appear to be resized (only ${FS_SIZE_GB}GB)"
        exit 1
    fi
fi

# Mount the root filesystem (either partition or LVM volume)
MOUNT_POINT=$(mktemp -d /tmp/verify-image-mount.XXXXXX)
echo "= Mounting root filesystem at $MOUNT_POINT..."

if ! mount -o ro "$ROOTLV" "$MOUNT_POINT"; then
    echo "Error: Failed to mount root filesystem"
    exit 1
fi

echo "= ✓ Root filesystem mounted successfully"

# Verify filesystem contents
echo "= Checking filesystem contents..."

# Detect image type and set paths (matching arm-image-installer logic)
IOT_IMAGE=0
PREFIX="$MOUNT_POINT"
OSTREE_ROOT_HOME=""

if [ -d "$MOUNT_POINT/ostree" ]; then
    echo "= Detected OSTree-based system (IoT/Silverblue)"
    IOT_IMAGE=1

    if [ ! -d "$MOUNT_POINT/ostree/deploy" ]; then
        echo "Error: OSTree filesystem missing deploy directory"
        exit 1
    fi

    # Set OSTree-specific paths (matching arm-image-installer)
    OSTREE_ROOT_HOME="$MOUNT_POINT/ostree/deploy/fedora-iot/var/roothome"
    # PREFIX will be expanded from wildcard
    PREFIX=$(echo $MOUNT_POINT/ostree/deploy/fedora-iot/deploy/*/)

    echo "= ✓ OSTree filesystem structure looks correct"
else
    # Traditional filesystem - check for basic directories
    for dir in etc usr var; do
        if [ ! -d "$MOUNT_POINT/$dir" ]; then
            echo "Error: Missing expected directory: /$dir"
            exit 1
        fi
    done
    echo "= ✓ Basic filesystem structure looks correct"
fi

# Verify SSH key was added
if [ -n "$VERIFY_SSH_KEY" ]; then
    echo "= Verifying SSH key was added..."

    if [ ! -f "$VERIFY_SSH_KEY" ]; then
        echo "Error: SSH public key not found: $VERIFY_SSH_KEY"
        exit 1
    fi

    # Set authorized_keys path based on image type (matching arm-image-installer)
    if [ $IOT_IMAGE -eq 1 ]; then
        AUTH_KEYS="$OSTREE_ROOT_HOME/.ssh/authorized_keys"
    else
        AUTH_KEYS="$PREFIX/root/.ssh/authorized_keys"
    fi

    if [ ! -f "$AUTH_KEYS" ]; then
        echo "Error: authorized_keys file not found at $AUTH_KEYS"
        exit 1
    fi

    SSH_KEY_CONTENT=$(cat "$VERIFY_SSH_KEY")
    if grep -qF "$SSH_KEY_CONTENT" "$AUTH_KEYS"; then
        echo "= ✓ SSH key found in authorized_keys"
    else
        echo "= ✗ SSH key NOT found in authorized_keys"
        exit 1
    fi
fi

# Verify root password was cleared
if [ $VERIFY_NOROOT -eq 1 ]; then
    echo "= Verifying root password was cleared..."

    # arm-image-installer uses sed on /etc/passwd (not /etc/shadow)
    PASSWD_FILE="$PREFIX/etc/passwd"
    if [ ! -f "$PASSWD_FILE" ]; then
        echo "Error: passwd file not found at $PASSWD_FILE"
        exit 1
    fi

    # Check if root password field is empty (root::) instead of (root:x:)
    ROOT_PASSWD=$(grep "^root:" "$PASSWD_FILE")
    if echo "$ROOT_PASSWD" | grep -qE '^root::'; then
        echo "= ✓ Root password is empty"
    else
        echo "= ✗ Root password is NOT empty: $ROOT_PASSWD"
        exit 1
    fi
fi

# Verify Wi-Fi configuration
if [ -n "$VERIFY_WIFI" ]; then
    echo "= Verifying Wi-Fi configuration for SSID: $VERIFY_WIFI..."

    # arm-image-installer puts WiFi configs in PREFIX/etc/NetworkManager/system-connections
    NM_CONNECTIONS="$PREFIX/etc/NetworkManager/system-connections"
    if [ ! -d "$NM_CONNECTIONS" ]; then
        echo "Error: NetworkManager connections directory not found at $NM_CONNECTIONS"
        exit 1
    fi

    if grep -l "ssid=${VERIFY_WIFI}" "$NM_CONNECTIONS"/*.nmconnection 2>/dev/null | grep -q .; then
        echo "= ✓ Wi-Fi configuration found"
    else
        echo "= ✗ Wi-Fi configuration not found"
        echo "= Connections directory contents:"
        ls -la "$NM_CONNECTIONS" || true
        exit 1
    fi
fi

# Verify ignition configuration was embedded
if [ -n "$VERIFY_IGNITION" ]; then
    echo "= Verifying ignition configuration was embedded..."

    if [ ! -f "$VERIFY_IGNITION" ]; then
        echo "Error: Ignition file not found: $VERIFY_IGNITION"
        exit 1
    fi

    # Mount the boot partition (p2 - arm-image-installer uses p2 for boot)
    BOOT_PARTITION="${LOOP_DEVICE}p2"
    if [ ! -b "$BOOT_PARTITION" ]; then
        echo "Error: Boot partition not found: $BOOT_PARTITION"
        exit 1
    fi

    BOOT_MOUNT=$(mktemp -d /tmp/verify-boot-mount.XXXXXX)
    echo "= Mounting boot partition at $BOOT_MOUNT..."

    if ! mount -o ro "$BOOT_PARTITION" "$BOOT_MOUNT"; then
        echo "Error: Failed to mount boot partition"
        rmdir "$BOOT_MOUNT" 2>/dev/null || true
        exit 1
    fi

    # Check for ignition config file (arm-image-installer copies to /ignition/config.ign)
    BOOT_IGNITION="$BOOT_MOUNT/ignition/config.ign"
    if [ ! -f "$BOOT_IGNITION" ]; then
        echo "= ✗ Ignition file not found at /ignition/config.ign on boot partition"
        echo "= Boot partition contents:"
        ls -laR "$BOOT_MOUNT" || true
        exit 1
    fi

    # Verify the ignition file content matches what we passed
    if diff -q "$VERIFY_IGNITION" "$BOOT_IGNITION" > /dev/null 2>&1; then
        echo "= ✓ Ignition configuration file matches"
    else
        echo "= ✗ Ignition configuration file differs from source"
        echo "= Expected: $VERIFY_IGNITION"
        echo "= Found: $BOOT_IGNITION"
        exit 1
    fi

    # Check that ignition.firstboot has the right kernel parameters
    IGNITION_FIRSTBOOT="$BOOT_MOUNT/ignition.firstboot"
    if [ ! -f "$IGNITION_FIRSTBOOT" ]; then
        echo "Warning: ignition.firstboot file not found (may be normal for some images)"
    elif grep -q "ignition.firstboot=1" "$IGNITION_FIRSTBOOT" && grep -q "ignition.config.file=/ignition/config.ign" "$IGNITION_FIRSTBOOT"; then
        echo "= ✓ Ignition kernel parameters configured correctly"
    else
        echo "Warning: ignition.firstboot exists but doesn't have expected parameters"
        echo "= Contents: $(cat "$IGNITION_FIRSTBOOT")"
    fi
fi

# Summary
VERIFICATIONS_RUN=0

echo ""
echo "= Verification Summary:"
echo "  ✓ Image file is valid disk image"
echo "  ✓ Partition table is readable"
echo "  ✓ Root filesystem is mountable"
if [ $IOT_IMAGE -eq 1 ]; then
    echo "  ✓ OSTree filesystem structure is correct"
else
    echo "  ✓ Basic filesystem structure is correct"
fi
VERIFICATIONS_RUN=4

[ $VERIFY_RESIZE -eq 1 ] && echo "  ✓ Filesystem was resized" && VERIFICATIONS_RUN=$((VERIFICATIONS_RUN + 1))
[ -n "$VERIFY_SSH_KEY" ] && echo "  ✓ SSH key was added" && VERIFICATIONS_RUN=$((VERIFICATIONS_RUN + 1))
[ $VERIFY_NOROOT -eq 1 ] && echo "  ✓ Root password cleared" && VERIFICATIONS_RUN=$((VERIFICATIONS_RUN + 1))
[ -n "$VERIFY_WIFI" ] && echo "  ✓ Wi-Fi configuration added" && VERIFICATIONS_RUN=$((VERIFICATIONS_RUN + 1))
[ -n "$VERIFY_IGNITION" ] && echo "  ✓ Ignition configuration embedded" && VERIFICATIONS_RUN=$((VERIFICATIONS_RUN + 1))

echo "= Total verifications: $VERIFICATIONS_RUN"
echo ""
echo "= All verifications passed!"

exit 0
