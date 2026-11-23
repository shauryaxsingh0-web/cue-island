import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech

/// Tracks words in the same whitespace-delimited coordinate system as the display.
struct ScriptAlignment {
    private struct Token {
        let text: String
        let wordIndex: Int
    }

    private let tokens: [Token]
    private var segmentStart = 0
    private var nextToken = 0
    private(set) var lastMatchedWord: Int

    init(script: String, fromWordIndex: Int) {
        let start = max(0, fromWordIndex)
        lastMatchedWord = start - 1
        let words = script.split(whereSeparator: { $0.isWhitespace })
        tokens = words.enumerated().dropFirst(min(start, words.count)).flatMap { index, word in
            Self.normalise(String(word)).map { Token(text: $0, wordIndex: index) }
        }
    }

    var isFinished: Bool { nextToken == tokens.count }

    mutating func beginSegment() {
        segmentStart = nextToken
    }

    // Apple sends revised, cumulative partial transcripts. Reconcile each revision from
    // the beginning of this segment, and only publish forward progress.
    mutating func consume(_ transcript: String) {
        let spoken = Self.normalise(transcript)
        var heard = 0
        var expected = segmentStart
        while heard < spoken.count && expected < tokens.count {
            if tokens[expected].text == spoken[heard] {
                expected += 1
            } else if let match = nearbyAnchor(spoken, heard: heard, expected: expected) {
                expected = match + 1
            }
            heard += 1
        }
        guard expected > nextToken else { return }
        nextToken = expected

        // A hyphenated or expanded word may contain multiple recognition tokens.
        if nextToken == tokens.count || tokens[nextToken].wordIndex != tokens[nextToken - 1].wordIndex {
            lastMatchedWord = tokens[nextToken - 1].wordIndex
        } else {
            lastMatchedWord = max(lastMatchedWord, tokens[nextToken - 1].wordIndex - 1)
        }
    }

    private func nearbyAnchor(_ spoken: [String], heard: Int, expected: Int) -> Int? {
        let end = min(expected + 9, tokens.count)
        for candidate in (expected + 1)..<end where tokens[candidate].text == spoken[heard] {
            let skipped = candidate - expected
            var evidence = 1
            while candidate + evidence < tokens.count && heard + evidence < spoken.count
                    && tokens[candidate + evidence].text == spoken[heard + evidence] && evidence < 3 {
                evidence += 1
            }
            if evidence >= (skipped <= 3 ? 2 : 3) { return candidate }
            // A distinctive final word can recover from a missed penultimate word.
            if candidate == tokens.count - 1 && skipped <= 2 && spoken[heard].count >= 4 {
                return candidate
            }
        }
        return nil
    }

    private static func normalise(_ text: String) -> [String] {
        let clean = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_GB"))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "&", with: " and ")
        return clean.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.flatMap { part -> [String] in
            let word = String(part).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard !word.isEmpty else { return [] }
            switch word {
            case "can't", "cannot": return ["can", "not"]
            case "won't": return ["will", "not"]
            case "let's": return ["let", "us"]
            case "it's", "he's", "she's", "that's": return [String(word.dropLast(2)), "is"]
            default: break
            }
            for (ending, expanded) in [("n't", "not"), ("'re", "are"), ("'ll", "will"),
                                       ("'ve", "have"), ("'m", "am")] where word.hasSuffix(ending) {
                return [String(word.dropLast(ending.count)), expanded]
            }
            if let number = Int(word), (0...99).contains(number), word == String(number) {
                let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                             "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                             "sixteen", "seventeen", "eighteen", "nineteen"]
                let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
                            "eighty", "ninety"]
                if number < 20 { return [units[number]] }
                return number % 10 == 0 ? [tens[number / 10]] : [tens[number / 10], units[number % 10]]
            }
            return [word.replacingOccurrences(of: "'", with: "")]
        }
    }
}

