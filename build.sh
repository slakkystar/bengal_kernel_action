#!/usr/bin/env bash

set -e

SECONDS=0
USER="slakkystar"
HOSTNAME="github"
DEVICE_TARGET=${DEVICE_TARGET:-"chime"}
TC_DIR="$HOME/clang-22"
OUT_DIR="$(pwd)/out"
KCFLAGS_W=${KCFLAGS_W:-"false"}
CCACHE_DIR="${HOME}/.ccache"
CCACHE_SIZE=${CCACHE_SIZE:-"5G"}
CLEAN_BUILD=${CLEAN_BUILD:-"false"}

export TERM=xterm
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
reset='\033[0m'

msg() { echo -e "${blue}INFO: ${reset}$1"; }
error() {
    echo -e "${red}ERROR: ${reset}$1"
    exit 1
}

merge_kernel_configs() {
    local base_defconfig="$1"
    local merged_config="$OUT_DIR/.config"
    local fragment_list=("${@:2}")

    mkdir -p "$OUT_DIR"

    if [[ ${#fragment_list[@]} -eq 0 ]]; then
        msg "No extra fragments, copying base defconfig directly."
        cp "arch/arm64/configs/$base_defconfig" "$merged_config"
        return
    fi

    if [[ ! -x "scripts/kconfig/merge_config.sh" ]]; then
        error "merge_config.sh not found or not executable. Make sure you are in kernel root."
    fi

    msg "Merging defconfig with fragments: ${fragment_list[*]}"
    scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" \
        "arch/arm64/configs/$base_defconfig" \
        "${fragment_list[@]}"

    if [[ ! -f "$merged_config" ]]; then
        error "Merged config not created!"
    fi
    msg "Merged config written to $merged_config"
}

setup_deps() {
    local deps_lists=(aptitude bc bison ccache cpio curl flex git lz4 perl python-is-python3 tar wget)
    sudo apt update -y
    sudo apt install "${deps_lists[@]}" -y
    sudo aptitude install libssl-dev -y
}

_setup_toolchain() {
    local url="${TOOLCHAIN_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/9b144befdfd93b90e02c663504fb9f4b95f9faf8/clang-r596125.tar.gz}"
    msg "Downloading toolchain from $url..."
    wget -q "$url" -O /tmp/clang.tar.gz
    [ ! -d "$TC_DIR" ] && mkdir -p "$TC_DIR"
    tar -xzf /tmp/clang.tar.gz -C "$TC_DIR"
    rm /tmp/clang.tar.gz
    msg "Toolchain extracted to $TC_DIR"
}

setup_toolchain() {
    if [ "$UPDATE_TOOLCHAINS" = "true" ]; then
        msg "Cleaning up old toolchains cache.."
        rm -rf "$TC_DIR"
        rm -rf "$CCACHE_DIR"
        mkdir -p "$CCACHE_DIR"
    fi
    if [ ! -d "$TC_DIR" ]; then
        _setup_toolchain
    else
        msg "Toolchain already exists"
    fi
    exit 0
}

regen_defconfig() {
    msg "Generating minimal defconfig for $DEVICE_TARGET..."
    prepare_config
    make $BUILD_FLAGS savedefconfig
    cp "$OUT_DIR/defconfig" "$OUT_DIR/${DEVICE_TARGET}_defconfig"
    msg "Defconfig saved to $OUT_DIR/${DEVICE_TARGET}_defconfig"
}

prepare_config() {
    local base_defconfig=""
    local fragments=()

    case "$DEVICE_TARGET" in
        bengal-perf|bengal-stock)
            base_defconfig="vendor/${DEVICE_TARGET}_defconfig"
            ;;
        chime|lime|citrus)
            base_defconfig="vendor/bengal-perf_defconfig"
            fragments+=("arch/arm64/configs/vendor/xiaomi/chime.config")
            [[ "$DEVICE_TARGET" == "lime" ]] && fragments+=("arch/arm64/configs/vendor/xiaomi/lime.config")
            [[ "$DEVICE_TARGET" == "citrus" ]] && fragments+=("arch/arm64/configs/vendor/xiaomi/citrus.config")
            ;;
        *)
            error "Unsupported DEVICE_TARGET: $DEVICE_TARGET"
            ;;
    esac

    if [[ "$KSU" == "true" ]]; then
        if [[ -f "arch/arm64/configs/vendor/kernelsu.config" ]]; then
            msg "KernelSU enabled"
            fragments+=("arch/arm64/configs/vendor/kernelsu.config")
        else
            msg "WARNING: kernelsu.config not found, KernelSU fragment skipped."
        fi
    fi

    if [[ "$APPLY_WORKAROUND" == "true" ]]; then
        local therm_disable="$OUT_DIR/disable-thermal.config"
        mkdir -p "$OUT_DIR"
        cat > "$therm_disable" << EOF
# CONFIG_QCOM_SPMI_TEMP_ALARM is not set
# CONFIG_QTI_ADC_TM is not set
# CONFIG_QTI_VIRTUAL_SENSOR is not set
EOF
        msg "Workaround enabled: adding disable-thermal.config"
        fragments+=("$therm_disable")
    fi

    merge_kernel_configs "$base_defconfig" "${fragments[@]}"
    make $BUILD_FLAGS olddefconfig
}

