// Port of CameraModesTests.swift. Fragments of real specs from miot-spec.org (2026-10-04).
import { beforeEach, describe, expect, it } from 'vitest'
import {
  CameraModeOption,
  MiotPropertyID,
  MiotSpec,
  MiotSpecError,
  MiotValue,
  XiaomiCameraError,
  setCoreLanguage,
} from '@core/index'

const c302n = `{"type": "urn:miot-spec-v2:device:camera:0000A01C:xiaomi-c302n:1:0000D070", "services": [{"iid": 2, "type": "urn:miot-spec-v2:service:camera-control:0000782F:xiaomi-c302n:1:0000D070", "properties": [{"iid": 1, "type": "urn:miot-spec-v2:property:on:00000006:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 3, "type": "urn:miot-spec-v2:property:night-shot:00000057:xiaomi-c302n:1:0000D070", "format": "uint8", "access": ["read", "write", "notify"], "value-list": [{"value": 0, "description": "Off"}, {"value": 1, "description": "On"}, {"value": 2, "description": "Auto"}]}, {"iid": 4, "type": "urn:miot-spec-v2:property:image-rollover:00000058:xiaomi-c302n:1:0000D070", "format": "uint16", "access": ["read", "write", "notify"], "value-range": [0, 270, 90]}, {"iid": 5, "type": "urn:miot-spec-v2:property:time-watermark:00000087:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 7, "type": "urn:miot-spec-v2:property:glimmer-full-color:00000089:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 9, "type": "urn:miot-spec-v2:property:human-tracking:000001A8:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 11, "type": "urn:miot-spec-v2:property:recording-mode:0000008B:xiaomi-c302n:1:0000D070", "format": "uint8", "access": ["read", "write", "notify"], "value-list": [{"value": 0, "description": "All Record "}, {"value": 1, "description": "Motion Record"}, {"value": 2, "description": "No Record"}]}, {"iid": 12, "type": "urn:miot-spec-v2:property:power-frequency:0000036B:xiaomi-c302n:1:0000D070", "format": "uint8", "access": ["read", "write", "notify"], "value-list": [{"value": 0, "description": "auto"}, {"value": 1, "description": "50"}, {"value": 2, "description": "60"}]}]}, {"iid": 4, "type": "urn:miot-spec-v2:service:indicator-light:00007803:xiaomi-c302n:1:0000D070", "properties": [{"iid": 1, "type": "urn:miot-spec-v2:property:on:00000006:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}]}, {"iid": 8, "type": "urn:miot-spec-v2:service:ai-detection:000078C8:xiaomi-c302n:1:0000D070", "properties": [{"iid": 22, "type": "urn:miot-spec-v2:property:pet-tracking:000003E4:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}]}]}`

const chuangmiV6 = `{"type": "urn:miot-spec-v2:device:camera:0000A01C:chuangmi-v6:1", "services": [{"iid": 2, "type": "urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-v6:1", "properties": [{"iid": 1, "type": "urn:miot-spec-v2:property:on:00000006:chuangmi-v6:1", "format": "bool", "access": ["write"]}, {"iid": 2, "type": "urn:miot-spec-v2:property:night-shot:00000057:chuangmi-v6:1", "format": "uint8", "access": ["read", "write"], "value-list": [{"value": 0, "description": "On"}, {"value": 1, "description": "Off"}, {"value": 2, "description": "Auto"}]}, {"iid": 3, "type": "urn:miot-spec-v2:property:image-rollover:00000058:chuangmi-v6:1", "format": "uint16", "access": ["read", "write", "notify"], "value-range": [0, 180, 180]}, {"iid": 6, "type": "urn:miot-spec-v2:property:wdr-mode:00000088:chuangmi-v6:1", "format": "bool", "access": ["read", "write"]}]}]}`

const isaHlc7 = `{"type": "urn:miot-spec-v2:device:camera:0000A01C:isa-hlc7:2", "services": [{"iid": 2, "type": "urn:miot-spec-v2:service:camera-control:0000782F:isa-hlc7:1", "properties": [{"iid": 2, "type": "urn:miot-spec-v2:property:image-rollover:00000058:isa-hlc7:1", "format": "uint16", "access": ["read", "write", "notify"], "value-range": [0, 360, 180]}, {"iid": 3, "type": "urn:miot-spec-v2:property:night-shot:00000057:isa-hlc7:1", "format": "uint8", "access": ["read", "write", "notify"], "value-list": [{"value": 0, "description": "Off"}, {"value": 1, "description": "On"}, {"value": 2, "description": "Auto"}]}]}]}`

const modes = (json: string) => MiotSpec.cameraModes(json)
const choices = (option: CameraModeOption | undefined) => (option ? CameraModeOption.choices(option) : undefined)

