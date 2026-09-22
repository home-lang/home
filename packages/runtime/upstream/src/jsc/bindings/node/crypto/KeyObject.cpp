#include "KeyObject.h"
#include "JSPublicKeyObject.h"
#include "JSPrivateKeyObject.h"
#include "helpers.h"
#include "ZigGlobalObject.h"
#include "CryptoUtil.h"
#include "ErrorCode.h"
#include "NodeValidator.h"
#include "AsymmetricKeyValue.h"
#include "CryptoKeyAES.h"
#include "CryptoKeyHMAC.h"
#include "CryptoKeyRaw.h"
#include "CryptoKey.h"
#include "CryptoKeyType.h"
#include "JSCryptoKey.h"
#include "CryptoGenKeyPair.h"
#include "JSBuffer.h"
#include "BunString.h"
#include <openssl/bytestring.h>
#include <openssl/pem.h>
#include <openssl/pkcs8.h>
#include <openssl/rand.h>

namespace bssl {

int pkcs8_pbe_decrypt(uint8_t**, size_t*, CBS*, const char*, size_t, const uint8_t*, size_t);
int pkcs12_pbe_encrypt_init(CBB*, EVP_CIPHER_CTX*, int, const EVP_CIPHER*, uint32_t,
    const char*, size_t, const uint8_t*, size_t);

}

namespace {

void freeRsaPssMetadata(void*, void* pointer, CRYPTO_EX_DATA*, int, long, void*)
{
    delete static_cast<Bun::RsaPssMetadata*>(pointer);
}

int rsaPssMetadataIndex()
{
    static const int index = RSA_get_ex_new_index(0, nullptr, nullptr, nullptr, freeRsaPssMetadata);
    RELEASE_ASSERT(index >= 0);
    return index;
}

}

void KeyObjectData::setRsaPssMetadata(ncrypto::Digest digest, ncrypto::Digest mgf1Digest, int32_t minimumSaltLength)
{
    RSA* rsa = EVP_PKEY_get0_RSA(asymmetricKey.get());
    RELEASE_ASSERT(rsa);

    const int index = rsaPssMetadataIndex();
    auto* previous = static_cast<Bun::RsaPssMetadata*>(RSA_get_ex_data(rsa, index));
    auto metadata = std::make_unique<Bun::RsaPssMetadata>(Bun::RsaPssMetadata {
        .digest = digest,
        .mgf1Digest = mgf1Digest,
        .minimumSaltLength = minimumSaltLength,
    });
    RELEASE_ASSERT(RSA_set_ex_data(rsa, index, metadata.get()));
    metadata.release();
    delete previous;
}

std::optional<Bun::RsaPssMetadata> KeyObjectData::rsaPssMetadata() const
{
    RSA* rsa = EVP_PKEY_get0_RSA(asymmetricKey.get());
    if (!rsa) {
        return std::nullopt;
    }

    auto* metadata = static_cast<Bun::RsaPssMetadata*>(RSA_get_ex_data(rsa, rsaPssMetadataIndex()));
    if (!metadata) {
        return std::nullopt;
    }
    return *metadata;
}

