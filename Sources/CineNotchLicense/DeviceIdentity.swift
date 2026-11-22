import Foundation
import IOKit

/// Who this Mac is, for the license: a hash of the platform UUID, so the server (and Creem's dashboard) never see
/// the UUID itself, a name, or anything about the user. It is the same after reinstalling the app or macOS.
public enum DeviceIdentity {
    /// 64 hex characters: SHA-256 of "cinenotch.device.v1:" + the platform UUID.
    public static func hash() -> String {
        LicenseHash.sha256Hex("cinenotch.device.v1:" + platformUUID())
    }

    /// The hardware model, like "MacBookAir10,1". It names the activation in Creem's dashboard.
    public static func model() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }

    private static func platformUUID() -> String {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0,
           let value = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
               .takeRetainedValue() as? String, !value.isEmpty {
            return value
        }
        // Rare: no platform UUID. A random one kept for this user stands in, so the license still works on this Mac.
        let key = "licenseFallbackDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }
}
