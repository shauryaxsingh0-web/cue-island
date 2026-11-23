import AppKit

enum PlaybackMode: String {
    case timed
    case voice
}

private final class ScriptTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = textContainerOrigin
        let inset = textContainer?.lineFragmentPadding ?? 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 17),
            .foregroundColor: NSColor(white: 0.52, alpha: 1)
        ]
        ("Paste or type your script here…" as NSString).draw(
            at: NSPoint(x: origin.x + inset, y: origin.y), withAttributes: attributes
        )
    }
}

private final class StartButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 8
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        let luminance: CGFloat = !isEnabled ? 0.24 : isHighlighted ? 0.75 : 0.96
        NSColor(white: luminance, alpha: 1).setFill()
        shape.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor(white: isEnabled ? 0.065 : 0.57, alpha: 1)
        ]
        let label = title as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                   withAttributes: attributes)
    }
}

@MainActor
final class ScriptEditor: NSWindowController, NSTextViewDelegate, NSTextFieldDelegate {
    var onChange: ((String, Int, PlaybackMode) -> Void)?
    var onStart: ((String, Int, PlaybackMode) -> Void)?

    private let editor = ScriptTextView()
    private let wordCount = NSTextField(labelWithString: "")
    private let modePicker = NSSegmentedControl(labels: ["Timed WPM", "Follow my voice"],
                                                trackingMode: .selectOne, target: nil, action: nil)
    private let speedSlider = NSSlider(value: 150, minValue: 40, maxValue: 400, target: nil, action: nil)
    private let speedField = NSTextField()
    private let speedLabel = NSTextField(labelWithString: "Pace")
    private let speedUnit = NSTextField(labelWithString: "WPM")
    private let startButton = StartButton(title: "Start teleprompter", target: nil, action: nil)
    private var speed: Int
    private var playbackMode: PlaybackMode
    private static let muted = NSColor(white: 0.69, alpha: 1)
    private static let panelColor = NSColor(white: 0.115, alpha: 1)

    init(script: String, wpm: Int, mode: PlaybackMode) {
        speed = min(400, max(40, wpm))
        playbackMode = mode
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Cue Island"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.075, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 520, height: 425)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configure(script: script)
        window.center()
        window.setFrameAutosaveName("CueIslandScriptEditor")
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(editor)
    }

    func setWPM(_ value: Int) {
        speed = min(400, max(40, value))
        speedField.stringValue = String(speed)
        speedSlider.doubleValue = Double(speed)
        refreshScriptInfo()
    }

    func setMode(_ mode: PlaybackMode) {
        playbackMode = mode
        modePicker.selectedSegment = mode == .timed ? 0 : 1
        refreshSpeedAvailability()
        refreshScriptInfo()
    }

    func selectEntireScript() {
        window?.makeFirstResponder(editor)
        editor.selectAll(nil)
    }

