import Foundation
import XCTest
@testable import Pushwren

final class ServiceExtensionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ServiceExtensionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let notificationService = "com.apple.usernotifications.service"
    private static let widget = "com.apple.widgetkit-extension"
    /// What Xcode names the helper's resource bundle in an extension that links it.
    private static let helperBundle = "Pushwren_PushwrenNotificationService.bundle"

    /// An app extension to put in a fixture app's PlugIns.
    private struct Plugin {
        var name = "NotificationService"
        var point: String? = ServiceExtensionTests.notificationService
        /// Resource bundles inside the extension.
        var bundles = [ServiceExtensionTests.helperBundle]
        /// The Mac layout (Contents/Info.plist, Contents/Resources) instead of the iOS one.
        var mac = false
    }

    /// A fixture app bundle (Mac layout, so Foundation finds its PlugIns on the Mac the tests run on)
    /// with these extensions; nil makes one with no PlugIns folder at all.
    private func app(_ plugins: [Plugin]?) throws -> Bundle {
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try plist(["CFBundleIdentifier": "com.example.fixture", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"])
            .write(to: contents.appendingPathComponent("Info.plist"))
        if plugins != nil {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("PlugIns"), withIntermediateDirectories: true)
        }
        for plugin in plugins ?? [] {
            let appex = contents.appendingPathComponent("PlugIns/\(plugin.name).appex", isDirectory: true)
            let infoFolder = plugin.mac ? appex.appendingPathComponent("Contents", isDirectory: true) : appex
            let resources = plugin.mac ? infoFolder.appendingPathComponent("Resources", isDirectory: true) : appex
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleExecutable": plugin.name, "CFBundlePackageType": "XPC!"]
            if let point = plugin.point { info["NSExtension"] = ["NSExtensionPointIdentifier": point] }
            try plist(info).write(to: infoFolder.appendingPathComponent("Info.plist"))
            for name in plugin.bundles {
                let bundle = resources.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try plist(["CFBundlePackageType": "BNDL"]).write(to: bundle.appendingPathComponent("Info.plist"))
            }
        }
        return try XCTUnwrap(Bundle(url: app))
    }

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    func testANotificationServiceExtensionWithTheHelpersBundleIsFound() throws {
        XCTAssertTrue(ServiceExtension.detect(in: try app([Plugin()])))
    }

    func testTheMacLayoutIsFoundToo() throws {
        XCTAssertTrue(ServiceExtension.detect(in: try app([Plugin(mac: true)])))
    }

    func testThePackagesNameMayDiffer() throws {
        XCTAssertTrue(ServiceExtension.detect(in: try app([Plugin(bundles: ["pushwren-swift_PushwrenNotificationService.bundle"])])))
    }

    func testANotificationServiceExtensionWithoutTheHelperIsNot() throws {
        XCTAssertFalse(ServiceExtension.detect(in: try app([Plugin(bundles: [])])))
        XCTAssertFalse(ServiceExtension.detect(in: try app([Plugin(name: "Theirs", bundles: ["Pushwren_Pushwren.bundle", "Other_Images.bundle"])])))
    }

    func testAnAppWithoutPlugInsHasNone() throws {
        XCTAssertFalse(ServiceExtension.detect(in: try app(nil)))
        XCTAssertFalse(ServiceExtension.detect(in: try app([])))
    }

    func testTheHelpersBundleInAnotherKindOfExtensionDoesNotCount() throws {
        XCTAssertFalse(ServiceExtension.detect(in: try app([Plugin(name: "Widgets", point: Self.widget)])))
        XCTAssertFalse(ServiceExtension.detect(in: try app([Plugin(name: "Odd", point: nil)])))
    }

    func testOneMatchingExtensionAmongOthersIsEnough() throws {
        let plugins = [
            Plugin(name: "Widgets", point: Self.widget),
            Plugin(name: "Theirs", bundles: []),
            Plugin(name: "NotificationService"),
        ]
        XCTAssertTrue(ServiceExtension.detect(in: try app(plugins)))
    }
}
