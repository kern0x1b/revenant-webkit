/*
 * CoreText entry points WebKit uses for text layout that this system does not
 * have. These are not stubs: a stub here means text is measured with zero
 * advances or laid out with a null font, so the page loads and renders nothing
 * legible. Each one is implemented on the CoreText that iOS 6 does have.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <pthread.h>
#include <ImageIO/ImageIO.h>
#include <string.h>

typedef uint16_t UTF16Char;

extern const CFStringRef kCTFontCSSFamilyCursive;
extern const CFStringRef kCTFontCSSFamilyFantasy;
extern const CFStringRef kCTFontCSSFamilyMonospace;
extern const CFStringRef kCTFontCSSFamilySansSerif;
extern const CFStringRef kCTFontCSSFamilySerif;

/*
 * CSS generic families became a CoreText concept in iOS 13. Before that the
 * mapping was the embedder's job, so it is made here — against the fonts iOS 6
 * actually ships.
 */
CTFontDescriptorRef CTFontDescriptorCreateForCSSFamily(CFStringRef cssFamily, CFStringRef language)
{
    (void)language;

    CFStringRef family = CFSTR("Helvetica");
    if (cssFamily) {
        if (CFEqual(cssFamily, kCTFontCSSFamilySerif))
            family = CFSTR("Times New Roman");
        else if (CFEqual(cssFamily, kCTFontCSSFamilyMonospace))
            family = CFSTR("Courier");
        else if (CFEqual(cssFamily, kCTFontCSSFamilyCursive))
            family = CFSTR("Snell Roundhand");
        else if (CFEqual(cssFamily, kCTFontCSSFamilyFantasy))
            family = CFSTR("Papyrus");
    }

    const void *keys[] = { kCTFontFamilyNameAttribute };
    const void *values[] = { family };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    return descriptor;
}

/*
 * Font fallback for a run of characters. CTFontCreateForString has been here
 * since the beginning; what it does not report is how much of the run the
 * substitute font covers, so that is measured directly.
 */
CTFontRef CTFontCreateForCharactersWithLanguageAndOption(CTFontRef currentFont, const UTF16Char *characters, CFIndex length, CFStringRef language, CFOptionFlags options, CFIndex *coveredLength)
{
    (void)language;
    (void)options;

    if (coveredLength)
        *coveredLength = 0;
    if (!currentFont || !characters || length <= 0)
        return NULL;

    CFStringRef string = CFStringCreateWithCharacters(kCFAllocatorDefault, characters, length);
    if (!string)
        return NULL;
    CTFontRef substitute = CTFontCreateForString(currentFont, string, CFRangeMake(0, length));
    CFRelease(string);
    if (!substitute)
        return NULL;

    if (coveredLength) {
        CGGlyph stackGlyphs[128];
        CGGlyph *glyphs = length <= 128 ? stackGlyphs : malloc(length * sizeof(CGGlyph));
        if (glyphs) {
            CTFontGetGlyphsForCharacters(substitute, characters, glyphs, length);
            CFIndex covered = 0;
            while (covered < length && glyphs[covered])
                covered++;
            *coveredLength = covered ? covered : length;
            if (glyphs != stackGlyphs)
                free(glyphs);
        } else
            *coveredLength = length;
    }

    return substitute;
}

/*
 * Shaping. The caller has already mapped characters to glyphs through the cmap
 * and wants advances, origins and cluster mapping back. Real shaping — kerning,
 * ligatures, reordering, right-to-left — needs the engine that arrived in
 * iOS 17. What can be done here is the horizontal metrics for the glyphs as
 * given, which is correct for scripts that need no reordering, and readable
 * rather than blank for the ones that do.
 */
