import Foundation
#if os(macOS)
import Security
#endif

/// The APNs environment a build's push entitlement points at.
public enum ApsEnvironment: String, Sendable, Codable {
    case sandbox, production
}

/// Which Apple platform the app is running on, as the API names it.
enum Platform: String, Sendable, Codable {
    case ios, ipados, macos, maccatalyst

    static var current: Platform {
        #if targetEnvironment(macCatalyst)
        return .maccatalyst
        #elseif os(macOS)
        return .macos
        #else
        return modelIdentifier.hasPrefix("iPad") ? .ipados : .ios
        #endif
    }

    /// The hardware model, such as "iPhone17,2". On the simulator, the simulated model.
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(macOS)
        let name = "hw.model"
        #else
        let name = "hw.machine"
        #endif
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The entitlement that names the APNs environment: Apple uses a different key on the Mac.
    var apsEntitlementKey: String {
        switch self {
        case .ios, .ipados: "aps-environment"
        case .macos, .maccatalyst: "com.apple.developer.aps-environment"
        }
    }
}

struct EnvironmentDetection: Sendable, Equatable {
    /// nil when the build has no push entitlement at all.
    let environment: ApsEnvironment?
    let warning: String?
}

/// Spec section 8, "Environment detection". The provisioning profile embedded in the app names
/// the APNs environment, except that TestFlight and App Store builds on iOS carry no profile.
enum EnvironmentDetector {
    static let missingCapability =
        "This build has no APNs entitlement. In Xcode, add the Push Notifications capability to the app target."

    /// The XML plist inside a provisioning profile's signed (CMS) envelope.
    static func parseProfile(_ data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
    }

    static func fromEntitlement(_ value: String?) -> EnvironmentDetection {
        switch value {
        case "development": EnvironmentDetection(environment: .sandbox, warning: nil)
        case "production": EnvironmentDetection(environment: .production, warning: nil)
        default: EnvironmentDetection(environment: nil, warning: missingCapability)
        }
    }

    static func fromProfile(_ data: Data?, platform: Platform) -> EnvironmentDetection {
        guard let data else {
            switch platform {
            case .ios, .ipados:
                return EnvironmentDetection(environment: .production, warning: nil)
            case .macos, .maccatalyst:
                // Every Mac distribution carries a profile, so a missing one means push isn't set up.
                return EnvironmentDetection(
                    environment: .production,
                    warning: "No embedded provisioning profile: assuming production. Push is probably not configured for this build."
                )
            }
        }
        let entitlements = parseProfile(data)?["Entitlements"] as? [String: Any]
        return fromEntitlement(entitlements?[platform.apsEntitlementKey] as? String)
    }

    /// The running app's environment.
    static func detect() -> EnvironmentDetection {
        #if targetEnvironment(simulator)
        return EnvironmentDetection(environment: .sandbox, warning: nil)
        #else
        let platform = Platform.current
        #if os(macOS)
        // The code signature carries the entitlement itself, whatever the profile says.
        if let task = SecTaskCreateFromSelf(nil),
           let value = SecTaskCopyValueForEntitlement(task, platform.apsEntitlementKey as CFString, nil) as? String {
            return fromEntitlement(value)
        }
        #endif
        return fromProfile(embeddedProfile(platform), platform: platform)
        #endif
    }

    private static func embeddedProfile(_ platform: Platform) -> Data? {
        let url: URL? = switch platform {
        case .ios, .ipados: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        case .macos, .maccatalyst: Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        }
        return url.flatMap { try? Data(contentsOf: $0) }
    }
}
