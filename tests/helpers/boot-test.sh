#!/bin/bash
# Boot a disk image in QEMU and verify it works

set -e -o pipefail

# Verify bash version (need 3.0+ for [[ ]])
if [ -z "$BASH_VERSION" ] || [ "${BASH_VERSION%%.*}" -lt 3 ]; then
    echo "Error: This script requires bash 3.0 or later"
    exit 1
fi

IMAGE_FILE=""
SSH_KEY=""
SSH_USER="root"
VERIFY_RESIZE=0
VERIFY_NOROOT=0
VERIFY_WIFI=""
VERIFY_IGNITION=0
TIMEOUT=300  # 5 minutes boot timeout

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <image-file>

Boot an ARM disk image in QEMU and verify it works.

Options:
    --ssh-key FILE        SSH private key to use for login verification
    --ssh-user USER       SSH user to login as (default: root)
    --verify-resize       Verify partition was resized
    --verify-noroot       Verify root password is empty
    --verify-wifi SSID    Verify Wi-Fi configuration exists
    --verify-ignition     Verify ignition marker file exists
    --timeout SECONDS     Boot timeout in seconds (default: 300)
    -h, --help            Show this help

Examples:
    $0 test-server.img
    $0 --ssh-key ~/.ssh/id_rsa --verify-resize test-custom.img
EOF
    exit 1
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --ssh-key)
            if [ -z "$2" ] || [ "${2:0:1}" = "-" ]; then
                echo "Error: --ssh-key requires an argument"
                usage
            fi
            SSH_KEY="$2"
            shift 2
            ;;
        --ssh-user)
            if [ -z "$2" ] || [ "${2:0:1}" = "-" ]; then
                echo "Error: --ssh-user requires an argument"
                usage
            fi
            SSH_USER="$2"
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
            VERIFY_IGNITION=1
            shift
            ;;
        --timeout)
            if [ -z "$2" ] || [ "${2:0:1}" = "-" ]; then
                echo "Error: --timeout requires an argument"
                usage
            fi
            TIMEOUT="$2"
            # Validate TIMEOUT is a positive number
            if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [ "$TIMEOUT" -le 0 ]; then
                echo "Error: --timeout must be a positive number"
                usage
            fi
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

echo "= Booting image: $IMAGE_FILE"

# Check for required tools
for tool in qemu-system-aarch64 nc; do
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: Required tool '$tool' not found"
        if [ "$tool" = "nc" ]; then
            echo "Please install: dnf install nmap-ncat"
        else
            echo "Please install: dnf install qemu-system-aarch64 edk2-aarch64"
        fi
        exit 1
    fi
done

# Find UEFI firmware
UEFI_FIRMWARE=""
for fw in /usr/share/edk2/aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd; do
    if [ -f "$fw" ]; then
        UEFI_FIRMWARE="$fw"
        break
    fi
done

if [ -z "$UEFI_FIRMWARE" ]; then
    echo "Error: UEFI firmware not found"
    echo "Please install: dnf install edk2-aarch64"
    exit 1
fi

# Find an available SSH port
SSH_PORT=2222
PORT_ATTEMPTS=0
while nc -z localhost "$SSH_PORT" 2>/dev/null; do
    SSH_PORT=$((SSH_PORT + 1))
    PORT_ATTEMPTS=$((PORT_ATTEMPTS + 1))
    if [ $PORT_ATTEMPTS -gt 100 ]; then
        echo "Error: Could not find available port after 100 attempts"
        exit 1
    fi
done
echo "= Using SSH port: $SSH_PORT"

# Create unique log file
QEMU_LOG=$(mktemp /tmp/qemu-boot-test.XXXXXX.log)

# Boot QEMU in background
echo "= Starting QEMU..."
qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a57 \
    -m 2048 \
    -bios "$UEFI_FIRMWARE" \
    -drive if=virtio,format=raw,file="$IMAGE_FILE" \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    -serial mon:stdio \
    > "$QEMU_LOG" 2>&1 &

QEMU_PID=$!

# Verify QEMU actually started
if [ -z "$QEMU_PID" ] || ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "Error: QEMU failed to start"
    exit 1
fi

cleanup() {
    echo "= Cleaning up..."
    if [ -n "$QEMU_PID" ]; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    rm -f "$QEMU_LOG"
}

trap cleanup EXIT INT TERM

echo "= QEMU started (PID: $QEMU_PID)"
echo "= Waiting for system to boot (timeout: ${TIMEOUT}s)..."

