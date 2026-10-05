import { createSocket, type RemoteInfo, type Socket } from 'node:dgram'
import { hostname } from 'node:os'
import {
  type DNSMessage,
  type Name,
  type ResourceRecord,
  Flags,
  RecordType,
  decodeMessage,
  encodeMessage,
  sameName,
  txtStrings,
} from './dnsPacket'
import { type LanInterface, lanIPv4Interfaces, onSubnet } from './network'

/// Advertises one DNS-SD service over Multicast DNS (RFC 6762 / 6763) — what `NWListener.service` does for the Mac
/// app: the iPhone's `NWBrowser(.bonjourWithTXTRecord(type: "_waitingpaws._tcp"))` finds this computer, reads the TXT
/// record and connects to the SRV port.
///
/// A small responder of its own on `node:dgram` (no native modules, no npm package):
/// - one UDP socket on 0.0.0.0:5353 (shared with Windows' own mDNS service through SO_REUSEADDR), joined to
///   224.0.0.251 on every IPv4 adapter;
/// - answers go out on the adapter the query came from, with that adapter's address in the A record (a laptop with
///   Wi-Fi plus WSL / VPN / VirtualBox adapters would otherwise hand the iPhone an address it can't reach);
/// - announcements at start (3×) and after TXT or address changes (2×), goodbyes (TTL 0) at stop;
/// - IPv4 only: the iPhone also asks over IPv4, and the Mac sends IPv4 addresses too.
/// Not done: probing for a name conflict (the instance is the computer's name, unique on a home network).

export const mdnsGroup = '224.0.0.251'
export const mdnsPort = 5353

/// TTLs Apple uses: 120 s for host-bound records (SRV, A), 4500 s for the rest.
const hostTTL = 120
const otherTTL = 4500

export interface BonjourServiceOptions {
  /// Service instance name: the computer's name, shown on the iPhone.
  instance: string
  /// "_waitingpaws._tcp".
  serviceType: string
  port: number
  txt: Record<string, string>
  /// Host label for the SRV target (`<label>.local`); default "WaitingPaws-<computer name>", apart from the name
  /// Windows itself answers for.
  hostLabel?: string
  log?: (line: string) => void
  /// A problem with the socket (null once it works again).
  onError?: (message: string | null) => void
  /// Adapters to serve (default: every IPv4 adapter, re-read every 5 s).
  interfaces?: () => LanInterface[]
}

/// The records of the service as seen on one adapter.
export interface ServiceRecords {
  ptr: ResourceRecord
  srv: ResourceRecord
  txt: ResourceRecord
  a: ResourceRecord
  enumeration: ResourceRecord
  instanceNSEC: ResourceRecord
  hostNSEC: ResourceRecord
}

export interface ServiceNames {
  service: Name
  instance: Name
  host: Name
  enumeration: Name
}

export function serviceNames(instance: string, serviceType: string, hostLabel: string): ServiceNames {
  const service = [...serviceType.split('.').filter(Boolean), 'local']
  return {
    service,
    instance: [truncateLabel(instance), ...service],
    host: [truncateLabel(hostLabel), 'local'],
    enumeration: ['_services', '_dns-sd', '_udp', 'local'],
  }
}

export function serviceRecords(names: ServiceNames, port: number, txt: Record<string, string>, address: string, goodbye = false): ServiceRecords {
  const ttl = (value: number) => (goodbye ? 0 : value)
  return {
    ptr: { name: names.service, ttl: ttl(otherTTL), cacheFlush: false, data: { type: 'PTR', target: names.instance } },
    srv: { name: names.instance, ttl: ttl(hostTTL), cacheFlush: true, data: { type: 'SRV', priority: 0, weight: 0, port, target: names.host } },
    txt: { name: names.instance, ttl: ttl(otherTTL), cacheFlush: true, data: { type: 'TXT', strings: txtStrings(txt) } },
    a: { name: names.host, ttl: ttl(hostTTL), cacheFlush: true, data: { type: 'A', address } },
    enumeration: { name: names.enumeration, ttl: ttl(otherTTL), cacheFlush: false, data: { type: 'PTR', target: names.service } },
    instanceNSEC: {
      name: names.instance,
      ttl: ttl(otherTTL),
      cacheFlush: true,
      data: { type: 'NSEC', next: names.instance, types: [RecordType.TXT, RecordType.SRV] },
    },
    hostNSEC: { name: names.host, ttl: ttl(hostTTL), cacheFlush: true, data: { type: 'NSEC', next: names.host, types: [RecordType.A] } },
  }
}