namespace Bun {

using namespace Bun;
using namespace JSC;
using namespace ncrypto;
using namespace WebCore;

namespace {

enum class RsaPssParseStatus : uint8_t {
    NotRsaPss,
    Invalid,
    Success,
};

struct RsaPssParseResult {
    RsaPssParseStatus status { RsaPssParseStatus::NotRsaPss };
    RefPtr<KeyObjectData> keyData;
};

bool parseDigestAlgorithm(CBS* input, ncrypto::Digest& digest)
{
    CBS algorithm;
    CBS oid;
    if (!CBS_get_asn1(input, &algorithm, CBS_ASN1_SEQUENCE)
        || !CBS_get_asn1(&algorithm, &oid, CBS_ASN1_OBJECT)) {
        return false;
    }

    const EVP_MD* md = EVP_get_digestbynid(OBJ_cbs2nid(&oid));
    if (!md) {
        return false;
    }

    if (CBS_len(&algorithm) > 0) {
        CBS nullValue;
        if (!CBS_get_asn1(&algorithm, &nullValue, CBS_ASN1_NULL)
            || CBS_len(&nullValue) != 0) {
            return false;
        }
    }

    if (CBS_len(&algorithm) != 0) {
        return false;
    }

    digest = md;
    return true;
}

bool parseRsaPssParameters(CBS* parameters, RsaPssMetadata& metadata)
{
    metadata.digest = ncrypto::Digest::SHA1();
    metadata.mgf1Digest = ncrypto::Digest::SHA1();
    metadata.minimumSaltLength = 20;

    CBS wrapper;
    int present = 0;
    if (!CBS_get_optional_asn1(parameters, &wrapper, &present,
            CBS_ASN1_CONSTRUCTED | CBS_ASN1_CONTEXT_SPECIFIC | 0)) {
        return false;
    }
    if (present && (!parseDigestAlgorithm(&wrapper, metadata.digest) || CBS_len(&wrapper) != 0)) {
        return false;
    }

    if (!CBS_get_optional_asn1(parameters, &wrapper, &present,
            CBS_ASN1_CONSTRUCTED | CBS_ASN1_CONTEXT_SPECIFIC | 1)) {
        return false;
    }
    if (present) {
        CBS maskAlgorithm;
        CBS oid;
        if (!CBS_get_asn1(&wrapper, &maskAlgorithm, CBS_ASN1_SEQUENCE)
            || !CBS_get_asn1(&maskAlgorithm, &oid, CBS_ASN1_OBJECT)
            || OBJ_cbs2nid(&oid) != NID_mgf1
            || !parseDigestAlgorithm(&maskAlgorithm, metadata.mgf1Digest)
            || CBS_len(&maskAlgorithm) != 0
            || CBS_len(&wrapper) != 0) {
            return false;
        }
    }

    uint64_t saltLength = 20;
    if (!CBS_get_optional_asn1_uint64(parameters, &saltLength,
            CBS_ASN1_CONSTRUCTED | CBS_ASN1_CONTEXT_SPECIFIC | 2, 20)
        || saltLength > INT32_MAX) {
        return false;
    }
    metadata.minimumSaltLength = static_cast<int32_t>(saltLength);

    uint64_t trailerField = 1;
    if (!CBS_get_optional_asn1_uint64(parameters, &trailerField,
            CBS_ASN1_CONSTRUCTED | CBS_ASN1_CONTEXT_SPECIFIC | 3, 1)
        || trailerField != 1) {
        return false;
    }

    return CBS_len(parameters) == 0;
}

RsaPssParseStatus parseRsaPssAlgorithm(CBS* input, RsaPssMetadata& metadata)
{
    CBS algorithm;
    CBS oid;
    if (!CBS_get_asn1(input, &algorithm, CBS_ASN1_SEQUENCE)
        || !CBS_get_asn1(&algorithm, &oid, CBS_ASN1_OBJECT)) {
        return RsaPssParseStatus::NotRsaPss;
    }
    if (OBJ_cbs2nid(&oid) != NID_rsassaPss) {
        return RsaPssParseStatus::NotRsaPss;
    }

    if (CBS_len(&algorithm) == 0) {
        metadata = {};
        return RsaPssParseStatus::Success;
    }

    CBS parameters;
    if (!CBS_get_asn1(&algorithm, &parameters, CBS_ASN1_SEQUENCE)
        || CBS_len(&algorithm) != 0
        || !parseRsaPssParameters(&parameters, metadata)) {
        return RsaPssParseStatus::Invalid;
    }
    return RsaPssParseStatus::Success;
}

RsaPssParseResult parseRsaPssDer(std::span<const uint8_t> der, bool isPrivate)
{
    CBS input;
    CBS keySequence;
    CBS_init(&input, der.data(), der.size());
    if (!CBS_get_asn1(&input, &keySequence, CBS_ASN1_SEQUENCE) || CBS_len(&input) != 0) {
        return {};
    }

    if (isPrivate) {
        uint64_t version = 0;
        if (!CBS_get_asn1_uint64(&keySequence, &version) || version != 0) {
            return {};
        }
    }

    RsaPssMetadata metadata;
    const auto algorithmStatus = parseRsaPssAlgorithm(&keySequence, metadata);
    if (algorithmStatus != RsaPssParseStatus::Success) {
        return { .status = algorithmStatus };
    }

    CBS encodedKey;
    if (isPrivate) {
        if (!CBS_get_asn1(&keySequence, &encodedKey, CBS_ASN1_OCTETSTRING)) {
            return { .status = RsaPssParseStatus::Invalid };
        }
    } else {
        if (!CBS_get_asn1(&keySequence, &encodedKey, CBS_ASN1_BITSTRING)) {
            return { .status = RsaPssParseStatus::Invalid };
        }
        uint8_t padding = 0;
        if (!CBS_get_u8(&encodedKey, &padding) || padding != 0) {
            return { .status = RsaPssParseStatus::Invalid };
        }
    }

    if (CBS_len(&keySequence) != 0) {
        return { .status = RsaPssParseStatus::Invalid };
    }

    ncrypto::RSAPointer rsa(isPrivate
            ? RSA_private_key_from_bytes(CBS_data(&encodedKey), CBS_len(&encodedKey))
            : RSA_public_key_from_bytes(CBS_data(&encodedKey), CBS_len(&encodedKey)));
    auto key = ncrypto::EVPKeyPointer::NewRSA(WTF::move(rsa));
    if (!key) {
        return { .status = RsaPssParseStatus::Invalid };
    }

    auto keyData = KeyObjectData::create(WTF::move(key));
    keyData->setRsaPssMetadata(metadata.digest, metadata.mgf1Digest, metadata.minimumSaltLength);
    return { .status = RsaPssParseStatus::Success, .keyData = WTF::move(keyData) };
}

ncrypto::DataPointer decryptPkcs8(
    std::span<const uint8_t> encrypted,
    const ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig& config)
{
    if (!config.passphrase) {
        return {};
    }

    CBS input;
    CBS encryptedKey;
    CBS algorithm;
    CBS ciphertext;
    CBS_init(&input, encrypted.data(), encrypted.size());
    if (!CBS_get_asn1(&input, &encryptedKey, CBS_ASN1_SEQUENCE)
        || !CBS_get_asn1(&encryptedKey, &algorithm, CBS_ASN1_SEQUENCE)
        || !CBS_get_asn1(&encryptedKey, &ciphertext, CBS_ASN1_OCTETSTRING)
        || CBS_len(&encryptedKey) != 0
        || CBS_len(&input) != 0) {
        return {};
    }

    const char* passphrase = static_cast<const char*>(config.passphrase->get());
    uint8_t* decoded = nullptr;
    size_t decodedLength = 0;
    if (!bssl::pkcs8_pbe_decrypt(&decoded, &decodedLength, &algorithm,
            passphrase, config.passphrase->size(), CBS_data(&ciphertext), CBS_len(&ciphertext))) {
        return {};
    }
    return ncrypto::DataPointer(decoded, decodedLength);
}

ncrypto::DataPointer encryptPkcs8(
    std::span<const uint8_t> plaintext,
    const EVP_CIPHER* cipher,
    const ncrypto::DataPointer& passphrase)
{
    constexpr size_t saltLength = 16;
    uint8_t salt[saltLength];
    if (!RAND_bytes(salt, sizeof(salt))) {
        return {};
    }

    auto cipherContext = ncrypto::CipherCtxPointer::New();
    if (!cipherContext) {
        return {};
    }

    CBB output;
    if (!CBB_init(&output, plaintext.size() + 128)) {
        return {};
    }

    const char* password = static_cast<const char*>(passphrase.get());
    CBB encryptedKey;
    CBB ciphertext;
    uint8_t* ciphertextData = nullptr;
    size_t ciphertextLength = 0;
    size_t finalLength = 0;
    if (!CBB_add_asn1(&output, &encryptedKey, CBS_ASN1_SEQUENCE)
        || !bssl::pkcs12_pbe_encrypt_init(&encryptedKey, cipherContext.get(), -1, cipher,
            PKCS12_DEFAULT_ITER, password, passphrase.size(), salt, sizeof(salt))) {
        CBB_cleanup(&output);
        return {};
    }

    const size_t maximumLength = plaintext.size() + EVP_CIPHER_CTX_block_size(cipherContext.get());
    const bool ok = maximumLength >= plaintext.size()
        && CBB_add_asn1(&encryptedKey, &ciphertext, CBS_ASN1_OCTETSTRING)
        && CBB_reserve(&ciphertext, &ciphertextData, maximumLength)
        && EVP_CipherUpdate_ex(cipherContext.get(), ciphertextData, &ciphertextLength, maximumLength,
            plaintext.data(), plaintext.size())
        && EVP_CipherFinal_ex2(cipherContext.get(), ciphertextData + ciphertextLength, &finalLength,
            maximumLength - ciphertextLength)
        && CBB_did_write(&ciphertext, ciphertextLength + finalLength)
        && CBB_flush(&output);

    uint8_t* encoded = nullptr;
    size_t encodedLength = 0;
    if (!ok || !CBB_finish(&output, &encoded, &encodedLength)) {
        CBB_cleanup(&output);
        return {};
    }
    return ncrypto::DataPointer(encoded, encodedLength);
}

RsaPssParseResult tryParseRsaPssKey(
    const ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig& config,
    const ncrypto::Buffer<const uint8_t>& buffer,
    bool requirePrivate)
{
    if (config.format == ncrypto::EVPKeyPointer::PKFormatType::DER) {
        if (config.type == ncrypto::EVPKeyPointer::PKEncodingType::SPKI) {
            if (requirePrivate) {
                return { .status = RsaPssParseStatus::Invalid };
            }
            return parseRsaPssDer({ buffer.data, buffer.len }, false);
        }
        if (config.type == ncrypto::EVPKeyPointer::PKEncodingType::PKCS8) {
            auto result = parseRsaPssDer({ buffer.data, buffer.len }, true);
            if (result.status != RsaPssParseStatus::NotRsaPss) {
                return result;
            }
            auto decrypted = decryptPkcs8({ buffer.data, buffer.len }, config);
            return decrypted ? parseRsaPssDer(decrypted.span(), true) : result;
        }
        return {};
    }

    if (config.format != ncrypto::EVPKeyPointer::PKFormatType::PEM) {
        return {};
    }

    auto bio = ncrypto::BIOPointer::New(buffer.data, buffer.len);
    if (!bio) {
        return { .status = RsaPssParseStatus::Invalid };
    }

    char* name = nullptr;
    char* header = nullptr;
    uint8_t* data = nullptr;
    long length = 0;
    if (!PEM_read_bio(bio.get(), &name, &header, &data, &length)) {
        return {};
    }

    const bool isPrivate = strcmp(name, PEM_STRING_PKCS8INF) == 0;
    const bool isEncryptedPrivate = strcmp(name, PEM_STRING_PKCS8) == 0;
    const bool isPublic = strcmp(name, PEM_STRING_PUBLIC) == 0;
    OPENSSL_free(name);
    OPENSSL_free(header);
    ncrypto::DataPointer decoded(data, length);
    if (!isPrivate && !isEncryptedPrivate && !isPublic) {
        return {};
    }
    if (requirePrivate && isPublic) {
        return { .status = RsaPssParseStatus::Invalid };
    }

    if (isEncryptedPrivate) {
        auto decrypted = decryptPkcs8(decoded.span(), config);
        return decrypted ? parseRsaPssDer(decrypted.span(), true) : RsaPssParseResult {};
    }
    return parseRsaPssDer(decoded.span(), isPrivate);
}

bool addOid(CBB* output, int nid)
{
    const ASN1_OBJECT* object = OBJ_nid2obj(nid);
    return object
        && CBB_add_asn1_element(output, CBS_ASN1_OBJECT, OBJ_get0_data(object), OBJ_length(object));
}

bool addDigestAlgorithm(CBB* output, ncrypto::Digest digest)
{
    CBB algorithm;
    CBB nullValue;
    return digest
        && CBB_add_asn1(output, &algorithm, CBS_ASN1_SEQUENCE)
        && addOid(&algorithm, EVP_MD_type(digest.get()))
        && CBB_add_asn1(&algorithm, &nullValue, CBS_ASN1_NULL)
        && CBB_flush(output);
}

bool addRsaPssAlgorithm(CBB* output, const RsaPssMetadata& metadata)
{
    CBB algorithm;
    if (!CBB_add_asn1(output, &algorithm, CBS_ASN1_SEQUENCE)
        || !addOid(&algorithm, NID_rsassaPss)) {
        return false;
    }

    // An absent parameters field means the key is unrestricted. Explicit
    // SHA-1/MGF1-SHA-1/salt-20 restrictions encode as an empty sequence
    // because those are the RFC 4055 defaults.
    if (!metadata.digest) {
        return CBB_flush(output);
    }

    CBB parameters;
    if (!CBB_add_asn1(&algorithm, &parameters, CBS_ASN1_SEQUENCE)) {
        return false;
    }

    if (EVP_MD_type(metadata.digest.get()) != NID_sha1) {
        CBB hashWrapper;
        if (!CBB_add_asn1(&parameters, &hashWrapper,
                CBS_ASN1_CONSTRUCTED | CBS_ASN1_CONTEXT_SPECIFIC | 0)
            || !addDigestAlgorithm(&hashWrapper, metadata.digest)) {
            return false;
        }
    }

    if (metadata.mgf1Digest && EVP_MD_type(metadata.mgf1Digest.get()) != NID_sha1) {
        CBB maskWrapper;
        CBB maskAlgorithm;
        if (!CBB_add_asn1(&parameters, &maskWrapper,
                CBS_ASN1_CONSTRUCTED | CBS_ASN1_CONTEXT_SPECIFIC | 1)
            || !CBB_add_asn1(&maskWrapper, &maskAlgorithm, CBS_ASN1_SEQUENCE)
            || !addOid(&maskAlgorithm, NID_mgf1)
            || !addDigestAlgorithm(&maskAlgorithm, metadata.mgf1Digest)) {
            return false;
        }
    }

    if (metadata.minimumSaltLength >= 0 && metadata.minimumSaltLength != 20) {
        CBB saltWrapper;
        if (!CBB_add_asn1(&parameters, &saltWrapper,
                CBS_ASN1_CONSTRUCTED | CBS_ASN1_CONTEXT_SPECIFIC | 2)
            || !CBB_add_asn1_uint64(&saltWrapper, metadata.minimumSaltLength)) {
            return false;
        }
    }

    return CBB_flush(output);
}

ncrypto::DataPointer encodeRsaPssKey(const KeyObjectData& keyData, bool isPrivate)
{
    const RSA* rsa = EVP_PKEY_get0_RSA(keyData.asymmetricKey.get());
    const auto metadata = keyData.rsaPssMetadata();
    if (!rsa || !metadata) {
        return {};
    }

    uint8_t* rawKey = nullptr;
    const int rawKeyLength = isPrivate
        ? i2d_RSAPrivateKey(rsa, &rawKey)
        : i2d_RSAPublicKey(rsa, &rawKey);
    if (rawKeyLength <= 0) {
        return {};
    }
    ncrypto::DataPointer rawKeyData(rawKey, rawKeyLength);

    CBB output;
    if (!CBB_init(&output, static_cast<size_t>(rawKeyLength) + 128)) {
        return {};
    }

    CBB keySequence;
    bool ok = CBB_add_asn1(&output, &keySequence, CBS_ASN1_SEQUENCE);
    if (isPrivate) {
        ok = ok && CBB_add_asn1_uint64(&keySequence, 0);
    }
    ok = ok && addRsaPssAlgorithm(&keySequence, *metadata);

    if (isPrivate) {
        ok = ok && CBB_add_asn1_octet_string(&keySequence, rawKeyData.get<const uint8_t>(), rawKeyData.size());
    } else {
        CBB bitString;
        ok = ok
            && CBB_add_asn1(&keySequence, &bitString, CBS_ASN1_BITSTRING)
            && CBB_add_u8(&bitString, 0)
            && CBB_add_bytes(&bitString, static_cast<const uint8_t*>(rawKeyData.get()), rawKeyData.size());
    }

    uint8_t* encoded = nullptr;
    size_t encodedLength = 0;
    if (!ok || !CBB_finish(&output, &encoded, &encodedLength)) {
        CBB_cleanup(&output);
        return {};
    }
    return ncrypto::DataPointer(encoded, encodedLength);
}

ncrypto::BIOPointer writeRsaPssPublicKey(
    const KeyObjectData& keyData,
    const ncrypto::EVPKeyPointer::PublicKeyEncodingConfig& config)
{
    auto encoded = encodeRsaPssKey(keyData, false);
    auto bio = ncrypto::BIOPointer::NewMem();
    if (!encoded || !bio) {
        return {};
    }

    const int result = config.format == ncrypto::EVPKeyPointer::PKFormatType::PEM
        ? PEM_write_bio(bio.get(), PEM_STRING_PUBLIC, "", static_cast<const uint8_t*>(encoded.get()), encoded.size())
        : BIO_write(bio.get(), encoded.get(), encoded.size());
    return result > 0 ? WTF::move(bio) : ncrypto::BIOPointer {};
}

ncrypto::BIOPointer writeRsaPssPrivateKey(
    const KeyObjectData& keyData,
    const ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig& config)
{
    auto encoded = encodeRsaPssKey(keyData, true);
    if (!encoded) {
        return {};
    }

    const char* pemName = PEM_STRING_PKCS8INF;
    if (config.cipher) {
        if (!config.passphrase) {
            return {};
        }
        auto encrypted = encryptPkcs8(encoded.span(), config.cipher, *config.passphrase);
        if (!encrypted) {
            return {};
        }
        encoded = WTF::move(encrypted);
        pemName = PEM_STRING_PKCS8;
    }

    auto bio = ncrypto::BIOPointer::NewMem();
    if (!bio) {
        return {};
    }
    const int result = config.format == ncrypto::EVPKeyPointer::PKFormatType::PEM
        ? PEM_write_bio(bio.get(), pemName, "", static_cast<const uint8_t*>(encoded.get()), encoded.size())
        : BIO_write(bio.get(), encoded.get(), encoded.size());
    return result > 0 ? WTF::move(bio) : ncrypto::BIOPointer {};
}

} // namespace

ncrypto::BIOPointer serializeKeyObjectForStructuredClone(const KeyObject& keyObject)
{
    if (keyObject.type() == CryptoKeyType::Secret) {
        return {};
    }

    if (keyObject.isRsaPss()) {
        if (keyObject.type() == CryptoKeyType::Public) {
            ncrypto::EVPKeyPointer::PublicKeyEncodingConfig config {};
            config.format = ncrypto::EVPKeyPointer::PKFormatType::PEM;
            config.type = ncrypto::EVPKeyPointer::PKEncodingType::SPKI;
            return writeRsaPssPublicKey(*keyObject.data(), config);
        }

        ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig config {};
        config.format = ncrypto::EVPKeyPointer::PKFormatType::PEM;
        config.type = ncrypto::EVPKeyPointer::PKEncodingType::PKCS8;
        return writeRsaPssPrivateKey(*keyObject.data(), config);
    }

    auto bio = ncrypto::BIOPointer::NewMem();
    if (!bio) {
        return {};
    }
    const int result = keyObject.type() == CryptoKeyType::Public
        ? PEM_write_bio_PUBKEY(bio.get(), keyObject.asymmetricKey().get())
        : PEM_write_bio_PrivateKey(bio.get(), keyObject.asymmetricKey().get(), nullptr, nullptr, 0, nullptr, nullptr);
    return result > 0 ? WTF::move(bio) : ncrypto::BIOPointer {};
}

KeyObject deserializeKeyObjectForStructuredClone(CryptoKeyType keyType, std::span<const uint8_t> pem)
{
    if (keyType == CryptoKeyType::Secret) {
        return {};
    }

    auto config = ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig {};
    config.format = ncrypto::EVPKeyPointer::PKFormatType::PEM;
    config.type = ncrypto::EVPKeyPointer::PKEncodingType::PKCS8;
    auto buffer = ncrypto::Buffer<const uint8_t> {
        .data = pem.data(),
        .len = pem.size(),
    };

    auto rsaPssResult = tryParseRsaPssKey(config, buffer, keyType == CryptoKeyType::Private);
    if (rsaPssResult.status == RsaPssParseStatus::Success) {
        return KeyObject::create(keyType, WTF::move(rsaPssResult.keyData));
    }
    if (rsaPssResult.status == RsaPssParseStatus::Invalid) {
        return {};
    }

    if (keyType == CryptoKeyType::Public) {
        auto result = ncrypto::EVPKeyPointer::TryParsePublicKeyPEM(buffer);
        return result ? KeyObject::create(keyType, WTF::move(result.value)) : KeyObject {};
    }

    auto result = ncrypto::EVPKeyPointer::TryParsePrivateKey(config, buffer);
    return result ? KeyObject::create(keyType, WTF::move(result.value)) : KeyObject {};
}

JSValue encodeBignum(JSGlobalObject* globalObject, ThrowScope& scope, const BIGNUM* bn, int size)
{
    auto buf = ncrypto::BignumPointer::EncodePadded(bn, size);

    JSValue encoded = JSValue::decode(StringBytes::encode(globalObject, scope, buf.span(), BufferEncodingType::base64url));
    RETURN_IF_EXCEPTION(scope, {});

    return encoded;
}

void setEncodedValue(JSGlobalObject* globalObject, ThrowScope& scope, JSObject* obj, JSString* name, const BIGNUM* bn, int size = 0)
{
    if (size == 0) {
        size = ncrypto::BignumPointer::GetByteCount(bn);
    }

    VM& vm = globalObject->vm();
    JSValue encodedBn = encodeBignum(globalObject, scope, bn, size);
    RETURN_IF_EXCEPTION(scope, );

    obj->putDirect(vm, Identifier::fromString(vm, name->value(globalObject)), encodedBn);
}

JSC::JSValue KeyObject::exportJwkEdKey(JSC::JSGlobalObject* lexicalGlobalObject, JSC::ThrowScope& scope, CryptoKeyType exportType)
{
    VM& vm = lexicalGlobalObject->vm();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto& commonStrings = globalObject->commonStrings();

    const auto& pkey = m_data->asymmetricKey;

    JSObject* jwk = JSC::constructEmptyObject(lexicalGlobalObject);

    ASCIILiteral curve = ([&] {
        switch (pkey.id()) {
        case EVP_PKEY_ED25519:
            return "Ed25519"_s;
        case EVP_PKEY_ED448:
            return "Ed448"_s;
        case EVP_PKEY_X25519:
            return "X25519"_s;
        case EVP_PKEY_X448:
            return "X448"_s;
        default:
            UNREACHABLE();
        }
    })();

    jwk->putDirect(
        vm,
        Identifier::fromString(vm, commonStrings.jwkCrvString(lexicalGlobalObject)->value(lexicalGlobalObject)),
        jsString(vm, makeString(curve)));

    if (exportType == CryptoKeyType::Private) {
        ncrypto::DataPointer privateData = pkey.rawPrivateKey();

        JSValue encoded = JSValue::decode(StringBytes::encode(lexicalGlobalObject, scope, privateData.span(), BufferEncodingType::base64url));
        RETURN_IF_EXCEPTION(scope, {});
        jwk->putDirect(
            vm,
            Identifier::fromString(vm, commonStrings.jwkDString(lexicalGlobalObject)->value(lexicalGlobalObject)),
            encoded);
    }

    ncrypto::DataPointer publicData = pkey.rawPublicKey();
    JSValue encoded = JSValue::decode(StringBytes::encode(lexicalGlobalObject, scope, publicData.span(), BufferEncodingType::base64url));
    RETURN_IF_EXCEPTION(scope, {});
    jwk->putDirect(
        vm,
        Identifier::fromString(vm, commonStrings.jwkXString(lexicalGlobalObject)->value(lexicalGlobalObject)),
        encoded);

    jwk->putDirect(
        vm,
        Identifier::fromString(vm, commonStrings.jwkKtyString(lexicalGlobalObject)->value(lexicalGlobalObject)),
        commonStrings.jwkOkpString(lexicalGlobalObject));

    return jwk;
}

JSC::JSValue KeyObject::exportJwkEcKey(JSC::JSGlobalObject* lexicalGlobalObject, JSC::ThrowScope& scope, CryptoKeyType exportType)
{
    VM& vm = lexicalGlobalObject->vm();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto& commonStrings = globalObject->commonStrings();

    const auto& pkey = m_data->asymmetricKey;
    ASSERT(pkey.id() == EVP_PKEY_EC);

    const EC_KEY* ec = pkey;
    ASSERT(ec);

    const auto pub = ncrypto::ECKeyPointer::GetPublicKey(ec);
    const auto group = ncrypto::ECKeyPointer::GetGroup(ec);

    int degree_bits = EC_GROUP_get_degree(group);
    int degree_bytes = (degree_bits / CHAR_BIT) + (7 + (degree_bits % CHAR_BIT)) / 8;

    auto x = ncrypto::BignumPointer::New();
    auto y = ncrypto::BignumPointer::New();

    if (!EC_POINT_get_affine_coordinates(group, pub, x.get(), y.get(), nullptr)) {
        throwCryptoError(lexicalGlobalObject, scope, ERR_get_error(),
            "Failed to get elliptic-curve point coordinates");
        return {};
    }

    JSObject* jwk = JSC::constructEmptyObject(lexicalGlobalObject);

    jwk->putDirect(
        vm,
        Identifier::fromString(vm, commonStrings.jwkKtyString(lexicalGlobalObject)->value(lexicalGlobalObject)),
        commonStrings.jwkEcString(lexicalGlobalObject));

    setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkXString(lexicalGlobalObject), x.get(), degree_bytes);
    RETURN_IF_EXCEPTION(scope, {});
    setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkYString(lexicalGlobalObject), y.get(), degree_bytes);
    RETURN_IF_EXCEPTION(scope, {});

    WTF::ASCIILiteral crvName;
    const int nid = EC_GROUP_get_curve_name(group);
    switch (nid) {
    case NID_X9_62_prime256v1:
        crvName = "P-256"_s;
        break;
    case NID_secp256k1:
        crvName = "secp256k1"_s;
        break;
    case NID_secp384r1:
        crvName = "P-384"_s;
        break;
    case NID_secp521r1:
        crvName = "P-521"_s;
        break;
    default: {
        ERR::CRYPTO_JWK_UNSUPPORTED_CURVE(scope, lexicalGlobalObject, "Unsupported JWK EC curve: ", OBJ_nid2sn(nid));
        return {};
    }
    }

    jwk->putDirect(
        vm,
        Identifier::fromString(vm, commonStrings.jwkCrvString(lexicalGlobalObject)->value(lexicalGlobalObject)),
        jsString(vm, makeString(crvName)));

    if (exportType == CryptoKeyType::Private) {
        auto pvt = ncrypto::ECKeyPointer::GetPrivateKey(ec);
        setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkDString(lexicalGlobalObject), pvt, degree_bytes);
        RETURN_IF_EXCEPTION(scope, {});
    }

    return jwk;
}

