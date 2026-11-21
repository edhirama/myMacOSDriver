import Foundation
import DriverClient

/// Task 1: open a new browser window on the virtual monitor, go to the X feed, like the first post.
func likeFirstPostOnX(_ options: Options) throws {
    let window = try openWindow(options.browser)
    try goto(window, "https://x.com/home")

    func likeButtons() throws -> [JSONValue] {
        // "47 Likes. Like" before, "48 Likes. Liked" after.
        try find(window, "Like", role: "AXButton").filter { $0.label.contains(/Likes?\. Liked?$|^Liked?$/) }
    }

    let buttons: [JSONValue]
    do { buttons = try waitFor("the feed", likeButtons) }
    catch let e as TaskError {
        if try !find(window, "Email or username").isEmpty || !find(window, "Sign in").isEmpty {
            throw TaskError("X is signed out in this browser. Sign in, then run the task again.")
        }
        throw e
    }
    let first = buttons[0]
    print("First post: \(first.label)")
    if first.label.hasSuffix("Liked") {
        print("It is already liked; nothing to do.")
    } else if options.dryRun {
        print("Dry run: not clicking Like.")
    } else {
        try call("computer_click", ["ref": first.ref])
        let after = try waitFor("the like to register", timeout: 8) { try likeButtons().filter { $0.label.hasSuffix("Liked") } }
        print("Liked: \(after[0].label)")
    }
    try finish(window, options)
}

/// Task 2: go to Amazon, find a pair of smart glasses, add it to the shopping cart. Nothing is bought.
func addSmartGlassesToAmazonCart(_ options: Options) throws {
    let window = try openWindow(options.browser)
    try goto(window, "https://www.amazon.com/s?k=" + quotePlus(options.search))

    func productLinks() throws -> [JSONValue] {
        // Product titles: one-or-two-line links below the header, not the page's navigation.
        let word = options.search.lowercased().contains("glasses") ? "glasses" : String(options.search.split(separator: " ").first ?? "")
        return try find(window, word, role: "AXLink").filter { $0.y > 250 && $0.height < 60 && $0.label.count > 30 }
    }

    let product = try waitFor("search results") { try stopIfBotCheck(window); return try productLinks() }[0]
    print("Opening: \(product.label.prefix(100))")
    let resultsTitle = try windowTitle(window)
    try call("computer_click", ["ref": product.ref])
    try waitUntil("the product page") { try windowTitle(window) != resultsTitle }
    try stopIfBotCheck(window)

    let button = try waitFor("the Add to cart button") {
        try find(window, "Add to cart", role: "AXButton").filter { $0.label.lowercased() == "add to cart" && $0.width > 20 }
    }[0]
    if options.dryRun {
        print("Dry run: not clicking Add to cart.")
    } else {
        try call("computer_click", ["ref": button.ref])
        _ = try waitFor("the cart to confirm", timeout: 15) { try find(window, "Added to cart") }
        let count = try find(window, "in cart").first?.label
        print("Added to cart." + (count.map { " Amazon says: \($0)" } ?? ""))
    }
    try finish(window, options)
}

