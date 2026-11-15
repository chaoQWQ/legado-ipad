import AVFoundation
import Combine
import Foundation
import NaturalLanguage

@MainActor
final class ReaderSpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum State {
        case idle, playing, paused
    }

    @Published private(set) var state: State = .idle

    // The delegate may call off-main. Retain the utterance until delivery so
    // its identity cannot be reused, and compare it only on the main actor.
    private struct UtteranceIdentity: @unchecked Sendable {
        private let retained: AVSpeechUtterance

        init(_ utterance: AVSpeechUtterance) {
            retained = utterance
        }

        @MainActor
        func matches(_ utterance: AVSpeechUtterance?) -> Bool {
            retained === utterance
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var startingOffset = 0
    private var onProgress: ((Int) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        synthesizer.usesApplicationAudioSession = false
        #endif
    }

    func start(text: String, utf16Offset: Int, onProgress: ((Int) -> Void)? = nil) {
        stop()
        let body = text as NSString
        let offset = max(0, utf16Offset)
        guard offset < body.length else { return }
        let start = body.rangeOfComposedCharacterSequence(at: offset).location
        let passage = body.substring(from: start)
        guard !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let utterance = AVSpeechUtterance(string: passage)
        utterance.voice = voice(for: passage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        self.utterance = utterance
        startingOffset = start
        self.onProgress = onProgress
        state = .playing
        synthesizer.speak(utterance)
    }

    func pause() {
        guard state == .playing, synthesizer.pauseSpeaking(at: .immediate) else { return }
        state = .paused
    }

    func resume() {
        guard state == .paused, synthesizer.continueSpeaking() else { return }
        state = .playing
    }

    func stop() {
        utterance = nil
        onProgress = nil
        state = .idle
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let identity = UtteranceIdentity(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, identity.matches(self.utterance), self.state == .playing else { return }
            self.onProgress?(self.startingOffset + characterRange.location)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        let identity = UtteranceIdentity(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, identity.matches(self.utterance), self.synthesizer.isPaused else { return }
            self.state = .paused
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        let identity = UtteranceIdentity(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, identity.matches(self.utterance), !self.synthesizer.isPaused else { return }
            self.state = .playing
        }
    }

    private nonisolated func finish(_ utterance: AVSpeechUtterance) {
        let identity = UtteranceIdentity(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, identity.matches(self.utterance) else { return }
            self.utterance = nil
            self.onProgress = nil
            self.state = .idle
        }
    }

    private func voice(for passage: String) -> AVSpeechSynthesisVoice? {
        let sample = String(passage.prefix(500))
        let language = NLLanguageRecognizer.dominantLanguage(for: sample)
        switch language {
        case .traditionalChinese:
            return AVSpeechSynthesisVoice(language: "zh-TW") ?? AVSpeechSynthesisVoice(language: "zh-CN")
        case .simplifiedChinese, nil:
            return AVSpeechSynthesisVoice(language: "zh-CN")
        default:
            return language.flatMap { AVSpeechSynthesisVoice(language: $0.rawValue) }
        }
    }
}
