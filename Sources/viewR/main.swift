import AppKit

// Entry point: configure and run the application.
// NSApplication.shared accesses the main thread — this is fine because
// main.swift runs before the run loop starts.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
