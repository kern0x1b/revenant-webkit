# Soft-linked constants that are not on this OS

PAL soft-links constants and asserts when `dlsym` returns nothing. On a current
OS that is right: an absent constant means a broken install. On iOS 6 absence is
normal — the constant is missing because the feature it names was invented
later — so every one of them is a crash waiting for the first page that reaches
it, and chasing them one backtrace at a time never ends.

`tools/probe-soft-links.py` generates a probe that asks the device about all of
them at once. Run on the iPhone 4S (iOS 6.1.3):

    present 140   missing 135

Missing, by framework:

| framework | missing |
|---|---|
| AVFoundation | 70 |
| CoreMedia | 58 |
| UIKit | 4 |
| DataDetectorsUI | 3 |

Absent entirely, so every constant in them is missing: AppSSO, Contacts,
CoreMaterial, PassKitCore, ScreenCaptureKit, Vision, WebPrivacy.

Almost all of the 135 are capture-device, DRM or HLS names that an ordinary page
load never reaches, and this port already reports "AVFoundation media engine is
not available", which removes most of the rest. The ones that actually fired:

- `AVSystemController_ServerConnectionDiedNotification` and
  `AVSystemController_PIDToInheritApplicationStateFrom` (MediaExperience, a
  framework that postdates this OS by years) — reached from
  `MediaSessionHelperIOS` when a script touches a media element's `muted`.
  Guarded by turning off `HAVE_MEDIAEXPERIENCE_AVSYSTEMCONTROLLER`, whose two
  use sites were already written to expect it.
- `AVAudioSessionPortCarAudio` (CarPlay, iOS 7) — reached from
  `MediaSessionHelperIOS::updateCarPlayIsConnected()`, which had no guard at
  all. Added `HAVE_AVAUDIOSESSION_CARAUDIO_PORT`.

The assert in `WTF/wtf/cocoa/SoftLinking.h` now names the symbol and its
framework, so the next one is a one-line diagnosis rather than a backtrace to
decode: it used to report only `dlerror()`, which is empty here.

Re-run the probe after any engine update — the list grows as WebKit adds
soft-links.

## Cookie API, probed 2026-08-25

Every private cookie entry point the engine reaches for is absent on this
Foundation, and every public equivalent is present.

| absent | the public thing that does the same job |
|---|---|
| `-_setCookies:forURL:mainDocumentURL:policyProperties:` | `-setCookies:forURL:mainDocumentURL:` |
| `-_getCookiesForURL:…partition:policyProperties:…` | `-cookiesForURL:` |
| `+_cookieForSetCookieString:forURL:partition:` | `+cookiesWithResponseHeaderFields:forURL:` |
| `-_initWithCFHTTPCookieStorage:` | there is one storage; it is the shared one |
| `-_getCookiesForDomain:`, `-_getCookiesForPartition:` | `-cookiesForURL:`; partitions do not exist here |
| `-_saveCookies:` | CFNetwork writes the jar itself on this release |
| `-_setCookiesChangedHandler:onQueue:` and kin | `NSHTTPCookieManagerCookiesChangedNotification` |
| `-_storagePartition`, `-sameSitePolicy` | neither concept exists on this CFNetwork |
| `-removeCookiesSinceDate:` | nothing; iOS 8 API, and the caller already probes for it |

Present, and so needing no work: `-_cookieStorage`, `+_cf2nsCookies:`,
`-_GetInternalCFHTTPCookie`, `CFHTTPCookieStorageCopyCookies`,
`CFHTTPCookieStorageDeleteAllCookies`.

Two behaviours settled by measurement rather than by reading:

- `+cookieWithProperties:` **accepts** the non-public keys WebKit puts in —
  `Created`, `HttpOnly`, `SameSite` — so `createNSHTTPCookie()` works.
- `NSHTTPCookieManagerCookiesChangedNotification` **fires** on this release.
  `CookieStorageObserver` therefore has a real signal, and so does the packaging
  platform's cookie jar, which coalesces its writes on it.

Why this mattered: WebKit wraps these calls in exception guards, so every one of
them failed *silently*. `document.cookie = "x=y"` read back as empty and nothing
in any log said why.

## AVAudioSession, probed 2026-08-25

`AudioSessionIOS.mm` is reached the moment a page has a media element, which on
threads.com and instagram.com is immediately.

| absent | what this release has instead |
|---|---|
| `-maximumOutputNumberOfChannels` (iOS 7) | `-outputNumberOfChannels`; on a device whose outputs are a speaker, a jack and Bluetooth that is also the maximum |
| `-setCategory:mode:routeSharingPolicy:options:error:` (iOS 11) | `-setCategory:withOptions:error:` then `-setMode:error:` |
| `-routeSharingPolicy` (iOS 11) | the concept does not exist |
| `-routingContextUID` | the concept does not exist |
| `-setHostProcessAttribution:` | already behind `ENABLE(APP_PRIVACY_REPORT)` |
| `-setPreferredOutputNumberOfChannels:error:` | not used on the paths we reach |
| `-secondaryAudioShouldBeSilencedHint` | not used on the paths we reach |

Present: `-category`, `-mode`, `-categoryOptions`, `-setCategory:withOptions:error:`,
`-setCategory:error:`, `-setMode:error:`, `-setActive:error:`, `-sampleRate`,
`-outputNumberOfChannels`, `-outputLatency`, `-IOBufferDuration`,
`-preferredIOBufferDuration`, `-setPreferredIOBufferDuration:error:`,
`-setPreferredSampleRate:error:`, `-currentRoute`, `-outputVolume`,
`-isOtherAudioPlaying`, `-currentHardwareOutputNumberOfChannels`,
`-currentHardwareSampleRate`.
