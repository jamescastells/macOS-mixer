//
//  CoreAudioHelpers.swift
//  macOS-mixer
//

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// An app (or command-line tool) that currently has an audio client registered with Core Audio.
/// Helper processes (e.g. browser renderers) are grouped under their outermost `.app`.
struct AudioApp {
    let id: String
    let name: String
    let path: String
    let processObjectIDs: [AudioObjectID]
    let isPlaying: Bool
}

enum CoreAudioHelpers {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        initial: T
    ) -> T? {
        var addr = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        var result = initial
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        guard let cf = value(object, selector, initial: Optional<Unmanaged<CFString>>.none) ?? nil else { return nil }
        return cf.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    @discardableResult
    static func setValue<T: BitwiseCopyable>(
        _ newValue: T,
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var addr = address(selector, scope: scope)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &addr, &settable) == noErr, settable.boolValue else { return false }
        var copy = newValue
        return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &copy) == noErr
    }

    // MARK: - Change notifications

    /// A registered property listener, kept so it can be removed again.
    typealias Listener = (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)

    /// Calls `handler` on the main queue whenever the property changes. Returns nil if the object doesn't
    /// support the property.
    static func addListener(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        handler: @escaping @Sendable () -> Void
    ) -> Listener? {
        var addr = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr else { return nil }
        return (address, block)
    }

    static func removeListener(_ object: AudioObjectID, _ listener: Listener) {
        var addr = listener.address
        AudioObjectRemovePropertyListenerBlock(object, &addr, .main, listener.block)
    }

    // MARK: - Default output device (system volume)

    static func defaultOutputDeviceID() -> AudioObjectID? {
        guard let device = value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown)
        ), device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func deviceName(_ device: AudioObjectID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    /// The device's overall output volume, 0...1, or nil if the device has no software volume (e.g. some HDMI outputs).
    static func outputVolume(_ device: AudioObjectID) -> Float? {
        value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
              scope: kAudioDevicePropertyScopeOutput, initial: Float32(0))
    }

    @discardableResult
    static func setOutputVolume(_ volume: Float, _ device: AudioObjectID) -> Bool {
        setValue(Float32(volume), device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                 scope: kAudioDevicePropertyScopeOutput)
    }

    /// The device's current output level in decibels (what the volume slider actually does; it isn't linear).
    static func outputDecibels(_ device: AudioObjectID) -> Float? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            if let decibels = value(device, kAudioDevicePropertyVolumeDecibels,
                                    scope: kAudioDevicePropertyScopeOutput, element: element, initial: Float32(0)) {
                return decibels
            }
        }
        return nil
    }

    /// The quietest and loudest decibel values the device's volume can reach.
    static func outputDecibelRange(_ device: AudioObjectID) -> (min: Float, max: Float)? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            if let range = value(device, kAudioDevicePropertyVolumeRangeDecibels,
                                 scope: kAudioDevicePropertyScopeOutput, element: element, initial: AudioValueRange()) {
                return (Float(range.mMinimum), Float(range.mMaximum))
            }
        }
        return nil
    }

    static func isOutputMuted(_ device: AudioObjectID) -> Bool? {
        value(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0)).map { $0 != 0 }
    }

    @discardableResult
    static func setOutputMuted(_ muted: Bool, _ device: AudioObjectID) -> Bool {
        setValue(UInt32(muted ? 1 : 0), device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let device = value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown)
        ), device != kAudioObjectUnknown else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    // MARK: - Processes

    /// Snapshot of every process known to Core Audio, grouped per app.
    /// System UI that only makes sound momentarily (e.g. the screenshot shutter) and would flash up as a row.
    private static let ignoredAppPaths: Set<String> = [
        "/System/Applications/Utilities/Screenshot.app",
        "/usr/sbin/systemsoundserverd",   // plays system sounds such as the screenshot shutter
    ]

    static func currentApps() -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var groups: [String: (name: String, path: String, ids: [AudioObjectID], playing: Bool)] = [:]

        for object in objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard let pid = value(object, kAudioProcessPropertyPID, initial: pid_t(0)), pid != ownPID,
                  let path = executablePath(pid: pid) else { continue }
            let playing = (value(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            let (appPath, name) = appIdentity(forExecutablePath: path)
            guard !ignoredAppPaths.contains(appPath) else { continue }

            var group = groups[appPath] ?? (name, appPath, [], false)
            group.ids.append(object)
            group.playing = group.playing || playing
            groups[appPath] = group
        }

        return groups.map { id, group in
            AudioApp(id: id, name: group.name, path: group.path,
                     processObjectIDs: group.ids.sorted(), isPlaying: group.playing)
        }
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Returns the outermost `.app` bundle path (so helpers map to their parent app) and a display name.
    private static func appIdentity(forExecutablePath path: String) -> (path: String, name: String) {
        if let range = path.range(of: ".app/") {
            let bundlePath = String(path[..<range.lowerBound]) + ".app"
            let info = Bundle(path: bundlePath)?.infoDictionary
            let name = (info?["CFBundleDisplayName"] as? String)
                ?? (info?["CFBundleName"] as? String)
                ?? URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
            return (bundlePath, name)
        }
        return (path, URL(fileURLWithPath: path).lastPathComponent)
    }
}
