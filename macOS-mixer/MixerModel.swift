//
//  MixerModel.swift
//  macOS-mixer
//

import AppKit
import CoreAudio
import Observation

@Observable
@MainActor
final class MixerModel {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
        let isPlaying: Bool
    }

    private(set) var entries: [Entry] = []
    private(set) var errorMessage: String?

    // System output volume (the default output device), exactly as the macOS volume HUD shows it.
    private(set) var masterVolume: Float = 0
    private(set) var masterMuted = false
    private(set) var masterAvailable = false
    private(set) var outputDeviceName = ""

    private var volumes: [String: Float] = [:]
    private var mutedIDs: Set<String> = []

    /// Apps whose volume or mute the user has changed; they stay listed while paused. Apps merely lowered by the
    /// system volume cap don't count, or every idle audio process would show up.
    @ObservationIgnored private var adjustedIDs: Set<String> = []
    @ObservationIgnored private var curves: [String: VolumeCurve] = [:]   // by output device UID
    @ObservationIgnored private var activeCurve: VolumeCurve?
    /// What the device really outputs right now (amplitude 0...1); used to compensate app gains.
    @ObservationIgnored private var deviceAmplitude: Float = 0
    @ObservationIgnored private var sessions: [String: TapSession] = [:]
    @ObservationIgnored private var idleSince: [String: Date] = [:]   // app id -> when its tapped audio went silent
    private static let idleTapTimeout: TimeInterval = 3
    private static let unityGain: Float = 0.999
    @ObservationIgnored private var failures: [String: String] = [:]   // app id -> failing configuration
    @ObservationIgnored private var failureMessages: [String: String] = [:]
    @ObservationIgnored private var latestApps: [String: AudioApp] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var listenedDevice: AudioObjectID?
    @ObservationIgnored private var deviceListeners: [CoreAudioHelpers.Listener] = []
    @ObservationIgnored private var defaultDeviceListener: CoreAudioHelpers.Listener?

    init() {
        // Volume keys change the device's volume/mute; react right away instead of waiting for the next poll.
        defaultDeviceListener = CoreAudioHelpers.addListener(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice)
        ) { [weak self] in
            MainActor.assumeIsolated { self?.refreshMaster() }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Controls

    /// No app can be louder than the system slider, so lowering the system slider lowers the apps' sliders by the
    /// same amount. Without a system volume (some HDMI outputs) there's no cap.
    var volumeCap: Float { masterAvailable ? masterVolume : 1 }

    /// The volume you set, limited by the system level. If the system slider pushes an app down, the app comes back
    /// up with it, but never above the volume you set. An app below the system level doesn't move.
    func volume(for id: String) -> Float { min(volumes[id] ?? 1, volumeCap) }
    func isMuted(_ id: String) -> Bool { mutedIDs.contains(id) }

    func setVolume(_ value: Float, for id: String) {
        let value = min(value, volumeCap)
        adjustedIDs.insert(id)
        volumes[id] = value
        if value > 0 { mutedIDs.remove(id) }
        applyGain(for: id)
    }

    func toggleMute(_ id: String) {
        adjustedIDs.insert(id)
        if mutedIDs.contains(id) { mutedIDs.remove(id) } else { mutedIDs.insert(id) }
        applyGain(for: id)
    }

    func setMasterVolume(_ value: Float) {
        guard let device = CoreAudioHelpers.defaultOutputDeviceID() else { return }
        CoreAudioHelpers.setOutputVolume(value, device)
        if value > 0, masterMuted { CoreAudioHelpers.setOutputMuted(false, device) }
        refreshMaster()
    }

    func toggleMasterMute() {
        guard let device = CoreAudioHelpers.defaultOutputDeviceID() else { return }
        CoreAudioHelpers.setOutputMuted(!masterMuted, device)
        refreshMaster()
    }

    /// Reads the default output device's name, volume and mute state. Only assigns on change to avoid redraws.
    private func refreshMaster() {
        let previousCap = volumeCap
        let previousDeviceAmplitude = deviceAmplitude
        let device = CoreAudioHelpers.defaultOutputDeviceID()
        let name = device.flatMap(CoreAudioHelpers.deviceName) ?? ""
        let position = device.flatMap(CoreAudioHelpers.outputVolume)
        let muted = device.flatMap(CoreAudioHelpers.isOutputMuted) ?? false

        // The device's real loudness. If it doesn't report decibels, treat its slider as linear.
        var amplitude = position ?? 0
        activeCurve = nil
        if let device, let uid = CoreAudioHelpers.string(device, kAudioDevicePropertyDeviceUID),
           let decibels = CoreAudioHelpers.outputDecibels(device),
           let range = CoreAudioHelpers.outputDecibelRange(device) {
            var curve = curves[uid] ?? VolumeCurve(minDecibels: range.min, maxDecibels: range.max)
            if let position { curve.record(position: position, decibels: decibels) }
            curves[uid] = curve
            activeCurve = curve
            amplitude = min(Float(pow(10, Double(decibels - range.max) / 20)), 1)
        }
        deviceAmplitude = amplitude

        if outputDeviceName != name { outputDeviceName = name }
        if masterAvailable != (position != nil) { masterAvailable = position != nil }
        if masterVolume != (position ?? 0) { masterVolume = position ?? 0 }
        if masterMuted != muted { masterMuted = muted }
        // Every app's gain depends on the system volume, so they all need updating when it changes.
        if volumeCap != previousCap || deviceAmplitude != previousDeviceAmplitude {
            for id in latestApps.keys { applyGain(for: id) }
        }
    }

    /// The gain the tap applies. An app at X% plays as loud as the system slider (the HUD) at X% would, whatever the
    /// system slider is currently at. The output device attenuates everything by its own amount on top, so the tap
    /// compensates for that. Apps can't be set above the system slider, so this never needs to boost (gain <= 1).
    private func effectiveGain(for id: String) -> Float {
        guard !mutedIDs.contains(id) else { return 0 }
        let volume = volume(for: id)
        let deviceLevel = masterAvailable ? deviceAmplitude : 1
        guard volume > 0, deviceLevel > 0 else { return 0 }
        let target = activeCurve?.amplitude(at: volume) ?? volume
        return min(target / deviceLevel, 1)
    }

    private func applyGain(for id: String) {
        if let app = latestApps[id] { sync(app) }
    }

    // MARK: - Syncing with Core Audio

    private func refresh() {
        refreshMaster()
        let apps = CoreAudioHelpers.currentApps()
        latestApps = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })

        // Drop sessions whose app has gone away.
        for id in sessions.keys where latestApps[id] == nil {
            sessions[id]?.stop()
            sessions[id] = nil
            idleSince[id] = nil
        }
        for app in apps { sync(app) }

        let visible = apps
            .filter { $0.isPlaying || adjustedIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { Entry(id: $0.id, name: $0.name, icon: icon(for: $0), isPlaying: $0.isPlaying) }
        if visible.map(\.id) != entries.map(\.id) || visible.map(\.isPlaying) != entries.map(\.isPlaying) {
            entries = visible
        }
        errorMessage = failureMessages.values.sorted().first
    }

    /// Makes the tap for `app` match the desired gain. A tap is created once the app plays and needs attenuation,
    /// and kept while it plays, so moving the slider only changes gain; creating or destroying a tap
    /// mid-playback causes an audible click. Once the app has been silent, or back at unity gain, for `idleTapTimeout`
    /// the tap is removed.
    /// Any active tap shows the system's purple recording indicator, so apps at unity gain aren't tapped at all.
    private func sync(_ app: AudioApp) {
        let gain = effectiveGain(for: app.id)
        // Floating-point error in the volume compensation can leave "full volume" a hair under 1.
        let needsTap = gain < Self.unityGain
        guard (app.isPlaying && needsTap) || sessions[app.id] != nil else { return }

        if sessions[app.id] != nil {
            if app.isPlaying && needsTap {
                idleSince[app.id] = nil
            } else {
                let since = idleSince[app.id] ?? .now
                idleSince[app.id] = since
                if Date.now.timeIntervalSince(since) >= Self.idleTapTimeout {
                    sessions[app.id]?.stop()
                    sessions[app.id] = nil
                    idleSince[app.id] = nil
                    return
                }
            }
        }
        guard let outputUID = CoreAudioHelpers.defaultOutputDeviceUID() else { return }

        if let session = sessions[app.id] {
            if session.processObjectIDs == app.processObjectIDs, session.outputDeviceUID == outputUID {
                session.gain = gain
                return
            }
            // Process set or output device changed: rebuild the tap.
            session.stop()
            sessions[app.id] = nil
        }

        let key = "\(app.processObjectIDs)|\(outputUID)"
        guard failures[app.id] != key else { return }   // don't retry a failing configuration every second
        do {
            sessions[app.id] = try TapSession(
                name: app.name, processObjectIDs: app.processObjectIDs, outputDeviceUID: outputUID, gain: gain)
            failures[app.id] = nil
            failureMessages[app.id] = nil
        } catch {
            failures[app.id] = key
            failureMessages[app.id] = "\(app.name): \(error.localizedDescription). Check System Settings › Privacy & Security › Screen & System Audio Recording."
        }
    }

    private func icon(for app: AudioApp) -> NSImage {
        if let cached = icons[app.id] { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 28, height: 28)
        icons[app.id] = image
        return image
    }
}
