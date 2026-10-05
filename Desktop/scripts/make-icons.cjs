// Builds the Windows app icon from the iOS artwork (Design/app-icon/AppIcon-ios.svg): a rounded square in the
// "night" palette without the macOS plate and shadow, rasterized by Electron itself (no rsvg/ImageMagick needed).
//   npx electron scripts/make-icons.cjs
// Writes build/icon.ico (16–256 px, PNG-compressed entries), build/icon.png (512 px) and resources/icon.png (256 px,
// the window icon in development).
const { app, BrowserWindow } = require('electron')
const { readFileSync, writeFileSync, mkdirSync } = require('node:fs')
const { join } = require('node:path')

const root = join(__dirname, '..')
const svg = readFileSync(join(root, '..', 'Design', 'app-icon', 'AppIcon-ios.svg'), 'utf8')
// Windows 11 app icons are rounded squares with a little breathing room, not full-bleed tiles.
const rounded = svg
  .replace('<svg ', '<svg ')
  .replace(/<rect width="1024" height="1024" fill="([^"]+)"\/>/, (_m, fill) => `<rect x="24" y="24" width="976" height="976" rx="200" fill="${fill}"/>`)
const sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256, 512]

app.disableHardwareAcceleration()
app.whenReady().then(async () => {
  const window = new BrowserWindow({ show: false, width: 512, height: 512, transparent: true, frame: false, webPreferences: { offscreen: true } })
  const pngs = {}
  for (const size of sizes) {
    const html = `<html><body style="margin:0;background:transparent"><img src="data:image/svg+xml;base64,${Buffer.from(rounded).toString('base64')}" style="width:${size}px;height:${size}px;display:block"></body></html>`
    window.setContentSize(Math.max(size, 16), Math.max(size, 16))
    await window.loadURL('data:text/html;base64,' + Buffer.from(html).toString('base64'))
    await new Promise((resolve) => setTimeout(resolve, 150))
    const image = await window.webContents.capturePage({ x: 0, y: 0, width: size, height: size })
    pngs[size] = image.resize({ width: size, height: size, quality: 'best' }).toPNG()
  }
  mkdirSync(join(root, 'build'), { recursive: true })
  writeFileSync(join(root, 'build', 'icon.png'), pngs[512])
  writeFileSync(join(root, 'resources', 'icon.png'), pngs[256])
  // ICO with PNG entries (Vista+): header, directory, images.
  const entries = sizes.filter((size) => size <= 256)
  const header = Buffer.alloc(6)
  header.writeUInt16LE(0, 0)
  header.writeUInt16LE(1, 2)
  header.writeUInt16LE(entries.length, 4)
  const directory = Buffer.alloc(16 * entries.length)
  let offset = 6 + directory.length
  entries.forEach((size, index) => {
    const png = pngs[size]
    const at = index * 16
    directory.writeUInt8(size >= 256 ? 0 : size, at)
    directory.writeUInt8(size >= 256 ? 0 : size, at + 1)
    directory.writeUInt8(0, at + 2)
    directory.writeUInt8(0, at + 3)
    directory.writeUInt16LE(1, at + 4)
    directory.writeUInt16LE(32, at + 6)
    directory.writeUInt32LE(png.length, at + 8)
    directory.writeUInt32LE(offset, at + 12)
    offset += png.length
  })
  writeFileSync(join(root, 'build', 'icon.ico'), Buffer.concat([header, directory, ...entries.map((size) => pngs[size])]))
  console.log(`icons: ${entries.join(', ')} px → build/icon.ico, build/icon.png, resources/icon.png`)
  app.quit()
})
