#!/usr/bin/env bash
# Configure the Cocoa/iOS port for armv7 on webkitglib/2.54, WebKitLegacy only,
# with the BASELINE JIT enabled (no DFG, no FTL).
#
# 2.54 still ships the ARMv7 assembler, offlineasm/arm.rb and
# LowLevelInterpreter32_64.asm, but its PlatformEnable.h forces ENABLE_JIT 0 for
# every USE(JSVALUE32_64) build. Our tree widens that predicate; see
# Source/WTF/wtf/PlatformEnable.h. -DENABLE_JIT=ON alone is NOT enough.
#
# Source tree webkit-254 / build dir build-254, so webkit-trunk, webkit-trunk-jit,
# build-cocoa and build-jit are all left alone.
set -e
P=$P; L=$P/third_party/libcxx-armv7; I=$P/third_party/icu-armv7; SDK=${IOS_SDK:-$HOME/sdks/iPhoneOS13.7.sdk}
S=$P/webkit-254; B=$P/build-254-bmalloc
CXXF="-mllvm -hot-cold-split=false -target armv7-apple-ios6.0 -mcpu=cortex-a9 -mtune=cortex-a9 -mfpu=neon -isysroot $SDK -nostdinc++ -isystem $L/include/c++/v1 -isystem $P/compat/stubs -include $P/compat/stubs/ios6_dispatch_compat.h -include $P/compat/stubs/ios6_class_prefix.h -D_LIBCPP_DISABLE_AVAILABILITY -DWEBKIT_IOS6=1 -DWEBKIT_IOS6_BMALLOC=1 -DENABLE_UNFAIR_LOCK=0 -DWEBKIT_IOS6_NO_READLINE -DU_STATIC_IMPLEMENTATION"
CF="-mllvm -hot-cold-split=false -target armv7-apple-ios6.0 -mcpu=cortex-a9 -mtune=cortex-a9 -mfpu=neon -isysroot $SDK -isystem $P/compat/stubs -include $P/compat/stubs/ios6_class_prefix.h -DWEBKIT_IOS6=1 -DWEBKIT_IOS6_BMALLOC=1 -DENABLE_UNFAIR_LOCK=0 -DWEBKIT_IOS6_NO_READLINE -DU_STATIC_IMPLEMENTATION"
python3 $P/tools/prefix-exports.py $P/compat/stubs/ios6_class_prefix.h \
  $S/Source/WebKitLegacy/WebKitLegacy-iOS.exp $P/compat/WebKitLegacy-iOS.exp
