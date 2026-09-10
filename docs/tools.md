# The probes, and what each one answers

Every tool in `tools/` exists because a question about the device could not be
answered from inside the engine, or could not be trusted from inside it. Each
one runs on the phone, links nothing of WebKit unless it says so, and prints a
verdict rather than a log.

They are documented here rather than in their own source, because the source of
a probe should be the experiment and nothing else.

| Tool | The question it answers |
| --- | --- |
| `gles-iosurface-probe.m` | Can an IOSurface be a GL texture on this GPU at all? Creates a BGRA surface, binds it through `CVOpenGLESTextureCache`, renders into it through a framebuffer and reads the bytes back out of the surface. This was the risk that could have ended the WebGL plan before it started. |
| `angle-eagl-probe.mm` | Does ANGLE itself initialise, make a context and render here? Links the ANGLE archives and drives them through the `EGL_`/`GL_` entry points the way WebCore does. |
| `gles-cull-probe.m` | Which colour attachments does this driver cull into? Builds a renderbuffer, a plain texture and a texture made from an IOSurface, and runs `BACK`, `FRONT` and `FRONT_AND_BACK` against each, three passes apiece. See `webgl.md`. |
| `gles-npot-cube-probe.m` | Will this driver sample a non-power-of-two cube map? A power-of-two one for comparison, then 5x5 and 7x7. |
| `revavprobe.m` | Can AVFoundation open this URL, outside the engine? Prints the `AVPlayerItem` status and error, so a playback failure is attributed rather than guessed. |
| `revclip.m` | What does the system pasteboard actually hold, and as which types? The phone has no way to look, and a copy made by a page has to be checked against what every other application would see. |
| `uiwebview-probe.m` | What does the system's own `UIWebView` do in the same situation? The reference implementation, running beside ours. |
| `objc-surface.m` | Which selectors does a class on this system actually have? Used to find the real shape of private classes before calling into them. |
| `revtouch.c` | Drives the interface without a finger: injects a synthetic touch through the IOKit HID digitizer. Coordinates are screen points - 320x480 on this phone - and are normalised to 0..1 for the digitizer. `revtouch tap|swipe|down|up X Y`. |
| `revmem.c` | `revmem <pid>` - dirty and resident memory of another process, summed by VM tag. A vmmap for a phone that ships no vmmap; run as root, and read it to see which framework owns the resident dirty pages. |
| `revpid.c` | `revpid [name]` - the pid of each running process, or only those whose name matches. This device has no `ps`, so this is how a process is found at all. |
| `raise-memory-limit.c` | Raises the jetsam limit for a process, for measurements that would otherwise be killed before they finish. |
| `device.sh` | Not a probe: the address, port and credentials of the phone in one place, sourced by every script that talks to it. Two things it does that matter. **Source it from bash** - in zsh `BASH_SOURCE` is empty, `device.env` is never read, and commands go to whatever is on the default port. And it revives the `iproxy` tunnel before every command, because a dead tunnel answers "connection refused", which reads in a log exactly like a browser that crashed - an evening went into a crash that was a dead cable. |

## Building one

They are all built the same way, against the iOS SDK the port uses, for armv7:

```sh
clang -target armv7-apple-ios6.0 -isysroot "$IOS_SDK" -O2 -fno-objc-arc \
    -framework Foundation -framework OpenGLES \
    tools/<name>.m -o dist/<name>
```

Add `-framework CoreVideo` for anything that touches `CVOpenGLESTextureCache`
(`gles-cull-probe`, `gles-npot-cube-probe`, `gles-iosurface-probe`),
`-framework AVFoundation -framework CoreMedia` for `revavprobe`, and
`-framework UIKit` for `revclip` and `uiwebview-probe`.

A binary that links the ANGLE archives - `angle-eagl-probe` - also has to be
pointed at the engine's C++ runtime or it traps at load with nothing printed:

```sh
install_name_tool -change @executable_path/Frameworks/libc++.1.dylib \
    /usr/lib/librev-c++.1.dylib dist/angle-eagl-probe
```

Copy it over with `scp` on the device port and run it over ssh; `tools/device.sh`
has both.
