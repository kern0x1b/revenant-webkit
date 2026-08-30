# Superseded build scripts

Each of these configured or built the engine at some point and was replaced. They
are kept because the reasons they were abandoned are recorded in their comments,
and because the differences between them are the record of how the current
configuration was arrived at.

Nothing here is used by the current build. The live path is in the top-level
README: `fetch-source.sh`, `build-libcxx.sh`, `build-icu.sh`, `build-openssl.sh`,
`build-compat.sh`, `configure-webkit-254-bmalloc.sh`, `build-app-lto.sh`.

| Script | What it was |
| --- | --- |
| `configure-webkit.sh` | The first attempt, against the Safari-603 branch |
| `configure-webkit-jit.sh` | 603 with the JIT enabled, before the JIT moved to trunk |
| `configure-webkit-254.sh` | Trunk, system allocator, no LTO |
| `configure-webkit-254-sys.sh` | Trunk against the system's own frameworks |
| `configure-webkit-254-slim.sh` | Feature-stripped, a measured dead end |
| `configure-webkit-254-bm.sh` | First bmalloc attempt |
| `configure-webkit-254-bm2.sh` | Second, with a different page size |
| `configure-webkit-254-lto.sh` | LTO before it was folded into the bmalloc configure |
| `configure-jsc.sh` | JavaScriptCore alone, for the JIT work |
| `build-webkit.sh` | Driver for the 603 build |
| `build-app.sh`, `build-app-sys.sh` | Application against those earlier trees |
| `patch-python2.sh` | Made the 603 branch's Python 2 scripts run |
| `ios6-armv7.cmake` | Toolchain file for 603; trunk uses `ios6-armv7-trunk.cmake` |
| `fetch-source-603.sh` | Fetched the 603 branch, before the port moved to trunk |
