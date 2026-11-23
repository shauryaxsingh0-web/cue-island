import AppKit
import CoreText

/// A camera-aligned reading surface. Positions use whitespace-delimited words so
/// relayout and speed changes preserve the speaker's place in the script.
@MainActor
final class PrompterScrollView: NSView {
    var script = "" {
        didSet {
            guard script != oldValue else { return }
            paragraphs = script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { $0.split(whereSeparator: \.isWhitespace) }
            wordCount = paragraphs.reduce(0) { $0 + $1.count }
            layoutWidth = nil
            setAccessibilityValue(script)
            restart()
        }
    }

    var onFinish: (() -> Void)?

    var wordsPerMinute: Double {
        get { pace }
        set {
            guard newValue.isFinite, newValue > 0 else { return }
            if playStart != nil {
                let now = ProcessInfo.processInfo.systemUptime
                baseWord = position(at: now)
                playStart = now
            }
            pace = newValue
        }
    }

    var isPlaying: Bool {
        get { playStart != nil }
        set {
            let now = ProcessInfo.processInfo.systemUptime
            if newValue {
                guard playStart == nil, wordCount > 0 else { return }
                baseWord = position(at: now)
                if baseWord >= Double(wordCount) { baseWord = 0 }
                speechMove = nil
                playStart = now
                startTimer()
            } else {
                baseWord = position(at: now)
                playStart = nil
                speechMove = nil
                stopTimer()
            }
            needsDisplay = true
        }
    }

    var progress: Double {
        wordCount > 0 ? position(at: ProcessInfo.processInfo.systemUptime) / Double(wordCount) : 0
    }

    func restart() {
        isPlaying = false
        baseWord = 0
        needsDisplay = true
    }

    /// Speech recognition may return several new words at once. Ease to the
    /// latest word without advancing through silence or starting timed playback.
    func followSpeech(toWordIndex index: Int) {
        guard wordCount > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let nextWord = Double(min(max(0, index), wordCount - 1))
        if playStart == nil, speechMove?.to == nextWord { return }
        let current = position(at: now)
        playStart = nil
        baseWord = current
        if abs(nextWord - current) < 0.001 {
            baseWord = nextWord
            speechMove = nil
            stopTimer()
        } else {
            speechMove = SpeechMove(from: current, to: nextWord, start: now)
            startTimer()
        }
        needsDisplay = true
    }

    private struct Line {
        let text: NSAttributedString
        let startWord: Double
        let y: CGFloat
    }

    private struct SpeechMove {
        let from: Double
        let to: Double
        let start: TimeInterval
        let duration: TimeInterval = 0.18
    }

