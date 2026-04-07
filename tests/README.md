# arm-image-installer Tests

Automated tests for arm-image-installer that download real Fedora ARM images, create custom disk images, and verify the modifications were applied correctly.

## Test Structure

```
tests/
├── helpers/
│   ├── download-images.sh     # Download images from Koji
│   ├── verify-image.sh        # Verify image structure and modifications
│   └── generate-ssh-key.sh    # Generate SSH keys for testing
├── plans/                  # TMT test plans
│   ├── basic.fmf          # Quick smoke test (Server)
│   ├── full.fmf           # Full customization test (Server)
│   ├── iot.fmf            # IoT with ignition test
│   ├── iot-full.fmf       # IoT full customization test
│   ├── minimal.fmf        # Minimal image basic test
│   └── minimal-full.fmf   # Minimal image full customization
├── test-server-basic.sh          # Server image basic test
├── test-server-customized.sh     # Server image with all options
├── test-iot.sh                   # IoT image with ignition
├── test-iot-customized.sh        # IoT image with all options
├── test-minimal.sh               # Minimal image basic test
└── test-minimal-customized.sh    # Minimal image with all options
```

## Requirements

### System Requirements
- Linux (tested on Fedora, Ubuntu, RHEL/CentOS)
- x86_64 or aarch64 architecture
- Bash 3.0 or later
- At least 30GB free disk space
- Root/sudo access
- Network access to dl.fedoraproject.org and kojipkgs.fedoraproject.org for image downloads

### Package Requirements
```bash
# Fedora/RHEL/CentOS
dnf install -y curl xz lvm2 parted e2fsprogs btrfs-progs util-linux xfsprogs openssh-clients

# Ubuntu/Debian
apt-get install -y curl xz-utils lvm2 parted e2fsprogs btrfs-progs util-linux xfsprogs openssh-client
```

## Running Tests Manually

### Quick Smoke Test
**Note**: Tests must be run with sudo/root as arm-image-installer requires root privileges.

```bash
sudo ./tests/test-server-basic.sh
```

### Full Server Customization Test
```bash
sudo ./tests/test-server-customized.sh
```

### IoT Test
```bash
sudo ./tests/test-iot.sh
```

### IoT Customization Test
```bash
sudo ./tests/test-iot-customized.sh
```

### Minimal Test
```bash
sudo ./tests/test-minimal.sh
```

### Minimal Customization Test
```bash
sudo ./tests/test-minimal-customized.sh
```

## Running with TMT

### Basic Test
```bash
tmt run plan --name /tests/plans/basic
# Or by file path:
tmt run -vvv plan --name tests/plans/basic
```

### Full Test Suite
```bash
tmt run plan --name /tests/plans/full
```

### IoT Test
```bash
tmt run plan --name /tests/plans/iot
```

### All Tests
```bash
tmt run
```

### Run Tests by Tag
```bash
# Run only quick smoke tests
tmt run --filter 'tag:quick'

# Run all server-related tests
tmt run --filter 'tag:server'

# Run IoT tests
tmt run --filter 'tag:iot'

# Run full customization tests
tmt run --filter 'tag:full'
```

## Test Details

### test-server-basic.sh
- Downloads latest Server image from Koji (~5-8 GB download)
- Creates a basic custom image with minimal options
- Verifies the image structure and partition table
- **Typical Runtime**: 10-20 minutes (mostly download time)

### test-server-customized.sh
- Downloads latest Server image from Koji (~5-8 GB download)
- Creates a 20GB custom image with:
  - `--resizefs` - Resize root partition
  - `--addkey` - Add SSH key
  - `--norootpass` - Empty root password
  - `--wifi-ssid/pass/security` - Wi-Fi configuration
  - `--target=rpi4` - Raspberry Pi 4 target
- Mounts the image and verifies:
  - SSH key was added to authorized_keys
  - Root password is empty in /etc/shadow
  - Root partition was resized to fill disk
  - Wi-Fi config file exists in NetworkManager
- **Typical Runtime**: 15-25 minutes (10-15 min download, 5-10 min for dd and verification)

### test-iot.sh
- Downloads latest IoT image from Koji (~4-6 GB download)
- Creates an ignition configuration file
- Creates a custom IoT image with ignition
- Verifies the image structure and ignition file embedding
- **Verifies**: Ignition file was copied to `/ignition/config.ign` on boot partition
- **Note**: Ignition configuration is processed at boot time
- **Typical Runtime**: 10-20 minutes (mostly download time)

### test-iot-customized.sh
- Downloads latest IoT image from Koji (~4-6 GB download)
- Creates a 20GB custom image with:
  - `--ignition` - Ignition configuration file
  - `--resizefs` - Resize root partition
  - `--addkey` - Add SSH key
  - `--norootpass` - Empty root password
  - `--wifi-ssid/pass/security` - Wi-Fi configuration
  - `--target=rpi4` - Raspberry Pi 4 target