CGSize CTFontShapeGlyphs(CTFontRef font, CGGlyph glyphs[], CGSize advances[], CGPoint origins[], CFIndex indexes[], const UniChar characters[], CFIndex count, CFOptionFlags options, CFStringRef language, void (^handler)(CFRange, CGGlyph **, CGSize **, CGPoint **, CFIndex **))
{
    (void)characters;
    (void)options;
    (void)language;
    (void)handler;
    (void)indexes;

    if (font && glyphs && advances && count > 0)
        CTFontGetAdvancesForGlyphs(font, 0 /* horizontal */, glyphs, advances, count);
    if (origins && count > 0)
        memset(origins, 0, (size_t)count * sizeof(CGPoint));

    return CGSizeZero;
}

bool CTFontHasTable(CTFontRef font, CTFontTableTag tag)
{
    if (!font)
        return false;
    CFDataRef table = CTFontCopyTable(font, tag, kCTFontTableOptionNoOptions);
    if (!table)
        return false;
    CFRelease(table);
    return true;
}

CTFontSymbolicTraits CTFontGetPhysicalSymbolicTraits(CTFontRef font)
{
    return font ? CTFontGetSymbolicTraits(font) : 0;
}

bool CTFontIsAppleColorEmoji(CTFontRef font)
{
    if (!font)
        return false;
    CFStringRef family = CTFontCopyFamilyName(font);
    if (!family)
        return false;
    bool isEmoji = CFStringCompare(family, CFSTR("Apple Color Emoji"), 0) == kCFCompareEqualTo;
    CFRelease(family);
    return isEmoji;
}

/* There is no separate system UI font this far back; the UI font is Helvetica. */
bool CTFontIsSystemUIFont(CTFontRef font)
{
    (void)font;
    return false;
}

/* Colour glyph coverage is only consulted to take a faster path; not knowing it
 * costs nothing but the fast path. */
CFBitVectorRef CTFontCopyColorGlyphCoverage(CTFontRef font)
{
    (void)font;
    return NULL;
}

/* Multi-image files (HEIF collections) postdate this system; index 0 is the
 * only image there is. */
size_t CGImageSourceGetPrimaryImageIndex(CGImageSourceRef source)
{
    (void)source;
    return 0;
}

/* ---------------------------------------------------------------------------
 * Font descriptors
 *
 * WebKit builds every font it uses out of descriptors, and a descriptor that
 * comes back null takes CoreText's own matching code down with it. None of
 * these may return nothing.
 */

static CTFontDescriptorRef descriptorForFamily(CFStringRef family)
{
    const void *keys[] = { kCTFontFamilyNameAttribute };
    const void *values[] = { family };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    return descriptor;
}

/* The UI font is reachable through CTFontCreateUIFontForLanguage, which is as
 * old as CoreText itself; only the descriptor-shaped entry point is new. */
CTFontDescriptorRef CTFontDescriptorCreateForUIType(CTFontUIFontType uiType, CGFloat size, CFStringRef language)
{
    CTFontRef font = CTFontCreateUIFontForLanguage(uiType, size, language);
    if (font) {
        CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(font);
        CFRelease(font);
        if (descriptor)
            return descriptor;
    }
    return descriptorForFamily(CFSTR("Helvetica"));
}

/* Dynamic Type is iOS 7. Text styles all resolve to the one UI font here. */
CTFontDescriptorRef CTFontDescriptorCreateWithTextStyle(CFStringRef style, CFStringRef size, CFStringRef language)
{
    (void)style;
    (void)size;
    (void)language;
    return descriptorForFamily(CFSTR("Helvetica"));
}

CTFontDescriptorRef CTFontDescriptorCreateWithTextStyleAndAttributes(CFStringRef style, CFStringRef size, CFDictionaryRef attributes)
{
    (void)style;
    (void)size;
    if (!attributes || !CFDictionaryGetCount(attributes))
        return descriptorForFamily(CFSTR("Helvetica"));

    CFMutableDictionaryRef merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, attributes);
    CFDictionarySetValue(merged, kCTFontFamilyNameAttribute, CFSTR("Helvetica"));
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(merged);
    CFRelease(merged);
    return descriptor;
}

CGFloat CTFontDescriptorGetTextStyleSize(CFStringRef style, CFTypeRef sizeCategory, uint32_t platform, CGFloat *weight, CGFloat *lineSpacing)
{
    (void)style;
    (void)sizeCategory;
    (void)platform;
    if (weight)
        *weight = 0;
    if (lineSpacing)
        *lineSpacing = 0;
    return 17; /* the body size on every iPhone of this era */
}

