import Foundation
import Testing
@testable import TalkCore

struct SpeakingDetectorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func startsAtTheFirstLoudReading() {
        var detector = SpeakingDetector()
        #expect(detector.update(level: 0.001, at: start) == false)
        #expect(detector.isSpeaking == false)
        #expect(detector.update(level: 0.2, at: start.addingTimeInterval(0.25)) == true)
        #expect(detector.isSpeaking)
    }

    @Test func staysOnThroughTheGapBetweenWords() {
        var detector = SpeakingDetector()
        detector.update(level: 0.2, at: start)
        // Half a second of quiet: a breath, not the end of a sentence.
        detector.update(level: 0.0, at: start.addingTimeInterval(0.25))
        detector.update(level: 0.0, at: start.addingTimeInterval(0.5))
        #expect(detector.isSpeaking)
        detector.update(level: 0.2, at: start.addingTimeInterval(0.75))
        #expect(detector.isSpeaking)
    }

    @Test func stopsAfterTheHush() {
        var detector = SpeakingDetector()
        detector.update(level: 0.2, at: start)
        #expect(detector.update(level: 0.0, at: start.addingTimeInterval(0.5)) == false)
        #expect(detector.update(level: 0.0, at: start.addingTimeInterval(0.9)) == true)
        #expect(detector.isSpeaking == false)
    }

    @Test func middlingLevelsHoldWhateverItWas() {
        var detector = SpeakingDetector()
        // Between the two thresholds, from quiet: still quiet.
        detector.update(level: 0.015, at: start)
        #expect(detector.isSpeaking == false)
        detector.update(level: 0.2, at: start.addingTimeInterval(0.25))
        // And from talking: still talking, however long it stays there.
        detector.update(level: 0.015, at: start.addingTimeInterval(3))
        #expect(detector.isSpeaking)
    }

    @Test func silenceStopsItAtOnce() {
        var detector = SpeakingDetector()
        detector.update(level: 0.4, at: start)
        #expect(detector.silence() == true)
        #expect(detector.isSpeaking == false)
        #expect(detector.silence() == false)
    }
}
