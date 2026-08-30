/* Gaps between the iPhoneOS 13.7 SDK this port compiles against and what WebKit
 * trunk expects. Everything here is either absent from the SDK entirely or
 * soft-linked at runtime and therefore never reached on iOS 6. */
#pragma once

/* The VM pressure source that DISPATCH_SOURCE_TYPE_MEMORYPRESSURE replaced in
 * iOS 8. libdispatch still exports it, and it is all this system has. */
struct dispatch_source_type_s;
#ifdef __cplusplus
extern "C" {
#endif
extern const struct dispatch_source_type_s _dispatch_source_type_vm;
#ifdef __cplusplus
}
#endif

/* XPC is private on iOS and ships no headers; WTF declares the SPI itself. */
#ifndef HAVE_XPC_API
#define HAVE_XPC_API 0
#endif

/* os_signpost exists in this SDK but not on the device. */
#ifndef HAVE_OS_SIGNPOST
#define HAVE_OS_SIGNPOST 0
#endif

/* VM_FLAGS_PERMANENT is not honoured by the iOS 6 kernel; zero makes the
 * mapping ordinary instead of making mach_vm_map fail. */
#include <mach/vm_statistics.h>
#undef VM_FLAGS_PERMANENT
#define VM_FLAGS_PERMANENT 0

/* CoreMedia tag types, added in iOS 17 for spatial video. Soft-linked. */
#include <stdint.h>
#ifndef WEBKIT_IOS6_CMTAG_STUBS
#define WEBKIT_IOS6_CMTAG_STUBS
typedef uint32_t CMTagCategory;
typedef struct OpaqueCMTagCollection *CMTagCollectionRef;
typedef struct OpaqueCMTaggedBufferGroup *CMTaggedBufferGroupRef;
typedef struct OpaqueCMTaggedBufferGroupFormatDescription *CMTaggedBufferGroupFormatDescriptionRef;
typedef struct { uint64_t value[2]; } CMTag;
#endif

/* Introduced after this SDK: a mach port token (iOS 17) and two idiom values
 * (iOS 14 and iOS 17). Only ever compared against, never produced here. */
#include <mach/port.h>
#ifndef WEBKIT_IOS6_TASK_ID_TOKEN
#define WEBKIT_IOS6_TASK_ID_TOKEN
typedef mach_port_t task_id_token_t;
#endif
#if defined(__OBJC__)
#define UIUserInterfaceIdiomMac ((UIUserInterfaceIdiom)5)
#define UIUserInterfaceIdiomVision ((UIUserInterfaceIdiom)6)
#endif

#if defined(__OBJC__)
/* UIButton configuration API, iOS 15. Only appears in soft-linked SPI headers. */
#ifndef WEBKIT_IOS6_UIBUTTON_CONFIG
#define WEBKIT_IOS6_UIBUTTON_CONFIG
typedef void (^UIButtonConfigurationUpdateHandler)(id button);
#endif
#endif

#if defined(__cplusplus)
/* Mach-O thread-local storage needs dyld support that arrived in iOS 9, so
 * clang refuses `thread_local` for this deployment target. This stands in for
 * it using a pthread key, for values that fit in a pointer slot. The key is
 * created on first use so the object needs no static constructor. */
