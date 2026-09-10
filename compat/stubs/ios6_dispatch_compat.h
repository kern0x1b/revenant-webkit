#pragma once

struct dispatch_source_type_s;
#ifdef __cplusplus
extern "C" {
#endif
extern const struct dispatch_source_type_s _dispatch_source_type_vm;
#ifdef __cplusplus
}
#endif

#ifndef HAVE_XPC_API
#define HAVE_XPC_API 0
#endif

#ifndef HAVE_OS_SIGNPOST
#define HAVE_OS_SIGNPOST 0
#endif

#include <mach/vm_statistics.h>
#undef VM_FLAGS_PERMANENT
#define VM_FLAGS_PERMANENT 0

#include <stdint.h>
#ifndef WEBKIT_IOS6_CMTAG_STUBS
#define WEBKIT_IOS6_CMTAG_STUBS
typedef uint32_t CMTagCategory;
typedef struct OpaqueCMTagCollection *CMTagCollectionRef;
typedef struct OpaqueCMTaggedBufferGroup *CMTaggedBufferGroupRef;
typedef struct OpaqueCMTaggedBufferGroupFormatDescription *CMTaggedBufferGroupFormatDescriptionRef;
typedef struct { uint64_t value[2]; } CMTag;
#endif

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
#ifndef WEBKIT_IOS6_UIBUTTON_CONFIG
#define WEBKIT_IOS6_UIBUTTON_CONFIG
typedef void (^UIButtonConfigurationUpdateHandler)(id button);
#endif
#endif

#if defined(__cplusplus)
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
#endif

#if defined(__OBJC__)
#ifndef AXCustomContentImportanceHigh
#define AXCustomContentImportanceHigh 1
#endif
#endif

#if defined(__OBJC__)
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

#ifndef NS_SWIFT_SENDABLE
#define NS_SWIFT_SENDABLE
#endif

#if defined(__OBJC__) && defined(WEBKIT_IOS6_OBJC_EXTRAS)
#import <AVFoundation/AVAudioSession.h>
#import <AVFoundation/AVFoundation.h>
#endif

#ifndef kCMVideoCodecType_VP9
#define kCMVideoCodecType_VP9 'vp09'
#endif
#ifndef kCMVideoCodecType_AV1
#define kCMVideoCodecType_AV1 'av01'
#endif

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

#if defined(__OBJC__) || defined(__cplusplus)
#ifndef kCGImagePropertyWebPDictionary
#define kCGImagePropertyWebPDictionary CFSTR("{WebP}")
#endif
#ifndef kCGImageAuxiliaryDataTypeHDRGainMap
#define kCGImageAuxiliaryDataTypeHDRGainMap CFSTR("kCGImageAuxiliaryDataTypeHDRGainMap")
#endif
#endif

#ifndef kCTFontVariationAxesAttribute
#define kCTFontVariationAxesAttribute kCTFontVariationAttribute
#endif

#ifndef kCVPixelFormatType_64RGBALE
#define kCVPixelFormatType_64RGBALE 'l64r'
#endif
#ifndef kCVPixelFormatType_30RGB_r210
#define kCVPixelFormatType_30RGB_r210 'r210'
#endif
#ifndef kCVPixelFormatType_4444AYpCbCrFloat
#define kCVPixelFormatType_4444AYpCbCrFloat 'r4fl'
#endif

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

#include <Security/SecTrust.h>
#ifdef __cplusplus
extern "C"
#endif
CFArrayRef SecTrustCopyCertificateChain(SecTrustRef trust);

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

#import <Foundation/NSError.h>
@interface NSError (WebKitIOS6UnderlyingErrors)
@property (readonly) NSArray<NSError *> *underlyingErrors;
@end
#endif

#if defined(__OBJC__)
#import <UIKit/UIScreen.h>
@interface UIScreen (WebKitIOS6EDR)
@property (readonly) CGFloat currentEDRHeadroom;
@property (readonly) CGFloat potentialEDRHeadroom;
@end
#endif
