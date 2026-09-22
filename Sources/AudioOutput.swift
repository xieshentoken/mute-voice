import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioDestination: Identifiable, Equatable, Codable {
  let id: String  // Persistent device UID, never a remembered numeric device ID.
  let name: String
  let deviceID: AudioObjectID
  let channels: Int
  var transport: UInt32 = kAudioDeviceTransportTypeBuiltIn

  var canMonitor: Bool {
    !name.lowercased().hasPrefix("blackhole")
      && ![kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate].contains(transport)
  }

  static func blackHoles() -> [AudioDestination] {
    outputs().filter { $0.name.lowercased().hasPrefix("blackhole") && $0.channels >= 2 }
  }

  static func outputs() -> [AudioDestination] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
      size > 0
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let result = ids.withUnsafeMutableBytes { buffer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, buffer.baseAddress!)
    }
    guard result == noErr else { return [] }
    return ids.compactMap { id in
      guard let name = string(id, kAudioObjectPropertyName),
        let uid = string(id, kAudioDevicePropertyDeviceUID), isAlive(id)
      else { return nil }
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
      var bytes: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &bytes) == noErr,
        bytes >= MemoryLayout<AudioBufferList>.size
      else { return nil }
      let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
      defer { storage.deallocate() }
      guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, storage) == noErr else {
        return nil
      }
      let list = UnsafeMutableAudioBufferListPointer(
        storage.assumingMemoryBound(to: AudioBufferList.self))
      let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
      guard channels >= 1 else { return nil }
      var transport: UInt32 = 0
      address.mSelector = kAudioDevicePropertyTransportType
      address.mScope = kAudioObjectPropertyScopeGlobal
      bytes = UInt32(MemoryLayout<UInt32>.size)
      guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &transport) == noErr else {
        return nil
      }
      return AudioDestination(
        id: uid, name: name, deviceID: id, channels: channels, transport: transport)
    }.sorted { $0.channels == $1.channels ? $0.name < $1.name : $0.channels < $1.channels }
  }

  static func monitor(_ uid: String) throws -> AudioDestination {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return try resolveMonitor(uid, from: outputs(), defaultDeviceID: device)
  }

  static func resolveMonitor(
    _ uid: String, from devices: [AudioDestination], defaultDeviceID: AudioObjectID
  ) throws -> AudioDestination {
    guard
      let device = devices.first(where: {
        uid.isEmpty ? $0.deviceID == defaultDeviceID : $0.id == uid
      }),
      device.canMonitor
    else {
      throw VoiceError.message("未找到监听耳机或扬声器，请在 API 配置中选择本机监听设备。监听不能使用虚拟或聚合音频设备。")
    }
    return device
  }

  static func resolve(_ uid: String, from devices: [AudioDestination]) throws -> AudioDestination {
    if uid.isEmpty, let first = devices.first { return first }
    guard let device = devices.first(where: { $0.id == uid }) else {
      throw VoiceError.message("未找到所选 BlackHole。请安装或启用 BlackHole，再到 API 配置中刷新输出设备。")
    }
    return device
  }

  static func isAlive(_ id: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr && alive != 0
  }
  private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> String?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let result = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard result == noErr else { return nil }
    return value?.takeRetainedValue() as String?
  }
}

struct PCM16Decoder {
  private var tail = Data()
  private var checkedHeader = false
  mutating func append(_ bytes: Data) throws -> [Float] {
    guard bytes.count <= 4 * 1024 * 1024 else { throw VoiceError.message("音频分块过大。") }
    tail.append(bytes)
    if !checkedHeader {
      guard tail.count >= 4 else { return [] }
      if [Data("RIFF".utf8), Data("OggS".utf8), Data("fLaC".utf8)].contains(Data(tail.prefix(4)))
        || tail.starts(with: Data("ID3".utf8))
      {
        throw VoiceError.message("API 返回了带容器的音频，所选接口必须返回 PCM。")
      }
      checkedHeader = true
    }
    let count = tail.count / 2
    var result = [Float]()
    result.reserveCapacity(count)
    tail.withUnsafeBytes { buffer in
      let input = buffer.bindMemory(to: UInt8.self)
      for index in 0..<count {
        let bits = UInt16(input[index * 2]) | UInt16(input[index * 2 + 1]) << 8
        result.append(Float(Int16(bitPattern: bits)) / 32768)
      }
    }
    tail = Data(tail.dropFirst(count * 2))
    return result
  }
  mutating func finish() throws -> [Float] {
    if tail.count % 2 != 0 { throw VoiceError.message("音频流在半个 PCM 样本处中断。") }
    // Also support a complete stream shorter than the four-byte header check.
    checkedHeader = true
    return try append(Data())
  }
}

