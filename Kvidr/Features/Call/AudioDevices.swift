import CoreAudio
import Foundation

/// The Mac's microphones and speakers, and which of them are the defaults — live, so AirPods
/// appear the moment they connect.
///
/// WebRTC's Mac audio takes whatever the system default is when a call's audio starts, and
/// can't be pointed anywhere else; so choosing a device here makes it the default, as the
/// Sound menu does, and the call restarts its audio to pick it up.
@MainActor
@Observable
final class AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioObjectID
        let name: String
    }

    private(set) var inputs: [Device] = []
    private(set) var outputs: [Device] = []
    private(set) var defaultInput: AudioObjectID = 0
    private(set) var defaultOutput: AudioObjectID = 0

    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    private static let watched: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]

    init() {
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listener = block
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    isolated deinit {
        guard let listener else { return }
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    func setDefaultInput(_ id: AudioObjectID) {
        Self.setDefault(kAudioHardwarePropertyDefaultInputDevice, to: id)
        refresh()
    }

    func setDefaultOutput(_ id: AudioObjectID) {
        Self.setDefault(kAudioHardwarePropertyDefaultOutputDevice, to: id)
        refresh()
    }

    func refresh() {
        let all = Self.deviceIDs()
        inputs = all.filter { Self.hasStreams($0, scope: kAudioObjectPropertyScopeInput) }.compactMap(Self.device)
        outputs = all.filter { Self.hasStreams($0, scope: kAudioObjectPropertyScopeOutput) }.compactMap(Self.device)
        defaultInput = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        defaultOutput = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func device(_ id: AudioObjectID) -> Device? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return Device(id: id, name: name.takeRetainedValue() as String)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = address(selector)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func setDefault(_ selector: AudioObjectPropertySelector, to id: AudioObjectID) {
        var address = address(selector)
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }
}
