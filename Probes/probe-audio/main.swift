import Foundation
import TallyCore
import TallyAudio

// probe-audio                 list the apps playing sound
// probe-audio --tap afplay    also route that app through a tap at 30%, mute it, then hand it back
// add --assume-permission to skip the privacy check when running from a terminal

@MainActor
func printApps(_ mixer: AudioMixer) {
    if mixer.apps.isEmpty { print("  Nothing is playing sound") }
    for app in mixer.apps {
        let state = app.isPlaying ? "playing" : "quiet"
        let level = app.isMuted ? "muted" : String(format: "%.0f%%", app.volume * 100)
        let tapped = app.isTapped ? " tapped" : ""
        print("  \(app.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(state.padding(toLength: 8, withPad: " ", startingAt: 0)) \(level)\(tapped)  pids \(app.pids.map(String.init).joined(separator: ","))  [\(app.bundleIdentifier ?? "-")]  \(app.id)")
        if let problem = app.problem { print("    problem: \(problem)") }
    }
}

@MainActor
func printTaps(_ mixer: AudioMixer, label: String) async {
    let taps = await mixer.diagnostics()
    if taps.isEmpty { print("  [\(label)] no taps") }
    for tap in taps {
        print(String(format: "  [%@] tap %u aggregate %u output %u processes %@ gain %.3f frames %d peak %.4f buffers in %d out channels %d", label, tap.tapID, tap.aggregateDeviceID, tap.outputDeviceID, tap.processObjectIDs.map(String.init).joined(separator: ","), tap.gain, tap.renderedFrames, tap.inputPeak, tap.inputBufferCount, tap.outputChannelCount))
    }
}

@MainActor
func run() async {
    let start = Date()
    let mixer = AudioMixer.shared
    print(String(format: "First load took %.0f ms", Date().timeIntervalSince(start) * 1000))
    print("Output device: \(mixer.outputDeviceName ?? "none")")
    print("Audio capture permission: \(mixer.permission.rawValue)")
    mixer.start()
    try? await Task.sleep(for: .milliseconds(600))
    print("Apps playing sound:")
    printApps(mixer)

    let arguments = CommandLine.arguments
    guard let flagIndex = arguments.firstIndex(of: "--tap") else {
        mixer.stop()
        mixer.shutdown()
        return
    }
    let targetName = flagIndex + 1 < arguments.count ? arguments[flagIndex + 1] : "afplay"
    guard let target = mixer.apps.first(where: { $0.name == targetName }) else {
        print("No app named \(targetName) is playing sound")
        mixer.shutdown()
        return
    }

    if arguments.contains("--assume-permission") { mixer.assumeAudioCaptureAllowed() }
    print("\nSetting \(target.name) to 30% (permission \(mixer.permission.rawValue))")
    mixer.setVolume(0.3, for: target.id)
    for second in 1...3 {
        try? await Task.sleep(for: .seconds(1))
        await printTaps(mixer, label: "30% +\(second)s")
    }
    printApps(mixer)

    print("\nMuting \(target.name)")
    mixer.setMuted(true, for: target.id)
    try? await Task.sleep(for: .seconds(1))
    await printTaps(mixer, label: "muted")

    print("\nUnmuting and dragging through 100% and back to 60%")
    mixer.setMuted(false, for: target.id)
    mixer.setVolume(1, for: target.id)
    try? await Task.sleep(for: .milliseconds(400))
    mixer.setVolume(0.6, for: target.id)
    try? await Task.sleep(for: .seconds(1))
    await printTaps(mixer, label: "60%")

    print("\nBack to 100%")
    mixer.setVolume(1, for: target.id)
    try? await Task.sleep(for: .seconds(1))
    await printTaps(mixer, label: "100% +1s")
    try? await Task.sleep(for: .seconds(1.5))
    await printTaps(mixer, label: "100% +2.5s")
    printApps(mixer)

    print("\nSetting 20% again, then shutting down with the tap live")
    mixer.setVolume(0.2, for: target.id)
    try? await Task.sleep(for: .seconds(1))
    await printTaps(mixer, label: "20%")
    mixer.shutdown()
    await printTaps(mixer, label: "after shutdown")
}

await run()