    private func configure(script: String) {
        guard let window, let content = window.contentView else { return }
        let heading = NSTextField(labelWithString: "Your script")
        heading.font = .systemFont(ofSize: 28, weight: .semibold)
        heading.textColor = .white
        wordCount.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        wordCount.textColor = Self.muted
        wordCount.alignment = .right
        let scroll = makeScriptField(script)

        let modeLabel = NSTextField(labelWithString: "Playback")
        for label in [modeLabel, speedLabel] {
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.textColor = .white
        }
        modePicker.selectedSegment = playbackMode == .timed ? 0 : 1
        modePicker.target = self
        modePicker.action = #selector(choosePlaybackMode)
        modePicker.segmentStyle = .rounded
        modePicker.setAccessibilityLabel("Playback mode")

        speedSlider.target = self
        speedSlider.action = #selector(slideSpeed)
        speedSlider.isContinuous = true
        speedSlider.trackFillColor = .white
        speedSlider.doubleValue = Double(speed)
        speedSlider.setAccessibilityLabel("Words per minute")
        speedField.stringValue = String(speed)
        speedField.alignment = .center
        speedField.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        speedField.delegate = self
        speedField.target = self
        speedField.action = #selector(commitSpeed)
        speedField.setAccessibilityLabel("Words per minute from 40 to 400")
        speedUnit.font = .systemFont(ofSize: 12, weight: .medium)
        speedUnit.textColor = Self.muted

        let separator = NSBox()
        separator.boxType = .separator
        let keys = NSTextField(labelWithString: "Space to pause or resume  ·  Esc to edit")
        keys.font = .systemFont(ofSize: 12)
        keys.textColor = Self.muted
        startButton.setButtonType(.momentaryPushIn)
        startButton.isBordered = false
        startButton.target = self
        startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"
        startButton.keyEquivalentModifierMask = [.command]
        startButton.toolTip = "Start from the beginning (⌘Return)"

        for view in [heading, wordCount, scroll, modeLabel, modePicker, speedLabel, speedSlider,
                     speedField, speedUnit, separator, keys, startButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let leading = content.leadingAnchor
        let trailing = content.trailingAnchor
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leading, constant: 24),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 11),
            wordCount.trailingAnchor.constraint(equalTo: trailing, constant: -25),
            wordCount.centerYAnchor.constraint(equalTo: heading.centerYAnchor, constant: 3),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: wordCount.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: modePicker.topAnchor, constant: -21),
            modeLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            modeLabel.centerYAnchor.constraint(equalTo: modePicker.centerYAnchor),
            modePicker.trailingAnchor.constraint(equalTo: wordCount.trailingAnchor),
            modePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            modePicker.bottomAnchor.constraint(equalTo: speedField.topAnchor, constant: -15),
            speedLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            speedLabel.centerYAnchor.constraint(equalTo: speedField.centerYAnchor),
            speedSlider.leadingAnchor.constraint(equalTo: modePicker.leadingAnchor),
            speedSlider.centerYAnchor.constraint(equalTo: speedField.centerYAnchor),
            speedSlider.trailingAnchor.constraint(equalTo: speedField.leadingAnchor, constant: -10),
            speedField.widthAnchor.constraint(equalToConstant: 47),
            speedField.centerYAnchor.constraint(equalTo: speedUnit.centerYAnchor),
            speedField.trailingAnchor.constraint(equalTo: speedUnit.leadingAnchor, constant: -6),
            speedUnit.trailingAnchor.constraint(equalTo: wordCount.trailingAnchor),
            separator.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: wordCount.trailingAnchor),
            separator.topAnchor.constraint(equalTo: speedField.bottomAnchor, constant: 19),
            separator.bottomAnchor.constraint(equalTo: startButton.topAnchor, constant: -15),
            keys.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            keys.centerYAnchor.constraint(equalTo: startButton.centerYAnchor),
            keys.trailingAnchor.constraint(lessThanOrEqualTo: startButton.leadingAnchor, constant: -12),
            startButton.trailingAnchor.constraint(equalTo: wordCount.trailingAnchor),
            startButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -19),
            startButton.widthAnchor.constraint(equalToConstant: 149),
            startButton.heightAnchor.constraint(equalToConstant: 37)
        ])
        window.initialFirstResponder = editor
        refreshScriptInfo()
        refreshSpeedAvailability()
    }

    private func makeScriptField(_ script: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Self.panelColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor(white: 0.23, alpha: 1).cgColor
        scroll.layer?.masksToBounds = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 17)
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.selectedTextAttributes = [.backgroundColor: NSColor(white: 0.34, alpha: 1),
                                         .foregroundColor: NSColor.white]
        editor.backgroundColor = Self.panelColor
        editor.textContainerInset = NSSize(width: 11, height: 13)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.string = script
        editor.delegate = self
        editor.setAccessibilityLabel("Teleprompter script")
        scroll.documentView = editor
        return scroll
    }

    func textDidChange(_ notification: Notification) {
        refreshScriptInfo()
        editor.needsDisplay = true
        publish()
    }

    func controlTextDidEndEditing(_ notification: Notification) { commitSpeed() }

    private func refreshScriptInfo() {
        let words = editor.string.split(whereSeparator: { $0.isWhitespace }).count
        let count = words == 1 ? "1 word" : "\(words.formatted()) words"
        if words > 0 && playbackMode == .timed {
            let seconds = Int(ceil(Double(words) * 60 / Double(speed)))
            let duration = String(format: "%d:%02d", seconds / 60, seconds % 60)
            wordCount.stringValue = "\(count)  ·  ~\(duration)"
        } else {
            wordCount.stringValue = count
        }
        startButton.isEnabled = words > 0
        startButton.needsDisplay = true
    }

    private func refreshSpeedAvailability() {
        let timed = playbackMode == .timed
        speedField.isEnabled = timed
        speedSlider.isEnabled = timed
        for label in [speedLabel, speedUnit] { label.alphaValue = timed ? 1 : 0.45 }
        speedSlider.toolTip = timed ? "Reading speed in words per minute" : "Your spoken words set the pace"
    }

    @objc private func choosePlaybackMode() {
        setMode(modePicker.selectedSegment == 1 ? .voice : .timed)
        publish()
    }

    @objc private func slideSpeed() {
        setWPM(Int(speedSlider.doubleValue.rounded()))
        publish()
    }

    @objc private func commitSpeed() {
        let entered = Int(speedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? speed
        let clamped = min(400, max(40, entered))
        speedField.stringValue = String(clamped)
        speedSlider.doubleValue = Double(clamped)
        guard speed != clamped else { return }
        setWPM(clamped)
        publish()
    }

    @objc private func start() {
        commitSpeed()
        guard startButton.isEnabled else { return }
        onStart?(editor.string, speed, playbackMode)
    }

    private func publish() { onChange?(editor.string, speed, playbackMode) }
}
