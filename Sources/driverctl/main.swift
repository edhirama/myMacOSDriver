import Foundation
import DriverClient

// driverctl — command-line client for the MacDriver host.
//
//   driverctl call '{"name":"computer_apps","arguments":{}}'
//   driverctl call computer_click '{"in":"shot:ab.1","x":300,"y":200}'
//   driverctl status
//   driverctl cancel <request-id>
//
// Prints the JSON response on stdout. Exit code: 0 when ok, 1 when the call failed, 2 on usage or
// connection errors.

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func roundTrip(_ msg: JSONValue, path: String) -> JSONValue {
    // One attempt, and a wait that outlasts any call's own timeout.
    do { return try Driver(socketPath: path, retries: 0).roundTrip(msg, wait: 3600) }
    catch { fail("\(error)") }
}

func parseObject(_ s: String) -> [String: JSONValue] {
    guard let v = try? JSONValue.parse(Data(s.utf8)), let o = v.objectValue else { fail("Expected a JSON object, got: \(s)") }
    return o
}

var args = Array(CommandLine.arguments.dropFirst())
var socketPath = DriverProtocol.defaultSocketPath
var pretty = true
if let i = args.firstIndex(of: "--socket"), i + 1 < args.count { socketPath = args[i + 1]; args.removeSubrange(i...i + 1) }
if let i = args.firstIndex(of: "--compact") { pretty = false; args.remove(at: i) }

guard let cmd = args.first else {
    fail("usage: driverctl [--socket PATH] [--compact] call '<request json>' | call <tool> ['<arguments json>'] | status | tools | cancel <id>")
}

let response: JSONValue
switch cmd {
case "status":
    response = roundTrip(["op": "status"], path: socketPath)
case "tools":
    response = roundTrip(["op": "tools"], path: socketPath)
case "cancel":
    guard args.count >= 2 else { fail("usage: driverctl cancel <id>") }
    response = roundTrip(["op": "cancel", "id": .string(args[1])], path: socketPath)
case "call":
    guard args.count >= 2 else { fail("usage: driverctl call '<request json>'") }
    var req: [String: JSONValue]
    if args[1].hasPrefix("{") { req = parseObject(args[1]) }
    else {
        req = ["name": .string(args[1])]
        if args.count >= 3 { req["arguments"] = .object(parseObject(args[2])) }
    }
    if req["id"] == nil { req["id"] = .string("cli-" + UUID().uuidString.lowercased()) }
    response = roundTrip(.object(req), path: socketPath)
default:
    fail("unknown command '\(cmd)'")
}

let out = try! response.jsonData(pretty: pretty)
FileHandle.standardOutput.write(out)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
exit(response["ok"]?.boolValue == true ? 0 : 1)