/// What to answer to a query (answers and additional records), or null when it's not about this service.
export function answerQuery(query: DNSMessage, names: ServiceNames, records: ServiceRecords): { answers: ResourceRecord[]; additionals: ResourceRecord[] } | null {
  const answers = new Set<ResourceRecord>()
  const additionals = new Set<ResourceRecord>()
  for (const question of query.questions) {
    const any = question.type === RecordType.ANY
    if (sameName(question.name, names.service) && (any || question.type === RecordType.PTR)) {
      // Known-answer suppression: the querier already has our PTR with at least half its TTL left.
      const known = query.answers.some(
        (record) =>
          record.data.type === 'PTR' &&
          sameName(record.name, names.service) &&
          sameName(record.data.target, names.instance) &&
          record.ttl >= records.ptr.ttl / 2,
      )
      if (!known) {
        answers.add(records.ptr)
        for (const record of [records.srv, records.txt, records.a, records.instanceNSEC, records.hostNSEC]) additionals.add(record)
      }
    } else if (sameName(question.name, names.enumeration) && (any || question.type === RecordType.PTR)) {
      answers.add(records.enumeration)
    } else if (sameName(question.name, names.instance)) {
      if (any || question.type === RecordType.SRV) {
        answers.add(records.srv)
        additionals.add(records.a)
        additionals.add(records.hostNSEC)
      }
      if (any || question.type === RecordType.TXT) answers.add(records.txt)
      if (!any && question.type !== RecordType.SRV && question.type !== RecordType.TXT) additionals.add(records.instanceNSEC)
    } else if (sameName(question.name, names.host)) {
      if (any || question.type === RecordType.A) answers.add(records.a)
      else additionals.add(records.hostNSEC) // No AAAA here: say so, so the iPhone doesn't wait for one.
    }
  }
  for (const record of answers) additionals.delete(record)
  if (answers.size === 0 && additionals.size === 0) return null
  return { answers: [...answers], additionals: [...additionals] }
}

interface Outgoing {
  packet: Buffer
  /// Adapter address for multicast (IP_MULTICAST_IF), null for unicast.
  via: string | null
  address: string
  port: number
}

export class BonjourAdvertiser {
  private socket: Socket | null = null
  private bound = false
  private stopped = false
  private failures = 0
  private interfaces: LanInterface[] = []
  private memberships = new Set<string>()
  private membershipErrors = new Set<string>()
  private refreshTimer: NodeJS.Timeout | null = null
  private retryTimer: NodeJS.Timeout | null = null
  private announceTimer: NodeJS.Timeout | null = null
  private pendingAnnouncements = 0
  private lastAnnouncement = 0
  private queue: Outgoing[] = []
  private sending = false
  private onDrained: (() => void) | null = null
  private recentResponses = new Map<string, number>()
  private sendErrorLogged = false
  private txt: Record<string, string>
  private readonly names: ServiceNames
  private readonly log: (line: string) => void

  constructor(private readonly options: BonjourServiceOptions) {
    this.txt = { ...options.txt }
    this.log = options.log ?? (() => undefined)
    this.names = serviceNames(options.instance, options.serviceType, options.hostLabel ?? defaultHostLabel())
  }

  start(): void {
    this.stopped = false
    this.open()
  }

  /// New TXT values (camera, session, exit): announced right away (at most once a second) and once more.
  updateTXT(txt: Record<string, string>): void {
    if (sameTXT(txt, this.txt)) return
    this.txt = { ...txt }
    this.requestAnnouncements(2)
  }

  /// Says goodbye (TTL 0) on every adapter, then closes the socket.
  stop(): void {
    if (this.stopped) return
    this.stopped = true
    for (const timer of [this.refreshTimer, this.retryTimer, this.announceTimer]) if (timer) clearTimeout(timer)
    this.refreshTimer = this.retryTimer = this.announceTimer = null
    const socket = this.socket
    if (!socket) return
    if (!this.bound || this.interfaces.length === 0) {
      this.close()
      return
    }
    this.queue = []
    for (const entry of this.interfaces) {
      const records = serviceRecords(this.names, this.options.port, this.txt, entry.address, true)
      this.enqueue(encodeMessage({ flags: Flags.response | Flags.authoritative, answers: [records.ptr, records.srv, records.txt, records.a] }), entry.address)
    }
    const timer = setTimeout(() => this.close(), 1000)
    timer.unref()
    this.onDrained = () => {
      clearTimeout(timer)
      this.close()
    }
    if (!this.sending) this.onDrained()
  }

