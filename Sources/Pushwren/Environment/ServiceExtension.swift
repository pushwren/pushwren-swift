import Foundation

/// Whether the app ships Pushwren's Notification Service Extension helper (the
/// PushwrenNotificationService library), so the server can ask this device for delivery receipts.
/// An app with only its own extension doesn't count: Pushwren never makes an extension run on
/// pushes it didn't run on before.
enum ServiceExtension {
    static let extensionPoint = "com.apple.usernotifications.service"

    /// The end of the helper's resource bundle's name, which Xcode copies into every extension that
    /// links the helper: `Pushwren_PushwrenNotificationService.bundle`, the package's name first.
    static let helperBundleSuffix = "_PushwrenNotificationService.bundle"

    /// True when one of the bundle's `PlugIns/*.appex` is a Notification Service Extension that
    /// contains the helper's resource bundle. Files only: nothing in an App Store build's
    /// encrypted executables is read.
    static func detect(in bundle: Bundle) -> Bool {
        guard let plugIns = bundle.builtInPlugInsURL,
              let appexes = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
        else { return false }
        return appexes.contains { $0.pathExtension == "appex" && hasHelper($0) }
    }

    /// The iOS layout (Info.plist and resources at the top) or the Mac one (Contents/Info.plist,
    /// Contents/Resources).
    private static func hasHelper(_ appex: URL) -> Bool {
        let layouts = [
            (info: appex.appendingPathComponent("Info.plist"), resources: appex),
            (info: appex.appendingPathComponent("Contents/Info.plist"), resources: appex.appendingPathComponent("Contents/Resources")),
        ]
        for layout in layouts {
            guard let data = try? Data(contentsOf: layout.info),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            else { continue }
            let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
            guard point == extensionPoint,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: layout.resources.path)
            else { return false }
            return names.contains { $0.hasSuffix(helperBundleSuffix) }
        }
        return false
    }
}
