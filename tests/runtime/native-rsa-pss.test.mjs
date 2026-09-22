import assert from 'node:assert/strict'
import {
  constants,
  createPrivateKey,
  createPublicKey,
  createSign,
  createVerify,
  generateKeyPair,
  generateKeyPairSync,
  sign,
  verify,
} from 'node:crypto'
import { readFileSync } from 'node:fs'
import { basename } from 'node:path'
import { promisify } from 'node:util'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const message = Buffer.from('home native rsa-pss')
const expectedDetails = { modulusLength: 2048, publicExponent: 65537n }

function checkPair(
  { privateKey, publicKey },
  digest = 'sha256',
  saltLengths = [undefined, 8, 20],
  keyDetails = expectedDetails,
) {
  assert.equal(privateKey.type, 'private')
  assert.equal(publicKey.type, 'public')
  assert.equal(privateKey.asymmetricKeyType, 'rsa-pss')
  assert.equal(publicKey.asymmetricKeyType, 'rsa-pss')
  assert.deepEqual(privateKey.asymmetricKeyDetails, keyDetails)
  assert.deepEqual(publicKey.asymmetricKeyDetails, keyDetails)

  for (const saltLength of saltLengths) {
    const privateOptions = saltLength === undefined ? privateKey : { key: privateKey, saltLength }
    const signature = sign(digest, message, privateOptions)
    assert.equal(signature.length, 256)
    for (const key of [privateKey, publicKey]) {
      const publicOptions = saltLength === undefined ? key : { key, saltLength }
      assert.equal(verify(digest, message, publicOptions, signature), true)
      assert.equal(verify(digest, Buffer.from('wrong message'), publicOptions, signature), false)
    }
  }

  const streamingSigner = createSign(digest)
  streamingSigner.update(message)
  const streamingSignature = streamingSigner.sign(privateKey)
  const streamingVerifier = createVerify(digest)
  streamingVerifier.update(message)
  assert.equal(streamingVerifier.verify(publicKey, streamingSignature), true)

  for (const key of [privateKey, publicKey]) {
    assert.throws(() => key.export({ format: 'jwk' }), { code: 'ERR_CRYPTO_JWK_UNSUPPORTED_KEY_TYPE' })
    assert.throws(() => key.export({ format: 'pem', type: 'pkcs1' }), { code: 'ERR_CRYPTO_INCOMPATIBLE_KEY_OPTIONS' })
  }
  assert.throws(
    () => sign(digest, message, { key: privateKey, padding: constants.RSA_PKCS1_PADDING }),
    { code: 'ERR_INVALID_ARG_VALUE' },
  )
}

function checkRoundTrips({ privateKey, publicKey }, digest, keyDetails) {
  const signature = sign(digest, message, privateKey)

  for (const format of ['pem', 'der']) {
    const encodedPublic = publicKey.export({ format, type: 'spki' })
    const importedPublic = createPublicKey({ key: encodedPublic, format, type: 'spki' })
    assert.equal(importedPublic.asymmetricKeyType, 'rsa-pss')
    assert.deepEqual(importedPublic.asymmetricKeyDetails, keyDetails)
    assert.equal(verify(digest, message, importedPublic, signature), true)

    for (const encrypted of [false, true]) {
      const passphrase = encrypted ? Buffer.from('rsa-pss passphrase') : undefined
      const encodedPrivate = privateKey.export({
        format,
        type: 'pkcs8',
        ...(encrypted ? { cipher: 'aes-256-cbc', passphrase } : {}),
      })
      if (encrypted) {
        assert.throws(
          () => createPrivateKey({ key: encodedPrivate, format, type: 'pkcs8' }),
          { code: 'ERR_MISSING_PASSPHRASE' },
        )
        assert.throws(
          () => createPrivateKey({
            key: encodedPrivate,
            format,
            type: 'pkcs8',
            passphrase: 'wrong passphrase',
          }),
          { message: /bad decrypt|BAD_DECRYPT/ },
        )
      }
      const importedPrivate = createPrivateKey({
        key: encodedPrivate,
        format,
        type: 'pkcs8',
        ...(encrypted ? { passphrase } : {}),
      })
      assert.equal(importedPrivate.asymmetricKeyType, 'rsa-pss')
      assert.deepEqual(importedPrivate.asymmetricKeyDetails, keyDetails)
      assert.equal(verify(digest, message, publicKey, sign(digest, message, importedPrivate)), true)

      const derivedPublic = createPublicKey({
        key: encodedPrivate,
        format,
        type: 'pkcs8',
        ...(encrypted ? { passphrase } : {}),
      })
      assert.equal(derivedPublic.type, 'public')
      assert.equal(derivedPublic.asymmetricKeyType, 'rsa-pss')
      assert.deepEqual(derivedPublic.asymmetricKeyDetails, keyDetails)
      assert.equal(verify(digest, message, derivedPublic, signature), true)
    }
  }
}