  private open(): void {
    if (this.stopped || this.socket) return
    const socket = createSocket({ type: 'udp4', reuseAddr: true })
    this.socket = socket
    this.bound = false
    socket.on('error', (error) => this.failed(socket, error))
    socket.on('message', (message, remote) => {
      try {
        this.receive(message, remote)
      } catch (error) {
        this.log(`[sync] Bonjour: bad query from ${remote.address}: ${(error as Error).message}`)
      }
    })
    try {
      socket.bind({ port: mdnsPort, address: '0.0.0.0', exclusive: false }, () => {
        if (this.socket !== socket) return
        this.bound = true
        try {
          socket.setMulticastTTL(255)
          socket.setMulticastLoopback(true)
        } catch {
          // Defaults are fine too.
        }
        if (this.failures > 0) this.options.onError?.(null)
        this.failures = 0
        this.refreshInterfaces()
        this.refreshTimer = setInterval(() => this.refreshInterfaces(), 5000)
        this.refreshTimer.unref()
        const list = this.interfaces.map((entry) => `${entry.name} ${entry.address}`).join(', ') || 'no network yet'
        this.log(`[sync] Bonjour: "${this.options.instance}" ${this.options.serviceType} port ${this.options.port} on ${list}`)
      })
    } catch (error) {
      this.failed(socket, error as Error)
    }
  }

