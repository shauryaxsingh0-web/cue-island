import AppKit

private let practiceScript = """
Take a breath and look toward the camera. Read this line at a comfortable pace.

The next lines will move into view as you go. Press Space when you want a moment to think, then press it again to pick up where you left off.

When you're ready to use your own words, press Escape and paste your script.
"""

@main
@MainActor
enum CueIslandApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppController()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppController: NSObject, NSApplicationDelegate {
    private enum State { case editing, waitingForMicrophone, playing, paused, finished }

    private let preferences = UserDefaults.standard
    private let follower = SpeechFollower()
    private var state: State = .editing
    private var mode: PlaybackMode = .timed
    private var script = ""
    private var speed = 150
    private var nextSpokenWord = 0
    private var shortcutsActive = false
    private var fallbackKeys = false
    private lazy var editor = ScriptEditor(script: script, wpm: speed, mode: mode)
    private lazy var island = IslandView(frame: NSRect(origin: .zero, size: islandSize))
    private let islandSize = NSSize(width: 430, height: 132)
    private lazy var panel = IslandPanel(content: island, size: islandSize)
    private lazy var shortcuts = PresentationShortcuts(
        onToggle: { [weak self] in self?.toggle() },
        onExit: { [weak self] in self?.showEditor() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedScript = preferences.string(forKey: "script")
        script = savedScript ?? practiceScript
        speed = min(400, max(40, preferences.object(forKey: "speed") as? Int ?? 150))
        mode = PlaybackMode(rawValue: preferences.string(forKey: "mode") ?? "") ?? .timed
        buildMenus()

        editor.onChange = { [weak self] in self?.save(script: $0, speed: $1, mode: $2) }
        editor.onStart = { [weak self] in
            self?.save(script: $0, speed: $1, mode: $2)
            self?.begin()
        }
        island.onEdit = { [weak self] in self?.showEditor() }
        island.onToggle = { [weak self] in self?.toggle() }
        island.onAdjustSpeed = { [weak self] in self?.adjustSpeed(by: $0) }
        island.reader.onFinish = { [weak self] in self?.finish() }
        follower.onWord = { [weak self] index in
            guard let self, self.mode == .voice, self.state == .playing else { return }
            self.nextSpokenWord = index + 1
            self.island.reader.followSpeech(toWordIndex: index)
        }
        follower.onFinished = { [weak self] in self?.finish() }
        follower.onError = { [weak self] reason in self?.speechFailed(reason) }
        follower.onListening = { [weak self] in
            guard let self, self.state == .waitingForMicrophone else { return }
            self.state = .playing
            self.armShortcuts()
            self.refreshIsland()
        }
        editor.present()
        if savedScript == nil { editor.selectEntireScript() }
    }

    private func save(script: String, speed: Int, mode: PlaybackMode) {
        self.script = script
        self.speed = speed
        self.mode = mode
        preferences.set(script, forKey: "script")
        preferences.set(speed, forKey: "speed")
        preferences.set(mode.rawValue, forKey: "mode")
    }

    private func begin() {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        follower.stop()
        editor.window?.orderOut(nil)
        island.reader.script = script
        island.reader.wordsPerMinute = Double(speed)
        island.reader.restart()
        nextSpokenWord = 0
        panel.showIsland()
        resume()
    }

    private func resume() {
        if mode == .timed {
            state = .playing
            armShortcuts()
            island.reader.isPlaying = true
        } else {
            state = .waitingForMicrophone
            disarmShortcuts()
            follower.start(script: script, fromWordIndex: nextSpokenWord)
        }
        refreshIsland()
    }

    private func armShortcuts() {
        guard !shortcutsActive else { return }
        fallbackKeys = !shortcuts.start()
        shortcutsActive = true
        panel.needsKeyboardFocus = fallbackKeys
        if fallbackKeys { panel.makeKeyAndOrderFront(nil) }
    }

    private func disarmShortcuts() {
        if shortcutsActive { shortcuts.stop() }
        shortcutsActive = false
        fallbackKeys = false
        panel.needsKeyboardFocus = false
    }

    @objc private func toggle() {
        switch state {
        case .editing: break
        case .paused: resume()
        case .finished: begin()
        case .playing, .waitingForMicrophone:
            state = .paused
            island.reader.isPlaying = false
            if mode == .voice { follower.stop() }
            armShortcuts()
            refreshIsland()
        }
    }

    private func finish() {
        guard state == .playing || state == .waitingForMicrophone else { return }
        state = .finished
        if mode == .voice { follower.stop() }
        armShortcuts()
        refreshIsland()
    }

    private func adjustSpeed(by delta: Int) {
        guard state != .editing, mode == .timed else { return }
        speed = max(40, min(400, speed + delta))
        island.reader.wordsPerMinute = Double(speed)
        preferences.set(speed, forKey: "speed")
        editor.setWPM(speed)
        refreshIsland()
    }

    private func refreshIsland() {
        let pace = mode == .timed ? "\(speed) WPM" : "Voice"
        let label: String
        let symbol: String
        let action: String
        switch state {
        case .editing: return
        case .waitingForMicrophone:
            (label, symbol, action) = ("Starting microphone…", "pause.fill", "Pause voice tracking")
        case .playing:
            (label, symbol, action) = (mode == .voice ? "Listening" : pace, "pause.fill", "Pause (Space)")
        case .paused:
            (label, symbol, action) = ("Paused · \(pace)", "play.fill", "Resume (Space)")
        case .finished:
            (label, symbol, action) = ("Finished", "arrow.counterclockwise", "Read again (Space)")
        }
        let hint = fallbackKeys ? " · Click island for keys" : ""
        island.update(label: label + hint, symbol: symbol, action: action, running: state == .playing, timed: mode == .timed)
    }

    @objc private func showEditor() {
        state = .editing
        disarmShortcuts()
        follower.stop()
        island.reader.isPlaying = false
        panel.hideIsland()
        editor.present()
    }

    private func speechFailed(_ reason: String) {
        guard state == .waitingForMicrophone || state == .playing, mode == .voice else { return }
        showEditor()
        let alert = NSAlert()
        alert.messageText = "Voice tracking is unavailable"
        alert.informativeText = reason
        alert.addButton(withTitle: "Back to script")
        alert.addButton(withTitle: "Start timed playback")
        if let window = editor.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertSecondButtonReturn else { return }
                self.editor.setMode(.timed)
                self.save(script: self.script, speed: self.speed, mode: .timed)
                self.begin()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if editor.window?.attachedSheet == nil { showEditor() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        disarmShortcuts()
        follower.stop()
        island.reader.isPlaying = false
    }

    private func buildMenus() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            bar.addItem(item)
            return submenu
        }
        let appMenu = menu("Cue Island")
        appMenu.addItem(withTitle: "About Cue Island", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Cue Island", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Cue Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = menu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = menu("Window")
        window.addItem(withTitle: "Open Script Editor", action: #selector(showEditor), keyEquivalent: "1").target = self
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.mainMenu = bar
    }
}