JSC::JSValue KeyObject::exportJwkRsaKey(JSC::JSGlobalObject* lexicalGlobalObject, JSC::ThrowScope& scope, CryptoKeyType exportType)
{
    VM& vm = lexicalGlobalObject->vm();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto& commonStrings = globalObject->commonStrings();

    JSObject* jwk = JSC::constructEmptyObject(lexicalGlobalObject);

    const auto& pkey = m_data->asymmetricKey;
    const ncrypto::Rsa rsa = pkey;

    auto publicKey = rsa.getPublicKey();

    jwk->putDirect(vm,
        Identifier::fromString(vm, commonStrings.jwkKtyString(lexicalGlobalObject)->value(lexicalGlobalObject)),
        commonStrings.jwkRsaString(lexicalGlobalObject));

    setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkNString(lexicalGlobalObject), publicKey.n);
    RETURN_IF_EXCEPTION(scope, {});
    setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkEString(lexicalGlobalObject), publicKey.e);
    RETURN_IF_EXCEPTION(scope, {});

    if (exportType == CryptoKeyType::Private) {
        auto privateKey = rsa.getPrivateKey();
        setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkDString(lexicalGlobalObject), publicKey.d);
        RETURN_IF_EXCEPTION(scope, {});
        setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkPString(lexicalGlobalObject), privateKey.p);
        RETURN_IF_EXCEPTION(scope, {});
        setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkQString(lexicalGlobalObject), privateKey.q);
        RETURN_IF_EXCEPTION(scope, {});
        setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkDpString(lexicalGlobalObject), privateKey.dp);
        RETURN_IF_EXCEPTION(scope, {});
        setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkDqString(lexicalGlobalObject), privateKey.dq);
        RETURN_IF_EXCEPTION(scope, {});
        setEncodedValue(lexicalGlobalObject, scope, jwk, commonStrings.jwkQiString(lexicalGlobalObject), privateKey.qi);
    }

    return jwk;
}

