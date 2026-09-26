// Qobuz Now Playing.app: a menu-bar app that runs the watcher
// (Contents/MacOS/qobuz-now-playing) while it's open, shows what it's doing,
// and walks through the one-off setup, so nobody needs Terminal.
// The menu-bar icon can be hidden; opening the app again shows its window.
// build.sh compiles it with swiftc; there's no Xcode project.
import AppKit
import ServiceManagement
import SwiftUI

let qobuzBundleID = "com.qobuz.desktop"
let agentLabel = "com.user.qobuz-nowplaying"
let home = FileManager.default.homeDirectoryForCurrentUser
let agentPlist = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
let logURL = home.appendingPathComponent("Library/Logs/Qobuz Now Playing.log")
let accessibilitySettings = URL(
  string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

enum BridgeState: Equatable {
  case starting, waiting, connected, failed(String)
}

// What the menu and the window show.
final class Model: ObservableObject {
  @Published var state = BridgeState.starting
  // Whether Qobuz can grab the keyboard's media keys, as the watcher reports
  // when it connects; nil until then.
  @Published var qobuzHasAccessibility: Bool?
  @Published var qobuzOpen = false
  @Published var reopeningQobuz = false
  @Published var showIcon = UserDefaults.standard.object(forKey: "showIcon") as? Bool ?? true {
    didSet { UserDefaults.standard.set(showIcon, forKey: "showIcon") }
  }
  @Published var openAtLogin = SMAppService.mainApp.status == .enabled

  var qobuz: NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: qobuzBundleID).first
  }

  var statusText: String {
    if !qobuzOpen { return "Qobuz isn't open" }
    switch state {
    case .starting: return "Connecting to Qobuz…"
    case .waiting: return "Waiting for Qobuz to finish loading…"
    case .connected: return "Working: Qobuz shows in Now Playing"
    case .failed(let reason): return "Not working: \(reason)"
    }
  }

  func setOpenAtLogin(_ on: Bool) {
    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    openAtLogin = SMAppService.mainApp.status == .enabled
  }

  // Qobuz checks its Accessibility access only when it starts.
  func reopenQobuz() {
    guard let running = qobuz, let appURL = running.bundleURL else {
      NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Qobuz.app"))
      return
    }
    reopeningQobuz = true
    running.terminate()
    DispatchQueue.global().async {
      for _ in 0..<100 where !running.isTerminated { usleep(100_000) }
      DispatchQueue.main.async {
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, _ in
          DispatchQueue.main.async { self.reopeningQobuz = false }
        }
      }
    }
  }
}

