#!/bin/bash
# Download Fedora ARM images from mirrors for testing

set -e -o pipefail

CACHE_DIR="${CACHE_DIR:-/var/tmp/arm-image-installer-test-cache}"
FEDORA_VERSION="${FEDORA_VERSION:-43}"

# Mirror URLs - handle both released versions and Rawhide
if [ "$FEDORA_VERSION" = "rawhide" ] || [ "$FEDORA_VERSION" = "Rawhide" ]; then
    SERVER_MIRROR_URL="https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Server/aarch64/images"
    IOT_COMPOSE_URL="https://kojipkgs.fedoraproject.org/compose/iot/latest-Fedora-IoT-44"
    MINIMAL_MIRROR_URL="https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Spins/aarch64/images"
else
    # Released versions (F42, F43, etc.)
    SERVER_MIRROR_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Server/aarch64/images"
    IOT_COMPOSE_URL="https://kojipkgs.fedoraproject.org/compose/iot/latest-Fedora-IoT-${FEDORA_VERSION}"
    MINIMAL_MIRROR_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Spins/aarch64/images"
fi

# Create cache directory
if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    echo "Error: Could not create cache directory: $CACHE_DIR"
    exit 1
fi

download_image() {
    local url_or_dir="$1"
    local image_type="$2"  # "Server", "IoT", or "Minimal"

    # Save stdout and redirect all output within function to stderr by default
    exec 3>&1 1>&2

    # Check if this is a Koji compose URL (for IoT) or a direct mirror URL
    if echo "$url_or_dir" | grep -q "latest-Fedora-IoT"; then
        # Handle Koji compose URL for IoT
        local compose_url="$url_or_dir"
        echo "= Downloading Fedora ${FEDORA_VERSION} ${image_type} image from Koji compose..."

        # Fetch the compose metadata to find the image filename
        local compose_id=$(curl -s "${compose_url}/COMPOSE_ID")
        local curl_exit=$?
        if [ $curl_exit -ne 0 ] || [ -z "$compose_id" ]; then
            echo "Error: Could not fetch COMPOSE_ID from ${compose_url}"
            echo "The compose may not exist or network is unavailable (curl exit: $curl_exit)"
            return 1
        fi
        echo "= Compose ID: ${compose_id}"

        # Construct image directory path for compose
        local image_dir="${compose_url}/compose/IoT/aarch64/images"
    else
        # Direct mirror URL
        local image_dir="$url_or_dir"
        echo "= Downloading Fedora ${FEDORA_VERSION} ${image_type} image from mirrors..."
    fi

    # List files and find the image
    echo "= Fetching file list from ${image_dir}..."

    # Fetch directory listing
    local dir_listing=$(curl -s "${image_dir}/")

    # Basic validation that we got HTML (not an error page)
    if ! echo "$dir_listing" | grep -qE '<html|<HTML|href='; then
        echo "Error: Directory listing doesn't appear to be valid HTML"
        echo "URL may be incorrect or server returned an error"
        return 1
    fi

    # Parse HTML to find image files - look for <a href="...raw.xz">
    # Use grep -F for literal string matching to avoid regex issues
    local image_file=$(echo "$dir_listing" | \
        grep -o 'href="[^"]*raw\.xz"' | \
        sed 's/href="//;s/"$//' | \
        grep -F "Fedora-${image_type}" | \
        grep "aarch64.*raw\.xz$" | \
        head -1)

    if [ -z "$image_file" ]; then
        echo "Error: Could not find ${image_type} image in ${image_dir}"
        echo "= Available files:"
        curl -s "${image_dir}/" | grep -o 'href="[^"]*"' | sed 's/href="//;s/"$//' | head -10
        return 1
    fi

    local image_url="${image_dir}/${image_file}"
    local cache_file="${CACHE_DIR}/${image_file}"

    # Check if already cached
    if [ -f "$cache_file" ]; then
        echo "= Image already cached: ${cache_file}"
        echo "$cache_file" >&3
        return 0
    fi

    # Download the image
    echo "= Downloading ${image_file}..."
    echo "= URL: ${image_url}"

    # Check available disk space (need at least 10GB free)
    local available_space=$(df -k "$CACHE_DIR" | tail -1 | awk '{print $4}')
    local required_space=$((10 * 1024 * 1024))  # 10GB in KB

    # Validate available_space is a number
    if ! [[ "$available_space" =~ ^[0-9]+$ ]]; then
        echo "Warning: Could not determine available disk space"
    elif [ "$available_space" -lt "$required_space" ]; then
        echo "Warning: Low disk space in $CACHE_DIR"
        echo "Available: $(numfmt --to=iec-i --suffix=B $((available_space * 1024)) 2>/dev/null || echo ${available_space}KB)"
        echo "Recommended: 10GB+ for image downloads"
    fi

    # Download with progress and capture exit code
    curl -L --progress-bar -o "${cache_file}.tmp" "${image_url}"
    local curl_exit=$?

    # Verify download completed
    if [ $curl_exit -eq 0 ]; then
        # Check temp file exists and has content
        if [ ! -f "${cache_file}.tmp" ]; then
            echo "Error: Temporary download file not found: ${cache_file}.tmp"
            return 1
        fi

        local tmp_size=$(stat -c "%s" "${cache_file}.tmp" 2>/dev/null || echo "0")
        if [ "$tmp_size" -lt 1000000 ]; then
            echo "Error: Downloaded file is too small (${tmp_size} bytes), expected several GB"
            echo "This may indicate a download error or redirect to an error page"
            rm -f "${cache_file}.tmp"
            return 1
        fi

        if ! mv "${cache_file}.tmp" "$cache_file"; then
            echo "Error: Failed to move temporary file to cache location"
            echo "Source: ${cache_file}.tmp"
            echo "Dest: $cache_file"
            ls -lh "${cache_file}.tmp" || true
            ls -ld "$CACHE_DIR" || true
            return 1
        fi

        # Verify file is readable and exists
        if [ ! -f "$cache_file" ]; then
            echo "Error: Cache file does not exist after move: $cache_file"
            ls -lh "$CACHE_DIR" || true
            return 1
        fi

        if [ ! -r "$cache_file" ]; then
            echo "Error: Downloaded file is not readable: $cache_file"
            ls -lh "$cache_file" || true
            rm -f "$cache_file"
            return 1
        fi

        echo "= Download complete: ${cache_file}"
        echo "$cache_file" >&3
    else
        echo "Error: Download failed (curl exit code: $curl_exit)"
        rm -f "${cache_file}.tmp"
        return 1
    fi
}

