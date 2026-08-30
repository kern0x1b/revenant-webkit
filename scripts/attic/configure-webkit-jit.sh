#!/usr/bin/env bash
# Configure the Cocoa/iOS port for armv7 with the baseline JIT (no DFG, no FTL).
# Same as configure-webkit.sh, but against webkit-trunk-jit / build-jit so the
# CLoop build in build-cocoa is left alone.
set -eu
P=$(cd "$(dirname "$0")/../.." && pwd); L=$P/third_party/libcxx-armv7; I=$P/third_party/icu-armv7; SDK=${IOS_SDK:-$HOME/sdks/iPhoneOS13.7.sdk}
S=$P/webkit-trunk-jit; B=$P/build-jit
CXXF="-mllvm -hot-cold-split=false -target armv7-apple-ios6.0 -isysroot $SDK -nostdinc++ -isystem $L/include/c++/v1 -isystem $P/compat/stubs -include $P/compat/stubs/ios6_dispatch_compat.h -include $P/compat/stubs/ios6_class_prefix.h -D_LIBCPP_DISABLE_AVAILABILITY -DWEBKIT_IOS6=1 -DENABLE_UNFAIR_LOCK=0 -DWEBKIT_IOS6_NO_READLINE -DU_STATIC_IMPLEMENTATION"
CF="-mllvm -hot-cold-split=false -target armv7-apple-ios6.0 -isysroot $SDK -isystem $P/compat/stubs -include $P/compat/stubs/ios6_class_prefix.h -DWEBKIT_IOS6=1 -DENABLE_UNFAIR_LOCK=0 -DWEBKIT_IOS6_NO_READLINE -DU_STATIC_IMPLEMENTATION"
python3 $P/tools/prefix-exports.py $P/compat/stubs/ios6_class_prefix.h \
  $S/Source/WebKitLegacy/WebKitLegacy-iOS.exp $P/compat/WebKitLegacy-iOS.exp
rm -rf $B && mkdir -p $B
cmake -S $S -B $B -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE=$P/ios6-armv7-trunk.cmake \
  -DPORT=IOS -DCMAKE_BUILD_TYPE=Release -DDEVELOPER_MODE=OFF \
  -DSWIFT_REQUIRED=OFF -DWEBKIT_IOS6_COMPAT_LIB=$P/compat/libios6compat.a -DWEBKIT_IOS6_EXPORTS=$P/compat/WebKitLegacy-iOS.exp -DWEBKIT_IOS6_LIBCXX_DIR=$L -DWEBKIT_NO_AVAILABILITY_OVERLAY=ON \
  -DENABLE_WEBKIT_LEGACY=ON -DENABLE_WEBKIT=OFF \
  -DENABLE_WEBGPU=OFF -DENABLE_WEBDRIVER=OFF -DENABLE_WEBINSPECTORUI=OFF \
  -DENABLE_API_TESTS=OFF -DENABLE_MINIBROWSER=OFF \
  -DENABLE_WEB_RTC=OFF -DUSE_LIBWEBRTC=OFF -DENABLE_MEDIA_STREAM=OFF \
  -DENABLE_WEB_CODECS=OFF -DENABLE_COCOA_WEBM_PLAYER=OFF -DENABLE_AV1=OFF \
  \
  -DENABLE_SPEECH_SYNTHESIS=OFF -DENABLE_WEB_SPEECH=OFF -DENABLE_WEBGL=OFF -DENABLE_GAMEPAD=OFF -DENABLE_PIXEL_FORMAT_RGBA16F=OFF -DENABLE_WIRELESS_PLAYBACK_TARGET=ON -DENABLE_WIRELESS_PLAYBACK_TARGET_AVAILABILITY_API=ON -DENABLE_WEB_CRYPTO=OFF -DENABLE_XSLT=OFF -DENABLE_COMPRESSION_STREAM=OFF -DENABLE_APPLE_PAY=OFF -DENABLE_APPLE_PAY_COUPON_CODE=OFF -DENABLE_APPLE_PAY_SESSION_V3=OFF -DUSE_ANGLE_EGL=OFF \
  -DENABLE_JIT=ON -DENABLE_C_LOOP=OFF -DENABLE_DFG_JIT=OFF -DENABLE_FTL_JIT=OFF \
  -DENABLE_SAMPLING_PROFILER=OFF -DUSE_SYSTEM_MALLOC=ON \
  -DICU_UC_LIBRARY=$I/lib/libicuuc.a -DICU_I18N_LIBRARY=$I/lib/libicui18n.a \
  -DICU_DATA_LIBRARY=$I/lib/libicudata.a -DICU_INCLUDE_DIR=$I/include \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-compatibility_version,1.0.0 -Wl,-current_version,1.0.0" \
  -DCMAKE_CXX_FLAGS="$CXXF" -DCMAKE_C_FLAGS="$CF" \
  -DCMAKE_OBJCXX_FLAGS="$CXXF -DWEBKIT_IOS6_OBJC_EXTRAS" -DCMAKE_OBJC_FLAGS="$CF -DWEBKIT_IOS6_OBJC_EXTRAS" \
  -DPYTHON_EXECUTABLE=/usr/bin/python3
