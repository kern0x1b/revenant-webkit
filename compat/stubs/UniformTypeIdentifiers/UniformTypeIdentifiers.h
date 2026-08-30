/*
 * UniformTypeIdentifiers.framework is iOS 14. This declares the small part of
 * UTType that WebKit uses, implemented on top of MobileCoreServices, which has
 * been present since iOS 3. The well-known constants become expressions rather
 * than globals so no new symbols are needed at link time.
 */
#pragma once
#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>

@interface UTType : NSObject
@property (readonly, copy) NSString *identifier;
@property (readonly, copy) NSString *preferredMIMEType;
@property (readonly, copy) NSString *preferredFilenameExtension;
+ (UTType *)typeWithIdentifier:(NSString *)identifier;
+ (UTType *)typeWithMIMEType:(NSString *)mimeType;
+ (UTType *)typeWithFilenameExtension:(NSString *)filenameExtension;
- (BOOL)conformsToType:(UTType *)type;
- (NSArray<NSString *> *)tags:(NSString *)tagClass;
@property (readonly, copy) NSDictionary<NSString *, NSArray<NSString *> *> *tags;
@property (readonly, getter=isDeclared) BOOL declared;
@property (readonly, getter=isDynamic) BOOL dynamic;
@end

#define WEBKIT_IOS6_UTTYPE(id) ([UTType typeWithIdentifier:(id)])
#define UTTypeItem              WEBKIT_IOS6_UTTYPE(@"public.item")
#define UTTypeContent           WEBKIT_IOS6_UTTYPE(@"public.content")
#define UTTypeData              WEBKIT_IOS6_UTTYPE(@"public.data")
#define UTTypeDirectory         WEBKIT_IOS6_UTTYPE(@"public.directory")
#define UTTypeFolder            WEBKIT_IOS6_UTTYPE(@"public.folder")
#define UTTypePackage           WEBKIT_IOS6_UTTYPE(@"com.apple.package")
#define UTTypeURL               WEBKIT_IOS6_UTTYPE(@"public.url")
#define UTTypeFileURL           WEBKIT_IOS6_UTTYPE(@"public.file-url")
#define UTTypeText              WEBKIT_IOS6_UTTYPE(@"public.text")
#define UTTypePlainText         WEBKIT_IOS6_UTTYPE(@"public.plain-text")
#define UTTypeUTF8PlainText     WEBKIT_IOS6_UTTYPE(@"public.utf8-plain-text")
#define UTTypeUTF16PlainText    WEBKIT_IOS6_UTTYPE(@"public.utf16-plain-text")
#define UTTypeHTML              WEBKIT_IOS6_UTTYPE(@"public.html")
#define UTTypeRTF               WEBKIT_IOS6_UTTYPE(@"public.rtf")
#define UTTypeRTFD              WEBKIT_IOS6_UTTYPE(@"com.apple.rtfd")
#define UTTypeFlatRTFD          WEBKIT_IOS6_UTTYPE(@"com.apple.flat-rtfd")
#define UTTypeWebArchive        WEBKIT_IOS6_UTTYPE(@"com.apple.webarchive")
#define UTTypePNG               WEBKIT_IOS6_UTTYPE(@"public.png")
#define UTTypeJPEG              WEBKIT_IOS6_UTTYPE(@"public.jpeg")
#define UTTypeGIF               WEBKIT_IOS6_UTTYPE(@"com.compuserve.gif")
#define UTTypeTIFF              WEBKIT_IOS6_UTTYPE(@"public.tiff")
#define UTTypeSVG               WEBKIT_IOS6_UTTYPE(@"public.svg-image")
#define UTTypePDF               WEBKIT_IOS6_UTTYPE(@"com.adobe.pdf")
#define UTTypeZIP               WEBKIT_IOS6_UTTYPE(@"public.zip-archive")
#define UTTypeVCard             WEBKIT_IOS6_UTTYPE(@"public.vcard")
#define UTTypeCalendarEvent     WEBKIT_IOS6_UTTYPE(@"com.apple.ical.ics")

#define UTTagClassFilenameExtension ((__bridge NSString *)kUTTagClassFilenameExtension)
#define UTTagClassMIMEType ((__bridge NSString *)kUTTagClassMIMEType)
