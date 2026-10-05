// Writes build/ThirdPartyNotices-desktop.txt: the licenses of the JavaScript packages the Windows app ships (bundled
// into the UI or the main process, plus runtime dependencies) and of Electron. go2rtc and its Go modules are listed
// in App/Resources/Legal/Acknowledgements.txt (GoMobile/licenses.sh); Chromium's notices come with Electron
// (LICENSES.chromium.html next to the app).
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const lock = JSON.parse(readFileSync(join(root, 'package-lock.json'), 'utf8'))
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))

// What ends up in the app: the UI and media libraries (bundled by Vite) and the main process's dependencies.
const roots = ['react', 'react-dom', 'zustand', 'radix-ui', '@fluentui/react-icons', 'mediabunny', ...Object.keys(pkg.dependencies ?? {}), 'electron']
const packages = lock.packages

function find(name, from = '') {
  // Node resolution inside the lockfile: nested node_modules first, then the top level.
  let base = from
  while (true) {
    const key = `${base ? base + '/' : ''}node_modules/${name}`
    if (packages[key]) return key
    if (!base) return null
    const index = base.lastIndexOf('/node_modules/')
    base = index >= 0 ? base.slice(0, index) : ''
  }
}

const seen = new Map()
const queue = roots.map((name) => find(name)).filter(Boolean)
while (queue.length) {
  const key = queue.shift()
  if (seen.has(key)) continue
  const info = packages[key]
  seen.set(key, info)
  if (key.endsWith('node_modules/electron')) continue // only Electron itself, not its build-time downloader
  for (const dependency of Object.keys({ ...(info.dependencies ?? {}), ...(info.peerDependencies ?? {}) })) {
    const next = find(dependency, key)
    if (next && !seen.has(next) && !packages[next].dev === false) queue.push(next)
    else if (next && !seen.has(next)) queue.push(next)
  }
}

function licenseText(directory) {
  if (!existsSync(directory)) return null
  const file = readdirSync(directory).find((name) => /^(licen[cs]e|copying|notice)(\.|$|-)/i.test(name))
  return file ? readFileSync(join(directory, file), 'utf8').trim() : null
}

const entries = [...seen.keys()]
  .map((key) => {
    const name = key.slice(key.lastIndexOf('node_modules/') + 'node_modules/'.length)
    const info = packages[key]
    return { name, version: info.version, license: info.license ?? 'see text', text: licenseText(join(root, key)) }
  })
  .filter((entry, index, all) => all.findIndex((other) => other.name === entry.name && other.version === entry.version) === index)
  .sort((a, b) => a.name.localeCompare(b.name))

const header = `Waiting Paws for Windows — third-party software
================================================

The Windows app is built with Electron and the open-source packages below.
mediabunny is used under the Mozilla Public License 2.0 (source: https://github.com/Vanilagy/mediabunny).
`
const body = entries
  .map((entry) => `${entry.name} ${entry.version} — ${entry.license}\n${'-'.repeat(60)}\n${entry.text ?? `License: ${entry.license}`}\n`)
  .join('\n')
writeFileSync(join(root, 'build', 'ThirdPartyNotices-desktop.txt'), header + '\n' + body)
console.log(`notices: ${entries.length} packages → build/ThirdPartyNotices-desktop.txt`)
