import CoreAudio
import Foundation

/// One app's audio, captured with a Core Audio process tap and played back at a new level.
///
/// The tap mutes the app's own output while Tally reads it; a private aggregate device made of the current
/// output device plus the tap runs an I/O proc that copies the tap to the output, scaled by the gain.
/// Nothing is stored: samples go straight from the input buffer to the output buffer.
final class ProcessTap {
    let appID: String
    let outputDeviceID: AudioObjectID
    private(set) var processObjectIDs: [AudioObjectID]
    let renderer: TapRenderer

    private let tapDescription: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(appID: String, name: String, processObjectIDs: [AudioObjectID], outputDeviceID: AudioObjectID, gain: Float) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Tally volume for \(name)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        var createdProc: AudioDeviceIOProcID?
        do {
            try check(AudioHardwareCreateProcessTap(description, &createdTap), "Creating the process tap")
            guard let outputUID = AudioProperty.string(outputDeviceID, kAudioDevicePropertyDeviceUID) else {
                throw CoreAudioError(operation: "Reading the output device", status: kAudioHardwareBadDeviceError)
            }
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Tally Volume",
                kAudioAggregateDeviceUIDKey: "local.tally.volume." + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregate), "Creating the aggregate device")

            guard let tapFormat = AudioProperty.streamFormat(tap: createdTap), tapFormat.mFormatID == kAudioFormatLinearPCM,
                  tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, tapFormat.mBitsPerChannel == 32 else {
                throw CoreAudioError(operation: "Reading the tap format", status: kAudioHardwareUnsupportedOperationError)
            }
            let isNonInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let tapBufferCount = isNonInterleaved ? Int(tapFormat.mChannelsPerFrame) : 1
            let sampleRate = AudioProperty.value(createdAggregate, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? tapFormat.mSampleRate

            let renderer = TapRenderer(gain: gain, startingGain: 1, sampleRate: sampleRate, tapBufferCount: tapBufferCount)
            try check(AudioDeviceCreateIOProcIDWithBlock(&createdProc, createdAggregate, nil) { _, input, _, output, _ in
                renderer.render(input: input, output: output)
            }, "Adding the I/O proc")
            if let createdProc { Self.useOnlyTapInput(aggregateDeviceID: createdAggregate, ioProcID: createdProc) }
            try check(AudioDeviceStart(createdAggregate, createdProc), "Starting the aggregate device")
            self.renderer = renderer
        } catch {
            Self.destroy(tapID: createdTap, aggregateDeviceID: createdAggregate, ioProcID: createdProc)
            throw error
        }

        self.appID = appID
        self.outputDeviceID = outputDeviceID
        self.processObjectIDs = processObjectIDs
        tapDescription = description
        tapID = createdTap
        aggregateDeviceID = createdAggregate
        ioProcID = createdProc
    }

    /// Point the existing tap at a new set of processes, for example when an app starts another helper.
    func update(processObjectIDs newIDs: [AudioObjectID]) -> Bool {
        guard tapID != kAudioObjectUnknown else { return false }
        tapDescription.processes = newIDs
        var address = AudioProperty.address(kAudioTapPropertyDescription)
        var reference = Unmanaged.passUnretained(tapDescription)
        let status = AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), &reference)
        guard status == noErr else { return false }
        processObjectIDs = newIDs
        return true
    }

    var diagnostics: AudioTapDiagnostics {
        AudioTapDiagnostics(
            appID: appID,
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            outputDeviceID: outputDeviceID,
            processObjectIDs: processObjectIDs,
            gain: renderer.gain,
            renderedFrames: renderer.renderedFrames,
            inputBufferCount: renderer.layout.inputBuffers,
            outputChannelCount: renderer.layout.outputChannels,
            inputPeak: renderer.takePeak()
        )
    }

    /// Stops playback and destroys the aggregate device and the tap, so the app plays on its own again.
    func invalidate() {
        Self.destroy(tapID: tapID, aggregateDeviceID: aggregateDeviceID, ioProcID: ioProcID)
        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// When the output device also has inputs (a headset, an audio interface), tell the HAL this I/O proc
    /// reads only the tap, so the microphone is never switched on.
    private static func useOnlyTapInput(aggregateDeviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) {
        let streamCount = AudioProperty.array(aggregateDeviceID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioObjectID.self).count
        guard streamCount > 1 else { return }
        var address = AudioProperty.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let byteCount = flagsOffset + MemoryLayout<UInt32>.size * streamCount
        let storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let usage = storage.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streamCount)
        var size = UInt32(byteCount)
        guard AudioObjectGetPropertyData(aggregateDeviceID, &address, 0, nil, &size, storage) == noErr else { return }
        let count = min(Int(usage.pointee.mNumberStreams), streamCount)
        let flags = (storage + flagsOffset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<count { flags[index] = index == count - 1 ? 1 : 0 }
        AudioObjectSetPropertyData(aggregateDeviceID, &address, 0, nil, size, storage)
    }

    private static func destroy(tapID: AudioObjectID, aggregateDeviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    deinit {
        invalidate()
    }
}
