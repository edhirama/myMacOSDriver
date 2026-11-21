import AppKit
import DriverCore

// Menu-bar agent app (LSUIElement). Owns the virtual display, the driver and its socket.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
