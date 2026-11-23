import AppKit

@MainActor
final class IslandView: NSView {
    let reader = PrompterScrollView(frame: .zero)
    var onToggle: (() -> Void)?
    var onEdit: (() -> Void)?
    var onAdjustSpeed: ((Int) -> Void)?

    private let status = NSTextField(labelWithString: "")
    private let toolbar = NSStackView()
    private let speedControls = NSStackView()
    private let toggle = NSButton()
    private var tracking: NSTrackingArea?
    private var isUnderPointer = false
    private var isRunning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        let edit = NSButton()
        let slower = NSButton()
        let faster = NSButton()
        style(edit, symbol: "square.and.pencil", title: "Return to script (Esc)", action: #selector(editScript))
        style(toggle, symbol: "pause.fill", title: "Pause (Space)", action: #selector(togglePlayback))
        style(slower, symbol: "minus", title: "Decrease by 10 words per minute", action: #selector(decreaseSpeed))
        style(faster, symbol: "plus", title: "Increase by 10 words per minute", action: #selector(increaseSpeed))

        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        status.textColor = NSColor(white: 0.85, alpha: 1)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        speedControls.orientation = .horizontal
        speedControls.spacing = 1
        speedControls.addArrangedSubview(slower)
        speedControls.addArrangedSubview(faster)

        let space = NSView()
        space.setContentHuggingPriority(.init(1), for: .horizontal)
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 4
        [toggle, status, speedControls, space, edit].forEach(toolbar.addArrangedSubview)

        [reader, toolbar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            reader.leadingAnchor.constraint(equalTo: leadingAnchor),
            reader.trailingAnchor.constraint(equalTo: trailingAnchor),
            reader.topAnchor.constraint(equalTo: topAnchor),
            reader.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            toolbar.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(label: String, symbol: String, action: String, running: Bool, timed: Bool) {
        status.stringValue = label
        toggle.image = icon(symbol, label: action)
        toggle.toolTip = action
        toggle.setAccessibilityLabel(action)
        speedControls.isHidden = !timed
        isRunning = running
        updateToolbar()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isUnderPointer = true; updateToolbar() }
    override func mouseExited(with event: NSEvent) { isUnderPointer = false; updateToolbar() }

    private func updateToolbar() {
        toolbar.alphaValue = isRunning && !isUnderPointer ? 0.66 : 1
    }

    private func icon(_ name: String, label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    }

    private func style(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.isBordered = false
        button.image = icon(symbol, label: title)
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.focusRingType = .none
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @objc private func togglePlayback() { onToggle?() }
    @objc private func editScript() { onEdit?() }
    @objc private func decreaseSpeed() { onAdjustSpeed?(-10) }
    @objc private func increaseSpeed() { onAdjustSpeed?(10) }
}
