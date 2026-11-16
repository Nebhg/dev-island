import CoreAudio
import Foundation

/// The system output volume, for `↑` / `↓` on the Music panel.
///
/// CoreAudio rather than `osascript`, because a held arrow key produces one event per
/// repeat and spawning a process for each of them is the wrong shape for something
/// that should feel like a key. This is a property write on the default output device.
///
/// It is the **system** volume, not a player's. MediaRemote exposes transport commands
/// and no volume, and the app is a now-playing reader rather than an audio client, so
/// there is no per-app volume to adjust even in principle.
///
/// Unverified on hardware. A device that reports no settable volume element does
/// nothing at all, deliberately: the alternative is a dialog raised by an arrow key.
/// The three things that make it no-op are worth knowing when it appears broken — no
/// default output device, no element that reports itself settable, or no element that
/// can be read back — and each is a separate early return for that reason.
enum SystemVolume {
    /// One arrow press. Sixteen steps end to end, which is roughly one notch of the
    /// system HUD per step.
    private static let step: Float = 1.0 / 16.0

    static func adjust(by delta: Float) {
        guard let device = defaultOutputDevice else { return }
        let elements = settableElements(of: device)
        // Read from the first element that actually answers, not from the first in
        // the list. A device can advertise a settable main element and still refuse
        // to be read, and taking the head of the list would then fail the whole
        // adjustment while the two channels beside it were perfectly usable.
        guard let current = elements.lazy.compactMap({ volume(of: device, element: $0) }).first
        else { return }
        let next = min(max(current + delta * step, 0), 1)
        // Written to every element that takes one. A stereo device exposes its two
        // channels separately and has no main element, so writing only the first would
        // move one channel and leave the other where it was.
        for element in elements {
            setVolume(next, of: device, element: element)
        }
    }

    // MARK: - CoreAudio

    private static var defaultOutputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    /// The main element where a device has one, otherwise its channels.
    ///
    /// Checked with `AudioObjectIsPropertySettable` rather than assumed: an aggregate
    /// or virtual device can advertise the property and refuse the write, and a failed
    /// write is silent.
    private static func settableElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var candidates: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
        candidates.append(contentsOf: [1, 2].map { AudioObjectPropertyElement($0) })
        return candidates.filter { element in
            var address = volumeAddress(element)
            guard AudioObjectHasProperty(device, &address) else { return false }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
            return settable.boolValue
        }
    }

    private static func volume(
        of device: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = volumeAddress(element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func setVolume(
        _ value: Float,
        of device: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) {
        var address = volumeAddress(element)
        var value = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }
}
