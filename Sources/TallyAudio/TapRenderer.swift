import CoreAudio
import Synchronization

/// Copies a tap's stereo mix to the output device, scaled by a gain that glides to its target so changes
/// never click. `render` runs on the real-time I/O thread: no locks, no allocation.
final class TapRenderer: @unchecked Sendable {
    private let targetGainBits: Atomic<UInt32>
    private let peakBits = Atomic<UInt32>(0)
    private let frameCounter = Atomic<Int>(0)
    private let inputBufferCounter = Atomic<Int>(0)
    private let outputChannelCounter = Atomic<Int>(0)
    /// Touched only on the I/O thread.
    private var currentGain: Float
    /// The largest gain change allowed per frame: a full sweep takes about 30 ms.
    private let maximumStepPerFrame: Float
    /// How many of the aggregate device's input buffers belong to the tap. They come after the output device's own inputs.
    private let tapBufferCount: Int

    init(gain: Float, startingGain: Float, sampleRate: Double, tapBufferCount: Int) {
        targetGainBits = Atomic(gain.bitPattern)
        currentGain = startingGain
        maximumStepPerFrame = Float(1 / (max(sampleRate, 8000) * 0.03))
        self.tapBufferCount = max(1, tapBufferCount)
    }

    var gain: Float {
        get { Float(bitPattern: targetGainBits.load(ordering: .relaxed)) }
        set { targetGainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var renderedFrames: Int { frameCounter.load(ordering: .relaxed) }

    /// The buffer layout of the last I/O cycle.
    var layout: (inputBuffers: Int, outputChannels: Int) {
        (inputBufferCounter.load(ordering: .relaxed), outputChannelCounter.load(ordering: .relaxed))
    }

    /// The loudest input sample since the last call.
    func takePeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let firstTapBuffer = max(0, inputs.count - tapBufferCount)
        inputBufferCounter.store(inputs.count, ordering: .relaxed)

        guard inputs.count > firstTapBuffer, let leftData = inputs[firstTapBuffer].mData, inputs[firstTapBuffer].mNumberChannels > 0 else {
            silence(outputs)
            return
        }
        let leftBuffer = inputs[firstTapBuffer]
        let left = leftData.assumingMemoryBound(to: Float.self)
        let leftStride = Int(leftBuffer.mNumberChannels)
        var right = left
        var rightStride = leftStride
        if leftStride >= 2 {
            right = left + 1
        } else if inputs.count > firstTapBuffer + 1, let rightData = inputs[firstTapBuffer + 1].mData, inputs[firstTapBuffer + 1].mNumberChannels > 0 {
            right = rightData.assumingMemoryBound(to: Float.self)
            rightStride = Int(inputs[firstTapBuffer + 1].mNumberChannels)
        }
        let inputFrames = Int(leftBuffer.mDataByteSize) / (MemoryLayout<Float>.size * leftStride)

        var outputChannelCount = 0
        var outputFrames = 0
        for buffer in outputs {
            outputChannelCount += Int(buffer.mNumberChannels)
            if buffer.mNumberChannels > 0 {
                outputFrames = max(outputFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
            }
        }
        outputChannelCounter.store(outputChannelCount, ordering: .relaxed)
        guard outputFrames > 0 else { return }

        let target = gain
        let startGain = currentGain
        let largestStep = maximumStepPerFrame * Float(outputFrames)
        let endGain = startGain + min(max(target - startGain, -largestStep), largestStep)
        let gainStep = (endGain - startGain) / Float(outputFrames)
        let frames = min(inputFrames, outputFrames)

        var peak: Float = 0
        for frame in 0..<frames {
            peak = max(peak, abs(left[frame * leftStride]), abs(right[frame * rightStride]))
        }

        var channelBase = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            defer { channelBase += channels }
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let bufferFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for frame in 0..<bufferFrames {
                let frameGain = startGain + gainStep * Float(frame + 1)
                let leftSample = frame < frames ? left[frame * leftStride] * frameGain : 0
                let rightSample = frame < frames ? right[frame * rightStride] * frameGain : 0
                for channel in 0..<channels {
                    let outputChannel = channelBase + channel
                    let sample: Float
                    if outputChannelCount == 1 {
                        sample = (leftSample + rightSample) * 0.5
                    } else if outputChannel == 0 {
                        sample = leftSample
                    } else if outputChannel == 1 {
                        sample = rightSample
                    } else {
                        sample = 0
                    }
                    data[frame * channels + channel] = sample
                }
            }
        }

        currentGain = endGain
        frameCounter.add(outputFrames, ordering: .relaxed)
        if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) {
            peakBits.store(peak.bitPattern, ordering: .relaxed)
        }
    }

    private func silence(_ outputs: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
}
