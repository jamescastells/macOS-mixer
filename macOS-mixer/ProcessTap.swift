//
//  ProcessTap.swift
//  macOS-mixer
//

import AudioToolbox
import CoreAudio
import Foundation

struct TapError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) failed (OSStatus \(status))" }
}

/// Applies gain between the tap's input and the output device. Runs on the audio thread,
/// so it is deliberately not main-actor isolated.
nonisolated final class GainRenderer: @unchecked Sendable {
    /// Written from the main thread, read from the audio thread. A stale read is harmless.
    var targetGain: Float = 1
    private var currentGain: Float = 1

    func makeBlock() -> AudioDeviceIOBlock {
        { [self] _, input, _, output, _ in
            render(input: input, output: output)
        }
    }

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let startGain = currentGain
        let endGain = targetGain

        for index in 0..<outputs.count {
            let out = outputs[index]
            guard let outData = out.mData else { continue }
            memset(outData, 0, Int(out.mDataByteSize))
            guard index < inputs.count, let inData = inputs[index].mData else { continue }

            let inChannels = max(Int(inputs[index].mNumberChannels), 1)
            let outChannels = max(Int(out.mNumberChannels), 1)
            let inFrames = Int(inputs[index].mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
            let outFrames = Int(out.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
            let frames = min(inFrames, outFrames)
            guard frames > 0 else { continue }

            let src = inData.assumingMemoryBound(to: Float.self)
            let dst = outData.assumingMemoryBound(to: Float.self)
            let channels = min(inChannels, outChannels)
            let step = (endGain - startGain) / Float(frames)   // ramp to avoid zipper noise

            for frame in 0..<frames {
                let gain = startGain + step * Float(frame)
                for channel in 0..<channels {
                    dst[frame * outChannels + channel] = src[frame * inChannels + channel] * gain
                }
            }
        }
        currentGain = endGain
    }
}

/// Taps a set of processes, silences their normal output, and re-plays the audio at a chosen gain.
final class TapSession {
    let processObjectIDs: [AudioObjectID]
    let outputDeviceUID: String

    private let renderer = GainRenderer()
    private let queue = DispatchQueue(label: "mixer.tap.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    var gain: Float {
        get { renderer.targetGain }
        set { renderer.targetGain = newValue }
    }

    init(name: String, processObjectIDs: [AudioObjectID], outputDeviceUID: String, gain: Float) throws {
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        renderer.targetGain = gain

        do {
            try start(name: name)
        } catch {
            stop()
            throw error
        }
    }

    private func start(name: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError(step: "Creating process tap", status: status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixer – \(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError(step: "Creating aggregate device", status: status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue, renderer.makeBlock())
        guard status == noErr else { throw TapError(step: "Creating IO proc", status: status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError(step: "Starting device", status: status) }
    }

    /// Tears everything down; the app's audio goes back to playing normally.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
