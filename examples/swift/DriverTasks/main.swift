import Foundation
import DriverClient

// drivertasks — the five example tasks, written against the Swift client.
//
//   drivertasks                  # all five
//   drivertasks 2 5              # only tasks 2 and 5
//   drivertasks --dry-run 1 3    # stop before anything changes in your accounts
//
// MacDriver.app must be running: open build/MacDriver.app

let usage = """
usage: drivertasks [options] [task numbers]

  1  Open the X feed and like the first post.
  2  Search Amazon for smart glasses and add the first result to the cart. Buys nothing.
  3  List the three latest unread Gmail messages and draft a reply to the latest, unsent.
  4  Find three places on iFood with delivery under 30 minutes.
  5  Create a 30-minute "Focus time" event in Google Calendar for tomorrow at 3 PM, unless it exists.

options:
  --browser NAME       browser app to drive (default: Google Chrome)
  --dry-run            stop before the step that changes anything in your account
  --close              close the browser window when the task ends
  --search TEXT        task 2: what to search for (default: smart glasses)
  --reply TEXT         task 3: text of the draft reply
  --allow-location     task 4: choose "Allow this time" on the browser's location prompt
  --max-minutes N      task 4: upper delivery estimate must be below this (default: 30)
  --count N            task 4: how many options to find (default: 3)
  --title TEXT         task 5: event title (default: Focus time)
  --hour N             task 5: start hour, 24-hour clock (default: 15)
  --minutes N          task 5: length in minutes (default: 30)
"""

func stop(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let tasks: [(name: String, run: (Options) throws -> Void)] = [
    ("X: like the first post", likeFirstPostOnX),
    ("Amazon: add smart glasses to the cart", addSmartGlassesToAmazonCart),
    ("Gmail: unread messages and a draft reply", listUnreadAndDraftReplyInGmail),
    ("iFood: dinner options under 30 minutes", findFastDinnerOptionsOnIFood),
    ("Calendar: Focus time tomorrow", createFocusTimeInCalendar),
]

var options = Options()
var chosen: [Int] = []
var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func value(of flag: String) -> String {
    guard !arguments.isEmpty else { stop("\(flag) needs a value\n\n\(usage)") }
    return arguments.removeFirst()
}
@MainActor func number(of flag: String) -> Int {
    guard let n = Int(value(of: flag)) else { stop("\(flag) needs a number\n\n\(usage)") }
    return n
}
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "-h", "--help": print(usage); exit(0)
    case "--browser": options.browser = value(of: argument)
    case "--dry-run": options.dryRun = true
    case "--close": options.close = true
    case "--search": options.search = value(of: argument)
    case "--reply": options.reply = value(of: argument)
    case "--allow-location": options.allowLocation = true
    case "--max-minutes": options.maxMinutes = number(of: argument)
    case "--count": options.count = number(of: argument)
    case "--title": options.title = value(of: argument)
    case "--hour": options.hour = number(of: argument)
    case "--minutes": options.minutes = number(of: argument)
    default:
        guard let n = Int(argument), tasks.indices.contains(n - 1) else { stop("Unknown option or task '\(argument)'\n\n\(usage)") }
        chosen.append(n)
    }
}
if chosen.isEmpty { chosen = Array(1...tasks.count) }

do { _ = try driver.status() } catch { stop("MacDriver is not running. Start it with: open build/MacDriver.app") }

// Line by line, also when the output goes to a file or a pipe.
setvbuf(stdout, nil, _IOLBF, 0)
var failed = false
for n in chosen {
    print("=== Task \(n): \(tasks[n - 1].name) ===")
    do { try tasks[n - 1].run(options) }
    catch let e as TaskError { print("STOPPED: \(e.message)"); failed = true }
    catch { print("STOPPED: \(error)"); failed = true }
    print()
}
exit(failed ? 1 : 0)
