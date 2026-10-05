import { networkInterfaces } from 'node:os'

/// An IPv4 address of this computer on a network adapter.
export interface LanInterface {
  /// Adapter name ("Wi-Fi", "Ethernet", "vEthernet (WSL)").
  name: string
  address: string
  netmask: string
}

/// Adapters of virtual machines, VPNs and the like: still served, but listed after Wi-Fi and Ethernet.
const virtualAdapter = /^(vEthernet|VirtualBox|VMware|Hyper-V|Npcap|Loopback|Bluetooth|Tailscale|ZeroTier|WireGuard|OpenVPN|TAP|Docker|WSL|Radmin|Hamachi|NordLynx|ProtonVPN)/i

/// Every non-loopback IPv4 address, Wi-Fi / Ethernet first.
export function lanIPv4Interfaces(): LanInterface[] {
  const result: LanInterface[] = []
  let all: ReturnType<typeof networkInterfaces>
  try {
    all = networkInterfaces()
  } catch {
    return []
  }
  for (const [name, addresses] of Object.entries(all)) {
    for (const entry of addresses ?? []) {
      const family = entry.family as string | number
      if ((family !== 'IPv4' && family !== 4) || entry.internal) continue
      result.push({ name, address: entry.address, netmask: entry.netmask })
    }
  }
  return result.sort((a, b) => rank(a) - rank(b))
}

function rank(entry: LanInterface): number {
  return (isLinkLocal(entry.address) ? 2 : 0) + (virtualAdapter.test(entry.name) ? 1 : 0)
}

export function isLinkLocal(address: string): boolean {
  return address.startsWith('169.254.')
}

/// Whether `address` is on the adapter's subnet.
export function onSubnet(address: string, entry: LanInterface): boolean {
  const a = ipv4Number(address)
  const b = ipv4Number(entry.address)
  const mask = ipv4Number(entry.netmask)
  if (a === null || b === null || mask === null) return false
  return ((a & mask) >>> 0) === ((b & mask) >>> 0)
}

export function ipv4Number(address: string): number | null {
  const parts = address.split('.')
  if (parts.length !== 4) return null
  let value = 0
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null
    const byte = Number(part)
    if (byte > 255) return null
    value = value * 256 + byte
  }
  return value >>> 0
}

/// The computer's LAN addresses for `SyncWelcome.addresses` (the Mac sends its Wi-Fi / Ethernet IPv4 addresses):
/// the one the iPhone connected to first.
export function welcomeAddresses(preferred: string | null, interfaces: LanInterface[] = lanIPv4Interfaces()): string[] {
  const addresses = interfaces.filter((entry) => !isLinkLocal(entry.address)).map((entry) => entry.address)
  if (preferred && preferred !== '127.0.0.1' && !isLinkLocal(preferred)) addresses.unshift(preferred)
  return [...new Set(addresses)]
}