@MainActor
final class SpeechFollower {
    var onWord: ((Int) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((String) -> Void)?
    var onListening: (() -> Void)?

    private var session = UUID()
    private var segment = UUID()
    private var alignment = ScriptAlignment(script: "", fromWordIndex: 0)
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var lastAudioEnd: TimeInterval = 0
    private var segmentBegan = Date()

    func start(script: String, fromWordIndex: Int = 0) {
        stop()
        alignment = ScriptAlignment(script: script, fromWordIndex: fromWordIndex)
        guard !alignment.isFinished else {
            onFinished?()
            return
        }
        let id = session
        Task { [weak self] in
            let speechAllowed = await Self.requestSpeechPermission()
            guard let self, self.session == id else { return }
            guard speechAllowed else {
                self.fail("Allow speech recognition in System Settings → Privacy & Security → Speech Recognition, or choose timed scrolling.")
                return
            }
            let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard self.session == id else { return }
            guard microphoneAllowed else {
                self.fail("Allow microphone access in System Settings → Privacy & Security → Microphone, or choose timed scrolling.")
                return
            }
            let preferred = Locale.preferredLanguages.first { $0.lowercased().hasPrefix("en") }
            for identifier in [preferred, "en-GB", "en-US"].compactMap({ $0 }) {
                if let candidate = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
                   candidate.supportsOnDeviceRecognition, candidate.isAvailable {
                    self.recognizer = candidate
                    break
                }
            }
            guard self.recognizer != nil else {
                self.fail("On-device English speech recognition is unavailable. Check your Dictation language in System Settings → Keyboard, or choose timed scrolling.")
                return
            }
            self.beginListening()
        }
    }

    func stop() {
        session = UUID()
        endSegment()
        recognizer = nil
    }

    private static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func beginListening() {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            fail("On-device speech recognition is currently unavailable. Try again or choose timed scrolling.")
            return
        }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            fail("Choose a working microphone in System Settings → Sound → Input, then resume.")
            return
        }

        alignment.beginSegment()
        lastAudioEnd = 0
        segmentBegan = Date()
        let id = segment
        let input = AVAudioEngine()
        let node = input.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("The microphone has no active input. Choose an input in System Settings → Sound, then resume.")
            return
        }

        let audio = SFSpeechAudioBufferRecognitionRequest()
        audio.requiresOnDeviceRecognition = true
        audio.shouldReportPartialResults = true
        audio.taskHint = .dictation
        request = audio
        engine = input
        node.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.tap(for: audio))
        input.prepare()
        do {
            try input.start()
        } catch {
            fail("The microphone could not start. \(error.localizedDescription)")
            return
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: input, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.segment == id, !input.isRunning else { return }
                self.fail("The microphone input changed. Resume to use the current microphone.")
            }
        }
        task = recognizer.recognitionTask(with: audio) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let segments = result?.bestTranscription.segments
            let first = segments?.first?.timestamp ?? 0
            let last = segments?.last.map { $0.timestamp + $0.duration } ?? 0
            let finished = result?.isFinal == true
            let problem = error as NSError?
            Task { @MainActor in
                guard let self, self.segment == id else { return }
                if let text {
                    // Some recognizer versions start a new partial transcription after silence.
                    if self.lastAudioEnd > 0 && first >= self.lastAudioEnd - 0.05 && last > self.lastAudioEnd {
                        self.alignment.beginSegment()
                    }
                    self.lastAudioEnd = max(self.lastAudioEnd, last)
                    let priorWord = self.alignment.lastMatchedWord
                    self.alignment.consume(text)
                    if self.alignment.lastMatchedWord > priorWord {
                        self.onWord?(self.alignment.lastMatchedWord)
                    }
                    guard self.segment == id else { return }
                    if self.alignment.isFinished {
                        self.stop()
                        self.onFinished?()
                        return
                    }
                }
                let noSpeech = problem?.domain == "kAFAssistantErrorDomain" && problem?.code == 1110
                let reachedDurationLimit = Date().timeIntervalSince(self.segmentBegan) >= 50
                if finished || (problem != nil && (noSpeech || reachedDurationLimit)) {
                    self.endSegment()
                    self.beginListening()
                } else if let problem {
                    self.fail("Voice following stopped. \(problem.localizedDescription) Resume to try again, or choose timed scrolling.")
                }
            }
        }
        onListening?()
    }

    // The audio tap runs on a Core Audio thread; this closure must not inherit the main actor.
    private nonisolated static func tap(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private func endSegment() {
        segment = UUID()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        engine = nil
    }

    private func fail(_ message: String) {
        stop()
        onError?(message)
    }
}
