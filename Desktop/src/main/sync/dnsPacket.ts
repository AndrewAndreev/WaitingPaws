/// The part of the DNS message format (RFC 1035, with the Multicast DNS bits of RFC 6762) the Bonjour advertiser
/// needs: reading queries (names may be compressed) and writing responses with PTR, SRV, TXT, A and NSEC records.
/// Names are arrays of labels, so an instance name with dots or spaces ("Andrew's PC.home") stays one label.

export const RecordType = { A: 1, PTR: 12, TXT: 16, AAAA: 28, SRV: 33, NSEC: 47, ANY: 255 } as const

const classIN = 1
/// In a question: the querier wants a unicast answer (QU). In a record: the cache-flush bit (unique records).
const topBit = 0x8000

export const Flags = { response: 0x8000, authoritative: 0x0400, truncated: 0x0200 } as const

export type Name = string[]

export interface Question {
  name: Name
  type: number
  /// QU bit.
  unicastResponse: boolean
}

export type RecordData =
  | { type: 'A'; address: string }
  | { type: 'PTR'; target: Name }
  | { type: 'SRV'; priority: number; weight: number; port: number; target: Name }
  | { type: 'TXT'; strings: Buffer[] }
  | { type: 'NSEC'; next: Name; types: number[] }
  | { type: 'other'; code: number; raw: Buffer }

export interface ResourceRecord {
  name: Name
  ttl: number
  /// Unique records (SRV, TXT, A, NSEC) are sent with the cache-flush bit.
  cacheFlush: boolean
  data: RecordData
}

export interface DNSMessage {
  id: number
  flags: number
  questions: Question[]
  answers: ResourceRecord[]
  authorities: ResourceRecord[]
  additionals: ResourceRecord[]
}

export class DNSFormatError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'DNSFormatError'
  }
}

/// Case-insensitive comparison of names (ASCII letters, as DNS does).
export function sameName(a: Name, b: Name): boolean {
  if (a.length !== b.length) return false
  return a.every((label, index) => label.toLowerCase() === b[index].toLowerCase())
}

export function typeCode(data: RecordData): number {
  return data.type === 'other' ? data.code : RecordType[data.type]
}

/// "key=value" strings for a TXT record; each is cut to 255 bytes (on a UTF-8 boundary).
export function txtStrings(txt: Record<string, string>): Buffer[] {
  return Object.entries(txt).map(([key, value]) => {
    let bytes = Buffer.from(`${key}=${value}`, 'utf8')
    if (bytes.length > 255) {
      let end = 255
      while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--
      bytes = bytes.subarray(0, end)
    }
    return bytes
  })
}

// MARK: - Writing

export function encodeMessage(message: Partial<DNSMessage> & Pick<DNSMessage, 'flags'>): Buffer {
  const questions = message.questions ?? []
  const answers = message.answers ?? []
  const authorities = message.authorities ?? []
  const additionals = message.additionals ?? []
  const header = Buffer.alloc(12)
  header.writeUInt16BE(message.id ?? 0, 0)
  header.writeUInt16BE(message.flags, 2)
  header.writeUInt16BE(questions.length, 4)
  header.writeUInt16BE(answers.length, 6)
  header.writeUInt16BE(authorities.length, 8)
  header.writeUInt16BE(additionals.length, 10)
  const parts: Buffer[] = [header]
  for (const question of questions) {
    const tail = Buffer.alloc(4)
    tail.writeUInt16BE(question.type, 0)
    tail.writeUInt16BE(classIN | (question.unicastResponse ? topBit : 0), 2)
    parts.push(encodeName(question.name), tail)
  }
  for (const record of [...answers, ...authorities, ...additionals]) parts.push(encodeRecord(record))
  return Buffer.concat(parts)
}

export function encodeName(name: Name): Buffer {
  const parts: Buffer[] = []
  for (const label of name) {
    const bytes = Buffer.from(label, 'utf8')
    if (bytes.length === 0 || bytes.length > 63) throw new DNSFormatError(`bad label "${label}"`)
    parts.push(Buffer.from([bytes.length]), bytes)
  }
  parts.push(Buffer.from([0]))
  return Buffer.concat(parts)
}

function encodeRecord(record: ResourceRecord): Buffer {
  const rdata = encodeData(record.data)
  const fixed = Buffer.alloc(10)
  fixed.writeUInt16BE(typeCode(record.data), 0)
  fixed.writeUInt16BE(classIN | (record.cacheFlush ? topBit : 0), 2)
  fixed.writeUInt32BE(Math.max(0, Math.min(0x7fffffff, Math.round(record.ttl))), 4)
  fixed.writeUInt16BE(rdata.length, 8)
  return Buffer.concat([encodeName(record.name), fixed, rdata])
}

function encodeData(data: RecordData): Buffer {
  switch (data.type) {
    case 'A': {
      const parts = data.address.split('.').map(Number)
      if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
        throw new DNSFormatError(`bad IPv4 address ${data.address}`)
      }
      return Buffer.from(parts)
    }
    case 'PTR':
      return encodeName(data.target)
    case 'SRV': {
      const fixed = Buffer.alloc(6)
      fixed.writeUInt16BE(data.priority, 0)
      fixed.writeUInt16BE(data.weight, 2)
      fixed.writeUInt16BE(data.port, 4)
      return Buffer.concat([fixed, encodeName(data.target)])
    }
    case 'TXT': {
      // An empty TXT record is one empty string (RFC 6763 §6.1).
      if (data.strings.length === 0) return Buffer.from([0])
      return Buffer.concat(data.strings.flatMap((item) => [Buffer.from([item.length]), item]))
    }
    case 'NSEC': {
      // Window block 0 only (types below 256), as mDNS uses it (RFC 6762 §6.1).
      const types = data.types.filter((type) => type > 0 && type < 256)
      const length = types.length === 0 ? 0 : Math.floor(Math.max(...types) / 8) + 1
      const bitmap = Buffer.alloc(length)
      for (const type of types) bitmap[type >> 3] |= 0x80 >> (type & 7)
      return Buffer.concat([encodeName(data.next), Buffer.from([0, length]), bitmap])
    }
    case 'other':
      return data.raw
  }
}

