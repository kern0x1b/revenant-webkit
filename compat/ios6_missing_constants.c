/*
 * Constants WebKit imports that this system does not define. Each becomes a
 * distinctly named CFString, so dictionary lookups miss rather than crash.
 */
#include <CoreFoundation/CoreFoundation.h>

const CFStringRef kAXSEnhanceTextLegibilityChangedNotification = CFSTR("kAXSEnhanceTextLegibilityChangedNotification");
const CFStringRef kCAContentsFormatRGBA10XR = CFSTR("kCAContentsFormatRGBA10XR");
const CFStringRef kCACornerCurveCircular = CFSTR("kCACornerCurveCircular");
const CFStringRef kCAFilterColorBlendMode = CFSTR("kCAFilterColorBlendMode");
const CFStringRef kCAFilterHueBlendMode = CFSTR("kCAFilterHueBlendMode");
const CFStringRef kCAFilterLuminosityBlendMode = CFSTR("kCAFilterLuminosityBlendMode");
const CFStringRef kCAFilterSaturationBlendMode = CFSTR("kCAFilterSaturationBlendMode");
const CFStringRef kCGColorSpaceDisplayP3 = CFSTR("kCGColorSpaceDisplayP3");
const CFStringRef kCGColorSpaceDisplayP3_PQ = CFSTR("kCGColorSpaceDisplayP3_PQ");
const CFStringRef kCGColorSpaceExtendedLinearDisplayP3 = CFSTR("kCGColorSpaceExtendedLinearDisplayP3");
const CFStringRef kCGColorSpaceExtendedLinearSRGB = CFSTR("kCGColorSpaceExtendedLinearSRGB");
const CFStringRef kCGColorSpaceExtendedSRGB = CFSTR("kCGColorSpaceExtendedSRGB");
const CFStringRef kCGColorSpaceGenericXYZ = CFSTR("kCGColorSpaceGenericXYZ");
const CFStringRef kCGColorSpaceITUR_2020 = CFSTR("kCGColorSpaceITUR_2020");
const CFStringRef kCGColorSpaceLinearSRGB = CFSTR("kCGColorSpaceLinearSRGB");
const CFStringRef kCGColorSpaceROMMRGB = CFSTR("kCGColorSpaceROMMRGB");
const CFStringRef kCGFlexRangeAlternateColorSpace = CFSTR("kCGFlexRangeAlternateColorSpace");
const CFStringRef kCGGradientInterpolatesPremultiplied = CFSTR("kCGGradientInterpolatesPremultiplied");
const CFStringRef kCGImageAuxiliaryDataInfoColorSpace = CFSTR("kCGImageAuxiliaryDataInfoColorSpace");
const CFStringRef kCGImageAuxiliaryDataInfoMetadata = CFSTR("kCGImageAuxiliaryDataInfoMetadata");
const CFStringRef kCGImageAuxiliaryDataTypeISOGainMap = CFSTR("kCGImageAuxiliaryDataTypeISOGainMap");
const CFStringRef kCGImagePropertyAuxiliaryData = CFSTR("kCGImagePropertyAuxiliaryData");
const CFStringRef kCGImagePropertyAuxiliaryDataType = CFSTR("kCGImagePropertyAuxiliaryDataType");
const CFStringRef kCGImagePropertyFileContentsDictionary = CFSTR("kCGImagePropertyFileContentsDictionary");
const CFStringRef kCGImagePropertyImageCount = CFSTR("kCGImagePropertyImageCount");
const CFStringRef kCGImagePropertyImages = CFSTR("kCGImagePropertyImages");
const CFStringRef kCGImageSourceShouldCacheImmediately = CFSTR("kCGImageSourceShouldCacheImmediately");
const CFStringRef kCGTargetColorSpace = CFSTR("kCGTargetColorSpace");
const CFStringRef kCGTargetHeadroom = CFSTR("kCGTargetHeadroom");
const CFStringRef kCGTargetPixelFormat = CFSTR("kCGTargetPixelFormat");
const CFStringRef kCTFontCSSFamilyCursive = CFSTR("kCTFontCSSFamilyCursive");
const CFStringRef kCTFontCSSFamilyFantasy = CFSTR("kCTFontCSSFamilyFantasy");
const CFStringRef kCTFontCSSFamilyMonospace = CFSTR("kCTFontCSSFamilyMonospace");
const CFStringRef kCTFontCSSFamilySansSerif = CFSTR("kCTFontCSSFamilySansSerif");
const CFStringRef kCTFontCSSFamilySerif = CFSTR("kCTFontCSSFamilySerif");
const CFStringRef kCTFontCSSWeightAttribute = CFSTR("kCTFontCSSWeightAttribute");
const CFStringRef kCTFontCSSWidthAttribute = CFSTR("kCTFontCSSWidthAttribute");
const CFStringRef kCTFontContentSizeCategoryL = CFSTR("kCTFontContentSizeCategoryL");
const CFStringRef kCTFontDescriptorLanguageAttribute = CFSTR("kCTFontDescriptorLanguageAttribute");
const CFStringRef kCTFontDescriptorTextStyleAttribute = CFSTR("kCTFontDescriptorTextStyleAttribute");
const CFStringRef kCTFontFallbackOptionAttribute = CFSTR("kCTFontFallbackOptionAttribute");
const CFStringRef kCTFontGradeTrait = CFSTR("kCTFontGradeTrait");
const CFStringRef kCTFontIgnoreLegibilityWeightAttribute = CFSTR("kCTFontIgnoreLegibilityWeightAttribute");
const CFStringRef kCTFontManagerRegisteredFontsChangedNotification = CFSTR("kCTFontManagerRegisteredFontsChangedNotification");
const CFStringRef kCTFontOpenTypeFeatureTag = CFSTR("kCTFontOpenTypeFeatureTag");
const CFStringRef kCTFontOpenTypeFeatureValue = CFSTR("kCTFontOpenTypeFeatureValue");
const CFStringRef kCTFontOpticalSizeAttribute = CFSTR("kCTFontOpticalSizeAttribute");
const CFStringRef kCTFontPaletteAttribute = CFSTR("kCTFontPaletteAttribute");
const CFStringRef kCTFontPaletteColorsAttribute = CFSTR("kCTFontPaletteColorsAttribute");
const CFStringRef kCTFontPostScriptNameAttribute = CFSTR("kCTFontPostScriptNameAttribute");
const CFStringRef kCTFontSizeCategoryAttribute = CFSTR("kCTFontSizeCategoryAttribute");
const CFStringRef kCTFontTrackAttribute = CFSTR("kCTFontTrackAttribute");
const CFStringRef kCTFontUIFontDesignDefault = CFSTR("kCTFontUIFontDesignDefault");
const CFStringRef kCTFontUIFontDesignMonospaced = CFSTR("kCTFontUIFontDesignMonospaced");
const CFStringRef kCTFontUIFontDesignRounded = CFSTR("kCTFontUIFontDesignRounded");
const CFStringRef kCTFontUIFontDesignSerif = CFSTR("kCTFontUIFontDesignSerif");
const CFStringRef kCTFontUIFontDesignTrait = CFSTR("kCTFontUIFontDesignTrait");
const CFStringRef kCTFontUnscaledTrackingAttribute = CFSTR("kCTFontUnscaledTrackingAttribute");
const CFStringRef kCTFontUserInstalledAttribute = CFSTR("kCTFontUserInstalledAttribute");
const CFStringRef kCTFontWeightBlack = CFSTR("kCTFontWeightBlack");
const CFStringRef kCTFontWeightBold = CFSTR("kCTFontWeightBold");
const CFStringRef kCTFontWeightHeavy = CFSTR("kCTFontWeightHeavy");
const CFStringRef kCTFontWeightLight = CFSTR("kCTFontWeightLight");
const CFStringRef kCTFontWeightMedium = CFSTR("kCTFontWeightMedium");
const CFStringRef kCTFontWeightRegular = CFSTR("kCTFontWeightRegular");
const CFStringRef kCTFontWeightSemibold = CFSTR("kCTFontWeightSemibold");
const CFStringRef kCTFontWeightThin = CFSTR("kCTFontWeightThin");
const CFStringRef kCTFontWeightUltraLight = CFSTR("kCTFontWeightUltraLight");
const CFStringRef kCTFontWidthCondensed = CFSTR("kCTFontWidthCondensed");
const CFStringRef kCTFontWidthExpanded = CFSTR("kCTFontWidthExpanded");
const CFStringRef kCTFontWidthExtraCompressed = CFSTR("kCTFontWidthExtraCompressed");
const CFStringRef kCTFontWidthExtraCondensed = CFSTR("kCTFontWidthExtraCondensed");
const CFStringRef kCTFontWidthExtraExpanded = CFSTR("kCTFontWidthExtraExpanded");
const CFStringRef kCTFontWidthSemiCondensed = CFSTR("kCTFontWidthSemiCondensed");
const CFStringRef kCTFontWidthSemiExpanded = CFSTR("kCTFontWidthSemiExpanded");
const CFStringRef kCTFontWidthStandard = CFSTR("kCTFontWidthStandard");
const CFStringRef kCTFontWidthUltraCompressed = CFSTR("kCTFontWidthUltraCompressed");
const CFStringRef kCTLanguageAttributeName = CFSTR("kCTLanguageAttributeName");
const CFStringRef kCTUIFontTextStyleBody = CFSTR("kCTUIFontTextStyleBody");
const CFStringRef kCTUIFontTextStyleCaption1 = CFSTR("kCTUIFontTextStyleCaption1");
const CFStringRef kCTUIFontTextStyleCaption2 = CFSTR("kCTUIFontTextStyleCaption2");
const CFStringRef kCTUIFontTextStyleFootnote = CFSTR("kCTUIFontTextStyleFootnote");
const CFStringRef kCTUIFontTextStyleHeadline = CFSTR("kCTUIFontTextStyleHeadline");
const CFStringRef kCTUIFontTextStyleShortBody = CFSTR("kCTUIFontTextStyleShortBody");
const CFStringRef kCTUIFontTextStyleShortCaption1 = CFSTR("kCTUIFontTextStyleShortCaption1");
const CFStringRef kCTUIFontTextStyleShortFootnote = CFSTR("kCTUIFontTextStyleShortFootnote");
const CFStringRef kCTUIFontTextStyleShortHeadline = CFSTR("kCTUIFontTextStyleShortHeadline");
const CFStringRef kCTUIFontTextStyleShortSubhead = CFSTR("kCTUIFontTextStyleShortSubhead");
const CFStringRef kCTUIFontTextStyleSubhead = CFSTR("kCTUIFontTextStyleSubhead");
const CFStringRef kCTUIFontTextStyleTallBody = CFSTR("kCTUIFontTextStyleTallBody");
const CFStringRef kCTUIFontTextStyleTitle0 = CFSTR("kCTUIFontTextStyleTitle0");
const CFStringRef kCTUIFontTextStyleTitle1 = CFSTR("kCTUIFontTextStyleTitle1");
const CFStringRef kCTUIFontTextStyleTitle2 = CFSTR("kCTUIFontTextStyleTitle2");
const CFStringRef kCTUIFontTextStyleTitle3 = CFSTR("kCTUIFontTextStyleTitle3");
const CFStringRef kCTUIFontTextStyleTitle4 = CFSTR("kCTUIFontTextStyleTitle4");

