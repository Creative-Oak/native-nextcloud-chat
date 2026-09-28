import Foundation

#if os(macOS)
import CoreAudio

/// A microphone or speaker, as the system names it: a Core Audio object on the Mac, a port
/// UID on iPhone and iPad.
typealias AudioDeviceID = AudioObjectID

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
        let id: AudioDeviceID
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
#else
@preconcurrency import AVFoundation
@preconcurrency import WebRTC

typealias AudioDeviceID = String

/// The microphones and speakers an iPhone or iPad can use in a call, and which are in use —
/// live, so AirPods appear the moment they connect.
///
/// iOS routes audio per app through its audio session, and WebRTC follows the route as it
/// changes, so choosing a device here re-routes the call without restarting it — unlike the
/// Mac, where the choice changes the system default.
@MainActor
@Observable
final class AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
    }

    /// The loudspeaker, which iOS doesn't list as a port you can prefer: it is an override.
    static let speaker = "kvidr.speaker"
    /// The earpiece, or an iPad's own speaker — what a call plays through with no override.
    static let builtIn = "kvidr.built-in"

    private(set) var inputs: [Device] = []
    private(set) var outputs: [Device] = []
    private(set) var defaultInput: AudioDeviceID = ""
    private(set) var defaultOutput: AudioDeviceID = ""

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        observer.map(NotificationCenter.default.removeObserver)
    }

    func setDefaultInput(_ id: AudioDeviceID) {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == id }) else { return }
        configure { try $0.setPreferredInput(port) }
        refresh()
    }

    func setDefaultOutput(_ id: AudioDeviceID) {
        if id == Self.speaker {
            configure { try $0.overrideOutputAudioPort(.speaker) }
        } else {
            configure { try $0.overrideOutputAudioPort(.none) }
            // A headset's output comes with its microphone: choosing it is choosing that input.
            if id != Self.builtIn, let port = AVAudioSession.sharedInstance().availableInputs?.first(where: { $0.uid == id }) {
                configure { try $0.setPreferredInput(port) }
            }
        }
        refresh()
    }

    /// Through WebRTC's session wrapper, which is holding the audio session for the call.
    private func configure(_ change: (RTCAudioSession) throws -> Void) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try change(session)
        } catch {
            Log.sync.warning("Call: couldn’t change the audio route — \(error.localizedDescription)")
        }
    }

    func refresh() {
        let session = AVAudioSession.sharedInstance()
        inputs = (session.availableInputs ?? []).map { Device(id: $0.uid, name: $0.portName) }
        defaultInput = session.currentRoute.inputs.first?.uid ?? session.preferredInput?.uid ?? inputs.first?.id ?? ""

        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        var outputs = [Device(id: Self.builtIn, name: isPhone ? "iPhone" : "iPad")]
        if isPhone { outputs.append(Device(id: Self.speaker, name: "Speaker")) }
        // Headsets and car kits: they come and go with the route.
        let external = (session.availableInputs ?? []).filter { $0.portType != .builtInMic }
        outputs += external.map { Device(id: $0.uid, name: $0.portName) }
        for port in session.currentRoute.outputs where ![.builtInReceiver, .builtInSpeaker].contains(port.portType)
            && !outputs.contains(where: { $0.name == port.portName }) {
            outputs.append(Device(id: port.uid, name: port.portName))
        }
        self.outputs = outputs

        let current = session.currentRoute.outputs.first
        switch current?.portType {
        case .builtInSpeaker?: defaultOutput = isPhone ? Self.speaker : Self.builtIn
        case .builtInReceiver?, nil: defaultOutput = Self.builtIn
        default:
            defaultOutput = external.first(where: { $0.portName == current?.portName })?.uid ?? current?.uid ?? Self.builtIn
        }
    }
}
#endif
