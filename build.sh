#!/bin/bash

# Exit on error, enable debug tracing for GitHub Actions
set -e
set -o pipefail

# Record start time
start_time=$(date +%s)

# Error handling function
handle_error() {
    local line=$1
    local error_code=$2
    local message="Error at line $line (exit code $error_code)"
    echo "ERROR: $message"
    send_telegram "Build failed: $message"
    send_telegram_file "./build.log" || echo "Warning: Failed to upload build log"
    exit 1
}

# Telegram notification function
send_telegram() {
    local message=$1
    for attempt in {1..3}; do
        if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="$message" --max-time 10; then
            return 0
        fi
        echo "Warning: Telegram notification attempt $attempt failed, retrying..."
        sleep 2
    done
    echo "Warning: Telegram notification failed after $attempt attempts"
}

# Telegram file upload function
send_telegram_file() {
    local file=$1
    [ -f "$file" ] || { echo "Warning: File $file not found for Telegram upload"; return 1; }
    for attempt in {1..3}; do
        if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument?chat_id=${TELEGRAM_CHAT_ID}" \
            -F document=@"$file" --max-time 30; then
            return 0
        fi
        echo "Warning: Telegram file upload attempt $attempt failed, retrying..."
        sleep 2
    done
    echo "Warning: Telegram file upload failed after $attempt attempts"
}

# Combined success message and file upload
send_success() {
    local message=$1
    local file=$2
    [ -f "$file" ] || { echo "Error: Zip file $file not found"; handle_error ${LINENO} "Missing zip file"; }
    for attempt in {1..3}; do
        if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument?chat_id=${TELEGRAM_CHAT_ID}" \
            -F document=@"$file" -F caption="$message" --max-time 30; then
            return 0
        fi
        echo "Warning: Telegram success upload attempt $attempt failed, retrying..."
        sleep 2
    done
    echo "Warning: Telegram success notification failed after $attempt attempts"
}

# Trap errors
trap 'handle_error ${LINENO} $?' ERR

# Directory setup
MAINPATH="${GITHUB_WORKSPACE:-$(pwd)}"
KERNEL_PATH="${MAINPATH}"
CLANG_DIR="${KERNEL_PATH}/clang"
WAIFU_DIR="${KERNEL_PATH}/Waifu"
OUTPUT_DIR="${KERNEL_PATH}/out"
DTS_DIR="${OUTPUT_DIR}/arch/arm64/boot/dts"
DTBO_DIR="${OUTPUT_DIR}/arch/arm64/boot"

# Ensure directories exist
mkdir -p "$CLANG_DIR" "$WAIFU_DIR" "$OUTPUT_DIR" || handle_error ${LINENO} "Failed to create directories"