JSC::JSValue KeyObject::exportJwkSecretKey(JSC::JSGlobalObject* lexicalGlobalObject, JSC::ThrowScope& scope)
{

    VM& vm = lexicalGlobalObject->vm();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto& commonStrings = globalObject->commonStrings();

    JSObject* jwk = JSC::constructEmptyObject(lexicalGlobalObject);

    JSValue encoded = JSValue::decode(StringBytes::encode(lexicalGlobalObject, scope, m_data->symmetricKey, BufferEncodingType::base64url));
    RETURN_IF_EXCEPTION(scope, {});

    jwk->putDirect(vm,
        Identifier::fromString(vm, commonStrings.jwkKtyString(lexicalGlobalObject)->value(lexicalGlobalObject)),
        commonStrings.jwkOctString(lexicalGlobalObject));

    jwk->putDirect(vm,
        Identifier::fromString(vm, commonStrings.jwkKString(lexicalGlobalObject)->value(lexicalGlobalObject)),
        encoded);

    return jwk;
}

JSC::JSValue KeyObject::exportJwkAsymmetricKey(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, CryptoKeyType exportType, bool handleRsaPss)
{
    switch (asymmetricKeyId()) {
    case EVP_PKEY_RSA_PSS: {
        if (handleRsaPss) {
            return exportJwkRsaKey(globalObject, scope, exportType);
        }
        break;
    }

    case EVP_PKEY_RSA:
        return exportJwkRsaKey(globalObject, scope, exportType);

    case EVP_PKEY_EC:
        return exportJwkEcKey(globalObject, scope, exportType);

    case EVP_PKEY_ED25519:
    case EVP_PKEY_ED448:
    case EVP_PKEY_X25519:
    case EVP_PKEY_X448:
        return exportJwkEdKey(globalObject, scope, exportType);
    }

    ERR::CRYPTO_JWK_UNSUPPORTED_KEY_TYPE(scope, globalObject);
    return {};
}

JSC::JSValue KeyObject::exportJwk(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, CryptoKeyType type, bool handleRsaPss)
{
    if (type == CryptoKeyType::Secret) {
        return exportJwkSecretKey(globalObject, scope);
    }

    return exportJwkAsymmetricKey(globalObject, scope, type, handleRsaPss);
}

JSValue toJS(JSGlobalObject* lexicalGlobalObject, ThrowScope& scope, const ncrypto::BIOPointer& bio, const ncrypto::EVPKeyPointer::AsymmetricKeyEncodingConfig& encodingConfig)
{
    VM& vm = lexicalGlobalObject->vm();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    BUF_MEM* bptr = bio;

    if (encodingConfig.format == ncrypto::EVPKeyPointer::PKFormatType::PEM) {
        WTF::String pem = String::fromUTF8({ bptr->data, bptr->length });
        return jsString(vm, pem);
    }

    ASSERT(encodingConfig.format == ncrypto::EVPKeyPointer::PKFormatType::DER);

    RefPtr<ArrayBuffer> buf = JSC::ArrayBuffer::tryCreateUninitialized(bptr->length, 1);
    if (!buf) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    memcpy(buf->data(), bptr->data, bptr->length);

    return JSUint8Array::create(lexicalGlobalObject, globalObject->JSBufferSubclassStructure(), WTF::move(buf), 0, bptr->length);
}

JSC::JSValue KeyObject::exportPublic(JSC::JSGlobalObject* lexicalGlobalObject, JSC::ThrowScope& scope, const ncrypto::EVPKeyPointer::PublicKeyEncodingConfig& config)
{
    VM& vm = lexicalGlobalObject->vm();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    ASSERT(type() != CryptoKeyType::Secret);

    if (config.output_key_object) {
        KeyObject keyObject = *this;
        keyObject.type() = CryptoKeyType::Public;
        Structure* structure = globalObject->m_JSPublicKeyObjectClassStructure.get(lexicalGlobalObject);
        JSPublicKeyObject* publicKey = JSPublicKeyObject::create(vm, structure, lexicalGlobalObject, WTF::move(keyObject));
        return publicKey;
    }

    if (config.format == ncrypto::EVPKeyPointer::PKFormatType::JWK) {
        return exportJwk(lexicalGlobalObject, scope, CryptoKeyType::Public, false);
    }

    if (isRsaPss() && config.type == ncrypto::EVPKeyPointer::PKEncodingType::PKCS1) {
        ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, lexicalGlobalObject, "pkcs1"_s, "can only be used for RSA keys"_s);
        return {};
    }

    if (isRsaPss()) {
        auto bio = writeRsaPssPublicKey(*m_data, config);
        if (!bio) {
            throwCryptoError(lexicalGlobalObject, scope, ERR_peek_error(), "Failed to encode RSA-PSS public key"_s);
            return {};
        }
        return toJS(lexicalGlobalObject, scope, bio, config);
    }

    const ncrypto::EVPKeyPointer& pkey = m_data->asymmetricKey;
    auto res = pkey.writePublicKey(config);
    if (!res) {
        throwCryptoError(lexicalGlobalObject, scope, res.openssl_error.value_or(0), "Failed to encode public key");
        return {};
    }

    return toJS(lexicalGlobalObject, scope, res.value, config);
}

JSValue KeyObject::exportPrivate(JSGlobalObject* lexicalGlobalObject, ThrowScope& scope, const ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig& config)
{
    VM& vm = lexicalGlobalObject->vm();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    ASSERT(type() != CryptoKeyType::Secret);

    if (config.output_key_object) {
        KeyObject keyObject = *this;
        Structure* structure = globalObject->m_JSPrivateKeyObjectClassStructure.get(lexicalGlobalObject);
        JSPrivateKeyObject* privateKey = JSPrivateKeyObject::create(vm, structure, lexicalGlobalObject, WTF::move(keyObject));
        return privateKey;
    }

    if (config.format == ncrypto::EVPKeyPointer::PKFormatType::JWK) {
        return exportJwk(lexicalGlobalObject, scope, CryptoKeyType::Private, false);
    }

    if (isRsaPss() && config.type == ncrypto::EVPKeyPointer::PKEncodingType::PKCS1) {
        ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, lexicalGlobalObject, "pkcs1"_s, "can only be used for RSA keys"_s);
        return {};
    }

    if (isRsaPss()) {
        auto bio = writeRsaPssPrivateKey(*m_data, config);
        if (!bio) {
            throwCryptoError(lexicalGlobalObject, scope, ERR_peek_error(), "Failed to encode RSA-PSS private key"_s);
            return {};
        }
        return toJS(lexicalGlobalObject, scope, bio, config);
    }

    const ncrypto::EVPKeyPointer& pkey = m_data->asymmetricKey;
    auto res = pkey.writePrivateKey(config);
    if (!res) {
        throwCryptoError(lexicalGlobalObject, scope, res.openssl_error.value_or(0), "Failed to encode private key");
        return {};
    }

    return toJS(lexicalGlobalObject, scope, res.value, config);
}

JSValue KeyObject::exportAsymmetric(JSGlobalObject* globalObject, ThrowScope& scope, JSValue optionsValue, CryptoKeyType exportType)
{
    VM& vm = globalObject->vm();

    ASSERT(type() != CryptoKeyType::Secret);

    if (JSObject* options = dynamicDowncast<JSObject>(optionsValue)) {
        JSValue formatValue = options->get(globalObject, Identifier::fromString(vm, "format"_s));
        RETURN_IF_EXCEPTION(scope, {});

        if (formatValue.isString()) {
            auto* formatString = formatValue.toString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            auto formatView = formatString->view(globalObject);
            RETURN_IF_EXCEPTION(scope, {});

            if (formatView == "jwk"_s) {
                if (exportType == CryptoKeyType::Private) {
                    JSValue passphraseValue = options->get(globalObject, Identifier::fromString(vm, "passphrase"_s));
                    RETURN_IF_EXCEPTION(scope, {});
                    if (!passphraseValue.isUndefined()) {
                        ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, globalObject, "jwk"_s, "does not support encryption"_s);
                        return {};
                    }
                }

                return exportJwk(globalObject, scope, exportType, false);
            }
        }

        JSValue keyType = asymmetricKeyType(globalObject);
        if (exportType == CryptoKeyType::Public) {
            ncrypto::EVPKeyPointer::PublicKeyEncodingConfig config;
            parsePublicKeyEncoding(globalObject, scope, options, keyType, WTF::nullStringView(), config);
            RETURN_IF_EXCEPTION(scope, {});
            RELEASE_AND_RETURN(scope, exportPublic(globalObject, scope, config));
        }

        ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig config;
        parsePrivateKeyEncoding(globalObject, scope, options, keyType, WTF::nullStringView(), config);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, exportPrivate(globalObject, scope, config));
    }

    // This would hit validateObject in `parseKeyEncoding`
    ERR::INVALID_ARG_TYPE(scope, globalObject, "options"_s, "object"_s, optionsValue);
    return {};
}

JSValue KeyObject::exportSecret(JSGlobalObject* lexicalGlobalObject, ThrowScope& scope, JSValue optionsValue)
{
    VM& vm = lexicalGlobalObject->vm();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    auto exportBuffer = [this, lexicalGlobalObject, globalObject, &scope]() -> JSValue {
        auto key = symmetricKey();
        auto buf = ArrayBuffer::tryCreateUninitialized(key.size(), 1);
        if (!buf) {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return {};
        }
        memcpy(buf->data(), key.begin(), key.size());
        return JSUint8Array::create(lexicalGlobalObject, globalObject->JSBufferSubclassStructure(), WTF::move(buf), 0, key.size());
    };

    if (!optionsValue.isUndefined()) {
        V::validateObject(scope, lexicalGlobalObject, optionsValue, "options"_s);
        RETURN_IF_EXCEPTION(scope, {});
        JSObject* options = dynamicDowncast<JSObject>(optionsValue);

        JSValue formatValue = options->get(lexicalGlobalObject, Identifier::fromString(vm, "format"_s));
        RETURN_IF_EXCEPTION(scope, {});
        if (!formatValue.isUndefined()) {
            if (formatValue.isString()) {
                auto* formatString = formatValue.toString(lexicalGlobalObject);
                RETURN_IF_EXCEPTION(scope, {});
                auto formatView = formatString->view(lexicalGlobalObject);
                RETURN_IF_EXCEPTION(scope, {});

                if (formatView == "jwk"_s) {
                    return exportJwk(lexicalGlobalObject, scope, CryptoKeyType::Secret, false);
                }

                if (formatView == "buffer"_s) {
                    return exportBuffer();
                }
            }

            ERR::INVALID_ARG_VALUE(scope, lexicalGlobalObject, "options.format"_s, formatValue, "must be one of: undefined, 'buffer', 'jwk'"_s);
            return {};
        }
    }

    return exportBuffer();
}

