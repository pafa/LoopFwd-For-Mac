import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

// String Catalog is the only authored translation source. Generate the legacy
// runtime format inside the staged bundle, never back into source directories.
const destination = process.argv[2]
if (!destination) throw new Error('Pass the staged resource bundle directory')
const catalog = JSON.parse(await readFile('Sources/LoopFwd/Resources/Localizable.xcstrings', 'utf8'))
for (const locale of ['en', 'zh-Hans']) {
  const output = Object.entries(catalog.strings).sort(([a], [b]) => a.localeCompare(b)).map(([key, entry]) => {
    const value = entry.localizations?.[locale]?.stringUnit?.value ?? key
    return JSON.stringify(key) + ' = ' + JSON.stringify(value) + ';'
  }).join('\n') + '\n'
  const directory = join(destination, locale + '.lproj')
  await mkdir(directory, { recursive: true })
  await writeFile(join(directory, 'Localizable.strings'), output)
}
