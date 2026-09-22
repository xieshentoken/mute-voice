// Opt-in hardware verification. Reads only BlackHole; retains levels, never raw audio.
// Compiled together with Sources/AudioOutput.swift and Sources/Configuration.swift.
import AVFoundation
import CoreAudio
import Foundation

private final class Meter {
  let device: AudioDestination
  let rate: Double
  private var proc: AudioDeviceIOProcID?
  private let peaks = UnsafeMutableBufferPointer<Float>.allocate(capacity: 18000)
  private let squares = UnsafeMutableBufferPointer<Double>.allocate(capacity: 18000)
  private let counts = UnsafeMutableBufferPointer<Int>.allocate(capacity: 18000)
  private var frames = 0

  init() throws {
    device = try AudioDestination.resolve("BlackHole2ch_UID", from: AudioDestination.blackHoles())
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(device.deviceID, &address, 0, nil, &size, &format)
    guard status == noErr, format.mFormatID == kAudioFormatLinearPCM,
      format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
      format.mBitsPerChannel == 32, format.mSampleRate > 0
    else { throw VoiceError.message("BlackHole meter requires Float32 input: \(status)") }
    rate = format.mSampleRate
    peaks.initialize(repeating: 0)
    squares.initialize(repeating: 0)
    counts.initialize(repeating: 0)
  }

  func start() throws {
    let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device.deviceID, nil) {
      [self] _, input, _, output, _ in
      // No allocations, locks, logging or network calls in the device callback.
      var blockFrames = 0
      for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
        guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
        let channels = Int(buffer.mNumberChannels)
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        blockFrames = max(blockFrames, count / channels)
        for index in 0..<count {
          let bin = Int(Double(frames + index / channels) / rate * 100)
          guard bin < peaks.count else { continue }
          let value = samples[index]
          peaks[bin] = max(peaks[bin], abs(value))
          squares[bin] += Double(value) * Double(value)
          counts[bin] += 1
        }
      }
      frames += blockFrames
      // A duplex IOProc must explicitly emit silence on its own output buffers.
      for buffer in UnsafeMutableAudioBufferListPointer(output) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
      }
    }
    guard status == noErr, let proc else {
      throw VoiceError.message("Create BlackHole meter failed: \(status)")
    }
    let start = AudioDeviceStart(device.deviceID, proc)
    guard start == noErr else { throw VoiceError.message("Start BlackHole meter failed: \(start)") }
  }

  func stop() {
    if let proc {
      AudioDeviceStop(device.deviceID, proc)
      AudioDeviceDestroyIOProcID(device.deviceID, proc)
    }
    proc = nil
  }

  func report() -> [String: Any] {
    let count = min(peaks.count, Int(ceil(Double(frames) / rate * 100)))
    let levels = (0..<count).map { index -> [String: Any] in
      [
        "second": Double(index) / 100, "peak": peaks[index],
        "rms": counts[index] > 0 ? sqrt(squares[index] / Double(counts[index])) : 0,
      ]
    }
    let active = (0..<count).filter { peaks[$0] > 0.0001 }
    var bursts: [[String: Double]] = []
    var first: Int?
    for index in 0...count {
      if index < count && peaks[index] > 0.0001 {
        if first == nil { first = index }
      } else if let begin = first {
        bursts.append([
          "start": Double(begin) / 100, "end": Double(index) / 100,
          "duration": Double(index - begin) / 100,
        ])
        first = nil
      }
    }
    let totalSamples = counts.prefix(count).reduce(0, +)
    return [
      "device": device.name, "sample_rate": rate, "frames": frames,
      "peak": peaks.prefix(count).max() ?? 0,
      "rms": totalSamples > 0 ? sqrt(squares.prefix(count).reduce(0, +) / Double(totalSamples)) : 0,
      "bursts": bursts,
      "audible_seconds": Double(active.count) / 100,
      "first_audio_second": active.first.map { Double($0) / 100 } ?? -1,
      "last_audio_second": active.last.map { Double($0 + 1) / 100 } ?? -1,
      "levels": levels,
    ]
  }

  deinit {
    stop()
    peaks.deallocate()
    squares.deallocate()
    counts.deallocate()
  }
}