  private failed(socket: Socket, error: Error): void {
    if (this.socket !== socket) return
    this.log(`[sync] Bonjour failed: ${error.message}`)
    this.close()
    this.failures += 1
    this.options.onError?.(error.message)
    if (this.stopped) return
    // The listener keeps accepting direct connections meanwhile; try again, less and less often.
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null
      this.open()
    }, Math.min(60_000, 3000 * this.failures))
    this.retryTimer.unref()
  }

  private close(): void {
    const socket = this.socket
    this.socket = null
    this.bound = false
    this.sending = false
    this.queue = []
    this.onDrained = null
    this.memberships.clear()
    if (this.refreshTimer) clearInterval(this.refreshTimer)
    this.refreshTimer = null
    if (!socket) return
    try {
      socket.close()
    } catch {
      // Already closed.
    }
  }

  /// Joins the group on new adapters and announces there; follows address changes (Wi-Fi reconnects, DHCP).
  private refreshInterfaces(): void {
    const socket = this.socket
    if (!socket || !this.bound) return
    const current = (this.options.interfaces ?? lanIPv4Interfaces)()
    const key = (entry: LanInterface) => `${entry.name}|${entry.address}|${entry.netmask}`
    const known = new Set(this.interfaces.map(key))
    const added = current.filter((entry) => !known.has(key(entry)))
    for (const entry of this.interfaces) {
      if (current.some((item) => item.address === entry.address)) continue
      try {
        socket.dropMembership(mdnsGroup, entry.address)
      } catch {
        // The adapter is gone already.
      }
      this.memberships.delete(entry.address)
    }
    this.interfaces = current
    for (const entry of current) {
      if (this.memberships.has(entry.address)) continue
      try {
        socket.addMembership(mdnsGroup, entry.address)
        this.memberships.add(entry.address)
        this.membershipErrors.delete(entry.address)
      } catch (error) {
        if (!this.membershipErrors.has(entry.address)) this.log(`[sync] Bonjour: can't listen on ${entry.name} ${entry.address}: ${(error as Error).message}`)
        this.membershipErrors.add(entry.address)
      }
    }
    if (added.length > 0) this.requestAnnouncements(this.lastAnnouncement === 0 ? 3 : 2)
  }

  private requestAnnouncements(count: number): void {
    this.pendingAnnouncements = Math.max(this.pendingAnnouncements, count)
    if (this.announceTimer || !this.socket || !this.bound || this.stopped) return
    const wait = Math.max(0, this.lastAnnouncement + 1000 - Date.now())
    this.announceTimer = setTimeout(() => this.announce(), wait)
    this.announceTimer.unref()
  }

  private announce(): void {
    this.announceTimer = null
    if (!this.socket || !this.bound || this.stopped || this.pendingAnnouncements <= 0) return
    this.pendingAnnouncements -= 1
    this.lastAnnouncement = Date.now()
    for (const entry of this.interfaces) {
      const records = serviceRecords(this.names, this.options.port, this.txt, entry.address)
      this.enqueue(
        encodeMessage({
          flags: Flags.response | Flags.authoritative,
          answers: [records.ptr, records.srv, records.txt, records.a],
          additionals: [records.instanceNSEC, records.hostNSEC],
        }),
        entry.address,
      )
    }
    if (this.pendingAnnouncements > 0) {
      this.announceTimer = setTimeout(() => this.announce(), 1000)
      this.announceTimer.unref()
    }
  }

  private receive(buffer: Buffer, remote: RemoteInfo): void {
    if (!this.bound || this.stopped || buffer.length < 12) return
    const flags = buffer.readUInt16BE(2)
    // Responses (ours looped back, other devices') and anything but a standard query are not ours to answer.
    if (flags & Flags.response || ((flags >> 11) & 0xf) !== 0) return
    const query = decodeMessage(buffer)
    if (query.questions.length === 0) return
    // The adapter the query came in on (by subnet); all of them when it can't be told.
    const matching = this.interfaces.filter((entry) => onSubnet(remote.address, entry))
    const targets = matching.length > 0 ? matching : this.interfaces
    for (const entry of targets) {
      const records = serviceRecords(this.names, this.options.port, this.txt, entry.address)
      const reply = answerQuery(query, this.names, records)
      if (!reply) continue
      if (remote.port !== mdnsPort) {
        // A one-shot (legacy unicast) query: answer it directly, with its id and question, short TTLs, no
        // cache-flush bits (RFC 6762 §6.7).
        const plain = (record: ResourceRecord): ResourceRecord => ({ ...record, cacheFlush: false, ttl: Math.min(record.ttl, 10) })
        this.enqueue(
          encodeMessage({
            id: query.id,
            flags: Flags.response | Flags.authoritative,
            questions: query.questions.map((question) => ({ ...question, unicastResponse: false })),
            answers: reply.answers.map(plain),
            additionals: reply.additionals.map(plain),
          }),
          null,
          remote.address,
          remote.port,
        )
        return
      }
      const packet = encodeMessage({ flags: Flags.response | Flags.authoritative, answers: reply.answers, additionals: reply.additionals })
      // The same answer on the same adapter at most once a second (RFC 6762 §6).
      const recentKey = `${entry.address}|${packet.toString('base64')}`
      const now = Date.now()
      if (now - (this.recentResponses.get(recentKey) ?? 0) < 1000) continue
      this.recentResponses.set(recentKey, now)
      if (this.recentResponses.size > 64) {
        for (const [key, time] of this.recentResponses) if (now - time >= 1000) this.recentResponses.delete(key)
      }
      this.enqueue(packet, entry.address)
    }
  }

  /// Sends one packet at a time: the multicast adapter is a socket option, so it must not change between a send and
  /// the next one.
  private enqueue(packet: Buffer, via: string | null, address = mdnsGroup, port = mdnsPort): void {
    this.queue.push({ packet, via, address, port })
    if (!this.sending) this.next()
  }

  private next(): void {
    const socket = this.socket
    const item = this.queue.shift()
    if (!socket || !item) {
      this.sending = false
      const drained = this.onDrained
      if (!item && drained) {
        this.onDrained = null
        drained()
      }
      return
    }
    this.sending = true
    try {
      if (item.via) socket.setMulticastInterface(item.via)
      socket.send(item.packet, item.port, item.address, (error) => {
        if (error) this.sendFailed(item, error)
        this.next()
      })
    } catch (error) {
      this.sendFailed(item, error as Error)
      this.next()
    }
  }

  private sendFailed(item: Outgoing, error: Error): void {
    if (this.sendErrorLogged) return
    this.sendErrorLogged = true
    this.log(`[sync] Bonjour: sending via ${item.via ?? item.address} failed: ${error.message}`)
  }
}

function sameTXT(a: Record<string, string>, b: Record<string, string>): boolean {
  const keys = Object.keys(a)
  return keys.length === Object.keys(b).length && keys.every((key) => a[key] === b[key])
}

/// "WaitingPaws-DESKTOP-ABC123": letters, digits and hyphens.
export function defaultHostLabel(): string {
  let name = 'Windows'
  try {
    name = hostname() || name
  } catch {
    // Keep the fallback.
  }
  const clean = name.replace(/[^A-Za-z0-9-]+/g, '-').replace(/^-+|-+$/g, '') || 'PC'
  return `WaitingPaws-${clean}`.slice(0, 63)
}

/// A DNS label is at most 63 bytes: cut on a UTF-8 boundary.
export function truncateLabel(text: string): string {
  let bytes = Buffer.from(text || '-', 'utf8')
  if (bytes.length <= 63) return text || '-'
  let end = 63
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--
  bytes = bytes.subarray(0, end)
  return bytes.toString('utf8')
}