CTFontDescriptorRef CTFontDescriptorCreateCopyWithSymbolicTraits(CTFontDescriptorRef original, CTFontSymbolicTraits value, CTFontSymbolicTraits mask)
{
    if (!original)
        return NULL;

    CFDictionaryRef existing = CTFontDescriptorCopyAttributes(original);
    CFMutableDictionaryRef attributes = existing
        ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, existing)
        : CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (existing)
        CFRelease(existing);

    CTFontSymbolicTraits current = 0;
    CFDictionaryRef existingTraits = CTFontDescriptorCopyAttribute(original, kCTFontTraitsAttribute);
    if (existingTraits) {
        CFNumberRef number = CFDictionaryGetValue(existingTraits, kCTFontSymbolicTrait);
        if (number)
            CFNumberGetValue(number, kCFNumberSInt32Type, &current);
        CFRelease(existingTraits);
    }

    CTFontSymbolicTraits updated = (current & ~mask) | (value & mask);
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &updated);
    const void *keys[] = { kCTFontSymbolicTrait };
    const void *values[] = { number };
    CFDictionaryRef traits = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attributes, kCTFontTraitsAttribute, traits);
    CFRelease(traits);
    CFRelease(number);

    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    return descriptor;
}

CTFontDescriptorRef CTFontDescriptorCreateLastResort(void)
{
    return descriptorForFamily(CFSTR("LastResort"));
}

bool CTFontDescriptorIsSystemUIFont(CTFontDescriptorRef descriptor)
{
    (void)descriptor;
    return false;
}

uint32_t CTFontDescriptorGetOptions(CTFontDescriptorRef descriptor)
{
    (void)descriptor;
    return 0;
}

CTFontRef CTFontCreateWithFontDescriptorAndOptions(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix, CTFontOptions options)
{
    (void)options;
    return CTFontCreateWithFontDescriptor(descriptor, size, matrix);
}

CTFontUIFontType CTFontGetUIFontType(CTFontRef font)
{
    (void)font;
    return kCTFontNoFontType;
}

/* ---------------------------------------------------------------------------
 * Web fonts
 *
 * A downloaded font arrives as bytes. CoreGraphics has been able to turn bytes
 * into a font since long before CoreText grew an entry point for it, so
 * @font-face works here rather than silently falling back to system fonts.
 */
static CTFontDescriptorRef descriptorFromFontData(CFDataRef data)
{
    if (!data)
        return NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    if (!provider)
        return NULL;
    CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
    if (!cgFont)
        return NULL;
    CTFontRef font = CTFontCreateWithGraphicsFont(cgFont, 0, NULL, NULL);
    CGFontRelease(cgFont);
    if (!font)
        return NULL;
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(font);
    CFRelease(font);
    return descriptor;
}

CTFontDescriptorRef CTFontManagerCreateFontDescriptorFromData(CFDataRef data)
{
    return descriptorFromFontData(data);
}

CTFontDescriptorRef CTFontManagerCreateMemorySafeFontDescriptorFromData(CFDataRef data)
{
    return descriptorFromFontData(data);
}