rm -rf $B && mkdir -p $B
cmake -S $S -B $B -G Ninja \
  `# ccache: every source file this build touches gets recompiled from scratch` \
  `# whenever a CMake flag changes, because the configure scripts rm -rf the` \
  `# build directory first - and tonight alone that has happened four times for` \
  `# a change to one or two files. ccache keys on preprocessed source plus` \
  `# command line, not on the build directory, so it survives the rm -rf and` \
  `# turns "rebuild everything" back into "recompile what changed" after the` \
  `# first pass warms it.` \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_OBJC_COMPILER_LAUNCHER=ccache -DCMAKE_OBJCXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_TOOLCHAIN_FILE=$P/ios6-armv7-trunk.cmake \
  -DPORT=IOS -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS_RELEASE="-Os -DNDEBUG" -DCMAKE_C_FLAGS_RELEASE="-Os -DNDEBUG" -DCMAKE_OBJC_FLAGS_RELEASE="-Os -DNDEBUG" -DCMAKE_OBJCXX_FLAGS_RELEASE="-Os -DNDEBUG" -DDEVELOPER_MODE=OFF \
  -DSWIFT_REQUIRED=OFF -DWEBKIT_IOS6_COMPAT_LIB=$P/compat/libios6compat.a -DWEBKIT_IOS6_EXPORTS=$P/compat/WebKitLegacy-iOS.exp -DWEBKIT_IOS6_LIBCXX_DIR=$L -DWEBKIT_NO_AVAILABILITY_OVERLAY=ON \
  -DENABLE_WEBKIT_LEGACY=ON -DENABLE_WEBKIT=OFF \
  `# This is a touch device and these sites are written for a finger.` \
  `# ENABLE_TOUCH_EVENTS and ENABLE_IOS_TOUCH_EVENTS both default to OFF, so` \
  `# touch support was compiled out entirely: measured directly, a synthetic tap` \
  `# produced mousedown/mouseup/click and no touch event at all, which is why a` \
  `# React interface built around touch did nothing.` \
  `# IOS_TOUCH_EVENTS stays off on purpose: EventHandlerIOS.mm's own guard pulls` \
  `# in WebKitAdditions/DocumentIOS.h and .../EventHandlerIOSTouch.cpp under it,` \
  `# and this open-source tree does not carry Apple's WebKitAdditions overlay.` \
  `# TOUCH_EVENTS alone is the portable path GTK/WPE build on - real Touch/` \
  `# TouchList/TouchEvent DOM dispatch, no WebKitAdditions - and` \
  `# EventHandlerIOS.mm now has a hand-written touchEvent()/` \
  `# dispatchSimulatedTouchEvent() pair for the !IOS_TOUCH_EVENTS case, built` \
  `# from that same already-open code.` \
  -DENABLE_TOUCH_EVENTS=ON -DENABLE_IOS_TOUCH_EVENTS=OFF \
  -DENABLE_WEBGPU=OFF -DENABLE_WEBDRIVER=OFF -DENABLE_WEBINSPECTORUI=OFF \
  -DENABLE_API_TESTS=OFF -DENABLE_MINIBROWSER=OFF \
  -DENABLE_WEB_RTC=OFF -DUSE_LIBWEBRTC=OFF -DENABLE_MEDIA_STREAM=OFF \
  -DENABLE_WEB_CODECS=OFF -DENABLE_COCOA_WEBM_PLAYER=OFF -DENABLE_AV1=OFF \
  \
  -DENABLE_SPEECH_SYNTHESIS=OFF -DENABLE_WEB_SPEECH=OFF -DENABLE_WEBGL=OFF -DENABLE_GAMEPAD=OFF -DENABLE_PIXEL_FORMAT_RGBA16F=OFF -DENABLE_WIRELESS_PLAYBACK_TARGET=ON -DENABLE_WIRELESS_PLAYBACK_TARGET_AVAILABILITY_API=ON -DENABLE_WEB_CRYPTO=OFF -DENABLE_XSLT=OFF -DENABLE_COMPRESSION_STREAM=OFF -DENABLE_APPLE_PAY=OFF -DENABLE_APPLE_PAY_COUPON_CODE=OFF -DENABLE_APPLE_PAY_SESSION_V3=OFF -DUSE_ANGLE_EGL=OFF \
  -DENABLE_JIT=ON -DENABLE_C_LOOP=OFF -DENABLE_DFG_JIT=ON -DENABLE_FTL_JIT=OFF \
  -DENABLE_SAMPLING_PROFILER=OFF -DENABLE_MEDIA_SOURCE=OFF -DENABLE_MEDIA_SOURCE_IN_WORKERS=OFF -DENABLE_ENCRYPTED_MEDIA=OFF -DENABLE_LEGACY_ENCRYPTED_MEDIA=OFF -DENABLE_WEB_AUTHN=OFF -DENABLE_WRITING_TOOLS=OFF -DENABLE_PAYMENT_REQUEST=OFF -DUSE_SYSTEM_MALLOC=OFF -DWEBKIT_IOS6_BMALLOC=ON \
  -DICU_UC_LIBRARY=$I/lib/libicuuc.a -DICU_I18N_LIBRARY=$I/lib/libicui18n.a \
  -DICU_DATA_LIBRARY=$I/lib/libicudata.a -DICU_INCLUDE_DIR=$I/include \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-compatibility_version,1.0.0 -Wl,-current_version,1.0.0" \
  -DCMAKE_CXX_FLAGS="$CXXF" -DCMAKE_C_FLAGS="$CF" \
  -DCMAKE_OBJCXX_FLAGS="$CXXF -DWEBKIT_IOS6_OBJC_EXTRAS" -DCMAKE_OBJC_FLAGS="$CF -DWEBKIT_IOS6_OBJC_EXTRAS" \
  -DPYTHON_EXECUTABLE=/usr/bin/python3
# Generator note: this build uses Ninja, unlike configure-webkit.sh (Unix Makefiles).
# With the JIT on, JavaScriptCore's CMake splits jit/dfg/ftl/bytecode into a
# JavaScriptCoreJIT OBJECT subtarget with a chained PCH
# (WEBKIT_DEFINE_SUBTARGET_WITH_PREFIX in Source/cmake/WebKitMacros.cmake). That
# wiring is file-level only and assumes Ninja's single global build graph; under
# Unix Makefiles the per-target build.make files carry no rules for each other's
# objects or PCH, and the link fails with "No rule to make target
# .../JavaScriptCoreJIT.dir/.../UnifiedSource-bytecode-1.cpp.o". The CLoop build never
# hit this because with the JIT off that subtarget is empty and the macro no-ops.
