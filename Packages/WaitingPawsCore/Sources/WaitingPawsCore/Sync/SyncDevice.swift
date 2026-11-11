import Foundation

/// What kind of device is on the other end. It travels as a plain string (`SyncHello.platform`, TXT `os`), so a
/// kind this build doesn't know yet (a newer port) still connects and shows as a generic device.
public enum SyncPlatform: String, CaseIterable, Sendable {
    case mac, iphone, ipad, windows

    /// What the UI calls a device of this kind: «Подтвердите на Mac», «Запись на ПК».
    public var title: String {
        switch self {
        case .mac: return "Mac"
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .windows: return tr("PC", ru: "ПК")
        }
    }

    /// SF Symbol of a device of this kind; for a Mac the model tells a laptop from a desktop.
    public func symbolName(model: String) -> String {
        switch self {
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .windows: return "pc"
        case .mac:
            if model.hasPrefix("MacBook") { return "laptopcomputer" }
            if model.hasPrefix("Mac mini") { return "macmini" }
            if model.hasPrefix("Mac Studio") { return "macstudio" }
            if model.hasPrefix("Mac Pro") { return "macpro.gen3" }
            return "desktopcomputer"
        }
    }
}

/// A device on the other end of the link, as the UI shows it. The id is what pairings and auto-reconnect are
/// bound to, so two Macs with the same name (or a renamed one) never mix up.
public struct SyncDevice: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    /// The name its owner gave it («MacBook Pro — Марк», «iPhone Ани»).
    public var name: String
    /// nil: a kind this build doesn't know.
    public var kind: SyncPlatform?
    /// "iPhone 16 Pro", "MacBook Air"; empty when unknown.
    public var model: String

    public init(id: String, name: String, kind: SyncPlatform?, model: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.model = model
    }

    /// "Mac", "ПК"; "устройство" for an unknown kind.
    public var kindTitle: String { kind?.title ?? tr("device", ru: "устройство") }

    /// The model, or the kind when the model is unknown.
    public var modelTitle: String { model.isEmpty ? kindTitle : model }

    public var symbolName: String { kind?.symbolName(model: model) ?? "questionmark.square.dashed" }

    /// The name alone says nothing new about the model (an iPhone keeps its model as the default name).
    public var nameIsModel: Bool { name == modelTitle }

    /// The model for a detail line, unless the name already says it ("MacBook Pro — Марк").
    public var distinctModel: String? {
        name.localizedCaseInsensitiveContains(modelTitle) ? nil : modelTitle
    }
}

/// This device's model as people know it.
public enum DeviceModelName {
    /// "iPhone17,3" → "iPhone 16". nil for an identifier this table doesn't know yet (a newer iPhone).
    public static func iPhone(_ identifier: String) -> String? {
        iPhones[identifier]
    }

    /// The Mac's product name ("MacBook Pro (16-inch, Nov 2023)") without the size and year, or its family from the
    /// model identifier on Macs that don't report one ("MacBookAir10,1" → "MacBook Air"). "Mac" when nothing fits.
    public static func mac(productName: String?, identifier: String) -> String {
        if let productName {
            let base = productName.replacingOccurrences(of: "\0", with: "")
                .split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !base.isEmpty { return base }
        }
        let families = [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"),
                        ("Macmini", "Mac mini"), ("MacPro", "Mac Pro"), ("iMacPro", "iMac Pro"), ("iMac", "iMac")]
        for (prefix, name) in families where identifier.hasPrefix(prefix) { return name }
        return "Mac"
    }

    /// iPhones that run iOS 17 and later (the app's minimum).
    private static let iPhones: [String: String] = [
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air",
    ]
}