# Parse command line arguments
IMAGE_TYPE="$1"

case "$IMAGE_TYPE" in
    server|Server|SERVER)
        download_image "$SERVER_MIRROR_URL" "Server"
        ;;
    iot|IoT|IOT)
        download_image "$IOT_COMPOSE_URL" "IoT"
        ;;
    minimal|Minimal|MINIMAL)
        download_image "$MINIMAL_MIRROR_URL" "Minimal"
        ;;
    all|ALL)
        # Disable set -e temporarily to allow all downloads to be attempted
        set +e
        SERVER_IMAGE=$(download_image "$SERVER_MIRROR_URL" "Server")
        SERVER_EXIT=$?
        IOT_IMAGE=$(download_image "$IOT_COMPOSE_URL" "IoT")
        IOT_EXIT=$?
        MINIMAL_IMAGE=$(download_image "$MINIMAL_MIRROR_URL" "Minimal")
        MINIMAL_EXIT=$?
        set -e

        # Report results
        if [ $SERVER_EXIT -eq 0 ]; then
            echo "SERVER_IMAGE=${SERVER_IMAGE}"
        else
            echo "SERVER_IMAGE=FAILED"
        fi

        if [ $IOT_EXIT -eq 0 ]; then
            echo "IOT_IMAGE=${IOT_IMAGE}"
        else
            echo "IOT_IMAGE=FAILED"
        fi

        if [ $MINIMAL_EXIT -eq 0 ]; then
            echo "MINIMAL_IMAGE=${MINIMAL_IMAGE}"
        else
            echo "MINIMAL_IMAGE=FAILED"
        fi

        # Exit with error if all failed
        if [ $SERVER_EXIT -ne 0 ] && [ $IOT_EXIT -ne 0 ] && [ $MINIMAL_EXIT -ne 0 ]; then
            echo "Error: All downloads failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {server|iot|minimal|all}"
        echo ""
        echo "Download latest Fedora ARM images for testing"
        echo ""
        echo "Options:"
        echo "  server  - Download Server image only"
        echo "  iot     - Download IoT image only"
        echo "  minimal - Download Minimal image only"
        echo "  all     - Download all images"
        echo ""
        echo "Environment variables:"
        echo "  CACHE_DIR       - Directory for cached images (default: /var/tmp/arm-image-installer-test-cache)"
        echo "  FEDORA_VERSION  - Fedora version to download (default: 43)"
        exit 1
        ;;
esac
