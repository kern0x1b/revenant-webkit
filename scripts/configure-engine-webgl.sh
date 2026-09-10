#!/usr/bin/env bash
# Configure the WebGL experiment into build-254-angle.
#
# Identical to configure-engine.sh except that ENABLE_WEBGL is ON and the build
# goes to its own tree, so the shipping engine is never disturbed by it. What
# this buys today is a compiled ANGLE for armv7 and nothing more: there is no
# GLES backend for this platform yet, so ANGLE is built with the null renderer
# and a browser built from this tree would answer getContext("webgl") with a
# context that draws nothing. Do not ship it. docs/webgl.md says what is left.
set -eu
P=$(cd "$(dirname "$0")/.." && pwd); L=$P/third_party/libcxx-armv7; I=$P/third_party/icu-armv7; X=$P/third_party/libxslt-armv7; W=$P/third_party/woff2-armv7; O=$P/third_party/openssl-armv7; WP=$P/third_party/libwebp-armv7; SDK=${IOS_SDK:-$HOME/sdks/iPhoneOS13.7.sdk}
S=$P/webkit-254; B=$P/build-254-angle
CXXF="-flto=thin -mllvm -hot-cold-split=false -target armv7-apple-ios6.0 -mcpu=cortex-a9 -mtune=cortex-a9 -mfpu=neon -isysroot $SDK -nostdinc++ -isystem $L/include/c++/v1 -isystem $X/include -isystem $P/compat/stubs -include $P/compat/stubs/ios6_dispatch_compat.h -include $P/compat/stubs/ios6_class_names.h -D_LIBCPP_DISABLE_AVAILABILITY -DWEBKIT_IOS6=1 -DENABLE_UNFAIR_LOCK=0 -DWEBKIT_IOS6_NO_READLINE -DU_STATIC_IMPLEMENTATION"
CF="-flto=thin -mllvm -hot-cold-split=false -target armv7-apple-ios6.0 -mcpu=cortex-a9 -mtune=cortex-a9 -mfpu=neon -isysroot $SDK -isystem $X/include -isystem $P/compat/stubs -include $P/compat/stubs/ios6_class_names.h -DWEBKIT_IOS6=1 -DENABLE_UNFAIR_LOCK=0 -DWEBKIT_IOS6_NO_READLINE -DU_STATIC_IMPLEMENTATION"
rm -rf $B && mkdir -p $B
cmake -S $S -B $B -G Ninja -DCMAKE_MAKE_PROGRAM=/opt/homebrew/bin/ninja \
  `# ccache: every source file this build touches gets recompiled from scratch` \
  `# whenever a CMake flag changes, because the configure scripts rm -rf the` \
  `# build directory first - and tonight alone that has happened four times for` \
  `# a change to one or two files. ccache keys on preprocessed source plus` \
  `# command line, not on the build directory, so it survives the rm -rf and` \
  `# turns "rebuild everything" back into "recompile what changed" after the` \
  `# first pass warms it.` \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_OBJC_COMPILER_LAUNCHER=ccache -DCMAKE_OBJCXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_TOOLCHAIN_FILE=$P/scripts/ios6-armv7-trunk.cmake \
  -DPORT=IOS -DCMAKE_BUILD_TYPE=Release -DDEVELOPER_MODE=OFF \
  -DWEBKIT_IOS6_CRYPTO_LIB=$O/lib/libcrypto.a \
  -DUSE_WEBP=ON -DWebP_INCLUDE_DIR=$WP/include -DWebP_LIBRARY=$WP/lib/libwebp.a -DWebP_DEMUX_LIBRARY=$WP/lib/libwebpdemux.a \
  -DSWIFT_REQUIRED=OFF -DWEBKIT_IOS6_COMPAT_LIB=$P/compat/libios6compat.a -DWEBKIT_IOS6_EXPORTS=$S/Source/WebKitLegacy/WebKitLegacy-iOS.exp -DWEBKIT_IOS6_LIBCXX_DIR=$L -DWEBKIT_NO_AVAILABILITY_OVERLAY=ON \
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
  `# The feed scrolls inside an overflow container, not the document. Without` \
  `# this the engine repaints that container on every frame of a drag and runs` \
  `# a full compositing update with it; with it the scrolled contents get their` \
  `# own layer and a scroll is a layer move.` \
  -DENABLE_WEBKIT_OVERFLOW_SCROLLING_CSS_PROPERTY=ON \
  `# Size, not speed, for everything except the script interpreter. Measured:` \
  `# the engine's own mapped code is ninety one megabytes against a page that` \
  `# uses forty, in a process the system kills at about a hundred and seventy.` \
  -DWEBKIT_IOS6_SIZE_OPTIMIZED=ON \
  `# MathML was cut alongside notifications/fullscreen as "pure code weight"` \
  `# under the old single-site framing; upstream default is ON, it is plain` \
  `# layout code with no platform backend to write, and the goal is no longer` \
  `# a site-specific engine.` \
  `#` \
  `# Fullscreen has a real UIKit bridge now,` \
  `# installFullscreenSupportIfNeeded) plus a fix for a real upstream gap:` \
  `# requestFullscreen()'s IDL is EnabledBySetting=FullScreenEnabled, checked` \
  `# against WebCore::Settings, but WebView.mm's hand-maintained WK1 preference` \
  `# sync (_preferencesChanged:) never grew a line copying it there - it was` \
  `# silently unreachable regardless of the WebPreferences value. Patched.` \
  `#` \
  `# Web notifications: ENABLE(NOTIFICATIONS) on, WK1 WebNotificationClient wired in` \
  `# WebView.mm, and NotificationsEnabled pref defaulted true for iOS in the yaml -` \
  `# window.Notification / requestPermission are exposed and permission is granted.` \
  -DENABLE_NOTIFICATIONS=ON -DENABLE_FULLSCREEN_API=ON \
  -DENABLE_WEBGPU=OFF -DENABLE_WEBDRIVER=OFF -DENABLE_WEBINSPECTORUI=OFF \
  -DENABLE_API_TESTS=OFF -DENABLE_MINIBROWSER=OFF \
  -DENABLE_WEB_RTC=OFF -DUSE_LIBWEBRTC=OFF -DENABLE_MEDIA_STREAM=ON \
  -DENABLE_WEB_CODECS=OFF -DENABLE_COCOA_WEBM_PLAYER=OFF -DENABLE_AV1=OFF \
  \
  `# The SDK ships only libxslt.tbd (link stub); no headers, no static lib for` \
  `# armv7. libxslt/libxml2 headers are the actual gap - libxml2's are already` \
  `# in the SDK and used as-is, libxslt 1.1.43 is vendored under` \
  `# third_party/libxslt-armv7 (scripts/build-libxslt.sh) and reached via the` \
  `# -isystem on $X above. Linking still goes through the existing` \
  `# WEBKIT_ADD_SDK_IMPORTED_LIBRARY(LibXslt::LibXslt libxslt.tbd) in` \
  `# OptionsCocoa.cmake, same mechanism already used for libxml2/sqlite3/zlib` \
  `# on this port - the vendored .a's lib dir is added to the linker search` \
  `# path below only so a future switch to a fully static link (bypassing the` \
  `# on-device system libxslt, the way OpenSSL bypasses SecureTransport) has` \
  `# something to point at.` \
  -DENABLE_XSLT=ON \
  -DENABLE_SPEECH_SYNTHESIS=OFF -DENABLE_WEB_SPEECH=OFF -DENABLE_WEBGL=ON -DENABLE_GAMEPAD=OFF -DENABLE_PIXEL_FORMAT_RGBA16F=OFF -DENABLE_WIRELESS_PLAYBACK_TARGET=ON -DENABLE_WIRELESS_PLAYBACK_TARGET_AVAILABILITY_API=ON -DENABLE_COMPRESSION_STREAM=OFF -DENABLE_APPLE_PAY=OFF -DENABLE_APPLE_PAY_COUPON_CODE=OFF -DENABLE_APPLE_PAY_SESSION_V3=OFF -DUSE_ANGLE_EGL=OFF \
  -DENABLE_JIT=ON -DENABLE_C_LOOP=OFF -DENABLE_DFG_JIT=ON -DENABLE_FTL_JIT=OFF \
  `# bmalloc was tried again and does not link on this port: WTF calls` \
  `# bmalloc::classic::*, which only exists in the non-libpas build, and the` \
  `# objects that do get compiled do not define it. PlatformUse.h also forces the` \
  `# system allocator on 32-bit Darwin unless WEBKIT_IOS6_BMALLOC is defined,` \
  `# which was a deliberate earlier decision. Allocation is 12% of the sampled` \
  `# load window, so the ceiling here is a few percent - not worth the hole.` \
  `# bmalloc builds and runs on this port - the classic allocator lives in` \
  `# Source/bmalloc/bmalloc/ios6 and is gated by the CMake variable` \
  `# WEBKIT_IOS6_BMALLOC, which must be set alongside the compiler define of the` \
  `# same name and USE_SYSTEM_MALLOC=OFF. Measured against the system allocator,` \
  `# alternating builds on the same device and network: domInteractive medians` \
  `# 6240 ms against 6090, resident 157-159 MB against 154-160, and bmalloc owns` \
  `# both outliers at 8.1 and 8.7 s. No gain, so the system allocator stays.` \
  `# bmalloc works here and is slower. The ported classic allocator lives in` \
  `# Source/bmalloc/bmalloc/ios6 behind the CMake variable WEBKIT_IOS6_BMALLOC,` \
  `# which must be set alongside the compiler define of the same name and` \
  `# USE_SYSTEM_MALLOC=OFF; that it is running can be confirmed from the malloc` \
  `# zone list, where it appears as "WebKit Malloc".` \
  `#` \
  `# Measured with tools/allocator-benchmark.js, which allocates without touching` \
  `# the network: system 1494 and 1550 ms, bmalloc 1690, bmalloc with the` \
  `# scavenger at 2048 ms instead of 512 gives 1626 and 1617. Tuning helps and is` \
  `# not enough - the system allocator stays.` \
  -DUSE_SYSTEM_MALLOC=ON \
  `# Verified to build and never reachable from the browser.` \
  -DENABLE_MEDIA_SOURCE=OFF -DENABLE_MEDIA_SOURCE_IN_WORKERS=OFF \
  -DENABLE_ENCRYPTED_MEDIA=OFF -DENABLE_LEGACY_ENCRYPTED_MEDIA=OFF \
  -DENABLE_WEB_AUTHN=OFF -DENABLE_WRITING_TOOLS=OFF -DENABLE_PAYMENT_REQUEST=OFF \
  `# Tools/CMakeLists.txt builds a standalone ImageDiff CLI for layout-test` \
  `# result comparison whenever ENABLE_TOOLS defaults on (it does, Tools/` \
  `# exists). It is not linked into any of the three shipped frameworks, so` \
  `# this saves build time only, not app __TEXT - included anyway since it is` \
  `# dead weight for this port.` \
  -DENABLE_IMAGE_DIFF=OFF \
  -DICU_UC_LIBRARY=$I/lib/libicuuc.a -DICU_I18N_LIBRARY=$I/lib/libicui18n.a \
  -DICU_DATA_LIBRARY=$I/lib/libicudata.a -DICU_INCLUDE_DIR=$I/include \
  -DUSE_WOFF2=ON -DWOFF2_INCLUDE_DIR=$W/include -DWOFF2_DEC_INCLUDE_DIR=$W/include \
  -DWOFF2_LIBRARY=$W/lib/libwoff2common.a -DWOFF2_DEC_LIBRARY=$W/lib/libwoff2dec.a \
  -DCMAKE_SHARED_LINKER_FLAGS="-flto=thin -Wl,-compatibility_version,1.0.0 -Wl,-current_version,1.0.0 -L$X/lib -L$W/lib -lbrotlidec" \
  -DCMAKE_CXX_FLAGS="$CXXF" -DCMAKE_C_FLAGS="$CF" \
  -DCMAKE_OBJCXX_FLAGS="$CXXF -DWEBKIT_IOS6_OBJC_EXTRAS" -DCMAKE_OBJC_FLAGS="$CF -DWEBKIT_IOS6_OBJC_EXTRAS" \
  `# find_library searches the host as well, and on a Mac it finds this` \
  `# framework in the running system - a path that means nothing to a linker` \
  `# targeting armv7, which then fails with "framework not found". It is an` \
  `# optional dependency, so it is declared absent.` \
  -DBROWSERENGINECORE_LIBRARY=BROWSERENGINECORE_LIBRARY-NOTFOUND \
  -DBROWSERENGINEKIT_LIBRARY=BROWSERENGINEKIT_LIBRARY-NOTFOUND \
  -DUNIFORMTYPEIDENTIFIERS_LIBRARY=UNIFORMTYPEIDENTIFIERS_LIBRARY-NOTFOUND \
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