    private let font = NSFont.systemFont(ofSize: 22, weight: .medium)
    private let lineSpacing: CGFloat = 31
    private let sideInset: CGFloat = 21
    private let edgeFade = NSGradient(starting: .black, ending: NSColor.black.withAlphaComponent(0))
    private var paragraphs: [[Substring]] = []
    private var wordCount = 0
    private var layoutWidth: CGFloat?
    private var lines: [Line] = []
    private var pace = 150.0
    private var baseWord = 0.0
    private var playStart: TimeInterval?
    private var speechMove: SpeechMove?
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Teleprompter script")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private func position(at now: TimeInterval) -> Double {
        if let playStart {
            return min(Double(wordCount), baseWord + max(0, now - playStart) * pace / 60)
        }
        if let move = speechMove {
            let t = min(1, max(0, (now - move.start) / move.duration))
            return move.from + (move.to - move.from) * (1 - pow(1 - t, 3))
        }
        return baseWord
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        needsDisplay = true
        if playStart != nil, position(at: now) >= Double(wordCount) {
            isPlaying = false
            onFinish?()
        } else if let move = speechMove, now - move.start >= move.duration {
            baseWord = move.to
            speechMove = nil
            stopTimer()
        }
    }

    private func rebuildIfNeeded() {
        let width = bounds.width - 2 * sideInset
        guard layoutWidth != width else { return }
        layoutWidth = width
        lines.removeAll(keepingCapacity: true)
        guard width > 1 else { return }

        let style: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        var wordIndex = 0
        var y: CGFloat = 0
        var paragraphBreak = false

        func append(_ text: String, at index: Double) {
            lines.append(Line(text: NSAttributedString(string: text, attributes: style), startWord: index, y: y))
            y += lineSpacing
        }

        for paragraph in paragraphs {
            guard !paragraph.isEmpty else {
                paragraphBreak = !lines.isEmpty
                continue
            }
            if paragraphBreak { y += lineSpacing * 0.28 }
            paragraphBreak = false
            var buffer = ""
            var firstWord = wordIndex
            for token in paragraph {
                let word = String(token)
                let candidate = buffer.isEmpty ? word : buffer + " " + word
                if (candidate as NSString).size(withAttributes: style).width <= width {
                    buffer = candidate
                } else {
                    if !buffer.isEmpty { append(buffer, at: Double(firstWord)) }
                    buffer = word
                    firstWord = wordIndex
                    // Long URLs and words still fit the island. Give each wrapped
                    // portion its fraction of the original word's reading time.
                    if (word as NSString).size(withAttributes: style).width > width {
                        let attributed = NSAttributedString(string: word, attributes: style)
                        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
                        let source = word as NSString
                        var offset = 0
                        while offset < attributed.length {
                            let suggested = CTTypesetterSuggestClusterBreak(typesetter, offset, Double(width))
                            let length = suggested > 0 ? suggested : source.rangeOfComposedCharacterSequence(at: offset).length
                            let range = NSRange(location: offset, length: min(length, attributed.length - offset))
                            let part = attributed.attributedSubstring(from: range).string
                            append(part, at: Double(wordIndex) + Double(offset) / Double(attributed.length))
                            offset = NSMaxRange(range)
                        }
                        buffer = ""
                        firstWord = wordIndex + 1
                    }
                }
                wordIndex += 1
            }
            if !buffer.isEmpty { append(buffer, at: Double(firstWord)) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        rebuildIfNeeded()
        guard !lines.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)

        let word = position(at: ProcessInfo.processInfo.systemUptime)
        var start = 0
        var end = lines.count
        while start < end {
            let middle = start + (end - start) / 2
            if lines[middle].startWord <= word {
                start = middle + 1
            } else {
                end = middle
            }
        }
        let active = max(0, start - 1)
        var offset = lines[active].y
        if active + 1 < lines.count {
            let next = lines[active + 1]
            let portion = (word - lines[active].startWord) / (next.startWord - lines[active].startWord)
            offset += (next.y - lines[active].y) * CGFloat(portion)
        }

        // The eye rests in the upper half, close to the camera. The last line
        // stays on the guide for its full duration and after playback finishes.
        let guideY = min(bounds.midY, max(lineSpacing * 0.72, bounds.height * 0.40))
        NSColor(white: 0.78, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 5, y: guideY - 1.5, width: 8, height: 3),
                     xRadius: 1.5, yRadius: 1.5).fill()

        let radius = Int(ceil(bounds.height / lineSpacing)) + 1
        let first = max(0, active - radius)
        let last = min(lines.count - 1, active + radius)
        for index in first...last {
            let line = lines[index]
            let center = guideY + line.y - offset
            guard center > -lineSpacing, center < bounds.height + lineSpacing else { continue }
            let distance = abs(center - guideY) / lineSpacing
            let alpha = max(0.40, 1.0 - max(0, distance - 0.56) * 0.38)
            let origin = NSPoint(x: sideInset, y: center - line.text.size().height / 2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            line.text.draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()
        }
        let fadeDepth = min(8, bounds.height / 6)
        edgeFade?.draw(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 0, y: fadeDepth), options: [])
        edgeFade?.draw(from: NSPoint(x: 0, y: bounds.height), to: NSPoint(x: 0, y: bounds.height - fadeDepth), options: [])
    }
}