JSValue KeyObject::asymmetricKeyType(JSGlobalObject* globalObject)
{
    VM& vm = globalObject->vm();

    if (type() == CryptoKeyType::Secret) {
        return jsUndefined();
    }

    switch (asymmetricKeyId()) {
    case EVP_PKEY_RSA:
        return jsNontrivialString(vm, "rsa"_s);
    case EVP_PKEY_RSA_PSS:
        return jsNontrivialString(vm, "rsa-pss"_s);
    case EVP_PKEY_DSA:
        return jsNontrivialString(vm, "dsa"_s);
    case EVP_PKEY_DH:
        return jsNontrivialString(vm, "dh"_s);
    case EVP_PKEY_EC:
        return jsNontrivialString(vm, "ec"_s);
    case EVP_PKEY_ED25519:
        return jsNontrivialString(vm, "ed25519"_s);
    case EVP_PKEY_ED448:
        return jsNontrivialString(vm, "ed448"_s);
    case EVP_PKEY_X25519:
        return jsNontrivialString(vm, "x25519"_s);
    case EVP_PKEY_X448:
        return jsNontrivialString(vm, "x448"_s);
    default:
        return jsUndefined();
    }
}

void KeyObject::getRsaKeyDetails(JSGlobalObject* globalObject, ThrowScope& scope, JSObject* result)
{
    VM& vm = globalObject->vm();

    const auto& pkey = m_data->asymmetricKey;
    const ncrypto::Rsa rsa = pkey;
    if (!rsa) {
        return;
    }

    auto pubKey = rsa.getPublicKey();

    result->putDirect(vm, Identifier::fromString(vm, "modulusLength"_s), jsNumber(ncrypto::BignumPointer::GetBitCount(pubKey.n)));

    auto publicExponentHex = BignumPointer::toHex(pubKey.e);
    if (!publicExponentHex) {
        ERR::CRYPTO_OPERATION_FAILED(scope, globalObject, "Failed to create publicExponent"_s);
        return;
    }

    JSValue publicExponent = JSBigInt::parseInt(globalObject, vm, publicExponentHex.span(), 16, JSBigInt::ErrorParseMode::IgnoreExceptions, JSBigInt::ParseIntSign::Unsigned);
    if (!publicExponent) {
        ERR::CRYPTO_OPERATION_FAILED(scope, globalObject, "Failed to create public exponent"_s);
        return;
    }

    result->putDirect(vm, Identifier::fromString(vm, "publicExponent"_s), publicExponent);

    if (auto metadata = m_data->rsaPssMetadata(); metadata && metadata->digest) {
        auto digestName = String::fromLatin1(OBJ_nid2sn(EVP_MD_type(metadata->digest.get()))).convertToASCIILowercase();
        result->putDirect(vm, Identifier::fromString(vm, "hashAlgorithm"_s), jsString(vm, digestName));

        if (metadata->mgf1Digest) {
            auto mgf1DigestName = String::fromLatin1(OBJ_nid2sn(EVP_MD_type(metadata->mgf1Digest.get()))).convertToASCIILowercase();
            result->putDirect(vm, Identifier::fromString(vm, "mgf1HashAlgorithm"_s), jsString(vm, mgf1DigestName));
        }

        if (metadata->minimumSaltLength >= 0) {
            result->putDirect(vm, Identifier::fromString(vm, "saltLength"_s), jsNumber(metadata->minimumSaltLength));
        }
        return;
    }

    if (pkey.id() == EVP_PKEY_RSA_PSS) {
        auto maybeParams = rsa.getPssParams();
        if (maybeParams.has_value()) {
            auto& params = maybeParams.value();
            result->putDirect(vm, Identifier::fromString(vm, "hashAlgorithm"_s), jsString(vm, params.digest));

            if (params.mgf1_digest.has_value()) {
                auto digest = params.mgf1_digest.value();
                result->putDirect(vm, Identifier::fromString(vm, "mgf1HashAlgorithm"_s), jsString(vm, digest));
            }

            result->putDirect(vm, Identifier::fromString(vm, "saltLength"_s), jsNumber(params.salt_length));
        }
    }
}

void KeyObject::getDsaKeyDetails(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, JSC::JSObject* result)
{
    VM& vm = globalObject->vm();

    const ncrypto::Dsa dsa = m_data->asymmetricKey;
    if (!dsa) {
        return;
    }

    size_t modulusLength = dsa.getModulusLength();
    size_t divisorLength = dsa.getDivisorLength();

    result->putDirect(vm, Identifier::fromString(vm, "modulusLength"_s), jsNumber(modulusLength));
    result->putDirect(vm, Identifier::fromString(vm, "divisorLength"_s), jsNumber(divisorLength));
}

void KeyObject::getEcKeyDetails(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, JSC::JSObject* result)
{
    VM& vm = globalObject->vm();

    const auto& pkey = m_data->asymmetricKey;
    ASSERT(pkey.id() == EVP_PKEY_EC);
    const EC_KEY* ec = pkey;

    const auto group = ncrypto::ECKeyPointer::GetGroup(ec);
    int nid = EC_GROUP_get_curve_name(group);

    String namedCurve = String::fromUTF8(OBJ_nid2sn(nid));

    result->putDirect(vm, Identifier::fromString(vm, "namedCurve"_s), jsString(vm, namedCurve));
}

JSObject* KeyObject::asymmetricKeyDetails(JSGlobalObject* globalObject, ThrowScope& scope)
{
    JSObject* result = JSC::constructEmptyObject(globalObject);

    if (type() == CryptoKeyType::Secret) {
        return result;
    }

    switch (asymmetricKeyId()) {
    case EVP_PKEY_RSA:
    case EVP_PKEY_RSA_PSS:
        getRsaKeyDetails(globalObject, scope, result);
        RETURN_IF_EXCEPTION(scope, {});
        break;
    case EVP_PKEY_DSA:
        getDsaKeyDetails(globalObject, scope, result);
        RETURN_IF_EXCEPTION(scope, {});
        break;
    case EVP_PKEY_EC: {
        getEcKeyDetails(globalObject, scope, result);
        RETURN_IF_EXCEPTION(scope, {});
        break;
    }
    default:
    }

    return result;
}

// returns std::nullopt for "unsupported crypto operation"
std::optional<bool> KeyObject::equals(const KeyObject& other) const
{
    auto thisType = type();
    auto otherType = other.type();
    if (thisType != otherType) {
        return false;
    }

    switch (thisType) {
    case CryptoKeyType::Secret: {
        auto thisKey = symmetricKey().span();
        auto otherKey = other.symmetricKey().span();

        if (thisKey.size() != otherKey.size()) {
            return false;
        }

        return CRYPTO_memcmp(thisKey.data(), otherKey.data(), thisKey.size()) == 0;
    }
    case CryptoKeyType::Public:
    case CryptoKeyType::Private: {
        EVP_PKEY* thisKey = m_data->asymmetricKey.get();
        EVP_PKEY* otherKey = other.m_data->asymmetricKey.get();

        int ok = EVP_PKEY_cmp(thisKey, otherKey);
        if (ok == -2) {
            return std::nullopt;
        }

        return ok == 1;
    }
    }
}

JSValue KeyObject::toCryptoKey(JSGlobalObject* globalObject, ThrowScope& scope, JSValue algorithmValue, JSValue extractableValue, JSValue keyUsagesValue)
{
    return jsUndefined();
}

static std::optional<const Vector<uint8_t>*> getSymmetricKey(const WebCore::CryptoKey& key)
{
    switch (key.keyClass()) {
    case WebCore::CryptoKeyClass::AES:
        return &downcast<CryptoKeyAES>(key).key();
    case WebCore::CryptoKeyClass::HMAC:
        return &downcast<CryptoKeyHMAC>(key).key();
    case WebCore::CryptoKeyClass::Raw:
        return &downcast<CryptoKeyRaw>(key).key();
    default: {
        return std::nullopt;
    }
    }
}

KeyObject KeyObject::create(CryptoKeyType type, RefPtr<KeyObjectData>&& data)
{
    return KeyObject(type, WTF::move(data));
}

WebCore::ExceptionOr<KeyObject> KeyObject::create(WebCore::CryptoKey& key)
{
    // Determine KeyCryptoKeyType and Extract Material
    switch (key.type()) {
    case WebCore::CryptoKeyType::Secret: {
        // Extract symmetric key data
        std::optional<const Vector<uint8_t>*> keyData = getSymmetricKey(key);
        if (!keyData) {
            return WebCore::Exception { WebCore::ExceptionCode::CryptoOperationFailedError, "Failed to extract secret key material"_s };
        }

        WTF::Vector<uint8_t> copy;
        copy.appendVector(*keyData.value());
        return create(WTF::move(copy));
    }

    case WebCore::CryptoKeyType::Public: {
        // Extract asymmetric public key data
        AsymmetricKeyValue keyValue(key);
        if (!keyValue.key) {
            return WebCore::Exception { WebCore::ExceptionCode::CryptoOperationFailedError, "Failed to extract public key material"_s };
        }

        // Increment ref count because KeyObject will own a reference
        EVP_PKEY_up_ref(keyValue.key);
        ncrypto::EVPKeyPointer keyPtr(keyValue.key);

        return create(CryptoKeyType::Public, WTF::move(keyPtr));
    }

    case WebCore::CryptoKeyType::Private: {
        // Extract asymmetric private key data
        AsymmetricKeyValue keyValue(key);
        if (!keyValue.key) {
            return WebCore::Exception { WebCore::ExceptionCode::CryptoOperationFailedError, "Failed to extract private key material"_s };
        }

        // Increment ref count because KeyObject will own a reference
        EVP_PKEY_up_ref(keyValue.key);
        ncrypto::EVPKeyPointer keyPtr(keyValue.key);

        return create(CryptoKeyType::Private, WTF::move(keyPtr));
    }
    }

    return WebCore::Exception { WebCore::ExceptionCode::CryptoOperationFailedError, "Unknown key type"_s };
}

KeyObject KeyObject::create(WTF::Vector<uint8_t>&& symmetricKey)
{
    RefPtr<KeyObjectData> data = KeyObjectData::create(WTF::move(symmetricKey));
    return KeyObject(CryptoKeyType::Secret, WTF::move(data));
}

KeyObject KeyObject::create(CryptoKeyType type, ncrypto::EVPKeyPointer&& asymmetricKey)
{
    RefPtr<KeyObjectData> data = KeyObjectData::create(WTF::move(asymmetricKey));
    return KeyObject(type, WTF::move(data));
}

void KeyObject::getKeyObjectFromHandle(JSGlobalObject* globalObject, ThrowScope& scope, JSValue keyValue, const KeyObject& handle, PrepareAsymmetricKeyMode mode)
{
    if (mode == PrepareAsymmetricKeyMode::CreatePrivate) {
        ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string, ArrayBuffer, Buffer, TypedArray, or DataView"_s, keyValue);
        return;
    }

    if (handle.type() != CryptoKeyType::Private) {
        if (mode == PrepareAsymmetricKeyMode::ConsumePrivate || mode == PrepareAsymmetricKeyMode::CreatePublic) {
            ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, handle.type(), "private"_s);
            return;
        }
        if (handle.type() != CryptoKeyType::Public) {
            ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, handle.type(), "private or public"_s);
            return;
        }
    }
}

