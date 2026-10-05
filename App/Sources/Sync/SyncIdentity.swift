import Foundation
import WaitingPawsCore
#if os(iOS)
import UIKit
#else
import IOKit
#endif

/// This device as the others see it when linking: a stable id (their pairings are bound to it), the kind, the
/// model and the name — the user's own from Settings (`AppSettings.linkName`), otherwise the system's.
enum SyncIdentity {
    /// Made once per install. The iPhone has sent it as `deviceID` since the first sync, so Macs keep their pairings.
    static let deviceID: String = {
        let key = "sync.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        #if os(iOS)
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        let id = UUID().uuidString
        #endif
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    #if os(iOS)
    /// An iPhone app also runs on iPads (and reports the phone idiom there), so the model decides.
    static let platform: SyncPlatform = UIDevice.current.model.hasPrefix("iPad") ? .ipad : .iphone

    /// "iPhone 16"; the generic "iPhone" for a model newer than the table.
    static let model: String = {
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine()
        return DeviceModelName.iPhone(identifier) ?? UIDevice.current.model
    }()

    /// iOS gives apps just "iPhone" as the device's name (the user's own one needs a special entitlement), which
    /// says nothing on a Mac that sees two of them — so the model stands in until the user names this iPhone.
    @MainActor static var systemName: String {
        let name = UIDevice.current.name
        return name == UIDevice.current.model ? model : name
    }

    private static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    #else
    static let platform: SyncPlatform = .mac

    /// "MacBook Pro", "Mac mini".
    static let model: String = DeviceModelName.mac(productName: productName(), identifier: hardwareModel())

    /// The computer name from System Settings → General → Sharing.
    static let systemName: String = Host.current().localizedName ?? "Mac"

    /// "MacBook Pro (16-inch, Nov 2023)" — Apple silicon Macs keep it in the device tree; nil on Intel.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// "Mac15,7", "MacBookAir10,1".
    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
    #endif
}
