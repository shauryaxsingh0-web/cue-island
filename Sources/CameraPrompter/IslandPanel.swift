import AppKit
import CoreGraphics

@MainActor
final class IslandPanel: NSPanel {
    private let islandSize: NSSize

    var needsKeyboardFocus = false
    override var canBecomeKey: Bool { needsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    init(content: NSView, size: NSSize = NSSize(width: 430, height: 118)) {
        islandSize = size
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)

        title = "Teleprompter island"
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        level = .floating
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        if #available(macOS 13.0, *) {
            collectionBehavior.insert(.canJoinAllApplications)
        }

        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        content.frame = backdrop.bounds
        content.autoresizingMask = [.width, .height]
        backdrop.addSubview(content)
        contentView = backdrop

        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    func showIsland() {
        reposition()
        orderFrontRegardless()
    }

    func hideIsland() {
        orderOut(nil)
    }

    @objc private func displayChanged(_ notification: Notification) {
        if isVisible { reposition() }
    }

    func reposition() {
        let screens = NSScreen.screens
        let builtIn = screens.first { screen in
            guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                else { return false }
            return CGDisplayIsBuiltin(display.uint32Value) != 0
        }
        guard let screen = builtIn ?? NSScreen.main ?? screens.first else { return }

        let display = screen.frame
        var cameraX = display.midX
        var top = screen.visibleFrame.maxY
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            top = display.maxY - screen.safeAreaInsets.top
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
               !left.isEmpty, !right.isEmpty, left.maxX < right.minX {
                cameraX = (left.maxX + right.minX) / 2
            }
        }

        let width = min(islandSize.width, display.width)
        let height = min(islandSize.height, top - display.minY)
        let x = max(display.minX, min(cameraX - width / 2, display.maxX - width))
        let rect = NSRect(x: x, y: top - height, width: width, height: height)
        setFrame(screen.backingAlignedRect(rect, options: .alignAllEdgesNearest), display: true)
    }
}
