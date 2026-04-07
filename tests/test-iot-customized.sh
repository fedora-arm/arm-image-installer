#!/bin/bash
# Test: IoT image with full customization
# Create a custom IoT image with resize, SSH key, and other options

set -e -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/helpers"
TEST_OUTPUT_DIR="${TEST_OUTPUT_DIR:-/var/tmp/arm-image-installer-tests}"

# Verify helpers directory exists
if [ ! -d "$HELPERS_DIR" ]; then
    echo "Error: Helpers directory not found: $HELPERS_DIR"
    exit 1
fi

TEST_START_TIME=$(date +%s 2>/dev/null || echo "0")

echo "======================================================"
echo "= Test: IoT Image - Full Customization"
echo "= Started: $(date)"
echo "======================================================"

# Create output directory
if ! mkdir -p "$TEST_OUTPUT_DIR"; then
    echo "Error: Failed to create output directory: $TEST_OUTPUT_DIR"
    exit 1
fi

# Download IoT image
echo "= Step 1: Downloading IoT image..."
IOT_IMAGE=$("${HELPERS_DIR}/download-images.sh" iot)

if [ -z "$IOT_IMAGE" ] || [ ! -f "$IOT_IMAGE" ]; then
    echo "Error: Failed to download IoT image"
    exit 1
fi

if [ ! -r "$IOT_IMAGE" ]; then
    echo "Error: IoT image is not readable: $IOT_IMAGE"
    exit 1
fi

echo "= Using image: $IOT_IMAGE"

# Generate SSH key for testing
SSH_KEY=$("${HELPERS_DIR}/generate-ssh-key.sh" "${TEST_OUTPUT_DIR}/test_rsa")

# Create ignition configuration
# Note: Testing that ignition works alongside other customization options
IGNITION_FILE="${TEST_OUTPUT_DIR}/test-iot-customized.ign"
IGNITION_USER="core"

# Read the SSH public key
SSH_PUB_KEY=$(cat "${SSH_KEY}.pub")

# Create the ignition file with network configuration
cat > "$IGNITION_FILE" <<EOF
{
  "ignition": {
    "version": "3.3.0"
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": [
          "${SSH_PUB_KEY}"
        ]
      }
    ]
  },
  "storage": {
    "files": [
      {
        "path": "/etc/hostname",
        "mode": 420,
        "contents": {
          "source": "data:,iot-test-device"
        }
      }
    ]
  }
}
EOF

echo "= Created ignition config: $IGNITION_FILE"

# Validate ignition JSON syntax if python3 is available
if command -v python3 &>/dev/null; then
    if ! python3 -m json.tool "$IGNITION_FILE" >/dev/null 2>&1; then
        echo "Error: Ignition file has invalid JSON syntax"
        echo "Please check: $IGNITION_FILE"
        exit 1
    fi
    echo "= ✓ Ignition JSON syntax validated"
fi

# Create output file (20GB to test resize)
OUTPUT_IMAGE="${TEST_OUTPUT_DIR}/test-iot-customized.img"
rm -f "$OUTPUT_IMAGE"

# Check disk space before creating 20GB file
AVAILABLE_SPACE=$(df -k "$TEST_OUTPUT_DIR" | tail -1 | awk '{print $4}')
REQUIRED_SPACE=$((25 * 1024 * 1024))  # 25GB in KB (20GB + buffer)
if [[ "$AVAILABLE_SPACE" =~ ^[0-9]+$ ]] && [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
    echo "Error: Insufficient disk space in $TEST_OUTPUT_DIR"
    echo "Available: $(numfmt --to=iec-i --suffix=B $((AVAILABLE_SPACE * 1024)) 2>/dev/null || echo ${AVAILABLE_SPACE}KB)"
    echo "Required: ~25GB for 20GB test image + overhead"
    exit 1
fi

echo "= Creating 20GB disk image (this may take a few minutes)..."
# Try with status=progress, fall back without if not supported
set +e
dd if=/dev/zero of="$OUTPUT_IMAGE" bs=1M count=20480 status=progress 2>/dev/null
DD_EXIT=$?
set -e
if [ $DD_EXIT -ne 0 ]; then
    # Retry without status=progress if it failed
    echo "= Retrying dd without status=progress..."
    dd if=/dev/zero of="$OUTPUT_IMAGE" bs=1M count=20480
elif [ ! -f "$OUTPUT_IMAGE" ]; then
    echo "Error: dd reported success but output file not created"
    exit 1
fi

echo "= Step 2: Creating custom image with full options..."
echo "= Output: $OUTPUT_IMAGE"
echo "= Options: --ignition --resizefs --addkey --norootpass --wifi"

# Verify arm-image-installer exists
ARM_IMAGE_INSTALLER="${SCRIPT_DIR}/../arm-image-installer"
if [ ! -f "$ARM_IMAGE_INSTALLER" ]; then
    echo "Error: arm-image-installer not found at: $ARM_IMAGE_INSTALLER"
    exit 1
fi

# Run arm-image-installer with multiple options including ignition (check if already root)
# Note: Testing that ignition works alongside other customization options
if [ "$(id -u)" -eq 0 ]; then
    "$ARM_IMAGE_INSTALLER" \
        --image="$IOT_IMAGE" \
        --media="$OUTPUT_IMAGE" \
        --target=rpi4 \
        --ignition="$IGNITION_FILE" \
        --resizefs \
        --addkey="${SSH_KEY}.pub" \
        --norootpass \
        --wifi-ssid="TestNetwork" \
        --wifi-pass="TestPassword123" \
        --wifi-security=wpa-psk \
        -y
else
    sudo "$ARM_IMAGE_INSTALLER" \
        --image="$IOT_IMAGE" \
        --media="$OUTPUT_IMAGE" \
        --target=rpi4 \
        --ignition="$IGNITION_FILE" \
        --resizefs \
        --addkey="${SSH_KEY}.pub" \
        --norootpass \
        --wifi-ssid="TestNetwork" \
        --wifi-pass="TestPassword123" \
        --wifi-security=wpa-psk \
        -y
fi

if [ ! -f "$OUTPUT_IMAGE" ]; then
    echo "Error: Output image was not created"
    exit 1
fi

echo "= ✓ Image created successfully"

echo "= Step 3: Verifying image customizations..."

if ! "${HELPERS_DIR}/verify-image.sh" \
    --verify-ignition "$IGNITION_FILE" \
    --verify-ssh-key "${SSH_KEY}.pub" \
    --verify-resize \
    --verify-noroot \
    --verify-wifi "TestNetwork" \
    "$OUTPUT_IMAGE"; then
    echo "Error: Image verification failed"
    exit 1
fi

echo "= ✓ All customizations verified (including ignition)"

TEST_END_TIME=$(date +%s 2>/dev/null || echo "0")
TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))

echo "======================================================"
echo "= ✓ Test PASSED: IoT Customized"
if [ "$TEST_START_TIME" != "0" ] && [ "$TEST_END_TIME" != "0" ]; then
    echo "= Duration: $((TEST_DURATION / 60)) minutes $((TEST_DURATION % 60)) seconds"
fi
echo "======================================================"

exit 0