# ------------------- Main -------------------

case "$1" in
"--setup-deps")
    setup_deps
    exit 0
    ;;
"--fetch-toolchains")
    setup_toolchain
    exit 0
    ;;
"--clean")
    msg "Cleaning..."
    rm -rf "$OUT_DIR" AnyKernel3
    make clean mrproper
    exit 0
    ;;
"--regen-defconfig")
    ;;
*)
    ;;
esac

VALID_DEVICES=("chime" "lime" "citrus" "bengal-perf" "bengal-stock")
if [[ ! " ${VALID_DEVICES[@]} " =~ " ${DEVICE_TARGET} " ]]; then
    error "Invalid DEVICE_TARGET='$DEVICE_TARGET'. Valid: ${VALID_DEVICES[*]}"
fi

export KBUILD_BUILD_USER=$USER
export KBUILD_BUILD_HOST=$HOSTNAME
export PATH="$TC_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$TC_DIR/lib"
export LLVM_IAS=1
export LLVM=1

[ "$KCFLAGS_W" = "true" ] && export KCFLAGS=-w

COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "untracked")
[ -z "$CI_ZIPNAME" ] && ZIPNAME="$DEVICE_TARGET-$(date '+%Y%m%d-%H%M')-$COMMIT_HASH.zip" || ZIPNAME=$CI_ZIPNAME
BUILD_FLAGS="O=$OUT_DIR ARCH=arm64 -j$(nproc --all)"

if [ "$1" = "--regen-defconfig" ]; then
    mkdir -p "$OUT_DIR"
    prepare_config
    regen_defconfig
    exit 0
fi

mkdir -p "$OUT_DIR"

if [ "$CLEAN_BUILD" = "true" ]; then
    msg "Cleaning output directory..."
    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"
fi

export CCACHE_DIR="$CCACHE_DIR"
ccache -M "$CCACHE_SIZE"
export CCACHE_SLOPPINESS="time_macros"

msg "Starting compilation for $DEVICE_TARGET..."

prepare_config

msg "Building kernel..."
make $BUILD_FLAGS

if [ -f "$OUT_DIR/arch/arm64/boot/Image.gz" ]; then
    msg "Kernel compiled successfully! Packaging..."
    rm -rf AnyKernel3
    git clone -q https://github.com/anggitmrt87/AnyKernel3.git --single-branch -b "master"
    cp "$OUT_DIR/arch/arm64/boot/Image.gz" AnyKernel3/
    cp "$OUT_DIR/arch/arm64/boot/dts/vendor/qcom/bengal.dtb" AnyKernel3/dtb 2>/dev/null || true
    cp "$OUT_DIR/arch/arm64/boot/dtbo.img" AnyKernel3/ 2>/dev/null || true

    cd AnyKernel3
    zip -r9 "../$ZIPNAME" * -x '.git*' README.md '*placeholder'
    cd ..

    MD5_CHECK=$(md5sum "$ZIPNAME" | cut -d' ' -f1)

    echo -e "\n${green}Build completed in $((SECONDS / 60)) minute(s)!${reset}"
    msg "Output Zip: $ZIPNAME (md5: $MD5_CHECK)"
else
    error "Compilation failed!"
fi
