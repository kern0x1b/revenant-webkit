# Third-party code, and where each piece stands

This repository contains no third-party source. Every dependency below is
fetched from its own upstream by a script in `scripts/`, into `third_party/`,
which is not tracked here. The engine is a git submodule pointing at a fork of
WebKit, so its code and its licenses live in that repository rather than this
one.

The point of this file is that a reader can tell, without building anything,
exactly what this project links against and under what terms.

## The engine

| Component | Where it comes from | License |
| --- | --- | --- |
| WebKit 2.54 | `webkit-254` submodule — the `ios6-armv7` branch of a fork; this port's changes are commits on that branch | LGPL-2.1-or-later and BSD-2-Clause, as WebKit ships them: `Source/WebCore/LICENSE-LGPL-2.1`, `Source/WebCore/LICENSE-APPLE`, `Source/JavaScriptCore/COPYING.LIB` |
| ANGLE | inside the WebKit tree, `Source/ThirdParty/ANGLE`; the EAGL backend this port adds lives there under the same terms | BSD-3-Clause, `Source/ThirdParty/ANGLE/LICENSE` |

## Libraries this operating system cannot supply

Each is downloaded by the script named beside it, at the version named beside
it, and built for armv7. None is redistributed here.

| Component | Version | License | Fetched by |
| --- | --- | --- | --- |
| libc++, libc++abi, libunwind | llvm-project checkout | Apache-2.0 with the LLVM exception | `scripts/build-libcxx.sh` |
| ICU | 74.2 | Unicode license (ICU) | `scripts/build-icu.sh` |
| OpenSSL | 3.0.15 | Apache-2.0 | `scripts/build-openssl.sh` |
| libpsl | 0.23.3 | MIT; the Public Suffix List data it carries is MPL-2.0 | `scripts/build-libpsl.sh` |
| libwebp | 1.4.0 | BSD-3-Clause | `scripts/build-libwebp.sh` |
| libxslt | 1.1.43 | MIT | `scripts/build-libxslt.sh` |
| woff2 | 1.0.2 | MIT | `scripts/build-woff2.sh` |
| brotli | 1.1.0 | MIT | `scripts/build-woff2.sh` |
| wasm3 | checkout under `third_party/wasm3` | MIT | cloned; `packaging/compat/Makefile` builds it |

## The one third-party file that is in this repository

| File | What it is | License |
| --- | --- | --- |
| `app/cacert.pem` | the CA certificate bundle the TLS backend verifies against: the public root certificates extracted from Mozilla's `certdata.txt` by the curl project's `mk-ca-bundle.pl` | The certificates are the certificate authorities' own, published to be distributed. Mozilla's `certdata.txt`, which they are extracted from, is MPL-2.0; the extract carries no license header of its own, only its provenance, date and SHA-256 |

It is here rather than fetched because a browser that cannot verify a
certificate is not shippable, and because the file has to match the build that
was tested. Its header names the source, the date of the extract and its
SHA-256; replacing it is one download from <https://curl.se/docs/caextract.html>.

## Things this project deliberately does not carry

- **No fonts.** `scripts/install-emoji-font.sh` copies the emoji font from the
  operator's own Mac to the operator's own phone. Apple's font is never
  downloaded from anywhere and never redistributed here.
- **No test corpus of other people's pages.** `tests/device/sweep.sh` ships with
  no site list: it loads only what the operator names on the command line or in
  a gitignored file of their own. Driving a browser at somebody's site from an
  automated run is a matter between that operator and that site's terms, and it
  is not something a repository should decide on their behalf. Everything the
  automated suite loads is served from `tests/device/` on the operator's own
  machine.
- **No conformance suite.** Khronos' WebGL conformance tests are cloned by the
  operator when they want to run them; `tests/device/conformance.sh` says how.
  They are not vendored and not modified.
- **No device credentials.** `device.env` is gitignored; `device.env.example`
  shows its shape.

## This project's own code

MIT, `LICENSE`. That covers what is in this repository: the compatibility
library, the port's tooling, the tests, the packaging and the documentation.
