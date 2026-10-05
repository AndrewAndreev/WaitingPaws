import { execFile } from 'node:child_process'
import { join } from 'node:path'
import { DeviceModelName } from '@core/syncDevice'

/// This computer as the iPhones see it (the Mac's `SyncIdentity`): kind "windows", and the PC's model as people know
/// it ("Dell XPS 15 9510", "HP EliteBook 840 G8 Notebook PC", "ThinkPad X1 Carbon Gen 9"). A self-built desktop has
/// no such name (its BIOS says "MS-7E16" or "To be filled by O.E.M."): the model stays empty and the iPhone shows
/// «ПК» / «PC» in its own language.

export const hostPlatform = 'windows'

/// The values of `HKLM\HARDWARE\DESCRIPTION\System\BIOS` used here (what WMI's Win32_ComputerSystem reports too).
export interface BIOSInfo {
  SystemManufacturer?: string
  SystemProductName?: string
  SystemFamily?: string
  SystemVersion?: string
  BaseBoardProduct?: string
}

const placeholder =
  /^(to be filled by o\.?e\.?m\.?|system (manufacturer|product name|version|family|sku|serial number)|default string|not applicable|not specified|n\/a|none|null|unknown|invalid|o\.?e\.?m\.?|oem|x\.x|\d+(\.\d+)*|type1productconfigid|type1family|sku|chassis manufacture|undefined|all series)$/i

function meaningful(value: string | undefined): string | null {
  const text = (value ?? '').replace(/\0/g, '').replace(/\s+/g, ' ').trim()
  return text === '' || placeholder.test(text) ? null : text
}

/// "Dell Inc." → "Dell", "ASUSTeK COMPUTER INC." → "ASUS", "Micro-Star International Co., Ltd." → "MSI".
export function brandName(manufacturer: string): string {
  const known: [RegExp, string][] = [
    [/^dell/i, 'Dell'],
    [/^(hp|hewlett)/i, 'HP'],
    [/^lenovo/i, 'Lenovo'],
    [/^asus/i, 'ASUS'],
    [/^acer/i, 'Acer'],
    [/^micro-star|^msi\b/i, 'MSI'],
    [/^microsoft/i, 'Microsoft'],
    [/^samsung/i, 'Samsung'],
    [/^gigabyte/i, 'Gigabyte'],
    [/^huawei/i, 'Huawei'],
    [/^honor/i, 'Honor'],
    [/^xiaomi/i, 'Xiaomi'],
    [/^toshiba|^dynabook/i, 'Toshiba'],
    [/^fujitsu/i, 'Fujitsu'],
    [/^razer/i, 'Razer'],
    [/^lg electronics/i, 'LG'],
    [/^apple/i, 'Apple'],
    [/^vmware/i, 'VMware'],
  ]
  for (const [pattern, name] of known) if (pattern.test(manufacturer)) return name
  const first = manufacturer.split(/[\s,]+/)[0] ?? ''
  // "TOSHIBA"-style capitals read better as a name, short ones ("HP", "LG") stay.
  return first.length > 3 && first === first.toUpperCase() ? first[0] + first.slice(1).toLowerCase() : first
}

/// The model name from the BIOS values, "" when there is none worth showing.
export function pcModelName(info: BIOSInfo): string {
  const manufacturer = meaningful(info.SystemManufacturer)
  const product = meaningful(info.SystemProductName)
  const brand = manufacturer ? brandName(manufacturer) : null
  let name: string | null = null
  if (brand === 'Apple' && product) {
    // Boot Camp: "MacBookPro16,1".
    name = DeviceModelName.mac(null, product)
  } else if (brand === 'Lenovo') {
    // Lenovo puts the machine type in the product name ("20XW0026GE") and the name people know in the version.
    name = meaningful(info.SystemVersion) ?? meaningful(info.SystemFamily) ?? null
    if (name && !/^(lenovo|think|idea|yoga|legion)/i.test(name)) name = `Lenovo ${name}`
  } else if (product) {
    // A motherboard code instead of a computer: a self-built PC.
    const board = info.BaseBoardProduct ?? ''
    const boardCode = /^MS-\w+$/i.test(product) || (board !== '' && (board === product || board.includes(`(${product})`)))
    if (!boardCode) {
      const hasBrand = brand !== null && (product.toLowerCase().startsWith(brand.toLowerCase()) || /^surface/i.test(product))
      name = brand && !hasBrand ? `${brand} ${product}` : product
    }
  }
  if (!name) return ''
  return name.length > 48 ? name.slice(0, 48).trimEnd() : name
}

/// `reg query` output: `    SystemProductName    REG_SZ    XPS 15 9510`.
export function parseRegQuery(output: string): BIOSInfo {
  const values: Record<string, string> = {}
  for (const line of output.split(/\r?\n/)) {
    const match = /^\s+(\S+)\s+REG_SZ\s+(.*?)\s*$/.exec(line)
    if (match) values[match[1]] = match[2]
  }
  return values
}

let cached: Promise<string> | null = null

/// This PC's model, read once per run in a child process (`reg.exe`, a few ms; never on the main thread), "" when
/// unknown or not on Windows.
export function readPCModel(): Promise<string> {
  if (!cached) {
    cached = new Promise<string>((resolve) => {
      if (process.platform !== 'win32') return resolve('')
      const reg = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'reg.exe')
      try {
        execFile(reg, ['query', 'HKLM\\HARDWARE\\DESCRIPTION\\System\\BIOS'], { windowsHide: true, timeout: 5000 }, (error, stdout) => {
          if (error) return resolve('')
          try {
            resolve(pcModelName(parseRegQuery(String(stdout))))
          } catch {
            resolve('')
          }
        })
      } catch {
        resolve('')
      }
    })
  }
  return cached
}