struct SetupView: View {
  @ObservedObject var model: Model

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Image(systemName: "music.note").font(.largeTitle)
        VStack(alignment: .leading) {
          Text("Qobuz Now Playing").font(.title2).bold()
          Text(model.statusText).foregroundStyle(.secondary)
        }
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          if model.qobuzHasAccessibility == false {
            Label {
              Text("Media keys work for every app").bold()
            } icon: {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text("Qobuz doesn't have Accessibility access, so there's nothing to set up.")
              .fixedSize(horizontal: false, vertical: true)
          } else {
            Label {
              Text("Turn off Qobuz in Accessibility").bold()
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text("""
              Qobuz asks for Accessibility access so it can grab the keyboard's play/pause, \
              next and previous keys, which stops them working for any other app. \
              Qobuz Now Playing doesn't need this access, and Qobuz works without it.
              """)
              .fixedSize(horizontal: false, vertical: true)
            Text("""
              1. Click Open Accessibility Settings and switch off Qobuz.
              2. Click Reopen Qobuz; it only notices the change when it starts. \
              If it asks for the access again, tick the option to not ask again and decline.
              """)
              .fixedSize(horizontal: false, vertical: true)
            HStack {
              Button("Open Accessibility Settings") { NSWorkspace.shared.open(accessibilitySettings) }
              Button(model.qobuzOpen ? "Reopen Qobuz" : "Open Qobuz") { model.reopenQobuz() }
                .disabled(model.reopeningQobuz)
            }
            if !model.qobuzOpen {
              Text("Open Qobuz so this app can check whether it's done.").foregroundStyle(.secondary)
            } else if model.qobuzHasAccessibility == nil {
              Text("Checking Qobuz…").foregroundStyle(.secondary)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: model.setOpenAtLogin))
          Toggle("Show icon in the menu bar", isOn: $model.showIcon)
          if !model.showIcon {
            Text("It keeps running. To get back here, open Qobuz Now Playing again from Applications or Spotlight.")
              .font(.callout).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
      }

      HStack {
        Button("Show Log") { NSWorkspace.shared.open(logURL) }
        Spacer()
        Button("Quit Qobuz Now Playing") { NSApp.terminate(nil) }
        Button("Done") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
      }
      Text("Version \(appVersion)").font(.caption).foregroundStyle(.tertiary)
    }
    .padding(20)
    .frame(width: 460)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let model = Model()
  private var statusItem: NSStatusItem?
  private var window: NSWindow?
  private var watcher: Process?
  private var quitting = false
  private var log: FileHandle?
  private var observers: [Any] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    if !FileManager.default.fileExists(atPath: logURL.path) {
      FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    log = try? FileHandle(forWritingTo: logURL)

    if FileManager.default.fileExists(atPath: agentPlist.path), !replaceCommandLineInstall() {
      NSApp.terminate(nil)
      return
    }

    model.qobuzOpen = model.qobuz != nil
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        guard let self else { return }
        self.model.qobuzOpen = self.model.qobuz != nil
        if !self.model.qobuzOpen { self.model.state = .starting }
      })
    }
    observers.append(model.$showIcon.sink { [weak self] show in
      DispatchQueue.main.async { self?.updateStatusItem(show: show) }
    })
    observers.append(model.$state.combineLatest(model.$qobuzHasAccessibility).sink { [weak self] _ in
      DispatchQueue.main.async { self?.updateIcon() }
    })

    // First launch: start at login from now on, and walk through the setup.
    if !UserDefaults.standard.bool(forKey: "didSetup") {
      UserDefaults.standard.set(true, forKey: "didSetup")
      model.setOpenAtLogin(true)
      showWindow()
    }
    startWatcher()
  }

  // Opening the app while it runs (Finder, Spotlight, Launchpad) shows the
  // window: the only way back in when the menu-bar icon is hidden.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow()
    return false
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
    try? FileManager.default.removeItem(at: home.appendingPathComponent(".qobuz-nowplaying"))
    return true
  }

  // MARK: Window

  private func showWindow() {
    if window == nil {
      let window = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: model)))
      window.title = "Qobuz Now Playing"
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  // MARK: Watcher

  private func startWatcher() {
    guard let exe = Bundle.main.url(forAuxiliaryExecutable: "qobuz-now-playing") else {
      model.state = .failed("the app is missing its qobuz-now-playing program")
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
        self.model.state = .failed("the watcher stopped; restarting it")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.startWatcher() }
      }
    }
    do {
      try process.run()
      watcher = process
    } catch {
      model.state = .failed(error.localizedDescription)
    }
  }

  // Log lines look like "<ISO date> bridge: installed" (see src/watcher.mjs).
  private func handle(_ line: String) {
    let message = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? line
    if message.hasPrefix("watcher ") {
      model.state = .starting
    } else if message.hasPrefix("bridge: waiting") {
      model.state = .waiting
    } else if message.hasPrefix("bridge: ") {
      model.qobuzHasAccessibility = message.contains("Accessibility access")
      model.state = message.contains("error") ? .failed(String(message.dropFirst(8))) : .connected
    } else if message.hasPrefix("inject error: ") {
      model.state = .failed(String(message.dropFirst(14)))
    }
  }

  // MARK: Menu bar

  private func updateStatusItem(show: Bool) {
    if show, statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      let menu = NSMenu()
      menu.delegate = self
      item.menu = menu
      statusItem = item
      updateIcon()
    } else if !show, let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
  }

  private func updateIcon() {
    let warn = model.qobuzHasAccessibility == true || { if case .failed = model.state { return true } else { return false } }()
    statusItem?.button?.image = NSImage(
      systemSymbolName: warn ? "exclamationmark.triangle" : "music.note", accessibilityDescription: "Qobuz Now Playing")
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(disabled("Qobuz Now Playing \(appVersion)"))
    menu.addItem(disabled(model.statusText))
    if model.qobuzHasAccessibility == true {
      menu.addItem(.separator())
      menu.addItem(disabled("Media keys always control Qobuz"))
      menu.addItem(item("Fix Media Keys…", #selector(openWindow)))
    }
    menu.addItem(.separator())
    menu.addItem(item("Settings…", #selector(openWindow), key: ","))
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

  @objc private func openWindow() {
    model.openAtLogin = SMAppService.mainApp.status == .enabled
    showWindow()
  }

  @objc private func showLog() {
    NSWorkspace.shared.open(logURL)
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
