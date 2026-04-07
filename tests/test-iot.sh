#!/bin/bash
# Test: IoT image with ignition configuration
# Create a custom IoT image with ignition file

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
echo "= Test: IoT Image - Ignition Configuration"
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
# Note: IoT images use 'core' as the default user, not 'root'
IGNITION_FILE="${TEST_OUTPUT_DIR}/test-ignition.ign"
IGNITION_USER="core"

# Read the SSH public key
SSH_PUB_KEY=$(cat "${SSH_KEY}.pub")

# Create the ignition file directly with the SSH key embedded
# Using here-doc with variable substitution (no quotes around EOF)
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
        "path": "/etc/ignition-test-marker",
        "mode": 420,
        "contents": {
          "source": "data:,Ignition%20configured%20by%20arm-image-installer%20test"
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

# Create output file (empty file for arm-image-installer to write to)
OUTPUT_IMAGE="${TEST_OUTPUT_DIR}/test-iot.img"
rm -f "$OUTPUT_IMAGE"
if ! touch "$OUTPUT_IMAGE"; then
    echo "Error: Failed to create output image file: $OUTPUT_IMAGE"
    exit 1
fi

echo "= Step 2: Creating custom IoT image with ignition..."
echo "= Output: $OUTPUT_IMAGE"

# Verify arm-image-installer exists
ARM_IMAGE_INSTALLER="${SCRIPT_DIR}/../arm-image-installer"
if [ ! -f "$ARM_IMAGE_INSTALLER" ]; then
    echo "Error: arm-image-installer not found at: $ARM_IMAGE_INSTALLER"
    exit 1
fi

# Run arm-image-installer with ignition (check if already root)
if [ "$(id -u)" -eq 0 ]; then
    "$ARM_IMAGE_INSTALLER" \
        --image="$IOT_IMAGE" \
        --media="$OUTPUT_IMAGE" \
        --target=rpi4 \
        --ignition="$IGNITION_FILE" \
        -y
else
    sudo "$ARM_IMAGE_INSTALLER" \
        --image="$IOT_IMAGE" \
        --media="$OUTPUT_IMAGE" \
        --target=rpi4 \
        --ignition="$IGNITION_FILE" \
        -y
fi

if [ ! -f "$OUTPUT_IMAGE" ]; then
    echo "Error: Output image was not created"
    exit 1
fi

echo "= ✓ Image created successfully"

echo "= Step 3: Verifying image and ignition embedding..."

# Verify image structure and that ignition file was embedded correctly
if ! "${HELPERS_DIR}/verify-image.sh" --verify-ignition "$IGNITION_FILE" "$OUTPUT_IMAGE"; then
    echo "Error: Image verification failed"
    exit 1
fi

echo "= ✓ Ignition file was embedded correctly on boot partition"
echo "= Note: Ignition configuration will be processed at boot time"

TEST_END_TIME=$(date +%s 2>/dev/null || echo "0")
TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))

echo "======================================================"
echo "= ✓ Test PASSED: IoT with Ignition"
if [ "$TEST_START_TIME" != "0" ] && [ "$TEST_END_TIME" != "0" ]; then
    echo "= Duration: $((TEST_DURATION / 60)) minutes $((TEST_DURATION % 60)) seconds"
fi
echo "======================================================"

exit 0