#include <pthread.h>
#include <stdint.h>
template<typename T> class IOS6ThreadLocal {
public:
    operator T() const { return unpack(pthread_getspecific(key())); }
    IOS6ThreadLocal& operator=(T value) { pthread_setspecific(key(), pack(value)); return *this; }
    T operator->() const { return unpack(pthread_getspecific(key())); }
    bool operator!() const { return !static_cast<T>(*this); }
    T operator++() { T value = static_cast<T>(*this) + 1; *this = value; return value; }
    T operator--() { T value = static_cast<T>(*this) - 1; *this = value; return value; }

private:
    /* C-style casts so the same template serves pointers and integers. */
    static T unpack(void* slot) { return (T)(uintptr_t)slot; }
    static void* pack(T value) { return (void*)(uintptr_t)value; }

    pthread_key_t key() const
    {
        uintptr_t stored = __atomic_load_n(&m_keyPlusOne, __ATOMIC_ACQUIRE);
        if (!stored) {
            pthread_key_t fresh;
            pthread_key_create(&fresh, nullptr);
            uintptr_t expected = 0;
            uintptr_t desired = static_cast<uintptr_t>(fresh) + 1;
            if (__atomic_compare_exchange_n(&m_keyPlusOne, &expected, desired, false,
                                            __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
                stored = desired;
            else {
                pthread_key_delete(fresh);
                stored = expected;
            }
        }
        return static_cast<pthread_key_t>(stored - 1);
    }

    mutable uintptr_t m_keyPlusOne = 0;
};
#endif /* __cplusplus */

#if defined(__OBJC__)
/* AXCustomContent is iOS 14; the accessibility wrapper only stores the value. */
#ifndef AXCustomContentImportanceHigh
#define AXCustomContentImportanceHigh 1
#endif
#endif

#if defined(__OBJC__)
/* NSTextList and NSParagraphStyle.textLists arrived in iOS 15. Declared here
 * rather than in a UIKit stub header so they precede WebKit's own forward
 * declarations. */
#import <Foundation/Foundation.h>
#ifndef WEBKIT_IOS6_TEXT_LIST
#define WEBKIT_IOS6_TEXT_LIST
typedef NSString *NSTextListMarkerFormat;
@interface NSTextList : NSObject
@property (readonly, copy) NSTextListMarkerFormat markerFormat;
@property NSInteger startingItemNumber;
@end
#endif
#endif

/* NS_SWIFT_SENDABLE post-dates this SDK; WebKit's own SPI headers use it. */
#ifndef NS_SWIFT_SENDABLE
#define NS_SWIFT_SENDABLE
#endif

#if defined(__OBJC__) && defined(WEBKIT_IOS6_OBJC_EXTRAS)
/* AVKit's AVPlaybackRouteSelecting.h extends AVAudioSession without importing
 * it; pulling AVFoundation in first satisfies the category. */
#import <AVFoundation/AVAudioSession.h>
#import <AVFoundation/AVFoundation.h>
#endif

/* Codec identifiers added in later releases; only compared against here. */
#ifndef kCMVideoCodecType_VP9
#define kCMVideoCodecType_VP9 'vp09'
#endif
#ifndef kCMVideoCodecType_AV1
#define kCMVideoCodecType_AV1 'av01'
#endif

/* Bounds-safety attributes. Newer SDKs supply these through <ptrcheck.h>, which
 * this one does not have; they are annotations only. */
#ifndef __counted_by
#define __counted_by(N)
#endif
#ifndef __sized_by
#define __sized_by(N)
#endif
#ifndef __ended_by
#define __ended_by(E)
#endif
#ifndef __terminated_by
#define __terminated_by(T)
#endif
#ifndef __null_terminated
#define __null_terminated
#endif
#ifndef __unsafe_indexable
#define __unsafe_indexable
#endif
#ifndef __bidi_indexable
#define __bidi_indexable
#endif
#ifndef __single
#define __single
#endif

/* Format constants added in later releases. Values taken from the current SDK;
 * they are only ever compared against here. */
#ifndef kAudioFileBW64Type
#define kAudioFileBW64Type 'BW64'
#endif
#ifndef kAudioFileWave64Type
#define kAudioFileWave64Type 'W64f'
#endif
#ifndef kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
#define kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange '&8v0'
#endif
#ifndef kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange
#define kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange '&8f0'
#endif

/* Ogg channel layout tags, added to CoreAudioTypes long after this SDK. Values
 * copied from the current one; used only in a switch over layouts. */
#ifndef kAudioChannelLayoutTag_Ogg_3_0
#define kAudioChannelLayoutTag_Ogg_3_0 kAudioChannelLayoutTag_AC3_3_0
#endif
#ifndef kAudioChannelLayoutTag_Ogg_4_0
#define kAudioChannelLayoutTag_Ogg_4_0 kAudioChannelLayoutTag_WAVE_4_0_B
#endif
#ifndef kAudioChannelLayoutTag_Ogg_5_0
#define kAudioChannelLayoutTag_Ogg_5_0 ((212U << 16) | 5)
#endif
#ifndef kAudioChannelLayoutTag_Ogg_5_1
#define kAudioChannelLayoutTag_Ogg_5_1 ((213U << 16) | 6)
#endif
#ifndef kAudioChannelLayoutTag_Ogg_6_1
#define kAudioChannelLayoutTag_Ogg_6_1 ((214U << 16) | 7)
#endif
#ifndef kAudioChannelLayoutTag_Ogg_7_1
#define kAudioChannelLayoutTag_Ogg_7_1 ((215U << 16) | 8)
#endif

/* ImageIO keys added later; WebKit only looks them up in dictionaries. */
#if defined(__OBJC__) || defined(__cplusplus)
#ifndef kCGImagePropertyWebPDictionary
#define kCGImagePropertyWebPDictionary CFSTR("{WebP}")
#endif
#ifndef kCGImageAuxiliaryDataTypeHDRGainMap
#define kCGImageAuxiliaryDataTypeHDRGainMap CFSTR("kCGImageAuxiliaryDataTypeHDRGainMap")
#endif
#endif

/* Keys and modes from much newer releases, looked up in dictionaries or
 * compared against; never produced on this device. */
#ifndef kIOSurfaceContentHeadroom
#define kIOSurfaceContentHeadroom CFSTR("IOSurfaceContentHeadroom")
#endif
#ifndef kCTFontVariationAxesAttribute
#define kCTFontVariationAxesAttribute kCTFontVariationAttribute
#endif

/* CoreVideo pixel formats added after this SDK; only used in format switches. */
#ifndef kCVPixelFormatType_64RGBALE
#define kCVPixelFormatType_64RGBALE 'l64r'
#endif
#ifndef kCVPixelFormatType_30RGB_r210
#define kCVPixelFormatType_30RGB_r210 'r210'
#endif
#ifndef kCVPixelFormatType_4444AYpCbCrFloat
#define kCVPixelFormatType_4444AYpCbCrFloat 'r4fl'
#endif

/* CoreVideo pixel formats newer than this SDK; used only in switches. */
#ifndef kCVPixelFormatType_16VersatileBayer
#define kCVPixelFormatType_16VersatileBayer 'bp16'
#endif
#ifndef kCVPixelFormatType_30RGBLE_8A_BiPlanar
#define kCVPixelFormatType_30RGBLE_8A_BiPlanar 'b3a8'
#endif
#ifndef kCVPixelFormatType_30RGB_r210
#define kCVPixelFormatType_30RGB_r210 'r210'
#endif
#ifndef kCVPixelFormatType_40ARGBLEWideGamut
#define kCVPixelFormatType_40ARGBLEWideGamut 'w40a'
#endif
#ifndef kCVPixelFormatType_40ARGBLEWideGamutPremultiplied
#define kCVPixelFormatType_40ARGBLEWideGamutPremultiplied 'w40m'
#endif
#ifndef kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange
#define kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange 'sv22'
#endif
#ifndef kCVPixelFormatType_422YpCbCr8BiPlanarFullRange
#define kCVPixelFormatType_422YpCbCr8BiPlanarFullRange '422f'
#endif
#ifndef kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
#define kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange '422v'
#endif
#ifndef kCVPixelFormatType_4444AYpCbCrFloat
#define kCVPixelFormatType_4444AYpCbCrFloat 'r4fl'
#endif
#ifndef kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange
#define kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange 'sv44'
#endif
#ifndef kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar
#define kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar 's4as'
#endif
#ifndef kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
#define kCVPixelFormatType_444YpCbCr8BiPlanarFullRange '444f'
#endif
#ifndef kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
#define kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange '444v'
#endif
#ifndef kCVPixelFormatType_64RGBALE
#define kCVPixelFormatType_64RGBALE 'l64r'
#endif
#ifndef kCVPixelFormatType_64RGBA_DownscaledProResRAW
#define kCVPixelFormatType_64RGBA_DownscaledProResRAW 'bp64'
#endif
#ifndef kCVPixelFormatType_96VersatileBayerPacked12
#define kCVPixelFormatType_96VersatileBayerPacked12 'btp2'
#endif
#ifndef kCVPixelFormatType_Lossless_30RGBLEPackedWideGamut
#define kCVPixelFormatType_Lossless_30RGBLEPackedWideGamut '&w3r'
#endif
#ifndef kCVPixelFormatType_Lossless_30RGBLE_8A_BiPlanar
#define kCVPixelFormatType_Lossless_30RGBLE_8A_BiPlanar '&b38'
#endif
#ifndef kCVPixelFormatType_Lossless_32BGRA
#define kCVPixelFormatType_Lossless_32BGRA '&BGA'
#endif
#ifndef kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange
#define kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange '&xf0'
#endif
#ifndef kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange
#define kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange '&xv0'
#endif
#ifndef kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange
#define kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange '&8f0'
#endif
#ifndef kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
#define kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange '&8v0'
#endif
#ifndef kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange
#define kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange '&xv2'
#endif
#ifndef kCVPixelFormatType_Lossless_64RGBAHalf
#define kCVPixelFormatType_Lossless_64RGBAHalf '&RhA'
#endif
#ifndef kCVPixelFormatType_Lossy_32BGRA
#define kCVPixelFormatType_Lossy_32BGRA '-BGA'
#endif
#ifndef kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange
#define kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange '-xv0'
#endif
#ifndef kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange
#define kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange '-8f0'
#endif
#ifndef kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange
#define kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange '-8v0'
#endif
#ifndef kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange
#define kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange '-xv2'
#endif
#ifndef kCVPixelFormatType_OneComponent10
#define kCVPixelFormatType_OneComponent10 'L010'
#endif
#ifndef kCVPixelFormatType_OneComponent12
#define kCVPixelFormatType_OneComponent12 'L012'
#endif
#ifndef kCVPixelFormatType_OneComponent16
#define kCVPixelFormatType_OneComponent16 'L016'
#endif
#ifndef kCVPixelFormatType_TwoComponent16
#define kCVPixelFormatType_TwoComponent16 '2C16'
#endif

/* Wide-gamut colour space names from later releases. This screen is sRGB, so
 * the nearest available space is the right answer. */
#ifndef kCGColorSpaceExtendedDisplayP3
#define kCGColorSpaceExtendedDisplayP3 kCGColorSpaceExtendedLinearSRGB
#endif
#ifndef kCGColorSpaceExtendedITUR_2020
#define kCGColorSpaceExtendedITUR_2020 kCGColorSpaceExtendedLinearSRGB
#endif
#ifndef kCGColorSpaceLinearDisplayP3
#define kCGColorSpaceLinearDisplayP3 kCGColorSpaceLinearSRGB
#endif

#if defined(__OBJC__)
/* NSURLRequest.attribution is iOS 15. WebKit only uses it to tell developer
 * initiated loads from user initiated ones, which changes nothing here. */
#ifndef WEBKIT_IOS6_URL_ATTRIBUTION
#define WEBKIT_IOS6_URL_ATTRIBUTION
#import <Foundation/NSURLRequest.h>
typedef NS_ENUM(NSInteger, WebKitIOS6URLRequestAttribution) {
    NSURLRequestAttributionDeveloper = 0,
    NSURLRequestAttributionUser = 1,
};
@interface NSURLRequest (WebKitIOS6Attribution)
@property (readonly) WebKitIOS6URLRequestAttribution attribution;
@end
@interface NSMutableURLRequest (WebKitIOS6Attribution)
@property WebKitIOS6URLRequestAttribution attribution;
@end
#endif
#endif

/* SecTrustCopyCertificateChain is iOS 14; the implementation lives in the
 * compatibility library and walks the trust with the older API. */
#include <Security/SecTrust.h>
#ifdef __cplusplus
extern "C"
#endif
CFArrayRef SecTrustCopyCertificateChain(SecTrustRef trust);

/* NW_OBJECT_DECL_SUBCLASS post-dates this SDK's Network framework, though the
 * underlying os_object macro is present. */
#if defined(__OBJC__)
#include <os/object.h>
#ifndef NW_OBJECT_DECL_SUBCLASS
#if OS_OBJECT_USE_OBJC
#define NW_OBJECT_DECL_SUBCLASS(type, base) OS_OBJECT_DECL_SUBCLASS(type, base)
#else
#define NW_OBJECT_DECL_SUBCLASS(type, base) \
    struct type;                            \
    typedef struct type *type##_t
#endif
#endif

/* NSError.underlyingErrors is iOS 15; the single underlying error has always
 * been available through the user info dictionary. */
#import <Foundation/NSError.h>
@interface NSError (WebKitIOS6UnderlyingErrors)
@property (readonly) NSArray<NSError *> *underlyingErrors;
@end
#endif

#if defined(__OBJC__)
/* Extended dynamic range headroom on UIScreen is iOS 16. A headroom of 1.0
 * means "standard dynamic range", which is what this display is. */
#import <UIKit/UIScreen.h>
@interface UIScreen (WebKitIOS6EDR)
@property (readonly) CGFloat currentEDRHeadroom;
@property (readonly) CGFloat potentialEDRHeadroom;
@end
#endif
