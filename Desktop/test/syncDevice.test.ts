// Port of SyncDeviceTests.swift: who is on the other end of the link (ids, kinds and models), and that builds on both
// sides of the change still understand each other.
import { beforeEach, describe, expect, it } from 'vitest'
import { DeviceModelName, SyncDevice, SyncHello, SyncHostInfo, SyncMessage, SyncPlatform, SyncWelcome, setCoreLanguage } from '@core/index'

describe('SyncDevice', () => {
  beforeEach(() => setCoreLanguage('ru'))

  it('host info carries id, kind and model through TXT', () => {
    const info = SyncHostInfo.make({ name: 'MacBook Air', cameraTitle: 'Прихожая', cameraReady: true, id: '7F1C', platform: 'mac', model: 'MacBook Air' })
    const parsed = SyncHostInfo.fromTXT('MacBook Air', SyncHostInfo.txt(info))
    expect(parsed).toEqual(info)
    expect(SyncHostInfo.device(parsed)).toEqual(SyncDevice.make('7F1C', 'MacBook Air', 'mac', 'MacBook Air'))
    expect(SyncDevice.symbolName(SyncHostInfo.device(parsed))).toBe('laptopcomputer')
  })

  it('a host without an id is known by name and is a Mac', () => {
    // TXT of a build before ids: the name stands in, and only Macs advertised then.
    const txt = { v: '2', cam: 'Прихожая', ready: '1', session: '0' }
    const device = SyncHostInfo.device(SyncHostInfo.fromTXT('Mac mini', txt))
    expect(device.id).toBe('name:Mac mini')
    expect(device.kind).toBe('mac')
    expect(SyncDevice.kindTitle(device)).toBe('Mac')
    expect(SyncDevice.symbolName(device)).toBe('desktopcomputer')
  })

  it('Windows hosts and unknown kinds', () => {
    const pc = SyncHostInfo.device(SyncHostInfo.fromTXT('DESKTOP-7Q', { v: '2', id: 'A1', os: 'windows' }))
    expect(pc.kind).toBe('windows')
    expect(SyncDevice.symbolName(pc)).toBe('pc')
    // No model: the kind stands in.
    expect(SyncDevice.modelTitle(pc)).toBe(SyncDevice.kindTitle(pc))

    const future = SyncHostInfo.device(SyncHostInfo.fromTXT('Box', { v: '2', id: 'B2', os: 'toaster' }))
    // A kind this build doesn't know is not taken for a Mac.
    expect(future.kind).toBeNull()
    expect(SyncDevice.symbolName(future)).toBe('questionmark.square.dashed')
  })

  it('a hello from an older iPhone is an iPhone', () => {
    // A v2 hello before `platform` and `model` existed.
    const json = '{"hello":{"_0":{"deviceID":"D1","deviceName":"iPhone","publicKey":"AAEC","protocolVersion":2}}}'
    const message = SyncMessage.decode(json)
    if (message.kind !== 'hello') throw new Error('not a hello')
    const device = SyncHello.device(message.hello)
    expect(device).toEqual(SyncDevice.make('D1', 'iPhone', 'iphone', ''))
    expect(SyncDevice.modelTitle(device)).toBe('iPhone')
    expect(SyncDevice.nameIsModel(device)).toBe(true)
  })

  it('new hello and welcome are still read by older builds', () => {
    const hello = SyncHello.make({ deviceID: 'D1', deviceName: 'iPhone Тани', publicKey: new Uint8Array([1, 2]), platform: 'iphone', model: 'iPhone 16' })
    const helloJSON = JSON.parse(SyncMessage.encode({ kind: 'hello', hello }))
    // The fields older builds decode are all there (unknown keys are ignored by `Decodable`).
    expect(helloJSON.hello._0).toMatchObject({ deviceID: 'D1', deviceName: 'iPhone Тани', publicKey: 'AQI=', protocolVersion: 2 })
    expect(helloJSON.hello._0).toMatchObject({ platform: 'iphone', model: 'iPhone 16' })

    const welcome = SyncWelcome.make({
      hostName: 'MacBook Pro',
      go2rtcPort: 11984,
      username: 'u',
      password: 'p',
      addresses: ['192.168.1.5'],
      hostID: 'H1',
      platform: 'mac',
      model: 'MacBook Pro',
    })
    const frame = SyncMessage.encode({ kind: 'welcome', welcome })
    expect(JSON.parse(frame).welcome._0).toMatchObject({ hostName: 'MacBook Pro', go2rtcPort: 11984, username: 'u', password: 'p', addresses: ['192.168.1.5'] })
    expect(SyncMessage.decode(frame)).toEqual({ kind: 'welcome', welcome })

    // …and a welcome from an older Mac reads here without the new fields, which are left out when nil.
    const oldBody = '{"hostName":"Mac","go2rtcPort":1,"username":"","password":"","addresses":[]}'
    const parsed = SyncMessage.decode(`{"welcome":{"_0":${oldBody}}}`)
    if (parsed.kind !== 'welcome') throw new Error('not a welcome')
    expect(parsed.welcome.hostID).toBeNull()
    expect(parsed.welcome.platform).toBeNull()
    expect(JSON.stringify(SyncMessage.toJSON(parsed).welcome)).toBe(`{"_0":${oldBody}}`)
  })

  it('model names', () => {
    expect(DeviceModelName.iPhone('iPhone17,3')).toBe('iPhone 16')
    expect(DeviceModelName.iPhone('iPhone16,1')).toBe('iPhone 15 Pro')
    expect(DeviceModelName.iPhone('iPhone99,1')).toBeNull()

    expect(DeviceModelName.mac('MacBook Pro (16-inch, Nov 2023)\0', 'Mac15,7')).toBe('MacBook Pro')
    expect(DeviceModelName.mac('Mac mini (2024)', 'Mac16,10')).toBe('Mac mini')
    expect(DeviceModelName.mac(null, 'MacBookAir10,1')).toBe('MacBook Air')
    expect(DeviceModelName.mac(null, 'iMacPro1,1')).toBe('iMac Pro')
    expect(DeviceModelName.mac(null, 'Mac15,7')).toBe('Mac')

    expect(SyncDevice.distinctModel(SyncDevice.make('1', 'MacBook Pro — Андрей', 'mac', 'MacBook Pro'))).toBeNull()
    expect(SyncDevice.distinctModel(SyncDevice.make('2', 'Кухня', 'mac', 'Mac mini'))).toBe('Mac mini')
    expect(SyncDevice.distinctModel(SyncDevice.make('3', 'DESKTOP-7QK', 'windows', ''))).toBe(SyncPlatform.title('windows'))
    expect(SyncPlatform.title('windows')).toBe('ПК')

    expect(SyncPlatform.symbolName('mac', 'Mac mini')).toBe('macmini')
    expect(SyncPlatform.symbolName('mac', 'iMac')).toBe('desktopcomputer')
  })
})