- Mounts the image and verifies:
  - Ignition file was embedded on boot partition at `/ignition/config.ign`
  - SSH key was added to authorized_keys (in OSTree deployment path)
  - Root password is empty in /etc/passwd
  - Root partition was resized to fill disk
  - Wi-Fi config file exists in NetworkManager
- **Note**: Tests that ignition works alongside direct filesystem customizations on IoT/OSTree
- **Typical Runtime**: 15-25 minutes (10-15 min download, 5-10 min for dd and verification)

### test-minimal.sh
- Downloads latest Minimal image from Koji (~3-5 GB download)
- Creates a basic custom image with minimal options
- Verifies the image structure and partition table
- **Note**: Minimal images use traditional partitions (no LVM, no OSTree)
- **Typical Runtime**: 10-20 minutes (mostly download time)

### test-minimal-customized.sh
- Downloads latest Minimal image from Koji (~3-5 GB download)
- Creates a 20GB custom image with:
  - `--resizefs` - Resize root partition
  - `--addkey` - Add SSH key
  - `--norootpass` - Empty root password
  - `--wifi-ssid/pass/security` - Wi-Fi configuration
  - `--target=rpi4` - Raspberry Pi 4 target
- Mounts the image and verifies:
  - SSH key was added to authorized_keys
  - Root password is empty in /etc/passwd
  - Root partition was resized to fill disk
  - Wi-Fi config file exists in NetworkManager
- **Note**: Tests all customization features on traditional partition layout
- **Typical Runtime**: 15-25 minutes (10-15 min download, 5-10 min for dd and verification)

## Environment Variables

### CACHE_DIR
Directory for cached downloaded images (default: `/var/tmp/arm-image-installer-test-cache`)

```bash
CACHE_DIR=/path/to/cache ./test-server-basic.sh
```

### TEST_OUTPUT_DIR
Directory for test outputs and custom images (default: `/var/tmp/arm-image-installer-tests`)

```bash
TEST_OUTPUT_DIR=/path/to/output ./test-server-basic.sh
```

### FEDORA_VERSION
Fedora version to test (default: `43`)

```bash
FEDORA_VERSION=44 ./test-server-basic.sh
```

**Note**: These environment variables can also be set in TMT plans. See `tests/plans/*.fmf` files for examples.

## CI Integration

### GitHub Actions

Tests are automatically run via GitHub Actions on pull requests. The workflow:
- Runs on x86_64 Ubuntu runners (standard GitHub-hosted)
- Downloads real Fedora ARM images from Koji
- Creates custom disk images using `arm-image-installer`
- Verifies the image structure and modifications
- Does not require QEMU or nested virtualization

### Packit (Optional)

Tests can also run via Packit on pull requests. The `.packit.yaml` configuration includes:

```yaml
jobs:
  - job: tests
    trigger: pull_request
    targets:
      - fedora-stable
      - fedora-development
    tf_extra_params:
      environments:
        - arch: aarch64
```

Tests run on actual aarch64 hardware in Fedora's Testing Farm.

## Caching

Downloaded images are cached in `CACHE_DIR` to speed up repeated test runs. The cache persists between runs, so subsequent tests only need to download images once.

To clear the cache:
```bash
sudo rm -rf /var/tmp/arm-image-installer-test-cache
```

## Troubleshooting

### Test fails with "Failed to mount root partition"
Ensure you're running the test with root/sudo privileges. The verification script needs to mount the image to check its contents.

### Download fails
Check network connectivity to `dl.fedoraproject.org` (for Server/Minimal images) and `kojipkgs.fedoraproject.org` (for IoT images). You may need to adjust firewall rules.

### Out of disk space
Tests require significant disk space:
- Basic test: ~6-8 GB (downloaded image + output)
- Full customization test: ~26-28 GB (downloaded image + 20GB output image)
- IoT test: ~6-8 GB (downloaded image + output)

Use `df -h` to check available space and clean up old test outputs in `TEST_OUTPUT_DIR`:
```bash
sudo rm -rf /var/tmp/arm-image-installer-tests
```

### Verification fails for customizations
If verification fails to find SSH keys, Wi-Fi configs, etc., check that:
- The script ran without errors during image creation
- You're checking the right partition (verify-image.sh looks for p3 or p2)
- The filesystem is ext4 or another Linux filesystem that can be mounted

### Test partially completed
If a test fails partway through, you may have leftover files:
- Downloaded images in `$CACHE_DIR` (safe to keep for reuse)
- Output images in `$TEST_OUTPUT_DIR` (can be removed to free space)
- Temporary SSH keys in `$TEST_OUTPUT_DIR/test_rsa*`

To clean up and retry:
```bash
# Keep downloaded images, remove test outputs
sudo rm -rf /var/tmp/arm-image-installer-tests

# Or clean everything including cached downloads
sudo rm -rf /var/tmp/arm-image-installer-tests /var/tmp/arm-image-installer-test-cache
```

## Contributing

When adding new tests:
1. Create a test script in `tests/`
2. Make it executable: `chmod +x tests/test-name.sh`
3. Add a TMT plan in `tests/plans/name.fmf`
4. Document the test in this README
5. Test locally before submitting PR