// A bounded FIFO lets API generation continue while playback is paused.
struct PCMBacklog {
  let limit: Int
  private var chunks: [[Float]] = []
  private var head = 0
  private var offset = 0
  private(set) var count = 0
  private(set) var total = 0
  init(limit: Int = 24000 * 180) { self.limit = limit }
  mutating func append(_ samples: [Float]) throws {
    guard total + samples.count <= limit else { throw VoiceError.message("语音已达到 180 秒音频上限，请缩短文字。") }
    guard !samples.isEmpty else { return }
    chunks.append(samples)
    count += samples.count
    total += samples.count
  }
  mutating func take(_ maximum: Int) -> [Float] {
    var result: [Float] = []
    let amount = min(maximum, count)
    result.reserveCapacity(amount)
    while result.count < amount {
      let length = min(amount - result.count, chunks[head].count - offset)
      result.append(contentsOf: chunks[head][offset..<(offset + length)])
      offset += length
      if offset == chunks[head].count {
        chunks[head] = []
        head += 1
        offset = 0
      }
    }
    count -= amount
    if head >= 64 || count == 0 {
      chunks.removeFirst(head)
      head = 0
    }
    return result
  }
}

@MainActor
final class PCMOutput {
  private var engines: [AVAudioEngine] = []
  private var players: [AVAudioPlayerNode] = []
  private var selected: [AudioDestination] = []
  private var queuedFrames: [Int] = []
  private let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 2)!
  private var generation = UUID()
  private var decoder = PCM16Decoder()
  private var backlog = PCMBacklog()
  private var observer: NSObjectProtocol?
  private var deviceWatch: Task<Void, Never>?
  private var playback: Task<Void, Error>?
  private var inputFinished = false
  private var started = false
  private(set) var isPaused = false
  var onFailure: ((String) -> Void)?
  var bufferedSeconds: Double { Double(backlog.count + (queuedFrames.max() ?? 0)) / 24000 }

  func prepare(uid: String, monitorUID: String? = nil, paused: Bool = false) async throws {
    try Task.checkCancellation()
    stop()
    let token = generation
    isPaused = paused
    selected = [try AudioDestination.resolve(uid, from: AudioDestination.blackHoles())]
    if let monitorUID { selected.append(try AudioDestination.monitor(monitorUID)) }
    for destination in selected {
      let engine = AVAudioEngine()
      let player = AVAudioPlayerNode()
      guard let unit = engine.outputNode.audioUnit else { throw VoiceError.message("无法创建音频输出。") }
      var device = destination.deviceID
      let status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
        0, &device, UInt32(MemoryLayout<AudioObjectID>.size))
      guard status == noErr else {
        throw VoiceError.message("无法绑定 \(destination.name)（\(status)）。")
      }
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: format)
      engine.prepare()
      engines.append(engine)
      players.append(player)
      queuedFrames.append(0)
    }
    // HAL device changes may asynchronously stop a newly started engine. Wait for readiness
    // before accepting PCM or submitting text. Only silent initialization can be retried.
    var ready = false
    for _ in 0..<5 {
      try Task.checkCancellation()
      guard token == generation else { throw CancellationError() }
      for engine in engines where !engine.isRunning { try engine.start() }
      try await Task.sleep(nanoseconds: 50_000_000)
      guard token == generation else { throw CancellationError() }
      if routeIsValid() {
        ready = true
        break
      }
    }
    guard ready else { throw VoiceError.message("音频引擎未能就绪，请检查 BlackHole 和监听设备。") }
    observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.generation == token, !self.routeIsValid() else { return }
        self.fail("音频设备发生变化，发言已停止。")
      }
    }
    deviceWatch = Task { [weak self] in
      do {
        while !Task.isCancelled {
          try await Task.sleep(nanoseconds: 250_000_000)
          guard let self, self.generation == token else { return }
          if !self.routeIsValid() {
            self.fail("音频设备已断开，发言已停止。")
            return
          }
        }
      } catch {}
    }
    playback = Task { [weak self] in
      guard let self else { throw CancellationError() }
      do { try await self.drain(token: token) } catch {
        if token == self.generation && !Task.isCancelled { self.fail(error.localizedDescription) }
        throw error
      }
    }
  }

  func append(_ data: Data) async throws {
    try Task.checkCancellation()
    guard !inputFinished, !players.isEmpty else { throw VoiceError.message("音频输出已结束。") }
    try backlog.append(decoder.append(data))
  }

  func setPaused(_ paused: Bool) {
    guard paused != isPaused else { return }
    isPaused = paused
    if paused {
      for player in players { player.pause() }
    } else if started {
      startPlayers()
    }
  }

  private func startPlayers() {
    let time = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
    for player in players { player.play(at: time) }
    started = true
  }

  private func drain(token: UUID) async throws {
    var lastProgress = Date()
    var lastQueued = 0
    while true {
      try Task.checkCancellation()
      guard token == generation else { throw CancellationError() }
      if isPaused {
        lastProgress = Date()
        try await Task.sleep(nanoseconds: 10_000_000)
        continue
      }
      guard routeIsValid() else { throw VoiceError.message("音频输出已中断。") }
      var queued = queuedFrames.max() ?? 0
      if queued != lastQueued { lastProgress = Date() }
      if backlog.count > 0 && queued < 12000 {
        let samples = backlog.take(min(480, 12000 - queued))
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
          let channels = buffer.floatChannelData
        else { throw VoiceError.message("无法创建 PCM 缓冲。") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
          channels[0][index] = samples[index]
          channels[1][index] = samples[index]
        }
        // Both outputs consume the same immutable samples, with one shared host-time start.
        for index in players.indices {
          queuedFrames[index] += samples.count
          players[index].scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor in
              guard let self, self.generation == token else { return }
              self.queuedFrames[index] -= samples.count
            }
          }
        }
        queued = queuedFrames.max() ?? 0
        lastProgress = Date()
      }
      if !started && (queued >= 2400 || (inputFinished && backlog.count == 0 && queued > 0)) {
        startPlayers()
        lastProgress = Date()
      }
      if inputFinished && backlog.count == 0 && queued == 0 { return }
      if started && queued > 0 && Date().timeIntervalSince(lastProgress) > 3 {
        throw VoiceError.message("音频设备未持续读取数据，发言已中止。")
      }
      lastQueued = queued
      // Fill up to the small device queue, then yield. Remaining generated PCM stays in RAM.
      if backlog.count == 0 || queued >= 12000 { try await Task.sleep(nanoseconds: 5_000_000) }
    }
  }

  func finish() async throws {
    try backlog.append(decoder.finish())
    guard backlog.total > 0, let playback else { throw VoiceError.message("API 未返回可播放的 PCM 音频。") }
    inputFinished = true
    try await playback.value  // Pausing may keep this pending after the provider has disconnected.
    stop()
  }

  private func routeIsValid() -> Bool {
    guard !selected.isEmpty, selected.count == engines.count else { return false }
    for index in engines.indices {
      let engine = engines[index]
      guard AudioDestination.isAlive(selected[index].deviceID), engine.isRunning,
        let unit = engine.outputNode.audioUnit
      else { return false }
      var actual: AudioObjectID = 0
      var size = UInt32(MemoryLayout<AudioObjectID>.size)
      guard
        AudioUnitGetProperty(
          unit, kAudioOutputUnitProperty_CurrentDevice,
          kAudioUnitScope_Global, 0, &actual, &size) == noErr,
        actual == selected[index].deviceID
      else { return false }
    }
    return true
  }

  private func fail(_ message: String) {
    stop()
    onFailure?(message)
  }

  func stop() {
    generation = UUID()
    playback?.cancel()
    playback = nil
    deviceWatch?.cancel()
    deviceWatch = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    for player in players { player.stop() }
    for engine in engines {
      engine.stop()
      engine.reset()
    }
    engines = []
    players = []
    selected = []
    queuedFrames = []
    started = false
    isPaused = false
    inputFinished = false
    decoder = PCM16Decoder()
    backlog = PCMBacklog()
  }
}
