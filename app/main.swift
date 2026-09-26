// Qobuz Now Playing.app: a menu-bar app that runs the watcher
// (Contents/MacOS/qobuz-now-playing) while it's open, shows what it's doing,
// and handles the one-off setup steps, so nobody needs Terminal.
// build.sh compiles it with swiftc; there's no Xcode project.
import AppKit
import ServiceManagement

let qobuzBundleID = "com.qobuz.desktop"
let agentLabel = "com.user.qobuz-nowplaying"
let agentPlist = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
let logURL = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Logs/Qobuz Now Playing.log")
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

enum BridgeState {
  case starting, waiting, connected, failed(String)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private var watcher: Process?
  private var quitting = false
  private var state = BridgeState.starting
  // The watcher reports this when Qobuz can grab the keyboard's media keys.
  private var qobuzHasAccessibility = false
  private var log: FileHandle?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Qobuz Now Playing")
    menu.delegate = self
    statusItem.menu = menu

    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    log = try? FileHandle(forWritingTo: logURL)

    if FileManager.default.fileExists(atPath: agentPlist.path), !replaceCommandLineInstall() {
      NSApp.terminate(nil)
      return
    }
    // First launch: start at login from now on. The menu can turn it off.
    if !UserDefaults.standard.bool(forKey: "didOfferLogin") {
      UserDefaults.standard.set(true, forKey: "didOfferLogin")
      try? SMAppService.mainApp.register()
    }
    startWatcher()
  }

  func applicationWillTerminate(_ notification: Notification) {
    quitting = true
    watcher?.terminate()
  }

  // The Homebrew cask and install.sh run the same watcher as a LaunchAgent.
  // Two watchers would each re-inject the bridge, so only one should run.
  private func replaceCommandLineInstall() -> Bool {
    let alert = NSAlert()
    alert.messageText = "The command-line version of Qobuz Now Playing is installed"
    alert.informativeText = """
      It already runs in the background. Remove it so this app takes over? \
      If you installed it with Homebrew, also run: brew uninstall --cask qobuz-now-playing
      """
    alert.addButton(withTitle: "Remove It")
    alert.addButton(withTitle: "Quit")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    run("/bin/launchctl", "bootout", "gui/\(getuid())/\(agentLabel)")
    try? FileManager.default.removeItem(at: agentPlist)
    try? FileManager.default.removeItem(
      at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".qobuz-nowplaying"))
    return true
  }

  // MARK: Watcher

  private func startWatcher() {
    guard let exe = Bundle.main.url(forAuxiliaryExecutable: "qobuz-now-playing") else {
      state = .failed("the app is missing its qobuz-now-playing program")
      return
    }
    let process = Process()
    process.executableURL = exe
    // Tells the watcher to exit if the app goes away without stopping it.
    process.environment = ProcessInfo.processInfo.environment.merging(["QOBUZ_NOW_PLAYING_APP": "1"]) { $1 }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    var pending = ""
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.log?.seekToEndOfFile()
      self?.log?.write(data)
      pending += String(decoding: data, as: UTF8.self)
      while let newline = pending.firstIndex(of: "\n") {
        let line = String(pending[..<newline])
        pending.removeSubrange(...newline)
        DispatchQueue.main.async { self?.handle(line) }
      }
    }
    process.terminationHandler = { [weak self] _ in
      DispatchQueue.main.async {
        guard let self, !self.quitting else { return }
        self.state = .failed("the watcher stopped; restarting it")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.startWatcher() }
      }
    }
    do {
      try process.run()
      watcher = process
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  // Log lines look like "<ISO date> bridge: installed" (see src/watcher.mjs).
  private func handle(_ line: String) {
    let message = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? line
    if message.hasPrefix("watcher ") {
      state = .starting
    } else if message.hasPrefix("bridge: waiting") {
      state = .waiting
    } else if message.hasPrefix("bridge: ") {
      qobuzHasAccessibility = message.contains("Accessibility access")
      state = message.contains("error") ? .failed(String(message.dropFirst(8))) : .connected
    } else if message.hasPrefix("inject error: ") {
      state = .failed(String(message.dropFirst(14)))
    }
    updateIcon()
  }

  private func updateIcon() {
    let symbol: String
    switch state {
    case .failed: symbol = "exclamationmark.triangle"
    default: symbol = qobuzHasAccessibility ? "exclamationmark.triangle" : "music.note"
    }
    statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Qobuz Now Playing")
  }

  // MARK: Menu

  private var qobuz: NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: qobuzBundleID).first
  }

  private var statusText: String {
    if qobuz == nil { return "Qobuz isn't open" }
    switch state {
    case .starting: return "Connecting to Qobuz…"
    case .waiting: return "Waiting for Qobuz to finish loading…"
    case .connected: return "Working: Qobuz shows in Now Playing"
    case .failed(let reason): return "Not working: \(reason)"
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(disabled("Qobuz Now Playing \(appVersion)"))
    menu.addItem(disabled(statusText))
    if qobuzHasAccessibility {
      menu.addItem(.separator())
      menu.addItem(disabled("Media keys always control Qobuz"))
      menu.addItem(item("Fix Media Keys…", #selector(fixMediaKeys)))
    }
    menu.addItem(.separator())
    let login = item("Open at Login", #selector(toggleLogin))
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)
    menu.addItem(item("Show Log", #selector(showLog)))
    menu.addItem(.separator())
    menu.addItem(item("Quit Qobuz Now Playing", #selector(NSApplication.terminate(_:)), key: "q"))
  }

  private func disabled(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
    return item
  }

  @objc private func toggleLogin() {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch {
      show("Couldn't change Open at Login", error.localizedDescription)
    }
  }

  @objc private func showLog() {
    NSWorkspace.shared.open(logURL)
  }

  // With Accessibility access, Qobuz grabs the keyboard's media keys before
  // macOS can send them to whatever is playing. See the README.
  @objc private func fixMediaKeys() {
    let alert = NSAlert()
    alert.messageText = "Remove Qobuz's Accessibility access?"
    alert.informativeText = """
      Qobuz then stops grabbing the keyboard's play/pause, next and previous keys, \
      and they control whatever is playing. Qobuz has to quit and reopen for this to take effect.

      When Qobuz asks for Accessibility access again, tick the option to not ask again and decline.
      """
    alert.addButton(withTitle: qobuz == nil ? "Remove Access" : "Remove Access and Reopen Qobuz")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    guard run("/usr/bin/tccutil", "reset", "Accessibility", qobuzBundleID) else {
      show("Couldn't remove the access",
           "Open System Settings > Privacy & Security > Accessibility, select Qobuz and click −.")
      return
    }
    qobuzHasAccessibility = false
    updateIcon()
    guard let running = qobuz, let appURL = running.bundleURL else { return }
    running.terminate()
    // Wait for Qobuz to quit, then open it again; the watcher reconnects on its own.
    DispatchQueue.global().async {
      for _ in 0..<100 where !running.isTerminated { usleep(100_000) }
      DispatchQueue.main.async {
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
      }
    }
  }

  private func show(_ title: String, _ text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  @discardableResult
  private func run(_ path: String, _ args: String...) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