JSArrayBufferView* decodeJwkString(JSGlobalObject* globalObject, ThrowScope& scope, GCOwnedDataScope<WTF::StringView> strView, ASCIILiteral keyName)
{
    JSValue decoded = JSValue::decode(constructFromEncoding(globalObject, strView, BufferEncodingType::base64));
    RETURN_IF_EXCEPTION(scope, {});
    auto* decodedBuf = dynamicDowncast<JSArrayBufferView>(decoded);
    if (!decodedBuf) {
        ERR::INVALID_ARG_TYPE(scope, globalObject, keyName, "string"_s, decoded);
        return {};
    }
    return decodedBuf;
}

JSValue getJwkString(JSGlobalObject* globalObject, ThrowScope& scope, JSObject* jwk, ASCIILiteral propName, ASCIILiteral keyName)
{
    JSValue value = jwk->get(globalObject, Identifier::fromString(globalObject->vm(), propName));
    RETURN_IF_EXCEPTION(scope, {});
    V::validateString(scope, globalObject, value, keyName);
    RETURN_IF_EXCEPTION(scope, {});
    return value;
}

GCOwnedDataScope<WTF::StringView> getJwkStringView(JSGlobalObject* globalObject, ThrowScope& scope, JSObject* jwk, ASCIILiteral propName, ASCIILiteral keyName)
{
    JSValue value = getJwkString(globalObject, scope, jwk, propName, keyName);
    RETURN_IF_EXCEPTION(scope, GCOwnedDataScope<WTF::StringView>(nullptr, WTF::nullStringView()));
    auto* str = value.toString(globalObject);
    RETURN_IF_EXCEPTION(scope, GCOwnedDataScope<WTF::StringView>(nullptr, WTF::nullStringView()));
    auto strView = str->view(globalObject);
    RETURN_IF_EXCEPTION(scope, GCOwnedDataScope<WTF::StringView>(nullptr, WTF::nullStringView()));
    return strView;
}

JSArrayBufferView* getDecodedJwkStringBuf(JSGlobalObject* globalObject, ThrowScope& scope, JSObject* jwk, ASCIILiteral propName, ASCIILiteral keyName)
{
    auto strView = getJwkStringView(globalObject, scope, jwk, propName, keyName);
    RETURN_IF_EXCEPTION(scope, {});

    auto* dataBuf = decodeJwkString(globalObject, scope, strView, keyName);
    RETURN_IF_EXCEPTION(scope, {});

    return dataBuf;
}

inline BignumPointer jwkBufToBn(JSArrayBufferView* buf)
{
    return BignumPointer(reinterpret_cast<uint8_t*>(buf->vector()), buf->byteLength());
}

KeyObject KeyObject::getKeyObjectHandleFromJwk(JSGlobalObject* globalObject, ThrowScope& scope, JSObject* jwk, PrepareAsymmetricKeyMode mode)
{
    auto ktyView = getJwkStringView(globalObject, scope, jwk, "kty"_s, "key.kty"_s);
    RETURN_IF_EXCEPTION(scope, {});

    enum class Kty {
        Rsa,
        Ec,
        Okp,
    };

    Kty kty;
    if (ktyView == "RSA"_s) {
        kty = Kty::Rsa;
    } else if (ktyView == "EC"_s) {
        kty = Kty::Ec;
    } else if (ktyView == "OKP"_s) {
        kty = Kty::Okp;
    } else {
        // validateOneOf
        ERR::INVALID_ARG_VALUE(scope, globalObject, "key.kty"_s, ktyView.owner, "must be one of: 'RSA', 'EC', 'OKP'"_s);
        return {};
    }

    CryptoKeyType keyType = mode == PrepareAsymmetricKeyMode::ConsumePublic || mode == PrepareAsymmetricKeyMode::CreatePublic
        ? CryptoKeyType::Public
        : CryptoKeyType::Private;

    switch (kty) {
    case Kty::Okp: {
        auto crvView = getJwkStringView(globalObject, scope, jwk, "crv"_s, "key.crv"_s);
        RETURN_IF_EXCEPTION(scope, {});

        int nid;
        if (crvView == "Ed25519"_s) {
            nid = EVP_PKEY_ED25519;
        } else if (crvView == "Ed448"_s) {
            nid = EVP_PKEY_ED448;
        } else if (crvView == "X25519"_s) {
            nid = EVP_PKEY_X25519;
        } else if (crvView == "X448"_s) {
            nid = EVP_PKEY_X448;
        } else {
            // validateOneOf
            ERR::INVALID_ARG_VALUE(scope, globalObject, "key.crv"_s, crvView.owner, "must be one of: 'Ed25519', 'Ed448', 'X25519', 'X448'"_s);
            return {};
        }

        auto xView = getJwkStringView(globalObject, scope, jwk, "x"_s, "key.x"_s);
        RETURN_IF_EXCEPTION(scope, {});

        GCOwnedDataScope<WTF::StringView> dView = GCOwnedDataScope<WTF::StringView>(nullptr, WTF::nullStringView());

        if (keyType != CryptoKeyType::Public) {
            dView = getJwkStringView(globalObject, scope, jwk, "d"_s, "key.d"_s);
            RETURN_IF_EXCEPTION(scope, {});
        }

        auto dataView = keyType == CryptoKeyType::Public ? xView : dView;

        auto* dataBuf = decodeJwkString(globalObject, scope, dataView, "key.x"_s);
        RETURN_IF_EXCEPTION(scope, {});
        auto bufSpan = dataBuf->span();

        switch (nid) {
        case EVP_PKEY_ED25519:
        case EVP_PKEY_X25519:
            if (bufSpan.size() != 32) {
                ERR::CRYPTO_INVALID_JWK(scope, globalObject);
                return {};
            }
            break;
        case EVP_PKEY_ED448:
            if (bufSpan.size() != 57) {
                ERR::CRYPTO_INVALID_JWK(scope, globalObject);
                return {};
            }
            break;
        case EVP_PKEY_X448:
            if (bufSpan.size() != 56) {
                ERR::CRYPTO_INVALID_JWK(scope, globalObject);
                return {};
            }
            break;
        }

        MarkPopErrorOnReturn markPopError;

        auto buf = ncrypto::Buffer {
            .data = bufSpan.data(),
            .len = bufSpan.size(),
        };

        auto key = keyType == CryptoKeyType::Public
            ? EVPKeyPointer::NewRawPublic(nid, buf)
            : EVPKeyPointer::NewRawPrivate(nid, buf);

        if (!key) {
            ERR::CRYPTO_INVALID_JWK(scope, globalObject);
            return {};
        }

        return create(keyType, WTF::move(key));
    }
    case Kty::Ec: {
        auto crvView = getJwkStringView(globalObject, scope, jwk, "crv"_s, "key.crv"_s);
        RETURN_IF_EXCEPTION(scope, {});

        if (crvView != "P-256"_s && crvView != "secp256k1"_s && crvView != "P-384"_s && crvView != "P-521"_s) {
            // validateOneOf
            ERR::INVALID_ARG_VALUE(scope, globalObject, "key.crv"_s, crvView.owner, "must be one of: 'P-256', 'secp256k1', 'P-384', 'P-521'"_s);
            return {};
        }

        auto xView = getJwkStringView(globalObject, scope, jwk, "x"_s, "key.x"_s);
        RETURN_IF_EXCEPTION(scope, {});
        auto yView = getJwkStringView(globalObject, scope, jwk, "y"_s, "key.y"_s);
        RETURN_IF_EXCEPTION(scope, {});

        GCOwnedDataScope<WTF::StringView> dView = GCOwnedDataScope<WTF::StringView>(nullptr, WTF::nullStringView());

        if (keyType != CryptoKeyType::Public) {
            dView = getJwkStringView(globalObject, scope, jwk, "d"_s, "key.d"_s);
            RETURN_IF_EXCEPTION(scope, {});
        }

        MarkPopErrorOnReturn markPopError;

        auto crvUtf8 = crvView->utf8();
        int nid = Ec::GetCurveIdFromName(crvUtf8.data());
        if (nid == NID_undef) {
            ERR::CRYPTO_INVALID_CURVE(scope, globalObject);
            return {};
        }

        auto ec = ECKeyPointer::NewByCurveName(nid);
        if (!ec) {
            ERR::CRYPTO_INVALID_JWK(scope, globalObject);
            return {};
        }

        auto* xBuf = decodeJwkString(globalObject, scope, xView, "key.x"_s);
        RETURN_IF_EXCEPTION(scope, {});
        auto* yBuf = decodeJwkString(globalObject, scope, yView, "key.y"_s);
        RETURN_IF_EXCEPTION(scope, {});

        if (!ec.setPublicKeyRaw(jwkBufToBn(xBuf), jwkBufToBn(yBuf))) {
            ERR::CRYPTO_INVALID_JWK(scope, globalObject, "Invalid JWK EC key"_s);
            return {};
        }

        if (keyType != CryptoKeyType::Public) {
            auto* dBuf = decodeJwkString(globalObject, scope, dView, "key.d"_s);
            auto dBufSpan = dBuf->span();
            BignumPointer dBn = BignumPointer(dBufSpan.data(), dBufSpan.size());
            if (!ec.setPrivateKey(dBn)) {
                ERR::CRYPTO_INVALID_JWK(scope, globalObject, "Invalid JWK EC key"_s);
                return {};
            }
        }

        auto key = EVPKeyPointer::New();
        key.set(ec);

        return create(keyType, WTF::move(key));
    }
    case Kty::Rsa: {
        auto nView = getJwkStringView(globalObject, scope, jwk, "n"_s, "key.n"_s);
        RETURN_IF_EXCEPTION(scope, {});
        auto eView = getJwkStringView(globalObject, scope, jwk, "e"_s, "key.e"_s);
        RETURN_IF_EXCEPTION(scope, {});

        auto* nBuf = decodeJwkString(globalObject, scope, nView, "key.n"_s);
        RETURN_IF_EXCEPTION(scope, {});
        auto* eBuf = decodeJwkString(globalObject, scope, eView, "key.e"_s);
        RETURN_IF_EXCEPTION(scope, {});

        RSAPointer rsa(RSA_new());
        Rsa rsaView(rsa.get());

        if (!rsaView.setPublicKey(jwkBufToBn(nBuf), jwkBufToBn(eBuf))) {
            ERR::CRYPTO_INVALID_JWK(scope, globalObject, "Invalid JWK RSA key"_s);
            return {};
        }

        if (keyType == CryptoKeyType::Private) {
            auto* dBuf = getDecodedJwkStringBuf(globalObject, scope, jwk, "d"_s, "key.d"_s);
            RETURN_IF_EXCEPTION(scope, {});
            auto* pBuf = getDecodedJwkStringBuf(globalObject, scope, jwk, "p"_s, "key.p"_s);
            RETURN_IF_EXCEPTION(scope, {});
            auto* qBuf = getDecodedJwkStringBuf(globalObject, scope, jwk, "q"_s, "key.q"_s);
            RETURN_IF_EXCEPTION(scope, {});
            auto* dpBuf = getDecodedJwkStringBuf(globalObject, scope, jwk, "dp"_s, "key.dp"_s);
            RETURN_IF_EXCEPTION(scope, {});
            auto* dqBuf = getDecodedJwkStringBuf(globalObject, scope, jwk, "dq"_s, "key.dq"_s);
            RETURN_IF_EXCEPTION(scope, {});
            auto* qiBuf = getDecodedJwkStringBuf(globalObject, scope, jwk, "qi"_s, "key.qi"_s);
            RETURN_IF_EXCEPTION(scope, {});

            if (!rsaView.setPrivateKey(
                    jwkBufToBn(dBuf),
                    jwkBufToBn(qBuf),
                    jwkBufToBn(pBuf),
                    jwkBufToBn(dpBuf),
                    jwkBufToBn(dqBuf),
                    jwkBufToBn(qiBuf))) {
                ERR::CRYPTO_INVALID_JWK(scope, globalObject, "Invalid JWK RSA key"_s);
                return {};
            }
        }

        auto key = EVPKeyPointer::NewRSA(WTF::move(rsa));
        return create(keyType, WTF::move(key));
    }
    }

    UNREACHABLE();
}