describe('CameraModes', () => {
  // These tests check the Russian texts (the default language of the app's first users).
  beforeEach(() => setCoreLanguage('ru'))

  it('C302 offers picture settings in display order and skips the rest', () => {
    const options = modes(c302n)
    expect(options.map((o) => o.setting)).toEqual([
      'nightShot', 'glimmerFullColor', 'imageRollover', 'timeWatermark', 'powerFrequency',
      'humanTracking', 'petTracking', 'indicatorLight',
    ])
    // Camera power and SD recording are not offered.
    expect(options.some((o) => MiotPropertyID.equals(o.property, { siid: 2, piid: 1 }))).toBe(false)
    expect(options.some((o) => MiotPropertyID.equals(o.property, { siid: 2, piid: 11 }))).toBe(false)
    expect(options.find((o) => o.setting === 'indicatorLight')?.property).toEqual({ siid: 4, piid: 1 })
    expect(options.find((o) => o.setting === 'petTracking')?.property).toEqual({ siid: 8, piid: 22 })
  })

  it('night mode values follow the spec, not the number', () => {
    const c302 = modes(c302n).find((o) => o.setting === 'nightShot')!
    expect(c302.property).toEqual({ siid: 2, piid: 3 })
    expect(choices(c302)).toEqual([
      { value: 2, title: 'Авто' },
      { value: 1, title: 'Ночной' },
      { value: 0, title: 'Обычный' },
    ])

    // On chuangmi 0 means "On".
    const v6 = modes(chuangmiV6).find((o) => o.setting === 'nightShot')!
    expect(choices(v6)).toEqual([
      { value: 2, title: 'Авто' },
      { value: 0, title: 'Ночной' },
      { value: 1, title: 'Обычный' },
    ])
    expect(CameraModeOption.text(v6, 0)).toBe('Ночной')
  })

  it('rollover and power frequency choices', () => {
    const options = modes(c302n)
    expect(choices(options.find((o) => o.setting === 'imageRollover'))?.map((c) => c.title)).toEqual([
      'Без поворота', '90°', '180°', '270°',
    ])
    expect(choices(options.find((o) => o.setting === 'powerFrequency'))?.map((c) => c.title)).toEqual([
      'Авто', '50 Гц', '60 Гц',
    ])
    // 0…360 step 180: 360° is 0° again.
    expect(choices(modes(isaHlc7).find((o) => o.setting === 'imageRollover'))?.map((c) => c.value)).toEqual([0, 180])
  })

  it('skips write-only properties', () => {
    expect(modes(chuangmiV6).map((o) => o.setting)).toEqual(['nightShot', 'wdr', 'imageRollover'])
  })

  it('spec type takes the newest version', () => {
    const index = `{"instances": [
      {"model": "chuangmi.camera.v6", "version": 1, "type": "urn:miot-spec-v2:device:camera:0000A01C:chuangmi-v6:1"},
      {"model": "xiaomi.camera.c302n", "version": 1, "type": "urn:old"},
      {"model": "xiaomi.camera.c302n", "version": 2, "type": "urn:new"}
    ]}`
    expect(MiotSpec.specType('xiaomi.camera.c302n', index)).toBe('urn:new')
    expect(MiotSpec.specType('unknown.camera.x', index)).toBeNull()
  })

  it('values decode from bools and numbers', () => {
    const values = (JSON.parse('[true, 0, 2, 1.0]') as unknown[]).map((v) => MiotValue.decode(v))
    expect(values).toEqual([true, 0, 2, 1])
    expect(MiotValue.isOn(1)).toBe(true)
    expect(MiotValue.number(true)).toBe(1)
  })

  it('camera error codes', () => {
    expect(() => XiaomiCameraError.check(0)).not.toThrow()
    expect(() => XiaomiCameraError.check(1)).not.toThrow()
    let error: unknown
    try {
      XiaomiCameraError.check(-704042011)
    } catch (e) {
      error = e
    }
    expect(XiaomiCameraError.offline().equals(error)).toBe(true)
    try {
      XiaomiCameraError.check(-704220043)
    } catch (e) {
      error = e
    }
    expect(XiaomiCameraError.failed(-704220043).equals(error)).toBe(true)
    expect((error as Error).message).toBe('Xiaomi не применил настройку (код -704220043)')
  })
})

// Not in the Swift suite.
describe('CameraModes details', () => {
  beforeEach(() => setCoreLanguage('ru'))

  it('toggle texts and unknown values', () => {
    const wdr = modes(chuangmiV6).find((o) => o.setting === 'wdr')!
    expect(CameraModeOption.text(wdr, 1)).toBe('Включено')
    expect(CameraModeOption.text(wdr, false)).toBe('Выключено')
    expect(CameraModeOption.text(wdr, null)).toBe('—')
    const night = modes(chuangmiV6).find((o) => o.setting === 'nightShot')!
    expect(CameraModeOption.text(night, 7)).toBe('7')
  })

  it('unreadable specs throw MiotSpecError', () => {
    expect(() => MiotSpec.cameraModes('{"services": [{"type": "x"}]}')).toThrow(MiotSpecError)
    expect(() => MiotSpec.cameraModes('not json')).toThrow(MiotSpecError)
    expect(MiotSpec.urnName('urn:miot-spec-v2:property:night-shot:00000057:x:1')).toBe('night-shot')
    expect(MiotSpec.urnName('urn:x')).toBe('')
  })
})