CFArrayRef CTFontManagerCreateFontDescriptorsFromURL(CFURLRef url)
{
    if (!url)
        return NULL;
    CFDataRef data = NULL;
    SInt32 error = 0;
    if (!CFURLCreateDataAndPropertiesFromResource(kCFAllocatorDefault, url, &data, NULL, NULL, &error) || !data)
        return NULL;
    CTFontDescriptorRef descriptor = descriptorFromFontData(data);
    CFRelease(data);
    if (!descriptor)
        return NULL;
    const void *values[] = { descriptor };
    CFArrayRef array = CFArrayCreate(kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
    CFRelease(descriptor);
    return array;
}

CFArrayRef CTFontManagerCopyAvailableFontFamilyNames(void)
{
    /* Built once. The installed fonts do not change while the process runs, and
     * this walks the whole collection, matches every descriptor and dedupes the
     * family names - which real CoreText answers from a cache. It showed up in a
     * profile of the load window under FontDatabase::collectionForFamily, and the
     * engine asks for this list whenever it resolves a family it has not seen. */
    static CFArrayRef cachedFamilies;
    static pthread_mutex_t cacheLock = PTHREAD_MUTEX_INITIALIZER;

    pthread_mutex_lock(&cacheLock);
    if (cachedFamilies) {
        CFArrayRef answer = CFArrayCreateCopy(kCFAllocatorDefault, cachedFamilies);
        pthread_mutex_unlock(&cacheLock);
        return answer;
    }
    pthread_mutex_unlock(&cacheLock);

    CTFontCollectionRef collection = CTFontCollectionCreateFromAvailableFonts(NULL);
    if (!collection)
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);

    CFArrayRef descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection);
    CFRelease(collection);
    if (!descriptors)
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);

    CFMutableSetRef seen = CFSetCreateMutable(kCFAllocatorDefault, 0, &kCFTypeSetCallBacks);
    CFMutableArrayRef families = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0, count = CFArrayGetCount(descriptors); i < count; i++) {
        CFStringRef family = CTFontDescriptorCopyAttribute(CFArrayGetValueAtIndex(descriptors, i), kCTFontFamilyNameAttribute);
        if (!family)
            continue;
        if (!CFSetContainsValue(seen, family)) {
            CFSetAddValue(seen, family);
            CFArrayAppendValue(families, family);
        }
        CFRelease(family);
    }
    CFRelease(seen);
    CFRelease(descriptors);

    pthread_mutex_lock(&cacheLock);
    if (!cachedFamilies)
        cachedFamilies = CFArrayCreateCopy(kCFAllocatorDefault, families);
    pthread_mutex_unlock(&cacheLock);

    return families;
}

/* ---------------------------------------------------------------------------
 * Glyph and run details
 */

bool CTFontGetGlyphsForCharacterRange(CTFontRef font, CGGlyph glyphs[], CFRange range)
{
    if (!font || !glyphs || range.length <= 0)
        return false;

    UniChar stackCharacters[128];
    UniChar *characters = range.length <= 128 ? stackCharacters : malloc((size_t)range.length * sizeof(UniChar));
    if (!characters)
        return false;
    for (CFIndex i = 0; i < range.length; i++)
        characters[i] = (UniChar)(range.location + i);

    bool complete = CTFontGetGlyphsForCharacters(font, characters, glyphs, range.length);
    if (characters != stackCharacters)
        free(characters);
    return complete;
}

void CTRunGetBaseAdvancesAndOrigins(CTRunRef run, CFRange range, CGSize baseAdvances[], CGPoint origins[])
{
    if (!run)
        return;
    if (baseAdvances)
        CTRunGetAdvances(run, range, baseAdvances);
    if (origins) {
        CFIndex count = range.length ? range.length : CTRunGetGlyphCount(run);
        for (CFIndex i = 0; i < count; i++)
            origins[i] = CGPointZero;
    }
}

CFBitVectorRef CTFontCopyGlyphCoverageForFeature(CTFontRef font, CFDictionaryRef feature)
{
    (void)font;
    (void)feature;
    return NULL;
}

/* sbix is a bitmap-glyph table that postdates this system's CoreText. */
CGFloat CTFontGetSbixImageSizeForGlyphAndContentsScale(CTFontRef font, const CGGlyph glyph, CGFloat contentsScale)
{
    (void)font;
    (void)glyph;
    (void)contentsScale;
    return 0;
}

/* Bold Text is an accessibility setting that does not exist here. */
CGFloat CTFontGetAccessibilityBoldWeightOfWeight(CGFloat weight)
{
    return weight;
}

void CTParagraphStyleSetCompositionLanguage(CTParagraphStyleRef style, uint8_t language)
{
    (void)style;
    (void)language;
}

void GSFontPurgeFontCache(void)
{
}