void KeyObject::getKeyFormatAndType(
    EVPKeyPointer::PKFormatType formatType,
    std::optional<EVPKeyPointer::PKEncodingType> encodingType,
    KeyEncodingContext ctx,
    EVPKeyPointer::AsymmetricKeyEncodingConfig& config)
{
    // if (!formatType) {
    //     ASSERT(ctx == KeyEncodingContext::Generate);
    //     config.output_key_object = true;
    // } else {
    config.output_key_object = false;

    config.format = formatType;

    if (encodingType) {
        config.type = *encodingType;
    } else {
        ASSERT((ctx == KeyEncodingContext::Input && config.format == EVPKeyPointer::PKFormatType::PEM)
            || (ctx == KeyEncodingContext::Generate && config.format == EVPKeyPointer::PKFormatType::JWK));
        config.type = EVPKeyPointer::PKEncodingType::PKCS1;
    }
    // }
}

EVPKeyPointer::PrivateKeyEncodingConfig KeyObject::getPrivateKeyEncoding(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    EVPKeyPointer::PKFormatType formatType,
    std::optional<EVPKeyPointer::PKEncodingType> encodingType,
    const EVP_CIPHER* cipher,
    std::optional<DataPointer> passphrase,
    KeyEncodingContext ctx)
{
    EVPKeyPointer::PrivateKeyEncodingConfig config;
    getKeyFormatAndType(formatType, encodingType, ctx, config);

    if (config.output_key_object) {
        // TODO: make sure this case for key generation is handled
    } else {
        if (ctx != KeyEncodingContext::Input) {
            config.cipher = cipher;
        }

        if (passphrase) {
            config.passphrase = WTF::move(*passphrase);
        }
    }

    return config;
}

// KeyObjectHandle::init for public and private keys
KeyObject KeyObject::getPublicOrPrivateKey(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    std::span<const uint8_t> keyData,
    CryptoKeyType keyType,
    EVPKeyPointer::PKFormatType formatType,
    std::optional<EVPKeyPointer::PKEncodingType> encodingType,
    const EVP_CIPHER* cipher,
    std::optional<DataPointer> passphrase)
{
    auto buf = ncrypto::Buffer<const uint8_t> {
        .data = reinterpret_cast<const uint8_t*>(keyData.data()),
        .len = keyData.size(),
    };

    if (keyType == CryptoKeyType::Private) {
        auto config = getPrivateKeyEncoding(
            globalObject,
            scope,
            formatType,
            encodingType,
            cipher,
            WTF::move(passphrase),
            KeyEncodingContext::Input);
        RETURN_IF_EXCEPTION(scope, {});

        auto rsaPssResult = tryParseRsaPssKey(config, buf, true);
        if (rsaPssResult.status == RsaPssParseStatus::Success) {
            return create(CryptoKeyType::Private, WTF::move(rsaPssResult.keyData));
        }
        if (rsaPssResult.status == RsaPssParseStatus::Invalid) {
            throwCryptoError(globalObject, scope, ERR_peek_error(), "Failed to read RSA-PSS private key"_s);
            return {};
        }

        auto res = EVPKeyPointer::TryParsePrivateKey(config, buf);
        if (res) {
            return create(CryptoKeyType::Private, WTF::move(res.value));
        }

        if (res.error.value() == EVPKeyPointer::PKParseError::NEED_PASSPHRASE) {
            ERR::MISSING_PASSPHRASE(scope, globalObject, "Passphrase required for encrypted key"_s);
        } else {
            throwCryptoError(globalObject, scope, res.openssl_error.value_or(0), "Failed to read private key"_s);
        }
        return {};
    }

    if (buf.len > INT_MAX) {
        ERR::OUT_OF_RANGE(scope, globalObject, "keyData is too big"_s);
        return {};
    }

    auto config = getPrivateKeyEncoding(
        globalObject,
        scope,
        formatType,
        encodingType,
        cipher,
        WTF::move(passphrase),
        KeyEncodingContext::Input);
    RETURN_IF_EXCEPTION(scope, {});

    auto rsaPssResult = tryParseRsaPssKey(config, buf, false);
    if (rsaPssResult.status == RsaPssParseStatus::Success) {
        return create(CryptoKeyType::Public, WTF::move(rsaPssResult.keyData));
    }
    if (rsaPssResult.status == RsaPssParseStatus::Invalid) {
        throwCryptoError(globalObject, scope, ERR_peek_error(), "Failed to read RSA-PSS key"_s);
        return {};
    }

    if (config.format == EVPKeyPointer::PKFormatType::PEM) {
        auto publicRes = EVPKeyPointer::TryParsePublicKeyPEM(buf);
        if (publicRes) {
            return create(CryptoKeyType::Public, WTF::move(publicRes.value));
        }

        if (publicRes.error.value() == EVPKeyPointer::PKParseError::NOT_RECOGNIZED) {
            auto privateRes = EVPKeyPointer::TryParsePrivateKey(config, buf);
            if (privateRes) {
                return create(CryptoKeyType::Public, WTF::move(privateRes.value));
            }

            if (privateRes.error.value() == EVPKeyPointer::PKParseError::NEED_PASSPHRASE) {
                ERR::MISSING_PASSPHRASE(scope, globalObject, "Passphrase required for encrypted key"_s);
            } else {
                throwCryptoError(globalObject, scope, privateRes.openssl_error.value_or(0), "Failed to read private key"_s);
            }
            return {};
        }

        throwCryptoError(globalObject, scope, publicRes.openssl_error.value_or(0), "Failed to read asymmetric key"_s);
        return {};
    }

    static const auto isPublic = [](const auto& config, const auto& buffer) -> bool {
        switch (config.type) {
        case EVPKeyPointer::PKEncodingType::PKCS1:
            return !EVPKeyPointer::IsRSAPrivateKey(buffer);
        case EVPKeyPointer::PKEncodingType::SPKI:
            return true;
        case EVPKeyPointer::PKEncodingType::PKCS8:
            return false;
        case EVPKeyPointer::PKEncodingType::SEC1:
            return false;
        default:
            return false;
        }
    };

    if (isPublic(config, buf)) {
        auto res = EVPKeyPointer::TryParsePublicKey(config, buf);
        if (res) {
            return create(CryptoKeyType::Public, WTF::move(res.value));
        }

        throwCryptoError(globalObject, scope, res.openssl_error.value_or(0), "Failed to read asymmetric key"_s);
        return {};
    }

    auto res = EVPKeyPointer::TryParsePrivateKey(config, buf);
    if (res) {
        return create(CryptoKeyType::Private, WTF::move(res.value));
    }

    if (res.error.value() == EVPKeyPointer::PKParseError::NEED_PASSPHRASE) {
        ERR::MISSING_PASSPHRASE(scope, globalObject, "Passphrase required for encrypted key"_s);
    } else {
        throwCryptoError(globalObject, scope, res.openssl_error.value_or(0), "Failed to read asymmetric key"_s);
    }
    return {};
}