// MARK: - Reading

export function decodeMessage(buffer: Buffer): DNSMessage {
  if (buffer.length < 12) throw new DNSFormatError('short message')
  const counts = [4, 6, 8, 10].map((offset) => buffer.readUInt16BE(offset))
  let offset = 12
  const questions: Question[] = []
  for (let i = 0; i < counts[0]; i++) {
    const [name, next] = readName(buffer, offset)
    if (next + 4 > buffer.length) throw new DNSFormatError('short question')
    const qclass = buffer.readUInt16BE(next + 2)
    questions.push({ name, type: buffer.readUInt16BE(next), unicastResponse: (qclass & topBit) !== 0 })
    offset = next + 4
  }
  const sections: ResourceRecord[][] = [[], [], []]
  for (let section = 0; section < 3; section++) {
    for (let i = 0; i < counts[section + 1]; i++) {
      const [record, next] = readRecord(buffer, offset)
      sections[section].push(record)
      offset = next
    }
  }
  return {
    id: buffer.readUInt16BE(0),
    flags: buffer.readUInt16BE(2),
    questions,
    answers: sections[0],
    authorities: sections[1],
    additionals: sections[2],
  }
}

function readRecord(buffer: Buffer, offset: number): [ResourceRecord, number] {
  const [name, next] = readName(buffer, offset)
  if (next + 10 > buffer.length) throw new DNSFormatError('short record')
  const type = buffer.readUInt16BE(next)
  const rclass = buffer.readUInt16BE(next + 2)
  const ttl = buffer.readUInt32BE(next + 4)
  const length = buffer.readUInt16BE(next + 8)
  const start = next + 10
  const end = start + length
  if (end > buffer.length) throw new DNSFormatError('short record data')
  return [{ name, ttl, cacheFlush: (rclass & topBit) !== 0, data: readData(buffer, type, start, end) }, end]
}

function readData(buffer: Buffer, type: number, start: number, end: number): RecordData {
  switch (type) {
    case RecordType.A:
      if (end - start !== 4) break
      return { type: 'A', address: [...buffer.subarray(start, end)].join('.') }
    case RecordType.PTR:
      return { type: 'PTR', target: readName(buffer, start)[0] }
    case RecordType.SRV:
      if (end - start < 7) break
      return {
        type: 'SRV',
        priority: buffer.readUInt16BE(start),
        weight: buffer.readUInt16BE(start + 2),
        port: buffer.readUInt16BE(start + 4),
        target: readName(buffer, start + 6)[0],
      }
    case RecordType.TXT: {
      const strings: Buffer[] = []
      let offset = start
      while (offset < end) {
        const length = buffer[offset]
        if (offset + 1 + length > end) throw new DNSFormatError('bad TXT record')
        if (length > 0) strings.push(Buffer.from(buffer.subarray(offset + 1, offset + 1 + length)))
        offset += 1 + length
      }
      return { type: 'TXT', strings }
    }
    case RecordType.NSEC: {
      const [next, offset] = readName(buffer, start)
      const types: number[] = []
      let position = offset
      while (position + 2 <= end) {
        const window = buffer[position]
        const length = buffer[position + 1]
        for (let i = 0; i < length && position + 2 + i < end; i++) {
          const byte = buffer[position + 2 + i]
          for (let bit = 0; bit < 8; bit++) if (byte & (0x80 >> bit)) types.push(window * 256 + i * 8 + bit)
        }
        position += 2 + length
      }
      return { type: 'NSEC', next, types }
    }
  }
  return { type: 'other', code: type, raw: Buffer.from(buffer.subarray(start, end)) }
}

/// A (possibly compressed) name at `offset`; returns the labels and the offset after the name.
export function readName(buffer: Buffer, offset: number): [Name, number] {
  const labels: string[] = []
  let position = offset
  let next = -1
  let jumps = 0
  let total = 0
  for (;;) {
    if (position >= buffer.length) throw new DNSFormatError('name runs past the message')
    const length = buffer[position]
    if (length === 0) {
      if (next < 0) next = position + 1
      break
    }
    const kind = length & 0xc0
    if (kind === 0xc0) {
      if (position + 1 >= buffer.length) throw new DNSFormatError('short pointer')
      if (next < 0) next = position + 2
      if (++jumps > 64) throw new DNSFormatError('pointer loop')
      position = ((length & 0x3f) << 8) | buffer[position + 1]
      continue
    }
    if (kind !== 0) throw new DNSFormatError('unknown label type')
    if (position + 1 + length > buffer.length) throw new DNSFormatError('label runs past the message')
    labels.push(buffer.toString('utf8', position + 1, position + 1 + length))
    total += length + 1
    if (total > 255) throw new DNSFormatError('name too long')
    position += 1 + length
  }
  return [labels, next]
}
