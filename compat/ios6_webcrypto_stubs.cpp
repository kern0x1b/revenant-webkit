/*
 * Web Crypto is not available on this port.
 *
 * Upstream routes AES-GCM, AES-KW, HKDF, HMAC, Ed25519 and X25519 through
 * CryptoKit via generated Swift headers, and swiftc has no armv7 target.
 * WebCore still references the entry points, so each is aliased to one no-op
 * that reports itself. Hashing is unaffected: digests are computed directly
 * against CommonCrypto.
 */

#include <stdio.h>

extern "C" long webkitIOS6WebCryptoUnavailable()
{
    static bool reported;
    if (!reported) {
        reported = true;
        fprintf(stderr, "[ios6] Web Crypto is not available on this build\n");
    }
    return 0;
}

asm(
    ".globl __ZN3PAL6Crypto13PlatformECKey13importX963PubERKN3WTF6VectorIhLm0ENS2_15CrashOnOverflowELm16ENS2_10FastMallocEEENS0_12ECNamedCurveE\n"
    "__ZN3PAL6Crypto13PlatformECKey13importX963PubERKN3WTF6VectorIhLm0ENS2_15CrashOnOverflowELm16ENS2_10FastMallocEEENS0_12ECNamedCurveE = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto13PlatformECKey17importX963PrivateERKN3WTF6VectorIhLm0ENS2_15CrashOnOverflowELm16ENS2_10FastMallocEEENS0_12ECNamedCurveE\n"
    "__ZN3PAL6Crypto13PlatformECKey17importX963PrivateERKN3WTF6VectorIhLm0ENS2_15CrashOnOverflowELm16ENS2_10FastMallocEEENS0_12ECNamedCurveE = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto13PlatformECKey19importCompressedPubERKN3WTF6VectorIhLm0ENS2_15CrashOnOverflowELm16ENS2_10FastMallocEEEmNS0_12ECNamedCurveE\n"
    "__ZN3PAL6Crypto13PlatformECKey19importCompressedPubERKN3WTF6VectorIhLm0ENS2_15CrashOnOverflowELm16ENS2_10FastMallocEEEmNS0_12ECNamedCurveE = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto13PlatformECKeyC1ENS0_12ECNamedCurveE\n"
    "__ZN3PAL6Crypto13PlatformECKeyC1ENS0_12ECNamedCurveE = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto13PlatformECKeyC1EOS1_\n"
    "__ZN3PAL6Crypto13PlatformECKeyC1EOS1_ = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto13PlatformECKeyD1Ev\n"
    "__ZN3PAL6Crypto13PlatformECKeyD1Ev = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto20signEd25519CryptoKitERKN3WTF6VectorIhLm0ENS1_15CrashOnOverflowELm16ENS1_10FastMallocEEES7_\n"
    "__ZN3PAL6Crypto20signEd25519CryptoKitERKN3WTF6VectorIhLm0ENS1_15CrashOnOverflowELm16ENS1_10FastMallocEEES7_ = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto22verifyEd25519CryptoKitERKN3WTF6VectorIhLm0ENS1_15CrashOnOverflowELm16ENS1_10FastMallocEEES7_S7_\n"
    "__ZN3PAL6Crypto22verifyEd25519CryptoKitERKN3WTF6VectorIhLm0ENS1_15CrashOnOverflowELm16ENS1_10FastMallocEEES7_S7_ = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto25deriveBitsX25519CryptoKitERKN3WTF6VectorIhLm0ENS1_15CrashOnOverflowELm16ENS1_10FastMallocEEES7_\n"
    "__ZN3PAL6Crypto25deriveBitsX25519CryptoKitERKN3WTF6VectorIhLm0ENS1_15CrashOnOverflowELm16ENS1_10FastMallocEEES7_ = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto5EdKey15privateToPublicENS0_18EdSigningAlgorithmERKN3WTF6VectorIhLm0ENS3_15CrashOnOverflowELm16ENS3_10FastMallocEEE\n"
    "__ZN3PAL6Crypto5EdKey15privateToPublicENS0_18EdSigningAlgorithmERKN3WTF6VectorIhLm0ENS3_15CrashOnOverflowELm16ENS3_10FastMallocEEE = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto5EdKey15validateKeyPairENS0_18EdSigningAlgorithmERKN3WTF6VectorIhLm0ENS3_15CrashOnOverflowELm16ENS3_10FastMallocEEES9_\n"
    "__ZN3PAL6Crypto5EdKey15validateKeyPairENS0_18EdSigningAlgorithmERKN3WTF6VectorIhLm0ENS3_15CrashOnOverflowELm16ENS3_10FastMallocEEES9_ = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto5EdKey18generatePrivateKeyENS0_18EdSigningAlgorithmE\n"
    "__ZN3PAL6Crypto5EdKey18generatePrivateKeyENS0_18EdSigningAlgorithmE = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto5EdKey27privateToPublicKeyAgreementENS0_23EdKeyAgreementAlgorithmERKN3WTF6VectorIhLm0ENS3_15CrashOnOverflowELm16ENS3_10FastMallocEEE\n"
    "__ZN3PAL6Crypto5EdKey27privateToPublicKeyAgreementENS0_23EdKeyAgreementAlgorithmERKN3WTF6VectorIhLm0ENS3_15CrashOnOverflowELm16ENS3_10FastMallocEEE = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto5EdKey27validateKeyPairKeyAgreementENS0_23EdKeyAgreementAlgorithmERKN3WTF6VectorIhLm0ENS3_15CrashOnOverflowELm16ENS3_10FastMallocEEES9_\n"
    "__ZN3PAL6Crypto5EdKey27validateKeyPairKeyAgreementENS0_23EdKeyAgreementAlgorithmERKN3WTF6VectorIhLm0ENS3_15CrashOnOverflowELm16ENS3_10FastMallocEEES9_ = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZN3PAL6Crypto5EdKey30generatePrivateKeyKeyAgreementENS0_23EdKeyAgreementAlgorithmE\n"
    "__ZN3PAL6Crypto5EdKey30generatePrivateKeyKeyAgreementENS0_23EdKeyAgreementAlgorithmE = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZNK3PAL6Crypto13PlatformECKey10deriveBitsERKS1_\n"
    "__ZNK3PAL6Crypto13PlatformECKey10deriveBitsERKS1_ = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZNK3PAL6Crypto13PlatformECKey13exportX963PubEv\n"
    "__ZNK3PAL6Crypto13PlatformECKey13exportX963PubEv = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZNK3PAL6Crypto13PlatformECKey17exportX963PrivateEv\n"
    "__ZNK3PAL6Crypto13PlatformECKey17exportX963PrivateEv = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZNK3PAL6Crypto13PlatformECKey4signERKN3WTF6VectorIhLm0ENS2_15CrashOnOverflowELm16ENS2_10FastMallocEEENS0_24CryptoDigestHashFunctionE\n"
    "__ZNK3PAL6Crypto13PlatformECKey4signERKN3WTF6VectorIhLm0ENS2_15CrashOnOverflowELm16ENS2_10FastMallocEEENS0_24CryptoDigestHashFunctionE = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZNK3PAL6Crypto13PlatformECKey5toPubEv\n"
    "__ZNK3PAL6Crypto13PlatformECKey5toPubEv = _webkitIOS6WebCryptoUnavailable\n"
    ".globl __ZNK3PAL6Crypto13PlatformECKey8doVerifyERKN3WTF6VectorIhLm0ENS2_15CrashOnOverflowELm16ENS2_10FastMallocEEES8_NS0_24CryptoDigestHashFunctionE\n"
    "__ZNK3PAL6Crypto13PlatformECKey8doVerifyERKN3WTF6VectorIhLm0ENS2_15CrashOnOverflowELm16ENS2_10FastMallocEEES8_NS0_24CryptoDigestHashFunctionE = _webkitIOS6WebCryptoUnavailable\n"
);