/// Task 3: open Gmail, list the three most recent unread messages, and draft a reply to the latest
/// without sending it.
///
/// A script cannot write a summary by itself: it prints each message's sender, subject, time and
/// preview line for an agent (or you) to summarize, and types the reply text passed with --reply.
func listUnreadAndDraftReplyInGmail(_ options: Options) throws {
    let window = try openWindow(options.browser)
    try goto(window, "https://mail.google.com/mail/u/0/#inbox")

    let rows = try waitFor("the inbox", timeout: 30) {
        try find(window, "unread", role: "AXRow").filter { $0.label.lowercased().hasPrefix("unread") }
    }.prefix(3)
    print("Three most recent unread messages:")
    for (i, row) in rows.enumerated() {
        // A row reads "unread, <sender> , <subject> , <time> , <preview>".
        let parts = row.label.components(separatedBy: " , ").map { $0.trimmingCharacters(in: .whitespaces) }
        let sender = parts[0].split(separator: ",", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let subject = parts.count > 1 ? parts[1] : "", when = parts.count > 2 ? parts[2] : ""
        print("  \(i + 1). \(sender) | \(subject) | \(when)\n     \(parts.dropFirst(3).joined(separator: " ").prefix(240))")
    }
    if options.dryRun {
        print("Dry run: not opening the latest message (that would mark it read) and not drafting.")
        return try finish(window, options)
    }

    func replyBox() throws -> [JSONValue] {
        let english = try find(window, "Message Body", role: "AXTextArea")
        return english.isEmpty ? try find(window, "Corpo da mensagem", role: "AXTextArea") : english
    }

    let inboxTitle = try windowTitle(window)
    try call("computer_click", ["ref": rows[0].ref])
    try waitUntil("the message to open") { try windowTitle(window) != inboxTitle }
    let reply = try waitFor("the Reply button") {
        try find(window, "Reply", role: "AXButton").filter { ["Reply", "Responder"].contains($0.label) }
    }[0]
    try call("computer_click", ["ref": reply.ref])
    let body = try waitFor("the reply box", replyBox)[0]
    try call("computer_click", ["ref": body.ref])
    try call("computer_type", ["text": .string(options.reply)])
    let typed = try replyBox().first?["value"]?.stringValue ?? ""
    guard typed.contains(options.reply.prefix(20)) else { throw TaskError("The reply text did not appear in the reply box") }
    print("Draft typed and left unsent. Gmail saves it to Drafts on its own.")
    try finish(window, options)
}

/// Task 4: open iFood (Uber Eats does not operate in Brazil) and find three nearby options with an
/// estimated delivery time under 30 minutes.
///
/// iFood needs a delivery address. If none is set, the task uses the browser's location, which makes
/// the browser ask for permission: pass --allow-location to have the task choose "Allow this time",
/// or answer the prompt yourself in the mirror.
func findFastDinnerOptionsOnIFood(_ options: Options) throws {
    struct Place: Comparable {
        let high: Int, low: Int, text: String
        static func < (a: Place, b: Place) -> Bool { (a.high, a.low, a.text) < (b.high, b.low, b.text) }
    }
    let card = /Entrega entre (\d+) e (\d+) minutos/
    let window = try openWindow(options.browser)
    try goto(window, "https://www.ifood.com.br/restaurantes")

    func cards() throws -> [JSONValue] {
        try find(window, "Entrega entre", role: "AXButton").filter { $0.label.contains(card) }
    }
    func locationButton() throws -> [JSONValue] { try find(window, "Usar minha localização", role: "AXButton") }
    func listing() throws -> [JSONValue] {
        // With an address set, the page opens on its categories; the restaurant cards are further down.
        for look in [cards, { try find(window, "Conheça as categorias") }, { try find(window, "Lanches", role: "AXLink") }] {
            let found = try look()
            if !found.isEmpty { return found }
        }
        return []
    }

    _ = try waitFor("iFood to load", timeout: 30) {
        try stopIfBotCheck(window)
        let button = try locationButton()
        return button.isEmpty ? try listing() : button
    }
    if let button = try locationButton().first {
        try call("computer_click", ["ref": button.ref])
        Thread.sleep(forTimeInterval: 2.5)
        // The permission prompt is the browser's own bubble, not part of the page.
        if let prompt = try call("computer_snapshot", ["query": "Allow this time"])["matches"]?.arrayValue?.first {
            guard options.allowLocation else {
                throw TaskError("The browser is asking to share your location with iFood. Answer it in the mirror (Take Control), "
                                + "or run again with --allow-location.")
            }
            try call("computer_click", ["ref": prompt.ref])
            Thread.sleep(forTimeInterval: 1.5)
        }
        if let again = try locationButton().first { try call("computer_click", ["ref": again.ref]) }
        _ = try waitFor("restaurants near you", timeout: 30) {
            try stopIfBotCheck(window)
            return try locationButton().isEmpty ? try listing() : []
        }
    }

    var seen: [String: Place] = [:]
    func collect() throws -> [Place] {
        for c in try cards() {
            let text = c.label
            guard let m = text.firstMatch(of: card), let low = Int(m.1), let high = Int(m.2) else { continue }
            seen[text.components(separatedBy: ". Nota")[0]] = Place(high: high, low: low, text: text)
        }
        return seen.values.filter { $0.high < options.maxMinutes }
    }

    // Walk the list: load more while the page offers it, otherwise scroll on.
    for _ in 0..<40 {
        try stopIfBotCheck(window)
        if try collect().count >= options.count + 2 { break }
        if let more = try find(window, "Ver mais", role: "AXButton").last(where: { $0.y > 250 }) {
            try call("computer_click", ["ref": more.ref])
            Thread.sleep(forTimeInterval: 2.5)
        } else {
            try scroll(window, direction: "down", amount: 8)
        }
    }
    let fast = try collect().sorted()
    print("\(seen.count) places seen, \(fast.count) with delivery under \(options.maxMinutes) minutes:")
    for p in fast.prefix(max(options.count, 3)) { print("  \(p.low)-\(p.high) min | \(p.text)") }
    if fast.count < options.count {
        print("Fewer than \(options.count) qualify right now. Fastest of the rest:")
        for p in seen.values.filter({ $0.high >= options.maxMinutes }).sorted().prefix(3) {
            print("  \(p.low)-\(p.high) min | \(p.text.components(separatedBy: ". Nota")[0])")
        }
    }
    try finish(window, options)
}

/// Task 5: open Google Calendar on the virtual monitor and create a 30-minute event called
/// "Focus time" for tomorrow at 3 PM. Does nothing if the event is already there.
func createFocusTimeInCalendar(_ options: Options) throws {
    let calendar = Calendar.current
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
    let start = calendar.date(bySettingHour: options.hour, minute: 0, second: 0, of: tomorrow)!
    let end = start.addingTimeInterval(TimeInterval(options.minutes * 60))
    let day = calendar.dateComponents([.year, .month, .day], from: tomorrow)
    let dayView = "https://calendar.google.com/calendar/u/0/r/day/\(day.year!)/\(day.month!)/\(day.day!)"
    func text(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
        return f.string(from: date)
    }

    let window = try openWindow(options.browser)

    func events() throws -> [JSONValue] {
        // Event chips read like "3pm - 3:30pm, Focus time, <calendar>, ..."
        // The whole day is searched, not only the hours scrolled into view.
        try find(window, options.title, role: "AXButton", visible: false).filter { $0.label.contains(", \(options.title),") }
    }
    func saveButton() throws -> [JSONValue] {
        try find(window, "Sa", role: "AXButton").filter { ["Save", "Salvar"].contains($0.label) }
    }

    try goto(window, dayView)
    _ = try waitFor("the calendar", timeout: 30) {
        for query in [String(day.year!), "Create", "Criar"] {
            let found = try find(window, query)
            if !found.isEmpty { return found }
        }
        return []
    }
    // The page appears before its events do. Give them time to be drawn before concluding there are none:
    // deciding too early creates the event a second time.
    var existing: [JSONValue] = []
    for _ in 0..<8 {
        existing = try events()
        if !existing.isEmpty { break }
        Thread.sleep(forTimeInterval: 1)
    }
    if let event = existing.first {
        print("Already on the calendar: \(event.label)")
        return try finish(window, options)
    }
    if options.dryRun {
        print("Dry run: would create '\(options.title)' on \(text(start, "dd MMM yyyy")), \(text(start, "HH:mm"))-\(text(end, "HH:mm")).")
        return try finish(window, options)
    }

    let stamp = "yyyyMMdd'T'HHmmss"
    try goto(window, "https://calendar.google.com/calendar/u/0/r/eventedit?text=" + quotePlus(options.title)
             + "&dates=\(text(start, stamp))/\(text(end, stamp))")
    let save = try waitFor("the event form", timeout: 30, saveButton)[0]
    guard try !find(window, options.title, role: "AXTextField").isEmpty else {
        throw TaskError("The event form did not show the title; not saving")
    }
    try call("computer_click", ["ref": save.ref])
    try waitUntil("the event to be saved", timeout: 20) { try saveButton().isEmpty }
    try goto(window, dayView)
    let created = try waitFor("the event to appear", timeout: 30, events)
    print("Created: \(created[0].label)")
    try finish(window, options)
}
