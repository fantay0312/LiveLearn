import XCTest
@testable import LiveLearnApp

final class BrowserExtensionInstallerTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/BrowserExtension")
    }

    @MainActor func testBundledArchiveInstallsWithStableIdentityAndRepairsModifiedFiles() throws {
        try requireBundledPackage()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let destination = temporary.appendingPathComponent("Library/Application Support/LiveLearn/扩展")
        let package = try BrowserExtensionFiles.install(resources: resources, destination: destination)
        try package.validate(directory: destination)
        XCTAssertTrue(BrowserExtensionInstaller(resources: resources, destination: destination).prepared)
        try Data("changed same-version guide".utf8).write(to: destination.appendingPathComponent("livelearn.html"))
        let stale = BrowserExtensionInstaller(resources: resources, destination: destination)
        XCTAssertFalse(stale.prepared)
        XCTAssertTrue(stale.needsUpdate)
        try Data("broken".utf8).write(to: destination.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try package.validate(directory: destination))
        let repaired = try BrowserExtensionFiles.install(resources: resources, destination: destination)
        XCTAssertEqual(package.extensionID, repaired.extensionID)
        try repaired.validate(directory: destination)
    }

    func testDamagedArchivePreservesExistingInstallation() throws {
        try requireBundledPackage()
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let badResources = temporary.appendingPathComponent("resources")
        try fm.copyItem(at: resources, to: badResources)
        try Data("broken archive".utf8).write(to: badResources.appendingPathComponent("chromium.zip"))
        let destination = temporary.appendingPathComponent("existing")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("keep.txt")
        try Data("keep existing extension".utf8).write(to: sentinel)
        XCTAssertThrowsError(try BrowserExtensionFiles.install(resources: badResources, destination: destination))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep existing extension")
    }

    func testAllBrowsersUseLocalManagerAndExistingSettingsValuesRemainStable() {
        for browser in TranslationBrowser.allCases {
            XCTAssertEqual(browser.managerURL.host, "extensions")
            XCTAssertFalse(["http", "https"].contains(browser.managerURL.scheme!))
        }
        XCTAssertEqual(SettingsTab.theme.rawValue, 9)
        XCTAssertEqual(SettingsTab.browserExtension.rawValue, 10)
    }

    private func requireBundledPackage() throws {
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("package.json").path) else {
            throw XCTSkip("Run script/build_browser_extension.sh to enable packaged extension integration tests.")
        }
    }
}
