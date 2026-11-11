// Port of Sync/SyncDevice.swift: who is on the other end of the iPhone ↔ computer link.

import { tr } from './localization'

/**
 * What kind of device is on the other end. It travels as a plain string (`SyncHello.platform`, TXT `os`), so a
 * kind this build doesn't know yet (a newer port) still connects and shows as a generic device.
 */
export type SyncPlatform = 'mac' | 'iphone' | 'ipad' | 'windows'

export const SyncPlatform = {
  allCases: ['mac', 'iphone', 'ipad', 'windows'] as readonly SyncPlatform[],

  /** `SyncPlatform(rawValue:)`: null for a kind this build doesn't know. */
  from(raw: string): SyncPlatform | null {
    return (SyncPlatform.allCases as readonly string[]).includes(raw) ? (raw as SyncPlatform) : null
  },

  /** What the UI calls a device of this kind: «Подтвердите на Mac», «Запись на ПК». */
  title(platform: SyncPlatform): string {
    switch (platform) {
      case 'mac':
        return 'Mac'
      case 'iphone':
        return 'iPhone'
      case 'ipad':
        return 'iPad'
      case 'windows':
        return tr('PC', 'ПК')
    }
  },

  /** SF Symbol of a device of this kind; for a Mac the model tells a laptop from a desktop. */
  symbolName(platform: SyncPlatform, model: string): string {
    switch (platform) {
      case 'iphone':
        return 'iphone'
      case 'ipad':
        return 'ipad'
      case 'windows':
        return 'pc'
      case 'mac':
        if (model.startsWith('MacBook')) return 'laptopcomputer'
        if (model.startsWith('Mac mini')) return 'macmini'
        if (model.startsWith('Mac Studio')) return 'macstudio'
        if (model.startsWith('Mac Pro')) return 'macpro.gen3'
        return 'desktopcomputer'
    }
  },
}

/**
 * A device on the other end of the link, as the UI shows it. The id is what pairings and auto-reconnect are
 * bound to, so two Macs with the same name (or a renamed one) never mix up.
 */
export interface SyncDevice {
  id: string
  /** The name its owner gave it («MacBook Pro — Марк», «iPhone Ани»). */
  name: string
  /** null: a kind this build doesn't know. */
  kind: SyncPlatform | null
  /** "iPhone 16 Pro", "MacBook Air"; empty when unknown. */
  model: string
}

export const SyncDevice = {
  make(id: string, name: string, kind: SyncPlatform | null, model: string): SyncDevice {
    return { id, name, kind, model }
  },

  /** "Mac", "ПК"; "устройство" for an unknown kind. */
  kindTitle(device: SyncDevice): string {
    return device.kind === null ? tr('device', 'устройство') : SyncPlatform.title(device.kind)
  },

  /** The model, or the kind when the model is unknown. */
  modelTitle(device: SyncDevice): string {
    return device.model === '' ? SyncDevice.kindTitle(device) : device.model
  },

  symbolName(device: SyncDevice): string {
    return device.kind === null ? 'questionmark.square.dashed' : SyncPlatform.symbolName(device.kind, device.model)
  },

  /** The name alone says nothing new about the model (an iPhone keeps its model as the default name). */
  nameIsModel(device: SyncDevice): boolean {
    return device.name === SyncDevice.modelTitle(device)
  },

  /** The model for a detail line, unless the name already says it ("MacBook Pro — Марк"). */
  distinctModel(device: SyncDevice): string | null {
    const model = SyncDevice.modelTitle(device)
    return device.name.toLocaleLowerCase().includes(model.toLocaleLowerCase()) ? null : model
  },
}

/** This device's model as people know it. */
export const DeviceModelName = {
  /** "iPhone17,3" → "iPhone 16". null for an identifier this table doesn't know yet (a newer iPhone). */
  iPhone(identifier: string): string | null {
    return Object.prototype.hasOwnProperty.call(iPhones, identifier) ? iPhones[identifier] : null
  },

  /**
   * The Mac's product name ("MacBook Pro (16-inch, Nov 2023)") without the size and year, or its family from the
   * model identifier on Macs that don't report one ("MacBookAir10,1" → "MacBook Air"). "Mac" when nothing fits.
   */
  mac(productName: string | null, identifier: string): string {
    if (productName !== null) {
      // `split(separator:)` leaves out empty pieces; `.whitespaces` are spaces and tabs, not line breaks.
      const first = productName.replace(/\0/g, '').split('(').filter((piece) => piece !== '')[0] ?? ''
      const base = first.replace(/^[^\S\r\n]+|[^\S\r\n]+$/g, '')
      if (base !== '') return base
    }
    const families: [string, string][] = [
      ['MacBookPro', 'MacBook Pro'],
      ['MacBookAir', 'MacBook Air'],
      ['MacBook', 'MacBook'],
      ['Macmini', 'Mac mini'],
      ['MacPro', 'Mac Pro'],
      ['iMacPro', 'iMac Pro'],
      ['iMac', 'iMac'],
    ]
    for (const [prefix, name] of families) if (identifier.startsWith(prefix)) return name
    return 'Mac'
  },
}

/** iPhones that run iOS 17 and later (the app's minimum). */
const iPhones: Record<string, string> = {
  'iPhone11,2': 'iPhone XS', 'iPhone11,4': 'iPhone XS Max', 'iPhone11,6': 'iPhone XS Max', 'iPhone11,8': 'iPhone XR',
  'iPhone12,1': 'iPhone 11', 'iPhone12,3': 'iPhone 11 Pro', 'iPhone12,5': 'iPhone 11 Pro Max',
  'iPhone12,8': 'iPhone SE',
  'iPhone13,1': 'iPhone 12 mini', 'iPhone13,2': 'iPhone 12', 'iPhone13,3': 'iPhone 12 Pro',
  'iPhone13,4': 'iPhone 12 Pro Max',
  'iPhone14,2': 'iPhone 13 Pro', 'iPhone14,3': 'iPhone 13 Pro Max', 'iPhone14,4': 'iPhone 13 mini',
  'iPhone14,5': 'iPhone 13', 'iPhone14,6': 'iPhone SE', 'iPhone14,7': 'iPhone 14', 'iPhone14,8': 'iPhone 14 Plus',
  'iPhone15,2': 'iPhone 14 Pro', 'iPhone15,3': 'iPhone 14 Pro Max', 'iPhone15,4': 'iPhone 15',
  'iPhone15,5': 'iPhone 15 Plus',
  'iPhone16,1': 'iPhone 15 Pro', 'iPhone16,2': 'iPhone 15 Pro Max',
  'iPhone17,1': 'iPhone 16 Pro', 'iPhone17,2': 'iPhone 16 Pro Max', 'iPhone17,3': 'iPhone 16',
  'iPhone17,4': 'iPhone 16 Plus', 'iPhone17,5': 'iPhone 16e',
  'iPhone18,1': 'iPhone 17 Pro', 'iPhone18,2': 'iPhone 17 Pro Max', 'iPhone18,3': 'iPhone 17',
  'iPhone18,4': 'iPhone Air',
}
