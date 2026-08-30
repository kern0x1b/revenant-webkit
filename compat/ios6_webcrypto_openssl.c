/*
 * The Web Crypto operations this system cannot perform, over OpenSSL.
 *
 * Upstream routes AES-GCM, HMAC, HKDF and AES-KW through CryptoKit, whose Swift
 * has no armv7 target, so this port aliased every one of them to a stub that
 * returned nothing. That is not a missing corner: a page asking to encrypt three
 * bytes with AES-GCM got an empty buffer back and no error, which is what a
 * login form does with a password before it sends it.
 *
 * These are plain C entry points so the compatibility library can hold the
 * OpenSSL dependency and the engine's own code, which has the WTF types, calls
 * across a boundary that needs no OpenSSL headers.
 *
 * Every function returns 1 on success and 0 on failure, and writes the produced
 * length through outLength.
 */

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/kdf.h>
#include <string.h>

static const EVP_CIPHER *gcmCipherForKey(size_t keyLength)
{
    switch (keyLength) {
    case 16: return EVP_aes_128_gcm();
    case 24: return EVP_aes_192_gcm();
    case 32: return EVP_aes_256_gcm();
    default: return 0;
    }
}

/* Cipher text and tag are written contiguously, tag last, which is the layout
 * the Web Crypto specification defines and the caller expects. */
int ios6AesGcmEncrypt(const unsigned char *key, size_t keyLength,
    const unsigned char *iv, size_t ivLength,
    const unsigned char *additional, size_t additionalLength,
    const unsigned char *plainText, size_t plainTextLength,
    size_t tagLength, unsigned char *out, size_t outCapacity, size_t *outLength)
{
    const EVP_CIPHER *cipher = gcmCipherForKey(keyLength);
    if (!cipher || !tagLength || tagLength > 16 || outCapacity < plainTextLength + tagLength)
        return 0;

    EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
    if (!context)
        return 0;

    int ok = 0;
    int produced = 0, finished = 0, ignored = 0;
    do {
        if (EVP_EncryptInit_ex(context, cipher, 0, 0, 0) != 1)
            break;
        if (EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_IVLEN, (int)ivLength, 0) != 1)
            break;
        if (EVP_EncryptInit_ex(context, 0, 0, key, iv) != 1)
            break;
        if (additionalLength && EVP_EncryptUpdate(context, 0, &ignored, additional, (int)additionalLength) != 1)
            break;
        if (plainTextLength && EVP_EncryptUpdate(context, out, &produced, plainText, (int)plainTextLength) != 1)
            break;
        if (EVP_EncryptFinal_ex(context, out + produced, &finished) != 1)
            break;
        if (EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_GET_TAG, (int)tagLength, out + produced + finished) != 1)
            break;
        *outLength = (size_t)(produced + finished) + tagLength;
        ok = 1;
    } while (0);

    EVP_CIPHER_CTX_free(context);
    return ok;
}

int ios6AesGcmDecrypt(const unsigned char *key, size_t keyLength,
    const unsigned char *iv, size_t ivLength,
    const unsigned char *additional, size_t additionalLength,
    const unsigned char *cipherText, size_t cipherTextLength,
    size_t tagLength, unsigned char *out, size_t outCapacity, size_t *outLength)
{
    const EVP_CIPHER *cipher = gcmCipherForKey(keyLength);
    if (!cipher || !tagLength || tagLength > 16 || cipherTextLength < tagLength)
        return 0;

    size_t bodyLength = cipherTextLength - tagLength;
    if (outCapacity < bodyLength)
        return 0;

    EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
    if (!context)
        return 0;

    int ok = 0;
    int produced = 0, finished = 0, ignored = 0;
    do {
        if (EVP_DecryptInit_ex(context, cipher, 0, 0, 0) != 1)
            break;
        if (EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_IVLEN, (int)ivLength, 0) != 1)
            break;
        if (EVP_DecryptInit_ex(context, 0, 0, key, iv) != 1)
            break;
        if (additionalLength && EVP_DecryptUpdate(context, 0, &ignored, additional, (int)additionalLength) != 1)
            break;
        if (bodyLength && EVP_DecryptUpdate(context, out, &produced, cipherText, (int)bodyLength) != 1)
            break;
        /* The tag is verified by EVP_DecryptFinal_ex; a forged message fails
         * here and the caller is told, rather than handed plain text. */
        if (EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_AEAD_SET_TAG, (int)tagLength,
                (void *)(cipherText + bodyLength)) != 1)
            break;
        if (EVP_DecryptFinal_ex(context, out + produced, &finished) != 1)
            break;
        *outLength = (size_t)(produced + finished);
        ok = 1;
    } while (0);

    EVP_CIPHER_CTX_free(context);
    return ok;
}

static const EVP_MD *digestForIdentifier(int identifier)
{
    switch (identifier) {
    case 0: return EVP_sha1();
    case 1: return EVP_sha224();
    case 2: return EVP_sha256();
    case 3: return EVP_sha384();
    case 4: return EVP_sha512();
    default: return 0;
    }
}

