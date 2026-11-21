import Foundation
import DriverClient

// Shared helpers for the example tasks. Everything goes through driver.call(request).

let driver = Driver()

/// The task cannot continue; the message says why and what to do.
struct TaskError: Error { let message: String; init(_ message: String) { self.message = message } }

struct Options {
    var browser = "Google Chrome"
    var dryRun = false
    var close = false
    // Task 2
    var search = "smart glasses"
    // Task 3
    var reply = "Thanks for your message. I'll take a look and get back to you soon."
    // Task 4
    var allowLocation = false
    var maxMinutes = 30
    var count = 3
    // Task 5
    var title = "Focus time"
    var hour = 15
    var minutes = 30
}

/// One driver call. Prints warnings; throws TaskError when the driver reports an error.
@discardableResult
func call(_ name: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
    let response: JSONValue
    do { response = try driver.call(["name": .string(name), "arguments": .object(arguments)]) }
    catch { throw TaskError("\(error)") }
    for warning in response["warnings"]?.arrayValue ?? [] {
        guard let text = warning.stringValue else { continue }
        // Searches already narrow the snapshot; the hint to narrow it is not news here.
        if name == "computer_snapshot", text.contains("more elements than a snapshot holds") { continue }
        print("  note (\(name)): \(text)")
    }
    guard response["ok"]?.boolValue == true, let result = response["result"] else {
        let error = response["error"]
        throw TaskError("\(name) failed: \(error?["code"]?.stringValue ?? "?"): \(error?["message"]?.stringValue ?? "")")
    }
    return result
}

/// An element from a snapshot.
extension JSONValue {
    var role: String { self["role"]?.stringValue ?? "" }
    var ref: JSONValue { self["ref"] ?? .null }
    /// The element's name, or its value when it has no name, on one line.
    var label: String {
        var text = self["name"]?.stringValue ?? ""
        if text.isEmpty {
            if let s = self["value"]?.stringValue { text = s } else if let n = self["value"]?.doubleValue { text = String(n) }
        }
        return text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
    var x: Double { self["frame"]?["x"]?.doubleValue ?? 0 }
    var y: Double { self["frame"]?["y"]?.doubleValue ?? 0 }
    var width: Double { self["frame"]?["width"]?.doubleValue ?? 0 }
    var height: Double { self["frame"]?["height"]?.doubleValue ?? 0 }
}

/// Opens a new browser window on the virtual monitor and returns its id.
func openWindow(_ browser: String) throws -> String {
    let result = try call("computer_open", ["app": .string(browser), "intent": "new_window"])
    let created = (result["windows"]?.arrayValue ?? []).first { $0["status"]?.stringValue == "created" }
    guard let window = created?["window"]?.stringValue else { throw TaskError("\(browser) did not open a new window") }
    return window
}

/// Elements in the window whose name or value contains `text`, top to bottom.
func find(_ window: String, _ text: String, role: String? = nil, visible: Bool = true) throws -> [JSONValue] {
    var arguments: [String: JSONValue] = ["window": .string(window), "query": .string(text)]
    if visible { arguments["scope"] = "visible" }
    var matches = try call("computer_snapshot", arguments)["matches"]?.arrayValue ?? []
    if let role { matches = matches.filter { $0.role == role } }
    return matches.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
}

/// Polls `check` until it returns something; throws TaskError after `timeout` seconds.
func waitFor(_ what: String, timeout: TimeInterval = 20, interval: TimeInterval = 0.7, _ check: () throws -> [JSONValue]) throws -> [JSONValue] {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let found = try check()
        if !found.isEmpty { return found }
        if Date() > deadline { throw TaskError("Timed out waiting for \(what)") }
        Thread.sleep(forTimeInterval: interval)
    }
}

/// Polls `check` until it is true; throws TaskError after `timeout` seconds.
func waitUntil(_ what: String, timeout: TimeInterval = 20, interval: TimeInterval = 0.7, _ check: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while try !check() {
        if Date() > deadline { throw TaskError("Timed out waiting for \(what)") }
        Thread.sleep(forTimeInterval: interval)
    }
}

func windowTitle(_ window: String) throws -> String {
    // A query that matches nothing keeps the answer small; only the title is wanted.
    try call("computer_snapshot", ["window": .string(window), "query": "~no-such-element~"])["title"]?.stringValue ?? ""
}

/// Types `url` into the window's address bar and presses Return.
func goto(_ window: String, _ url: String) throws {
    guard let bar = try find(window, "Address and search bar", role: "AXTextField").first else {
        throw TaskError("Could not find the browser's address bar")
    }
    try call("computer_click", ["ref": bar.ref])
    try call("computer_key", ["key": "super+a"])
    try call("computer_type", ["text": .string(url + "\n")])
}

func scroll(_ window: String, direction: String = "down", amount: Int = 6) throws {
    let shot = try call("computer_screenshot", ["window": .string(window)])
    try call("computer_scroll", [
        "in": shot["screenshot"] ?? .null,
        "x": JSONValue((shot["width"]?.intValue ?? 0) / 2), "y": JSONValue((shot["height"]?.intValue ?? 0) / 2),
        "direction": .string(direction), "amount": JSONValue(amount),
    ])
    Thread.sleep(forTimeInterval: 0.8)
}

let botChecks = ["I am human", "Check the box to continue", "Press & Hold", "confirm you are a human", "Verify you are human"]

/// Sites sometimes ask to confirm a human is present. That is for the person to answer, never the script.
func stopIfBotCheck(_ window: String) throws {
    for phrase in botChecks where try !find(window, phrase).isEmpty {
        throw TaskError("The site is asking to confirm you are human (\"\(phrase)\"). Answer it yourself in the mirror "
                        + "(Take Control), then run the task again.")
    }
}

func finish(_ window: String, _ options: Options) throws {
    if options.close {
        try call("computer_close", ["window": .string(window)])
    } else {
        print("The window (\(window)) is left open on the virtual monitor.")
    }
}

/// Form encoding for a query value: spaces become "+".
func quotePlus(_ text: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~ ")
    return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text).replacingOccurrences(of: " ", with: "+")
}