const unrestricted = generateKeyPairSync('rsa-pss', { modulusLength: 2048, publicExponent: 65537 })
checkPair(unrestricted)
const unrestrictedSpki = unrestricted.publicKey.export({ format: 'der', type: 'spki' })
assert.notEqual(unrestrictedSpki.indexOf(Buffer.from('300b06092a864886f70d01010a', 'hex')), -1)
checkRoundTrips(unrestricted, 'sha256', expectedDetails)

const restricted = generateKeyPairSync('rsa-pss', {
  modulusLength: 2048,
  publicExponent: 65537,
  hashAlgorithm: 'sha256',
  mgf1HashAlgorithm: 'sha256',
  saltLength: 16,
})
checkPair(restricted, 'sha256', [undefined, 16, 20], {
  ...expectedDetails,
  hashAlgorithm: 'sha256',
  mgf1HashAlgorithm: 'sha256',
  saltLength: 16,
})
checkRoundTrips(restricted, 'sha256', {
  ...expectedDetails,
  hashAlgorithm: 'sha256',
  mgf1HashAlgorithm: 'sha256',
  saltLength: 16,
})
assert.throws(() => sign('sha1', message, restricted.privateKey), /digest not allowed/)
assert.throws(() => sign('sha256', message, { key: restricted.privateKey, saltLength: 8 }), /pss saltlen too small|too small for this RSA-PSS key/)
const wrongDigestSigner = createSign('sha1')
wrongDigestSigner.update(message)
assert.throws(() => wrongDigestSigner.sign(restricted.privateKey), /digest not allowed/)
const wrongDigestVerifier = createVerify('sha1')
wrongDigestVerifier.update(message)
assert.throws(() => wrongDigestVerifier.verify(restricted.publicKey, Buffer.alloc(256)), /digest not allowed/)

const asyncPair = await promisify(generateKeyPair)('rsa-pss', {
  modulusLength: 2048,
  publicExponent: 65537,
  hashAlgorithm: 'sha1',
  mgf1HashAlgorithm: 'sha1',
  saltLength: 20,
})
checkPair(asyncPair, 'sha1', [undefined, 20], {
  ...expectedDetails,
  hashAlgorithm: 'sha1',
  mgf1HashAlgorithm: 'sha1',
  saltLength: 20,
})

function pemToDer(pem) {
  return Buffer.from(
    pem
      .toString('ascii')
      .replace(/-----[^-]+-----/g, '')
      .replace(/\s/g, ''),
    'base64',
  )
}

const keyFixtureUrl = new URL(
  '../../packages/runtime/test/test/js/node/test/fixtures/keys/',
  import.meta.url,
)
const restrictedPrivatePem = readFileSync(
  new URL('rsa_pss_private_2048_sha512_sha256_20.pem', keyFixtureUrl),
)
const restrictedPublicPem = readFileSync(
  new URL('rsa_pss_public_2048_sha512_sha256_20.pem', keyFixtureUrl),
)
const importedDetails = {
  ...expectedDetails,
  hashAlgorithm: 'sha512',
  mgf1HashAlgorithm: 'sha256',
  saltLength: 20,
}

const importedPemPair = {
  privateKey: createPrivateKey(restrictedPrivatePem),
  publicKey: createPublicKey(restrictedPublicPem),
}
checkPair(
  importedPemPair,
  'sha512',
  [undefined, 20, 64],
  importedDetails,
)
checkRoundTrips(importedPemPair, 'sha512', importedDetails)
checkPair(
  {
    privateKey: createPrivateKey({ key: pemToDer(restrictedPrivatePem), format: 'der', type: 'pkcs8' }),
    publicKey: createPublicKey({ key: pemToDer(restrictedPublicPem), format: 'der', type: 'spki' }),
  },
  'sha512',
  [undefined, 20, 64],
  importedDetails,
)

console.log('native RSA-PSS generation and signing passed')