int ios6Hmac(int digestIdentifier, const unsigned char *key, size_t keyLength,
    const unsigned char *data, size_t dataLength, unsigned char *out, size_t *outLength)
{
    const EVP_MD *digest = digestForIdentifier(digestIdentifier);
    if (!digest)
        return 0;
    unsigned int produced = 0;
    /* A zero-length key is legal and HMAC() accepts it, but the pointer must
     * still be valid, so an empty vector's null data is given something to
     * point at. */
    static const unsigned char emptyKey[1] = { 0 };
    if (!HMAC(digest, keyLength ? (const void *)key : (const void *)emptyKey, (int)keyLength,
            data, dataLength, out, &produced))
        return 0;
    *outLength = produced;
    return 1;
}

int ios6HkdfDeriveBits(int digestIdentifier, const unsigned char *key, size_t keyLength,
    const unsigned char *salt, size_t saltLength,
    const unsigned char *info, size_t infoLength,
    unsigned char *out, size_t outLength)
{
    const EVP_MD *digest = digestForIdentifier(digestIdentifier);
    if (!digest || !outLength)
        return 0;

    EVP_PKEY_CTX *context = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, 0);
    if (!context)
        return 0;

    int ok = 0;
    size_t produced = outLength;
    do {
        if (EVP_PKEY_derive_init(context) <= 0)
            break;
        if (EVP_PKEY_CTX_set_hkdf_md(context, digest) <= 0)
            break;
        if (EVP_PKEY_CTX_set1_hkdf_salt(context, salt, (int)saltLength) <= 0)
            break;
        if (EVP_PKEY_CTX_set1_hkdf_key(context, key, (int)keyLength) <= 0)
            break;
        if (infoLength && EVP_PKEY_CTX_add1_hkdf_info(context, info, (int)infoLength) <= 0)
            break;
        if (EVP_PKEY_derive(context, out, &produced) <= 0)
            break;
        ok = produced == outLength;
    } while (0);

    EVP_PKEY_CTX_free(context);
    return ok;
}

/* AES key wrap, RFC 3394. The wrapped form is eight bytes longer than the key
 * it carries. */
int ios6AesKeyWrap(const unsigned char *key, size_t keyLength,
    const unsigned char *plainText, size_t plainTextLength,
    unsigned char *out, size_t outCapacity, size_t *outLength)
{
    if (plainTextLength % 8 || plainTextLength < 16 || outCapacity < plainTextLength + 8)
        return 0;
    const EVP_CIPHER *cipher = keyLength == 16 ? EVP_aes_128_wrap()
        : keyLength == 24 ? EVP_aes_192_wrap()
        : keyLength == 32 ? EVP_aes_256_wrap() : 0;
    if (!cipher)
        return 0;

    EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
    if (!context)
        return 0;
    EVP_CIPHER_CTX_set_flags(context, EVP_CIPHER_CTX_FLAG_WRAP_ALLOW);

    int ok = 0, produced = 0, finished = 0;
    do {
        if (EVP_EncryptInit_ex(context, cipher, 0, key, 0) != 1)
            break;
        if (EVP_EncryptUpdate(context, out, &produced, plainText, (int)plainTextLength) != 1)
            break;
        if (EVP_EncryptFinal_ex(context, out + produced, &finished) != 1)
            break;
        *outLength = (size_t)(produced + finished);
        ok = 1;
    } while (0);

    EVP_CIPHER_CTX_free(context);
    return ok;
}

int ios6AesKeyUnwrap(const unsigned char *key, size_t keyLength,
    const unsigned char *cipherText, size_t cipherTextLength,
    unsigned char *out, size_t outCapacity, size_t *outLength)
{
    if (cipherTextLength % 8 || cipherTextLength < 24 || outCapacity + 8 < cipherTextLength)
        return 0;
    const EVP_CIPHER *cipher = keyLength == 16 ? EVP_aes_128_wrap()
        : keyLength == 24 ? EVP_aes_192_wrap()
        : keyLength == 32 ? EVP_aes_256_wrap() : 0;
    if (!cipher)
        return 0;

    EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
    if (!context)
        return 0;
    EVP_CIPHER_CTX_set_flags(context, EVP_CIPHER_CTX_FLAG_WRAP_ALLOW);

    int ok = 0, produced = 0, finished = 0;
    do {
        if (EVP_DecryptInit_ex(context, cipher, 0, key, 0) != 1)
            break;
        if (EVP_DecryptUpdate(context, out, &produced, cipherText, (int)cipherTextLength) != 1)
            break;
        if (EVP_DecryptFinal_ex(context, out + produced, &finished) != 1)
            break;
        *outLength = (size_t)(produced + finished);
        ok = 1;
    } while (0);

    EVP_CIPHER_CTX_free(context);
    return ok;
}
