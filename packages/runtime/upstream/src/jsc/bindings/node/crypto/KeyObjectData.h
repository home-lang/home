#pragma once

#include "root.h"
#include "ncrypto.h"
#include "CryptoKeyType.h"

namespace Bun {
struct RsaPssMetadata {
    ncrypto::Digest digest;
    ncrypto::Digest mgf1Digest;
    int32_t minimumSaltLength = -1;
};
}

struct KeyObjectData : ThreadSafeRefCounted<KeyObjectData> {
    WTF_MAKE_TZONE_ALLOCATED(KeyObjectData);

    KeyObjectData(WTF::Vector<uint8_t>&& symmetricKey)
        : symmetricKey(WTF::move(symmetricKey))
    {
    }

    KeyObjectData(ncrypto::EVPKeyPointer&& asymmetricKey)
        : asymmetricKey(WTF::move(asymmetricKey))
    {
    }

public:
    ~KeyObjectData() = default;

    void setRsaPssMetadata(ncrypto::Digest digest, ncrypto::Digest mgf1Digest, int32_t minimumSaltLength)
    {
        struct Storage {
            uint64_t magic;
            const EVP_MD* digest;
            const EVP_MD* mgf1Digest;
            int32_t minimumSaltLength;
        } storage { 0x48524b5053530001, digest.get(), mgf1Digest.get(), minimumSaltLength };
        symmetricKey.grow(sizeof(storage));
        memcpy(symmetricKey.mutableSpan().data(), &storage, sizeof(storage));
    }

    std::optional<Bun::RsaPssMetadata> rsaPssMetadata() const
    {
        struct Storage {
            uint64_t magic;
            const EVP_MD* digest;
            const EVP_MD* mgf1Digest;
            int32_t minimumSaltLength;
        } storage;
        if (symmetricKey.size() != sizeof(storage)) {
            return std::nullopt;
        }
        memcpy(&storage, symmetricKey.span().data(), sizeof(storage));
        if (storage.magic != 0x48524b5053530001) {
            return std::nullopt;
        }
        return Bun::RsaPssMetadata {
            .digest = storage.digest,
            .mgf1Digest = storage.mgf1Digest,
            .minimumSaltLength = storage.minimumSaltLength,
        };
    }

    static RefPtr<KeyObjectData> create(WTF::Vector<uint8_t>&& symmetricKey)
    {
        return adoptRef(*new KeyObjectData(WTF::move(symmetricKey)));
    }

    static RefPtr<KeyObjectData> create(ncrypto::EVPKeyPointer&& asymmetricKey)
    {
        return adoptRef(*new KeyObjectData(WTF::move(asymmetricKey)));
    }

    WTF::Vector<uint8_t> symmetricKey;
    const ncrypto::EVPKeyPointer asymmetricKey;
};