@main enum VerifyAudio {
  @MainActor static func main() async throws {
    let arguments = CommandLine.arguments
    let listening = arguments.contains("--listen")
    let pausing = arguments.contains("--pause")
    let monitorUID: String? = arguments.contains("--monitor") ? "" : nil
    let meter = try Meter()
    try meter.start()
    defer { meter.stop() }
    let started = Date()
    print("BlackHole meter ready; raw audio is not saved.")
    fflush(stdout)
    var marks: [String: Double] = [:]
    if listening {
      try await Task.sleep(nanoseconds: 45_000_000_000)
    } else {
      let output = PCMOutput()
      defer { output.stop() }
      try await Task.sleep(nanoseconds: 300_000_000)
      // One second of PCM16LE at 24 kHz, delivered in deliberately odd-sized chunks.
      var tone = Data()
      for frame in 0..<24000 {
        let value = Int16(sin(2 * Double.pi * 440 * Double(frame) / 24000) * 1638)
        let bits = UInt16(bitPattern: value)
        tone.append(UInt8(bits & 255))
        tone.append(UInt8(bits >> 8))
      }
      if pausing {
        try await output.prepare(uid: meter.device.id, monitorUID: monitorUID, paused: true)
        try await output.append(tone)
        guard output.bufferedSeconds == 1 else {
          throw VoiceError.message("Initial paused buffering failed")
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        marks["first_resume"] = Date().timeIntervalSince(started)
        output.setPaused(false)
        try await Task.sleep(nanoseconds: 400_000_000)
        marks["pause_called"] = Date().timeIntervalSince(started)
        output.setPaused(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = output.bufferedSeconds
        try await output.append(tone)
        guard abs(output.bufferedSeconds - before - 1) < 0.01 else {
          throw VoiceError.message("Generation did not continue during pause")
        }
        let finishing = Task { try await output.finish() }
        marks["generation_finished"] = Date().timeIntervalSince(started)
        try await Task.sleep(nanoseconds: 700_000_000)
        guard abs(output.bufferedSeconds - before - 1) < 0.02 else {
          throw VoiceError.message("Paused audio was consumed")
        }
        marks["second_resume"] = Date().timeIntervalSince(started)
        output.setPaused(false)
        try await finishing.value
        marks["playback_finished"] = Date().timeIntervalSince(started)
        try await Task.sleep(nanoseconds: 500_000_000)
      } else {
        try await output.prepare(uid: meter.device.id, monitorUID: monitorUID)
        marks["normal_start"] = Date().timeIntervalSince(started)
        for offset in stride(from: 0, to: tone.count, by: 1001) {
          try await output.append(tone.subdata(in: offset..<min(offset + 1001, tone.count)))
        }
        try await output.finish()
        marks["normal_finished"] = Date().timeIntervalSince(started)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await output.prepare(uid: meter.device.id, monitorUID: monitorUID)
        let sending = Task {
          for _ in 0..<10 { try await output.append(tone) }
          try await output.finish()
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        marks["stop_called"] = Date().timeIntervalSince(started)
        output.stop()
        sending.cancel()
        _ = await sending.result
        marks["stop_returned"] = Date().timeIntervalSince(started)
        try await Task.sleep(nanoseconds: 700_000_000)
      }
    }
    meter.stop()
    var report = meter.report()
    report["mode"] = listening ? "listen" : (pausing ? "pause-resume" : "pcm-output")
    report["monitor_enabled"] = monitorUID != nil
    report["marks"] = marks
    let bursts = report["bursts"] as? [[String: Double]] ?? []
    let stopDelay = (report["last_audio_second"] as? Double ?? 0) - (marks["stop_called"] ?? 0)
    let pausePassed =
      bursts.count == 2
      && (1.98...2.05).contains(bursts.reduce(0) { $0 + ($1["duration"] ?? 0) })
      && (bursts.first?["start"] ?? 0) >= (marks["first_resume"] ?? 0) - 0.05
      && (bursts.first?["end"] ?? 0) <= (marks["pause_called"] ?? 0) + 0.15
      && (bursts.last?["start"] ?? 0) >= (marks["second_resume"] ?? 0) - 0.05
    let passed =
      (report["frames"] as? Int ?? 0) > 0 && (report["peak"] as? Float ?? 0) > 0.001
      && (listening
        || (pausing
          ? pausePassed
          : (bursts.count == 2 && (0.98...1.05).contains(bursts[0]["duration"] ?? 0)
            && (0.5...0.85).contains(bursts[1]["duration"] ?? 0)
            && (-0.05...0.15).contains(stopDelay))))
    report["passed"] = passed
    if !listening && !pausing { report["stop_to_silence_seconds"] = stopDelay }
    let path =
      (arguments.last?.hasPrefix("--") ?? false) || arguments.count == 1
      ? ".build/audio-verification.json" : arguments.last!
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path))
    report.removeValue(forKey: "levels")
    print(String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
    print("Report: \(path)")
    guard passed else {
      throw VoiceError.message(
        "BlackHole verification failed; inspect the saved levels and timing.")
    }
  }
}