KeyObject::PrepareAsymmetricKeyResult KeyObject::prepareAsymmetricKey(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, JSC::JSValue keyValue, PrepareAsymmetricKeyMode mode)
{
    VM& vm = globalObject->vm();

    auto checkKeyObject = [globalObject, &scope, mode](const KeyObject& keyObject, JSValue keyValue) -> void {
        if (mode == PrepareAsymmetricKeyMode::CreatePrivate) {
            ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string, ArrayBuffer, Buffer, TypedArray, or DataView"_s, keyValue);
            return;
        }

        if (keyObject.type() != CryptoKeyType::Private) {
            if (mode == PrepareAsymmetricKeyMode::ConsumePrivate || mode == PrepareAsymmetricKeyMode::CreatePublic) {
                ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, keyObject.type(), "private"_s);
                return;
            }
            if (keyObject.type() != CryptoKeyType::Public) {
                ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, keyObject.type(), "private or public"_s);
                return;
            }
        }
    };

    auto checkCryptoKey = [globalObject, &scope, mode](const CryptoKey& cryptoKey, JSValue keyValue) -> void {
        if (mode == PrepareAsymmetricKeyMode::CreatePrivate) {
            ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string, ArrayBuffer, Buffer, TypedArray, or DataView"_s, keyValue);
            return;
        }

        if (cryptoKey.type() != CryptoKeyType::Private) {
            if (mode == PrepareAsymmetricKeyMode::ConsumePrivate || mode == PrepareAsymmetricKeyMode::CreatePublic) {
                ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, cryptoKey.type(), "private"_s);
                return;
            }
            if (cryptoKey.type() != CryptoKeyType::Public) {
                ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, cryptoKey.type(), "private or public"_s);
                return;
            }
        }
    };

    if (JSKeyObject* keyObject = dynamicDowncast<JSKeyObject>(keyValue)) {
        auto& handle = keyObject->handle();
        checkKeyObject(handle, keyValue);
        RETURN_IF_EXCEPTION(scope, {});
        return { .keyData = handle.data() };
    }

    if (JSCryptoKey* cryptoKey = dynamicDowncast<JSCryptoKey>(keyValue)) {
        auto& key = cryptoKey->wrapped();
        checkCryptoKey(key, keyValue);
        RETURN_IF_EXCEPTION(scope, {});

        auto keyObject = create(key);
        if (keyObject.hasException()) [[unlikely]] {
            WebCore::propagateException(*globalObject, scope, keyObject.releaseException());
            RELEASE_AND_RETURN(scope, {});
        }
        KeyObject handle = keyObject.releaseReturnValue();
        RETURN_IF_EXCEPTION(scope, {});
        return { .keyData = handle.data() };
    }

    { // pem format
        if (keyValue.isString()) {
            auto* keyString = keyValue.toString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            auto keyView = keyString->view(globalObject);
            RETURN_IF_EXCEPTION(scope, {});

            JSValue decoded = JSValue::decode(constructFromEncoding(globalObject, keyView, BufferEncodingType::utf8));
            RETURN_IF_EXCEPTION(scope, {});

            auto* decodedBuf = dynamicDowncast<JSArrayBufferView>(decoded);
            if (!decodedBuf) {
                ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string"_s, decoded);
                return {};
            }

            return {
                .keyDataView = { decodedBuf, decodedBuf->span() },
                .formatType = EVPKeyPointer::PKFormatType::PEM,
            };
        }

        if (auto* view = dynamicDowncast<JSArrayBufferView>(keyValue)) {
            return {
                .keyDataView = { view, view->span() },
                .formatType = EVPKeyPointer::PKFormatType::PEM,
            };
        }

        if (auto* arrayBuffer = dynamicDowncast<JSArrayBuffer>(keyValue)) {
            auto* buffer = arrayBuffer->impl();
            return {
                .keyDataView = { arrayBuffer, buffer->span() },
                .formatType = EVPKeyPointer::PKFormatType::PEM,
            };
        }
    }

    if (JSObject* keyObj = dynamicDowncast<JSObject>(keyValue)) {
        JSValue dataValue = keyObj->get(globalObject, Identifier::fromString(vm, "key"_s));
        RETURN_IF_EXCEPTION(scope, {});
        JSValue encodingValue = keyObj->get(globalObject, Identifier::fromString(vm, "encoding"_s));
        RETURN_IF_EXCEPTION(scope, {});
        JSValue formatValue = keyObj->get(globalObject, Identifier::fromString(vm, "format"_s));
        RETURN_IF_EXCEPTION(scope, {});

        if (JSKeyObject* keyObject = dynamicDowncast<JSKeyObject>(dataValue)) {
            auto& handle = keyObject->handle();
            checkKeyObject(handle, dataValue);
            RETURN_IF_EXCEPTION(scope, {});
            return { .keyData = handle.data() };
        }

        if (JSCryptoKey* cryptoKey = dynamicDowncast<JSCryptoKey>(dataValue)) {
            auto& key = cryptoKey->wrapped();
            checkCryptoKey(key, dataValue);
            RETURN_IF_EXCEPTION(scope, {});

            auto keyObject = create(key);
            if (keyObject.hasException()) [[unlikely]] {
                WebCore::propagateException(*globalObject, scope, keyObject.releaseException());
                RELEASE_AND_RETURN(scope, {});
            }
            KeyObject handle = keyObject.releaseReturnValue();
            return { .keyData = handle.data() };
        }

        auto* formatString = formatValue.toString(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
        auto formatView = formatString->view(globalObject);
        RETURN_IF_EXCEPTION(scope, {});

        if (formatView == "jwk"_s) {
            V::validateObject(scope, globalObject, dataValue, "key.key"_s);
            RETURN_IF_EXCEPTION(scope, {});
            JSObject* jwk = dataValue.getObject();
            KeyObject handle = getKeyObjectHandleFromJwk(globalObject, scope, jwk, mode);
            RETURN_IF_EXCEPTION(scope, {});
            return { .keyData = handle.data() };
        }

        std::optional<bool> isPublic = mode == PrepareAsymmetricKeyMode::ConsumePrivate || mode == PrepareAsymmetricKeyMode::CreatePrivate
            ? std::optional<bool>(false)
            : std::nullopt;

        if (dataValue.isString()) {
            auto* dataString = dataValue.toString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            auto dataView = dataString->view(globalObject);
            RETURN_IF_EXCEPTION(scope, {});

            BufferEncodingType encoding = BufferEncodingType::utf8;
            if (encodingValue.isString()) {
                auto* encodingString = encodingValue.toString(globalObject);
                RETURN_IF_EXCEPTION(scope, {});
                auto encodingView = encodingString->view(globalObject);
                RETURN_IF_EXCEPTION(scope, {});

                if (encodingView != "buffer"_s) {
                    encoding = parseEnumerationFromView<BufferEncodingType>(encodingView).value_or(BufferEncodingType::utf8);
                    RETURN_IF_EXCEPTION(scope, {});
                }
            }

            JSValue decoded = JSValue::decode(constructFromEncoding(globalObject, dataView, encoding));
            RETURN_IF_EXCEPTION(scope, {});
            if (auto* decodedView = dynamicDowncast<JSArrayBufferView>(decoded)) {
                EVPKeyPointer::PrivateKeyEncodingConfig config;
                parseKeyEncoding(globalObject, scope, keyObj, jsUndefined(), isPublic, WTF::nullStringView(), config);
                RETURN_IF_EXCEPTION(scope, {});

                return {
                    .keyDataView = { decodedView, decodedView->span() },
                    .formatType = config.format,
                    .encodingType = config.type,
                    .cipher = config.cipher,
                    .passphrase = WTF::move(config.passphrase),
                };
            }
        }

        if (auto* view = dynamicDowncast<JSArrayBufferView>(dataValue)) {
            auto buffer = view->span();

            EVPKeyPointer::PrivateKeyEncodingConfig config;
            parseKeyEncoding(globalObject, scope, keyObj, jsUndefined(), isPublic, WTF::nullStringView(), config);
            RETURN_IF_EXCEPTION(scope, {});

            return {
                .keyDataView = { view, buffer },
                .formatType = config.format,
                .encodingType = config.type,
                .cipher = config.cipher,
                .passphrase = WTF::move(config.passphrase),
            };
        }

        if (auto* arrayBuffer = dynamicDowncast<JSArrayBuffer>(dataValue)) {
            auto* buffer = arrayBuffer->impl();
            auto data = buffer->span();

            EVPKeyPointer::PrivateKeyEncodingConfig config;
            parseKeyEncoding(globalObject, scope, keyObj, jsUndefined(), isPublic, WTF::nullStringView(), config);
            RETURN_IF_EXCEPTION(scope, {});

            return {
                .keyDataView = { arrayBuffer, data },
                .formatType = config.format,
                .encodingType = config.type,
                .cipher = config.cipher,
                .passphrase = WTF::move(config.passphrase),
            };
        }

        if (mode != PrepareAsymmetricKeyMode::CreatePrivate) {
            ERR::INVALID_ARG_TYPE(scope, globalObject, "key.key"_s, "string or an instance of ArrayBuffer, Buffer, TypedArray, DataView, KeyObject, or CryptoKey"_s, dataValue);
        } else {
            ERR::INVALID_ARG_TYPE(scope, globalObject, "key.key"_s, "string or an instance of ArrayBuffer, Buffer, TypedArray, or DataView"_s, dataValue);
        }
        return {};
    }

    if (mode != PrepareAsymmetricKeyMode::CreatePrivate) {
        ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string or an instance of ArrayBuffer, Buffer, TypedArray, DataView, KeyObject, or CryptoKey"_s, keyValue);
    } else {
        ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string or an instance of ArrayBuffer, Buffer, TypedArray, or DataView"_s, keyValue);
    }

    return {};
}

KeyObject::PrepareAsymmetricKeyResult KeyObject::preparePrivateKey(JSGlobalObject* globalObject, ThrowScope& scope, JSValue keyValue)
{
    return prepareAsymmetricKey(globalObject, scope, keyValue, PrepareAsymmetricKeyMode::ConsumePrivate);
}

KeyObject::PrepareAsymmetricKeyResult KeyObject::preparePublicOrPrivateKey(JSGlobalObject* globalObject, ThrowScope& scope, JSValue keyValue)
{
    return prepareAsymmetricKey(globalObject, scope, keyValue, PrepareAsymmetricKeyMode::ConsumePublic);
}

KeyObject KeyObject::prepareSecretKey(JSGlobalObject* globalObject, ThrowScope& scope, JSValue keyValue, JSValue encodingValue, bool bufferOnly)
{
    if (!bufferOnly) {
        if (JSKeyObject* keyObject = dynamicDowncast<JSKeyObject>(keyValue)) {
            auto& handle = keyObject->handle();
            if (handle.type() != CryptoKeyType::Secret) {
                ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, handle.type(), "secret"_s);
                return {};
            }
            return handle;
        } else if (JSCryptoKey* cryptoKey = dynamicDowncast<JSCryptoKey>(keyValue)) {
            auto& key = cryptoKey->wrapped();
            if (key.type() != CryptoKeyType::Secret) {
                ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, key.type(), "secret"_s);
                return {};
            }
            auto keyObject = create(key);
            if (keyObject.hasException()) [[unlikely]] {
                WebCore::propagateException(globalObject, scope, keyObject.releaseException());
                return {};
            }
            return keyObject.releaseReturnValue();
        }
    }

    if (keyValue.isString()) {
        auto* keyString = keyValue.toString(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
        auto keyView = keyString->view(globalObject);
        RETURN_IF_EXCEPTION(scope, {});

        BufferEncodingType encoding = parseEnumerationAllowBuffer(*globalObject, encodingValue).value_or(BufferEncodingType::utf8);
        RETURN_IF_EXCEPTION(scope, {});

        JSValue buffer = JSValue::decode(constructFromEncoding(globalObject, keyView, encoding));
        RETURN_IF_EXCEPTION(scope, {});

        if (buffer.isEmpty()) {
            // Both this exception and the one below should be unreachable, but constructFromEncoding doesn't
            // guarentee that it will always return a valid buffer.
            ERR::INVALID_ARG_VALUE(scope, globalObject, "encoding"_s, keyValue, "must be a valid encoding"_s);
            return {};
        }

        auto* view = dynamicDowncast<JSArrayBufferView>(buffer);
        if (!view) {
            ERR::INVALID_ARG_VALUE(scope, globalObject, "encoding"_s, keyValue, "must be a valid encoding"_s);
            return {};
        }

        Vector<uint8_t> copy;
        copy.append(view->span());
        return create(WTF::move(copy));
    }

    // TODO(dylan-conway): avoid copying by keeping the buffer alive
    if (auto* view = dynamicDowncast<JSArrayBufferView>(keyValue)) {
        Vector<uint8_t> copy;
        copy.append(view->span());
        return create(WTF::move(copy));
    }

    // TODO(dylan-conway): avoid copying by keeping the buffer alive
    if (auto* arrayBuffer = dynamicDowncast<JSArrayBuffer>(keyValue)) {
        auto* impl = arrayBuffer->impl();
        Vector<uint8_t> copy;
        copy.append(impl->span());
        return create(WTF::move(copy));
    }

    if (bufferOnly) {
        ERR::INVALID_ARG_INSTANCE(scope, globalObject, "key"_s, "ArrayBuffer, Buffer, TypedArray, or DataView"_s, keyValue);
    } else {
        ERR::INVALID_ARG_TYPE(scope, globalObject, "key"_s, "string or an instance of ArrayBuffer, Buffer, TypedArray, DataView, KeyObject, or CryptoKey"_s, keyValue);
    }

    return {};
}
}
