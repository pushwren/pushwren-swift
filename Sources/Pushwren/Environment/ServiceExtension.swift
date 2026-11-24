import Foundation

/// Whether the app ships Pushwren's Notification Service Extension helper (the
/// PushwrenNotificationService library), so the server can ask this device for delivery receipts.
/// An app with only its own extension doesn't count: Pushwren never makes an extension run on
/// pushes it didn't run on before.
enum ServiceExtension {
    /// `PushwrenExtension.markerString`, which the helper keeps in every extension that links it.
    /// Built from parts so this library's own binary doesn't contain it whole: an extension that
    /// links this library (and not the helper) must not count.
    static let marker = ["com", "pushwren", "notification-service", "v1"].joined(separator: ".")

    static let extensionPoint = "com.apple.usernotifications.service"

    /// True when one of the bundle's `PlugIns/*.appex` is a Notification Service Extension whose
    /// executable contains the helper's marker. Xcode's Debug builds keep an extension's code in
    /// `<executable>.debug.dylib` beside the executable, so that is searched too.
    static func detect(in bundle: Bundle) -> Bool {
        guard let plugIns = bundle.builtInPlugInsURL,
              let appexes = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
        else { return false }
        let marker = Data(marker.utf8)
        for appex in appexes where appex.pathExtension == "appex" {
            guard let executable = notificationServiceExecutable(appex) else { continue }
            let candidates = [executable, executable.deletingLastPathComponent().appendingPathComponent(executable.lastPathComponent + ".debug.dylib")]
            if candidates.contains(where: { contains(marker, file: $0) }) { return true }
        }
        return false
    }

    /// The executable of a Notification Service Extension, in the iOS layout (Info.plist and the
    /// executable at the top) or the Mac one (Contents/Info.plist, Contents/MacOS/<executable>).
    /// nil for any other kind of extension.
    private static func notificationServiceExecutable(_ appex: URL) -> URL? {
        let layouts = [
            (info: appex.appendingPathComponent("Info.plist"), executables: appex),
            (info: appex.appendingPathComponent("Contents/Info.plist"), executables: appex.appendingPathComponent("Contents/MacOS")),
        ]
        for layout in layouts {
            guard let data = try? Data(contentsOf: layout.info),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            else { continue }
            let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
            guard point == extensionPoint, let name = info["CFBundleExecutable"] as? String, !name.isEmpty else { return nil }
            return layout.executables.appendingPathComponent(name)
        }
        return nil
    }

    /// Searches the file without reading it all into memory.
    private static func contains(_ marker: Data, file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return false }
        return data.withUnsafeBytes { haystack in
            marker.withUnsafeBytes { needle in
                guard let h = haystack.baseAddress, let n = needle.baseAddress, haystack.count >= needle.count else { return false }
                return memmem(h, haystack.count, n, needle.count) != nil
            }
        }
    }
}
