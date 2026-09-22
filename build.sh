#!/usr/bin/env bash

set -e

SECONDS=0
USER="builder"
HOSTNAME="github-actions"
DEVICE_TARGET=${DEVICE_TARGET:-"lime"}
DEFCONFIG=${DEFCONFIG:-"vendor/lime-perf_defconfig"}
KCFLAGS_W=${KCFLAGS_W:-"true"}
TOOLCHAIN_BASE="/tmp/toolchains"
CLANG_REPO="$TOOLCHAIN_BASE/clang-prebuilts"
CLANG_DIR="$CLANG_REPO/clang-r377782d"
GCC64_DIR="$TOOLCHAIN_BASE/gcc64"
GCC32_DIR="$TOOLCHAIN_BASE/gcc32"

OUT_DIR="$(pwd)/out"
CCACHE_DIR="${HOME}/.ccache"
CCACHE_SIZE=${CCACHE_SIZE:-"7.5G"}
CLEAN_BUILD=${CLEAN_BUILD:-"false"}
ZIPNAME=${ZIPNAME:-"Kernel-$DEVICE_TARGET-$(date +%Y%m%d-%H%M).zip"}

export TERM=xterm
export DEBIAN_FRONTEND=noninteractive

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
reset='\033[0m'

msg() { echo -e "${blue}INFO: ${reset}$1"; }
error() {
    echo -e "${red}ERROR: ${reset}$1"
    exit 1
}

setup_deps() {
    local deps_lists=(aptitude bc bison build-essential ccache cpio curl flex git lz4 make perl python-is-python3 tar wget zip libssl-dev tzdata)
    apt-get update -y
    apt-get install -y "${deps_lists[@]}"
}

fetch_toolchains() {
    if [ "$UPDATE_TOOLCHAINS" = "true" ]; then
        msg "Cleaning up old toolchains cache..."
        rm -rf "$TOOLCHAIN_BASE"
        rm -rf "$CCACHE_DIR"
        mkdir -p "$CCACHE_DIR"
    fi

    mkdir -p "$TOOLCHAIN_BASE"
    if [ ! -x "$CLANG_DIR/bin/clang" ]; then
        msg "Cloning Clang r377782d (clang 10.0.7)..."
        rm -rf "$CLANG_REPO"
        if ! git clone --depth=1 --filter=blob:none --sparse -b android11-release \
            https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 "$CLANG_REPO"; then
            rm -rf "$CLANG_REPO"
            git clone --depth=1 -b android11-release \
                https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 "$CLANG_REPO"
        else
            git -C "$CLANG_REPO" sparse-checkout set clang-r377782d
        fi
        [ -x "$CLANG_DIR/bin/clang" ] || error "clang not found at $CLANG_DIR/bin/clang"
    else
        msg "Clang already exists"
    fi

    if [ ! -d "$GCC64_DIR" ]; then
        msg "Cloning GCC64 (aarch64-linux-android-4.9)..."
        git clone https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9 \
            -b android10-release --depth=1 "$GCC64_DIR"
    else
        msg "GCC64 already exists"
    fi

    if [ ! -d "$GCC32_DIR" ]; then
        msg "Cloning GCC32 (arm-linux-androideabi-4.9)..."
        git clone https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9 \
            -b android10-release --depth=1 "$GCC32_DIR"
    else
        msg "GCC32 already exists"
    fi
}

case "$1" in
"--setup-deps")
    setup_deps
    exit 0
    ;;
"--fetch-toolchains")
    fetch_toolchains
    exit 0
    ;;
"--clean")
    msg "Cleaning..."
    rm -rf "$OUT_DIR" AnyKernel3
    make clean mrproper
    exit 0
    ;;
*)
    ;;
esac

if [ ! -x "$CLANG_DIR/bin/clang" ] || [ ! -d "$GCC64_DIR" ] || [ ! -d "$GCC32_DIR" ]; then
    fetch_toolchains
fi

export KBUILD_BUILD_USER=$USER
export KBUILD_BUILD_HOST=$HOSTNAME
export PATH="$CLANG_DIR/bin:$GCC64_DIR/bin:$GCC32_DIR/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LD_LIBRARY_PATH="$CLANG_DIR/lib64:$LD_LIBRARY_PATH"
export ARCH=arm64
export SUBARCH=arm64

EXTRA_KCFLAGS="-B$GCC64_DIR/bin/aarch64-linux-android-"
if [ "$KCFLAGS_W" = "true" ]; then
    EXTRA_KCFLAGS="$EXTRA_KCFLAGS -w"
fi

BUILD_FLAGS=(
    O="$OUT_DIR"
    ARCH=arm64
    CC="ccache clang"
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE=aarch64-linux-android-
    CROSS_COMPILE_ARM32=arm-linux-androideabi-
    KCFLAGS="$EXTRA_KCFLAGS"
    -j"$(nproc --all)"
)

mkdir -p "$OUT_DIR"

if [ "$CLEAN_BUILD" = "true" ]; then
    msg "Cleaning output directory..."
    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"
fi

export CCACHE_DIR="$CCACHE_DIR"
ccache -M "$CCACHE_SIZE"
export CCACHE_SLOPPINESS="time_macros"

clang --version | head -n1 || error "clang is not in PATH"
msg "Starting compilation for $DEVICE_TARGET..."
msg "Generating defconfig ($DEFCONFIG)..."
make "${BUILD_FLAGS[@]}" "$DEFCONFIG"

msg "Building kernel..."
make "${BUILD_FLAGS[@]}"

if [ -f "$OUT_DIR/arch/arm64/boot/Image.gz" ] || [ -f "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" ]; then
    msg "Kernel compiled successfully! Packaging..."
    rm -rf AnyKernel3
    git clone -q https://github.com/slakkystar/AnyKernel3.git --single-branch -b "master"
    
    if [ -f "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" ]; then
        cp "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" AnyKernel3/Image.gz-dtb
    else
        cp "$OUT_DIR/arch/arm64/boot/Image.gz" AnyKernel3/
    fi

    cp "$OUT_DIR/arch/arm64/boot/dts/vendor/qcom/bengal.dtb" AnyKernel3/dtb 2>/dev/null || true
    cp "$OUT_DIR/arch/arm64/boot/dtbo.img" AnyKernel3/ 2>/dev/null || true

    cd AnyKernel3
    zip -r9 "../$ZIPNAME" * -x '.git*' README.md '*placeholder'
    cd ..

    MD5_CHECK=$(md5sum "$ZIPNAME" | cut -d' ' -f1)

    echo -e "\n${green}Build completed in $((SECONDS / 60)) minute(s)!${reset}"
    msg "Output Zip: $ZIPNAME (md5: $MD5_CHECK)"
else
    error "Compilation failed! Image.gz not found."
fi
