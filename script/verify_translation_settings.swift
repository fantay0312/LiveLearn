// Runs only with disposable settings and helper bundles prepared by the companion script.
import AppKit
import WebKit

final class ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

let args = CommandLine.arguments
let bundle = Bundle(path: args[1])!
let suite = bundle.bundleIdentifier!
precondition(suite.hasPrefix("com.fantasy.livelearn.testing."))
let preferences = UserDefaults(suiteName: suite)!
preferences.removePersistentDomain(forName: suite)
preferences.setPersistentDomain([
    "EZConfiguration_kFirstLaunch": false,
    "EZConfiguration_kAutoSelectTextKey": false,
    "EZConfiguration_kClearInputKey": false,
    "LanguagePreferenceLocalKey": "zh-Hans"
], forName: suite)
preferences.synchronize()
let hostDefault = UserDefaults.standard.object(forKey: "EZConfiguration_kClearInputKey")
UserDefaults.standard.set("host-sentinel", forKey: "EZConfiguration_kClearInputKey")

let child = Process()
let input = Pipe(), output = Pipe()
child.executableURL = URL(fileURLWithPath: args[2])
child.arguments = ["--livelearn-embedded"]
var environment = ProcessInfo.processInfo.environment
environment["LIVELEARN_TRANSLATION_CHANNEL"] = "settings-probe"
child.environment = environment
child.standardInput = input
child.standardOutput = output
child.standardError = FileHandle.nullDevice
let lock = NSLock()
var replies: [[String: Any]] = []
var buffer = Data()
output.fileHandleForReading.readabilityHandler = { file in
    let data = file.availableData
    lock.lock(); defer { lock.unlock() }
    buffer.append(data)
    while let end = buffer.firstIndex(of: 10) {
        let line = String(decoding: buffer[..<end], as: UTF8.self)
        buffer.removeSubrange(...end)
        let prefix = "LIVELEARN_TRANSLATION:settings-probe:"
        if line.hasPrefix(prefix), let value = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count).utf8)) as? [String: Any] { replies.append(value) }
    }
}
func send(_ action: String, id: String) {
    var data = try! JSONSerialization.data(withJSONObject: ["action": action, "id": id])
    data.append(10)
    try! input.fileHandleForWriting.write(contentsOf: data)
}
try child.run()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let mainBundleClass = object_getClass(Bundle.main)
let webMethod = class_getClassMethod(WKWebView.self, NSSelectorFromString("handlesURLScheme:"))!
let webImplementation = unsafeBitCast(method_getImplementation(webMethod), to: UInt.self)
try bundle.loadAndReturnError()
let type = bundle.principalClass as! NSViewController.Type
let controller = type.init(nibName: nil, bundle: bundle)
var forwarded = 0
let callback: @convention(block) (NSDictionary) -> Void = { message in
    if message["action"] as? String == "settings.reload" {
        forwarded += 1
        send("settings.reload", id: "reload")
    }
}
controller.setValue(callback, forKey: "eventHandler")
let window = ProbeWindow(contentRect: NSRect(x: 200, y: 100, width: 838, height: 668), styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentViewController = controller
controller.view.frame = NSRect(x: 0, y: 0, width: 838, height: 668)
controller.view.appearance = NSAppearance(named: .darkAqua)
window.orderBack(nil)

var bindingChanged = false
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    if let type = NSClassFromString("Easydict.MyConfiguration"),
       let method = class_getClassMethod(type, NSSelectorFromString("shared")) {
        typealias Shared = @convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>
        let model = unsafeBitCast(method_getImplementation(method), to: Shared.self)(type, NSSelectorFromString("shared")).takeUnretainedValue()
        model.setValue(true, forKey: "clearInput")
        bindingChanged = model.value(forKey: "clearInput") as? Bool == true
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { send("status", id: "status") }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    lock.lock()
    let status = replies.last { $0["id"] as? String == "status" }
    lock.unlock()
    preferences.synchronize()
    let result: [String: Any] = ["originalBindingUpdated": bindingChanged,
        "storedInTranslationDomain": preferences.bool(forKey: "EZConfiguration_kClearInputKey"),
        "hostBundleClassUnchanged": object_getClass(Bundle.main) === mainBundleClass,
        "webKitUnchanged": unsafeBitCast(method_getImplementation(webMethod), to: UInt.self) == webImplementation,
        "hostDomainUntouched": UserDefaults.standard.string(forKey: "EZConfiguration_kClearInputKey") == "host-sentinel",
        "changeForwarded": forwarded > 0,
        "helperReadUpdatedValue": status?["settingsClearInput"] as? Bool == true,
        "insideHostWindow": controller.view.window === window,
        "noExtraWindow": NSApp.windows.filter(\.isVisible).count == 1,
        "noKeyFocus": !window.isKeyWindow]
    try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[3]))
    send("shutdown", id: "shutdown")
    try? input.fileHandleForWriting.close()
    window.close()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        if child.isRunning { child.terminate() }
        preferences.removePersistentDomain(forName: suite)
        if let hostDefault { UserDefaults.standard.set(hostDefault, forKey: "EZConfiguration_kClearInputKey") } else { UserDefaults.standard.removeObject(forKey: "EZConfiguration_kClearInputKey") }
        exit(result.values.allSatisfy { ($0 as? Bool) == true } ? 0 : 1)
    }
}
app.run()
