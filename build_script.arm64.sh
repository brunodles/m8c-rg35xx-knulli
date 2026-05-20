#!/bin/bash

set -e

cd /build

# Create output directory (in case it wasn't created by Docker)
mkdir -p /build/compiled/m8c
mkdir -p /build/compiled/m8c/lib

# Preflight: verify SDL3 and libserialport are available.
# On Ubuntu 25.04+, these are provided by libsdl3-dev and libserialport-dev.
# For older Ubuntu versions, SDL3 must be built from source first:
#   https://github.com/libsdl-org/SDL/blob/main/docs/README-cmake.md
echo "Checking build dependencies..."
if ! pkg-config --exists sdl3 2>/dev/null; then
  echo "ERROR: SDL3 not found. Install libsdl3-dev (Ubuntu 25.04+) or build SDL3 from source."
  echo "See: https://github.com/libsdl-org/SDL/blob/main/docs/README-cmake.md"
  exit 1
fi
if ! pkg-config --exists libserialport 2>/dev/null; then
  echo "ERROR: libserialport not found. Install libserialport-dev."
  exit 1
fi
echo "✓ SDL3 $(pkg-config --modversion sdl3) found"
echo "✓ libserialport $(pkg-config --modversion libserialport) found"

# Build m8c
echo "Building m8c..."
cd /build/m8c
make VERBOSE=1
if [ $? -ne 0 ]; then
  echo "m8c build failed"
  exit 1
fi

# Build kernel modules
echo "Building kernel modules..."
cd /build/linux-$LINUX_KERNEL_VERSION

echo "Configuring kernel..."
cp /build/linux-sunxi64-legacy.config .config
sed -i 's/# CONFIG_SND_USB_AUDIO is not set/CONFIG_SND_USB_AUDIO=m/g' .config
sed -i 's/# CONFIG_USB_ACM is not set/CONFIG_USB_ACM=m/g' .config

sed -i 's/^YYLTYPE yylloc;$/extern YYLTYPE yylloc;/g' scripts/dtc/dtc-lexer.lex.c_shipped
make ARCH=arm64 olddefconfig
make ARCH=arm64 modules_prepare

echo "Building kernel modules..."
make ARCH=arm64 M=drivers/usb/class
make ARCH=arm64 M=sound/core
make ARCH=arm64 M=sound/usb

# Collect files
echo "Collecting files..."

# Copy kernel modules
for module in cdc-acm.ko snd-hwdep.ko snd-usbmidi-lib.ko snd-usb-audio.ko; do
  find /build/linux-$LINUX_KERNEL_VERSION -name "$module" -exec cp -v {} /build/compiled/m8c \; || echo "Warning: $module not found"
done

# Copy m8c executable
if [ -f "/build/m8c/m8c" ]; then
  cp -v /build/m8c/m8c /build/compiled/m8c
  echo "Copied m8c executable"
else
  echo "Error: m8c executable not found"
  exit 1
fi

# Copy SDL3 shared library for runtime loading
echo "Collecting SDL3 shared library..."
SDL3_LIB_COPIED=0
for SDL3_LIB_DIR in /usr/lib/aarch64-linux-gnu /usr/lib; do
  if compgen -G "$SDL3_LIB_DIR/libSDL3.so*" > /dev/null; then
    cp -av $SDL3_LIB_DIR/libSDL3.so* /build/compiled/m8c/lib/
    echo "Copied SDL3 shared library from $SDL3_LIB_DIR"
    SDL3_LIB_COPIED=1
    break
  fi
done

if [ "$SDL3_LIB_COPIED" -ne 1 ]; then
  echo "Error: SDL3 shared library not found in system library paths"
  exit 1
fi

# Create m8c.sh script
sed "s/\$LINUX_KERNEL_VERSION/$LINUX_KERNEL_VERSION/" <<'EOF' >/build/compiled/m8c.sh
#!/bin/sh

export HOME=$(dirname $(realpath $0))/m8c
cd $HOME

# Ensure m8c is executable
chmod +x ./m8c

export LD_LIBRARY_PATH="$HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cp *.ko /lib/modules/$LINUX_KERNEL_VERSION
depmod
modprobe -a cdc-acm snd-hwdep snd-usbmidi-lib snd-usb-audio

pw-loopback -C alsa_input.usb-DirtyWave_M8_14900360-02.analog-stereo -P alsa_output._sys_devices_platform_soc_soc_03000000_codec_mach_sound_card0.stereo-fallback &

SDL_GAMECONTROLLERCONFIG="19000000010000000100000000010000,Deeplay-keys,a:b3,b:b4,x:b6,y:b5,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,guide:b11,start:b10,back:b9,dpup:h0.1,dpleft:h0.8,dpright:h0.2,dpdown:h0.4,volumedown:b1,volumeup:b2,leftx:a0,lefty:a1,leftstick:b12,rightx:a2,righty:a3,rightstick:b15,platform:Linux," ./m8c

kill $(jobs -p)
EOF

chmod +x /build/compiled/m8c.sh

#
# Final checks and summary
#
check_build_output() {
    local error_count=0
    local warning_count=0

    # Check m8c executable
    if [ -f "/build/compiled/m8c/m8c" ]; then
        file_type=$(file /build/compiled/m8c/m8c)
        if [[ $file_type == *"ARM aarch64"* && $file_type == *"LSB"* && $file_type == *"executable"* ]]; then
            echo "✓ m8c executable present and valid ($(basename "$file_type"))"
        else
            echo "✗ m8c executable present but may be invalid: $file_type"
            ((error_count++))
        fi
    else
        echo "✗ m8c executable missing"
        ((error_count++))
    fi

    # Check kernel modules
    modules=("cdc-acm.ko" "snd-hwdep.ko" "snd-usbmidi-lib.ko" "snd-usb-audio.ko")
    for module in "${modules[@]}"; do
        if [ -f "/build/compiled/m8c/$module" ]; then
            echo "✓ Kernel module $module present"
        else
            echo "✗ Kernel module $module missing"
            ((warning_count++))
        fi
    done

    # Check m8c.sh script
    if [ -f "/build/compiled/m8c.sh" ]; then
        if grep -q "SDL_GAMECONTROLLERCONFIG" "/build/compiled/m8c.sh" && \
           grep -q "LD_LIBRARY_PATH" "/build/compiled/m8c.sh"; then
            echo "✓ m8c.sh script present and contains expected content"
        else
            echo "✗ m8c.sh script present but may be invalid"
            ((warning_count++))
        fi
    else
        echo "✗ m8c.sh script missing"
        ((error_count++))
    fi

    # Check SDL3 runtime library
    if compgen -G "/build/compiled/m8c/lib/libSDL3.so*" > /dev/null; then
        echo "✓ SDL3 runtime shared library present"
    else
        echo "✗ SDL3 runtime shared library missing"
        ((error_count++))
    fi

    # Print summary
    echo "-------------------"
    echo "Build Check Summary"
    echo "-------------------"
    echo "Errors: $error_count"
    echo "Warnings: $warning_count"

    if [ $error_count -eq 0 ] && [ $warning_count -eq 0 ]; then
        echo "Build completed successfully with no issues."
    elif [ $error_count -eq 0 ]; then
        echo "Build completed with warnings. Please review the output."
    else
        echo "Build completed with errors. Please review the output and correct the issues."
        exit 1
    fi
}

# Run the checks
check_build_output

echo "Build and check process complete. All compiled files are in /build/compiled/m8c"
