#import <Foundation/Foundation.h>
@class WebView;
@class WebFrame;

// Provides window.WebAssembly, backed by the wasm3 interpreter, for engines whose
// JSC has no WebAssembly (32-bit ARM: JSC's WASM is 64-bit-only). Installed into a
// frame's global object - an ObjC object exposed to
// JS plus a bootstrap script that shapes it into the standard WebAssembly API.
@interface RevWasm : NSObject
+ (void)installInWebView:(WebView *)webView forFrame:(WebFrame *)frame;
@end