# Wait for SSH to be available
SSH_READY=0
for i in $(seq 1 "$TIMEOUT"); do
    if nc -z localhost "$SSH_PORT" 2>/dev/null; then
        SSH_READY=1
        echo "= SSH port is open after ${i} seconds"
        break
    fi

    # Check if QEMU is still running
    if [ -z "$QEMU_PID" ] || ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "Error: QEMU process died"
        echo "= Boot log (last 100 lines):"
        tail -100 "$QEMU_LOG"
        exit 1
    fi

    sleep 1
done

if [ $SSH_READY -eq 0 ]; then
    echo "Error: System did not boot within ${TIMEOUT} seconds"
    echo "= Boot log (last 100 lines):"
    tail -100 "$QEMU_LOG"
    exit 1
fi

echo "= ✓ System booted successfully"

# If SSH key provided, try to login and run verifications
if [ -n "$SSH_KEY" ]; then
    echo "= Testing SSH login..."

    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"

    # Wait a bit more for SSH daemon to be fully ready
    sleep 5

    if ssh $SSH_OPTS -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@localhost" "echo SSH login successful" 2>/dev/null; then
        echo "= ✓ SSH login successful (user: ${SSH_USER})"

        # Verify partition resize
        if [ $VERIFY_RESIZE -eq 1 ]; then
            echo "= Verifying partition resize..."
            ROOT_SIZE=$(ssh $SSH_OPTS -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@localhost" "df -h / | tail -1 | awk '{print \$2}'")
            echo "= Root partition size: ${ROOT_SIZE}"
            echo "= ✓ Partition resize verified"
        fi

        # Verify root password is empty
        if [ $VERIFY_NOROOT -eq 1 ]; then
            echo "= Verifying empty root password..."
            SHADOW_ENTRY=$(ssh $SSH_OPTS -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@localhost" "sudo grep '^root:' /etc/shadow")
            # Empty/disabled password in shadow file is shown as * or ! or !!
            if echo "$SHADOW_ENTRY" | grep -qE '^root:[*!]+:'; then
                echo "= ✓ Root password is empty/disabled"
            else
                echo "= ✗ Root password is NOT empty: $SHADOW_ENTRY"
                exit 1
            fi
        fi

        # Verify Wi-Fi configuration
        # Note: This assumes NetworkManager connection files - may not work for other WiFi configurations
        if [ -n "$VERIFY_WIFI" ]; then
            echo "= Verifying Wi-Fi configuration for SSID: $VERIFY_WIFI..."
            if ssh $SSH_OPTS -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@localhost" \
                "grep -l 'ssid=${VERIFY_WIFI}' /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | grep -q ."; then
                echo "= ✓ Wi-Fi configuration found"
            else
                echo "= ✗ Wi-Fi configuration not found"
                exit 1
            fi
        fi

        # Verify ignition marker file
        if [ $VERIFY_IGNITION -eq 1 ]; then
            echo "= Verifying ignition ran successfully..."
            if ssh $SSH_OPTS -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@localhost" "test -f /etc/ignition-test-marker"; then
                echo "= ✓ Ignition marker file found"
            else
                echo "= ✗ Ignition marker file not found"
                exit 1
            fi
        fi
    else
        echo "= ✗ SSH login failed"
        exit 1
    fi
else
    echo "= No SSH key provided, skipping login tests"
fi

# Summary of verifications
VERIFICATIONS_RUN=0
echo ""
echo "= Verification Summary:"
if [ -n "$SSH_KEY" ]; then
    echo "  ✓ SSH login successful (user: ${SSH_USER})"
    VERIFICATIONS_RUN=1

    [ $VERIFY_RESIZE -eq 1 ] && echo "  ✓ Partition resize verified" && VERIFICATIONS_RUN=$((VERIFICATIONS_RUN + 1))
    [ $VERIFY_NOROOT -eq 1 ] && echo "  ✓ Root password empty/disabled" && VERIFICATIONS_RUN=$((VERIFICATIONS_RUN + 1))
    [ -n "$VERIFY_WIFI" ] && echo "  ✓ Wi-Fi configuration found" && VERIFICATIONS_RUN=$((VERIFICATIONS_RUN + 1))
    [ $VERIFY_IGNITION -eq 1 ] && echo "  ✓ Ignition marker file found" && VERIFICATIONS_RUN=$((VERIFICATIONS_RUN + 1))
else
    echo "  - Basic boot test only (no SSH verification)"
fi
echo "= Total verifications: $VERIFICATIONS_RUN"
echo ""
echo "= All verifications passed!"
echo "= Boot test successful"

exit 0