/*
 * These are data, not functions. Declaring them as function stubs links, and
 * then the address of the stub is used as if it were a string or a struct —
 * which is how NSProcessInfoPowerStateDidChangeNotification reached
 * CFXNotificationRegisterObserver as a garbage name and crashed it.
 */
const CFStringRef _kCFURLCachePartitionKey = CFSTR("kCFURLCachePartitionKey");

extern const void *const NSHTTPCookieSameSiteLax;
extern const void *const NSHTTPCookieSameSitePolicy;
extern const void *const NSHTTPCookieSameSiteStrict;
extern const void *const NSProcessInfoPowerStateDidChangeNotification;
extern const void *const NSProcessInfoThermalStateDidChangeNotification;
extern const void *const NSURLAuthenticationMethodOAuth;

const void *const NSHTTPCookieSameSiteLax = CFSTR("Lax");
const void *const NSHTTPCookieSameSitePolicy = CFSTR("SameSitePolicy");
const void *const NSHTTPCookieSameSiteStrict = CFSTR("Strict");
const void *const NSProcessInfoPowerStateDidChangeNotification = CFSTR("NSProcessInfoPowerStateDidChangeNotification");
const void *const NSProcessInfoThermalStateDidChangeNotification = CFSTR("NSProcessInfoThermalStateDidChangeNotification");
const void *const NSURLAuthenticationMethodOAuth = CFSTR("NSURLAuthenticationMethodOAuth");

const float NSURLSessionTaskPriorityDefault = 0.5f;

/* Page size is fixed on every device this build can run on. */
const unsigned long vm_kernel_page_size = 4096;
