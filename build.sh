#!/bin/bash
set -e

echo "[+] Checking for orphan build processes..."
pkill -f "make.*blu_spark|clang.*O=out" || true
sleep 1

echo "[+] Setting up build environment..."
export PATH="/home/defey/bernel/proton-clang/bin:$PATH"
export ARCH=arm64
export CC=clang
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip

echo "[+] Re-syncing defconfig..."
make O=out ARCH=$ARCH CC=$CC CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 blu_spark_defconfig

make O=out ARCH=$ARCH CC=$CC CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "[+] Compiling kernel..."
make -j$(nproc) O=out ARCH=$ARCH CC=$CC CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 LD=$LD AR=$AR NM=$NM OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP STRIP=$STRIP

echo "[+] Build completed successfully. Packaging..."
if [ -f "/home/defey/bernel/op8/package_kernel.sh" ]; then
    bash /home/defey/bernel/op8/package_kernel.sh
else
    echo "[-] Error: package_kernel.sh not found in $(pwd)"
    exit 1
fi

echo "[+] Done!"
