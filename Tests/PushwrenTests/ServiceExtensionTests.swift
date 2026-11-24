import Foundation
import PushwrenNotificationService
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

    /// An app extension to put in a fixture app's PlugIns.
    private struct Plugin {
        var name = "NotificationService"
        var point: String? = ServiceExtensionTests.notificationService
        /// The executable's bytes; nil leaves the executable out.
        var executable: Data? = ServiceExtensionTests.binary(containing: ServiceExtension.marker)
        /// Xcode's Debug builds put the code in `<executable>.debug.dylib` beside a small stub.
        var debugDylib: Data?
        /// The Mac layout (Contents/Info.plist, Contents/MacOS/<executable>) instead of the iOS one.
        var mac = false
    }

    /// Some bytes standing in for a linked executable, with `text` somewhere in the middle.
    private static func binary(containing text: String? = nil) -> Data {
        var data = Data(repeating: 0xCF, count: 40_000)
        if let text { data.append(contentsOf: Array(text.utf8) + [0]) }
        data.append(Data(repeating: 0xFA, count: 40_000))
        return data
    }

    /// A fixture app bundle (Mac layout, so Foundation finds its PlugIns on the Mac the tests run on)
    /// with these extensions; nil makes one with no PlugIns folder at all.
    private func app(_ plugins: [Plugin]?) throws -> Bundle {
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try plist(["CFBundleIdentifier": "com.example.fixture", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"])
            .write(to: contents.appendingPathComponent("Info.plist"))
        for plugin in plugins ?? [] {
            let appex = contents.appendingPathComponent("PlugIns/\(plugin.name).appex", isDirectory: true)
            let infoFolder = plugin.mac ? appex.appendingPathComponent("Contents", isDirectory: true) : appex
            let executableFolder = plugin.mac ? infoFolder.appendingPathComponent("MacOS", isDirectory: true) : appex
            try FileManager.default.createDirectory(at: executableFolder, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleExecutable": plugin.name, "CFBundlePackageType": "XPC!"]
            if let point = plugin.point { info["NSExtension"] = ["NSExtensionPointIdentifier": point] }
            try plist(info).write(to: infoFolder.appendingPathComponent("Info.plist"))
            try plugin.executable?.write(to: executableFolder.appendingPathComponent(plugin.name))
            try plugin.debugDylib?.write(to: executableFolder.appendingPathComponent("\(plugin.name).debug.dylib"))
        }
        return try XCTUnwrap(Bundle(url: app))
    }

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    func testTheMarkerIsTheHelpersOwn() {
        XCTAssertEqual(ServiceExtension.marker, PushwrenExtension.markerString)
    }

    func testANotificationServiceExtensionWithTheMarkerIsFound() throws {
        XCTAssertTrue(ServiceExtension.detect(in: try app([Plugin()])))
    }

    func testTheMacLayoutIsFoundToo() throws {
        XCTAssertTrue(ServiceExtension.detect(in: try app([Plugin(mac: true)])))
    }

    func testTheMarkerInADebugDylibIsFound() throws {
        let plugin = Plugin(executable: Self.binary(), debugDylib: Self.binary(containing: ServiceExtension.marker))
        XCTAssertTrue(ServiceExtension.detect(in: try app([plugin])))
    }

    func testANotificationServiceExtensionWithoutTheMarkerIsNot() throws {
        XCTAssertFalse(ServiceExtension.detect(in: try app([Plugin(executable: Self.binary(containing: "com.example.something-else"))])))
    }

    func testAnAppWithoutPlugInsHasNone() throws {
        XCTAssertFalse(ServiceExtension.detect(in: try app(nil)))
        XCTAssertFalse(ServiceExtension.detect(in: try app([])))
    }

    func testTheMarkerInAnotherKindOfExtensionDoesNotCount() throws {
        XCTAssertFalse(ServiceExtension.detect(in: try app([Plugin(name: "Widgets", point: Self.widget)])))
        XCTAssertFalse(ServiceExtension.detect(in: try app([Plugin(name: "Odd", point: nil)])))
    }

    func testOneMatchingExtensionAmongOthersIsEnough() throws {
        let plugins = [
            Plugin(name: "Widgets", point: Self.widget, executable: Self.binary()),
            Plugin(name: "Their", executable: Self.binary()),
            Plugin(name: "NotificationService"),
        ]
        XCTAssertTrue(ServiceExtension.detect(in: try app(plugins)))
    }

    func testAMissingExecutableIsNotAMatch() throws {
        XCTAssertFalse(ServiceExtension.detect(in: try app([Plugin(executable: nil)])))
    }
}
