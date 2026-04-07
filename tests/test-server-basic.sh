#!/bin/bash
# Test: Basic Server image creation
# Download latest Server image and create a custom disk image with minimal options

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
echo "= Test: Server Image - Basic Creation"
echo "= Started: $(date)"
echo "======================================================"

# Create output directory
if ! mkdir -p "$TEST_OUTPUT_DIR"; then
    echo "Error: Failed to create output directory: $TEST_OUTPUT_DIR"
    exit 1
fi

# Download Server image
echo "= Step 1: Downloading Server image..."
SERVER_IMAGE=$("${HELPERS_DIR}/download-images.sh" server)

if [ -z "$SERVER_IMAGE" ] || [ ! -f "$SERVER_IMAGE" ]; then
    echo "Error: Failed to download Server image"
    exit 1
fi

if [ ! -r "$SERVER_IMAGE" ]; then
    echo "Error: Server image is not readable: $SERVER_IMAGE"
    exit 1
fi

echo "= Using image: $SERVER_IMAGE"

# Create output file (empty file for arm-image-installer to write to)
OUTPUT_IMAGE="${TEST_OUTPUT_DIR}/test-server-basic.img"
rm -f "$OUTPUT_IMAGE"
if ! touch "$OUTPUT_IMAGE"; then
    echo "Error: Failed to create output image file: $OUTPUT_IMAGE"
    exit 1
fi

echo "= Step 2: Creating custom image with arm-image-installer..."
echo "= Output: $OUTPUT_IMAGE"

# Verify arm-image-installer exists
ARM_IMAGE_INSTALLER="${SCRIPT_DIR}/../arm-image-installer"
if [ ! -f "$ARM_IMAGE_INSTALLER" ]; then
    echo "Error: arm-image-installer not found at: $ARM_IMAGE_INSTALLER"
    exit 1
fi

# Run arm-image-installer (check if already root)
if [ "$(id -u)" -eq 0 ]; then
    "$ARM_IMAGE_INSTALLER" \
        --image="$SERVER_IMAGE" \
        --media="$OUTPUT_IMAGE" \
        --target=none \
        -y
else
    sudo "$ARM_IMAGE_INSTALLER" \
        --image="$SERVER_IMAGE" \
        --media="$OUTPUT_IMAGE" \
        --target=none \
        -y
fi

if [ ! -f "$OUTPUT_IMAGE" ]; then
    echo "Error: Output image was not created"
    exit 1
fi

echo "= ✓ Image created successfully"

# Verify image size (Linux stat)
IMAGE_SIZE=$(stat -c "%s" "$OUTPUT_IMAGE" 2>/dev/null || stat -f "%z" "$OUTPUT_IMAGE" 2>/dev/null || echo "0")

if [ -z "$IMAGE_SIZE" ] || [ "$IMAGE_SIZE" = "0" ]; then
    echo "Error: Could not determine image size"
    exit 1
fi

# Validate IMAGE_SIZE is a number
if ! [[ "$IMAGE_SIZE" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid image size: $IMAGE_SIZE"
    exit 1
fi

echo "= Image size: $(numfmt --to=iec-i --suffix=B $IMAGE_SIZE 2>/dev/null || echo ${IMAGE_SIZE} bytes)"

if [ "$IMAGE_SIZE" -lt 1000000000 ]; then
    echo "Error: Image seems too small (${IMAGE_SIZE} bytes)"
    exit 1
fi

echo "= Step 3: Verifying image structure..."

if ! "${HELPERS_DIR}/verify-image.sh" "$OUTPUT_IMAGE"; then
    echo "Error: Image verification failed"
    exit 1
fi

TEST_END_TIME=$(date +%s 2>/dev/null || echo "0")
TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))

echo "======================================================"
echo "= ✓ Test PASSED: Server Basic"
if [ "$TEST_START_TIME" != "0" ] && [ "$TEST_END_TIME" != "0" ]; then
    echo "= Duration: $((TEST_DURATION / 60)) minutes $((TEST_DURATION % 60)) seconds"
fi
echo "======================================================"

exit 0
