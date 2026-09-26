import AVFoundation
import Observation

@MainActor
@Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
  @ObservationIgnored private var synthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private var activeUtterance: AVSpeechUtterance?
  private(set) var isSpeaking = false

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(_ text: String, rate: Double) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    try? AVAudioSession.sharedInstance().setActive(true)

    let utterance = AVSpeechUtterance(string: trimmed)
    utterance.rate = Float(rate)
    activeUtterance = utterance
    isSpeaking = true
    synthesizer.speak(utterance)
  }

  func stop() {
    activeUtterance = nil
    synthesizer.stopSpeaking(at: .immediate)
    isSpeaking = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    finish(utterance)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    finish(utterance)
  }

  private func finish(_ utterance: AVSpeechUtterance) {
    guard utterance === activeUtterance else { return }
    activeUtterance = nil
    isSpeaking = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