# Download Clang if missing
if [ ! -d "$CLANG_DIR/bin" ]; then
    echo "Downloading Clang to $CLANG_DIR"
    cd "$CLANG_DIR" || handle_error ${LINENO} "Failed to change to $CLANG_DIR"
    CLANG_URL=$(curl -s https://raw.githubusercontent.com/ZyCromerZ/Clang/refs/heads/main/Clang-main-link.txt) || handle_error ${LINENO} "Failed to fetch Clang URL"
    wget -q "https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/10032024/neutron-clang-10032024.tar.zst" -O clang.tar.zst || handle_error ${LINENO} "Failed to download Clang"
    unzstd -d clang.tar.zst
    tar -xf clang.tar && rm -f clang.tar.gz || handle_error ${LINENO} "Failed to extract/remove Clang archive"
    cd "$KERNEL_PATH" || handle_error ${LINENO} "Failed to return to kernel directory"
fi

# Set up environment
export PATH="${CLANG_DIR}/bin:${PATH}"
export ARCH=arm64
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabi-"
export KBUILD_BUILD_USER="y82t2z"
export KBUILD_BUILD_HOST="GitHubActions"
export DEVICE="alioth"
export IMGPATH="${WAIFU_DIR}/Image"
export DTBPATH="${WAIFU_DIR}/dtb"
export DTBOPATH="${WAIFU_DIR}/dtbo.img"

# AnyKernel setup
if [ ! -f "${WAIFU_DIR}/anykernel.sh" ]; then
    echo "Cloning AnyKernel to $WAIFU_DIR"
    git clone -q --depth 1 "https://github.com/y82t2z/Anykernel.git" "${WAIFU_DIR}" || handle_error ${LINENO} "Failed to clone AnyKernel"
    rm -rf "${WAIFU_DIR}/.git" || echo "Warning: Failed to remove .git directory"
fi

# Build configuration
BUILD_DATE=$(date '+%Y-%m-%d_%H-%M-%S')
cd "$KERNEL_PATH" || handle_error ${LINENO} "Failed to change to kernel directory"

# System info
CPU_INFO=$(grep "model name" /proc/cpuinfo | head -n 1 || echo "CPU info not available")
CPU_COUNT=$(nproc || echo "Unknown")
RAM_INFO=$(free -h | awk '/Mem:/ {print $2}' || echo "RAM info not available")
GIT_COMMIT=$(git log -1 --pretty="%h - %s" 2>/dev/null || echo "No git info")
TRIGGER="Build triggered on $(date '+%Y-%m-%d %H:%M:%S') by ${GITHUB_ACTOR:-unknown}"

# Send build info
send_telegram "Build Info:
CPU: $CPU_INFO
Thread: $CPU_COUNT
RAM: $RAM_INFO
$TRIGGER
Device: $DEVICE"

# Clean previous build
rm -rf "$OUTPUT_DIR" build.log
mkdir -p "$OUTPUT_DIR"

# Build kernel
echo "Generating kernel config..."
make CC=clang O="$OUTPUT_DIR" "alioth_defconfig" "vendor/xiaomi/sm8250-common.config" || handle_error ${LINENO} "Failed to generate config"

echo "Building kernel..."
make -j$(nproc --all) O="$OUTPUT_DIR" \
    CC=clang CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1 \
    2>&1 | tee build.log || handle_error ${LINENO} "Kernel compilation failed"

# Verify output directories
[ -d "$DTS_DIR" ] || handle_error ${LINENO} "DTS directory $DTS_DIR not found"
[ -d "$DTBO_DIR" ] || handle_error ${LINENO} "DTBO directory $DTBO_DIR not found"

# Collect output files
echo "Collecting DTB, Image, and dtbo.img..."
find "$DTS_DIR" -name '*.dtb' -exec cat {} + > "$DTBPATH" || handle_error ${LINENO} "Failed to collect DTB files"
find "$DTBO_DIR" -name 'Image' -exec cp {} "$IMGPATH" \; || handle_error ${LINENO} "Failed to copy Image"
find "$DTBO_DIR" -name 'dtbo.img' -exec cp {} "$DTBOPATH" \; || handle_error ${LINENO} "Failed to copy dtbo.img"

# Calculate build time
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))

# Check for compilation errors
if grep -q -E "Error 2" build.log; then
    echo "Error: Build failed"
    send_telegram "Compilation error!"
    send_telegram_file "./build.log"
    exit 1
fi

# Create zip
echo "Creating zip file..."
cd "$WAIFU_DIR" || handle_error ${LINENO} "Failed to change to Waifu directory"
zip_file="Waifu-${DEVICE}-${BUILD_DATE}.zip"

# Verify critical files
for file in "$IMGPATH" "$DTBPATH" "$DTBOPATH"; do
    [ -f "$file" ] || handle_error ${LINENO} "Missing file: $file"
done

# List files for debugging
echo "Files in $WAIFU_DIR before zipping:"
ls -l "$WAIFU_DIR" || echo "No files found in $WAIFU_DIR"

# Create zip with necessary files
zip -r9 "$zip_file" . -x "*.git*" || handle_error ${LINENO} "Failed to create zip archive"

# Send success notification
send_success "Success! Time: $elapsed_time seconds \nBuild completed for $DEVICE on $BUILD_DATE" "$zip_file"

echo "Build completed successfully in $elapsed_time seconds"