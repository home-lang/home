import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const root = await mkdtemp(join(tmpdir(), 'home-bun-write-file-copy-'))
const sourcePath = join(root, 'source.txt')
const sourceText = '0123456789abcdefghijklmnopqrstuvwxyz'

const copyAndRead = async (name, destination, source) => {
  const copied = await Bun.write(destination, source)
  const text = await readFile(join(root, name), 'utf8')
  return { copied, text }
}

try {
  await writeFile(sourcePath, sourceText)

  const observedEmptyPath = join(root, 'observed-empty.txt')
  await writeFile(observedEmptyPath, '')
  const observedEmpty = Bun.file(observedEmptyPath)
  assert.equal(observedEmpty.size, 0)
  assert.deepEqual(await copyAndRead('observed-empty.txt', observedEmpty, Bun.file(sourcePath)), {
    copied: sourceText.length,
    text: sourceText,
  })

  const observedShortPath = join(root, 'observed-short.txt')
  await writeFile(observedShortPath, 'old')
  const observedShort = Bun.file(observedShortPath)
  assert.equal(observedShort.size, 3)
  assert.deepEqual(await copyAndRead('observed-short.txt', observedShort, Bun.file(sourcePath)), {
    copied: sourceText.length,
    text: sourceText,
  })

  const sourceSlicePath = join(root, 'source-slice.txt')
  assert.deepEqual(
    await copyAndRead('source-slice.txt', Bun.file(sourceSlicePath), Bun.file(sourcePath).slice(2, 8)),
    { copied: 6, text: '234567' },
  )

  const destinationSlicePath = join(root, 'destination-slice.txt')
  await writeFile(destinationSlicePath, 'abcdefghij')
  assert.deepEqual(
    await copyAndRead(
      'destination-slice.txt',
      Bun.file(destinationSlicePath).slice(2, 6),
      Bun.file(sourcePath),
    ),
    { copied: 4, text: 'ab0123' },
  )

  const bothSlicesPath = join(root, 'both-slices.txt')
  await writeFile(bothSlicesPath, 'abcdefghij')
  assert.deepEqual(
    await copyAndRead(
      'both-slices.txt',
      Bun.file(bothSlicesPath).slice(2, 5),
      Bun.file(sourcePath).slice(3, 9),
    ),
    { copied: 3, text: 'ab345' },
  )

  const emptySourceSlicePath = join(root, 'empty-source-slice.txt')
  await writeFile(emptySourceSlicePath, 'stale')
  assert.deepEqual(
    await copyAndRead(
      'empty-source-slice.txt',
      Bun.file(emptySourceSlicePath),
      Bun.file(sourcePath).slice(9, 9),
    ),
    { copied: 0, text: '' },
  )

  const emptyDestinationSlicePath = join(root, 'empty-destination-slice.txt')
  await writeFile(emptyDestinationSlicePath, 'abcdefghij')
  assert.deepEqual(
    await copyAndRead(
      'empty-destination-slice.txt',
      Bun.file(emptyDestinationSlicePath).slice(2, 2),
      Bun.file(sourcePath),
    ),
    { copied: 0, text: 'ab' },
  )

  const clonedSlicePath = join(root, 'structured-clone-slice.txt')
  const clonedSlice = structuredClone(Bun.file(sourcePath).slice(10, 16))
  assert.deepEqual(await copyAndRead('structured-clone-slice.txt', Bun.file(clonedSlicePath), clonedSlice), {
    copied: 6,
    text: 'abcdef',
  })
} finally {
  await rm(root, { recursive: true, force: true })
}

console.log('native Bun.write file copy passed')
