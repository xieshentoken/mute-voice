import AppKit
import CoreAudio
import XCTest

@testable import MuteVoice

@MainActor final class MuteVoiceTests: XCTestCase {
  private let pcm = Data([0, 0, 255, 127, 0, 128, 255, 255])

  func testPCMReassemblesArbitraryByteBoundariesWithoutLosingSamples() throws {
    for boundary in 0...pcm.count {
      var decoder = PCM16Decoder()
      var decoded = try decoder.append(Data(pcm.prefix(boundary)))
      decoded += try decoder.append(Data(pcm.dropFirst(boundary)))
      decoded += try decoder.finish()
      XCTAssertEqual(decoded, [0, Float(32767) / 32768, -1, Float(-1) / 32768])
    }
  }
  func testPCMRejectsTruncationAndAudioContainers() throws {
    var decoder = PCM16Decoder()
    _ = try decoder.append(Data([1]))
    XCTAssertThrowsError(try decoder.finish())
    decoder = PCM16Decoder()
    _ = try decoder.append(Data("RI".utf8))
    XCTAssertThrowsError(try decoder.append(Data("FFxxxx".utf8)))
  }
  func testShortAndSilentPCMRemainValid() throws {
    var decoder = PCM16Decoder()
    XCTAssertEqual(try decoder.append(Data([0, 0])), [])
    XCTAssertEqual(try decoder.finish(), [0])
  }
  func testPausedAudioCanAccumulateThenDrainInOriginalOrder() throws {
    var backlog = PCMBacklog(limit: 2000)
    // Network delivery can finish while the output consumer remains paused.
    for offset in stride(from: 0, to: 1900, by: 19) {
      try backlog.append((offset..<(offset + 19)).map(Float.init))
    }
    XCTAssertEqual(backlog.count, 1900)
    var heard: [Float] = []
    while backlog.count > 0 { heard += backlog.take(127) }
    XCTAssertEqual(heard, (0..<1900).map(Float.init))
    XCTAssertEqual(backlog.count, 0)
  }
  func testAudioLimitRejectsOverflowWithoutDiscardingQueuedSpeech() throws {
    var backlog = PCMBacklog(limit: 8)
    try backlog.append([1, 2, 3, 4])
    XCTAssertEqual(backlog.take(2), [1, 2])
    XCTAssertThrowsError(try backlog.append([5, 6, 7, 8, 9]))
    XCTAssertEqual(backlog.take(8), [3, 4])
    try backlog.append([5, 6, 7, 8])
    XCTAssertEqual(backlog.take(8), [5, 6, 7, 8])
  }
  func testSSEHandlesCommentsMultilineCRLFAndEmptyEvents() throws {
    var parser = SSEParser()
    XCTAssertNil(try parser.line(": ping\r"))
    XCTAssertNil(try parser.line("\r"))
    _ = try parser.line("event: 352\r")
    _ = try parser.line("data: {\"code\": 0,\r")
    _ = try parser.line("data: \"data\": \"AAA=\"}\r")
    let frame = try XCTUnwrap(parser.line("\r"))
    XCTAssertEqual(frame.event, "352")
    XCTAssertEqual(try StreamingTTS.object(Data(frame.data.utf8))["data"] as? String, "AAA=")
    XCTAssertNil(try parser.line(""))
  }
  func testHexAndBase64RejectMalformedAudio() throws {
    XCTAssertEqual(try StreamingTTS.hex("0000fF7f0080ffff"), pcm)
    XCTAssertThrowsError(try StreamingTTS.hex("a"))
    XCTAssertThrowsError(try StreamingTTS.hex("zz"))
    XCTAssertThrowsError(try StreamingTTS.base64("%%%"))
    XCTAssertThrowsError(try StreamingTTS.base64(nil))
  }
  func testEndpointValidationAndCredentialIsolation() throws {
    var config = VoiceAPI.qwen.defaults
    config.endpoint += "?model=obsolete"
    let components = try XCTUnwrap(
      URLComponents(url: config.url(for: .qwen), resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.queryItems?.filter { $0.name == "model" }.count, 1)
    XCTAssertEqual(components.queryItems?.first?.value, "qwen3-tts-flash-realtime")
    let originalAccount = config.credentialAccount(for: .qwen)
    config.endpoint = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime"
    XCTAssertNotEqual(config.credentialAccount(for: .qwen), originalAccount)
    config.endpoint = "ws://example.com/api"
    XCTAssertThrowsError(try config.url(for: .qwen))
    config.endpoint = "wss://user:secret@example.com/api"
    XCTAssertThrowsError(try config.url(for: .qwen))
    config.endpoint = "ws://127.0.0.1:10000/qwen"
    XCTAssertThrowsError(try config.url(for: .qwen))
    XCTAssertNoThrow(try config.url(for: .qwen, allowLocalTest: true))
  }
  func testMissingSelectedDeviceNeverFallsBackToAnotherDevice() throws {
    let devices = [
      AudioDestination(id: "blackhole-2", name: "BlackHole 2ch", deviceID: 99, channels: 2)
    ]
    XCTAssertEqual(try AudioDestination.resolve("", from: devices).id, "blackhole-2")
    XCTAssertThrowsError(try AudioDestination.resolve("removed-device", from: devices))
    XCTAssertThrowsError(try AudioDestination.resolve("", from: []))
  }
  func testMonitoringRejectsVirtualDevicesAndUnavailableSavedOutput() throws {
    let speaker = AudioDestination(id: "speaker", name: "Speakers", deviceID: 1, channels: 2)
    let virtual = AudioDestination(
      id: "virtual", name: "Loopback", deviceID: 2, channels: 2,
      transport: kAudioDeviceTransportTypeVirtual)
    let blackhole = AudioDestination(id: "bh", name: "BlackHole 2ch", deviceID: 3, channels: 2)
    let devices = [speaker, virtual, blackhole]
    XCTAssertEqual(
      try AudioDestination.resolveMonitor("", from: devices, defaultDeviceID: 1), speaker)
    XCTAssertThrowsError(try AudioDestination.resolveMonitor("", from: devices, defaultDeviceID: 2))
    XCTAssertThrowsError(
      try AudioDestination.resolveMonitor("bh", from: devices, defaultDeviceID: 1))
    XCTAssertThrowsError(
      try AudioDestination.resolveMonitor("removed", from: devices, defaultDeviceID: 1))
  }
  func testOldPreferencesSurviveAddingLocalMonitoring() throws {
    let old = Data(#"{"selected":"minimax","providers":{},"outputUID":"BlackHole2ch_UID"}"#.utf8)
    let config = try JSONDecoder().decode(AppConfiguration.self, from: old)
    XCTAssertEqual(config.selected, .minimax)
    XCTAssertEqual(config.outputUID, "BlackHole2ch_UID")
    XCTAssertNil(config.monitorUID)
  }
  func testConfigurationRoundTripStoresNoCredentialOrDraftText() throws {
    let suite = "mute-voice-tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var config = AppConfiguration()
    config.selected = .minimax
    config[.minimax].voice = "test-voice"
    config.outputUID = "test-device"
    try config.save(to: defaults)
    XCTAssertEqual(AppConfiguration.load(from: defaults), config)
    let bytes = try XCTUnwrap(defaults.data(forKey: "mute-voice.configuration.v1"))
    let json = String(decoding: bytes, as: UTF8.self)
    XCTAssertFalse(json.contains("apiKey"))
    XCTAssertFalse(json.contains("text"))
  }
  func testEnterSendsButIMECommitDoesNotAndShiftEnterAddsNewline() throws {
    _ = NSApplication.shared
    let input = InputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    var sent = 0
    input.onSend = { sent += 1 }
    let enter = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    input.keyDown(with: enter)
    XCTAssertEqual(sent, 1)
    input.setMarkedText(
      "ni", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(input.hasMarkedText())
    input.keyDown(with: enter)
    XCTAssertEqual(sent, 1)
    input.unmarkText()
    let shift = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.shift],
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    input.keyDown(with: shift)
    XCTAssertEqual(sent, 1)
    XCTAssertTrue(input.string.contains("\n"))
  }

  func testFourProviderProtocolsStreamPCMBeforeCompletion() async throws {
    let fixture = try await startFixture()
    defer {
      fixture.process.terminate()
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    for (api, path) in [
      (VoiceAPI.qwen, "qwen"), (.minimax, "minimax"), (.doubao, "doubao"), (.live, "live"),
    ] {
      var config = api.defaults
      config.endpoint = "\(api == .doubao ? "http" : "ws")://127.0.0.1:\(fixture.port)/\(path)"
      var received = Data()
      var firstByteAt: Date?
      try await StreamingTTS(allowLocalTest: true).run(
        api: api, config: config, key: "fixture-key", text: "你好，测试。"
      ) { bytes in
        firstByteAt = firstByteAt ?? Date()
        received.append(bytes)
      }
      XCTAssertEqual(received, pcm, api.name)
      if api != .live {
        XCTAssertGreaterThan(Date().timeIntervalSince(try XCTUnwrap(firstByteAt)), 0.08)
      }
    }
  }
  func testEveryProtocolSendsSelectedPresetAndCustomVoiceWithoutFallingBackToDefault() async throws
  {
    let fixture = try await startFixture()
    defer {
      fixture.process.terminate()
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    for (api, preset) in [
      (VoiceAPI.qwen, "Serena"), (.doubao, "zh_female_xiaohe_uranus_bigtts"),
      (.minimax, "Chinese (Mandarin)_Gentleman"), (.live, "quartz"),
    ] {
      for voice in [preset, "custom-\(api.rawValue)-voice-ABC_123"] {
        var config = api.defaults
        XCTAssertNotEqual(voice, config.voice)
        config.voice = voice
        var endpoint = URLComponents()
        endpoint.scheme = api == .doubao ? "http" : "ws"
        endpoint.host = "127.0.0.1"
        endpoint.port = try XCTUnwrap(Int(fixture.port))
        endpoint.path = "/\(api.rawValue)/voice/\(voice)"
        config.endpoint = try XCTUnwrap(endpoint.url).absoluteString
        var received = Data()
        // The fixture checks the wire-level voice field before returning any PCM.
        // Custom IDs are synthetic: this verifies forwarding, not account entitlement.
        try await StreamingTTS(allowLocalTest: true).run(
          api: api, config: config, key: "fixture-key", text: "你好，测试。"
        ) { received.append($0) }
        XCTAssertEqual(received, pcm, "\(api.name): \(voice)")
      }
    }
  }
  func testDoubaoLegacyCredentialsAndTruncatedStreams() async throws {
    let fixture = try await startFixture()
    defer {
      fixture.process.terminate()
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    var config = VoiceAPI.doubao.defaults
    config.endpoint = "http://127.0.0.1:\(fixture.port)/doubao-legacy"
    config.appID = "fixture-app"
    var received = Data()
    try await StreamingTTS(allowLocalTest: true).run(
      api: .doubao, config: config, key: "fixture-key", text: "你好，测试。"
    ) { received.append($0) }
    XCTAssertEqual(received, pcm)
    config.appID = ""
    for path in ["doubao-truncated", "doubao-error", "redirect"] {
      config.endpoint = "http://127.0.0.1:\(fixture.port)/\(path)"
      do {
        try await StreamingTTS(allowLocalTest: true).run(
          api: .doubao, config: config, key: "fixture-key", text: "你好，测试。"
        ) { _ in }
        XCTFail("Expected failure for \(path)")
      } catch {
        XCTAssertFalse(error.localizedDescription.contains("fixture-key"))
      }
    }
  }
  func testCancellationInterruptsAStalledWebSocket() async throws {
    let fixture = try await startFixture()
    defer {
      fixture.process.terminate()
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    var config = VoiceAPI.qwen.defaults
    config.endpoint = "ws://127.0.0.1:\(fixture.port)/qwen-stall"
    let client = StreamingTTS(allowLocalTest: true)
    let task = Task {
      try await client.run(api: .qwen, config: config, key: "fixture-key", text: "你好，测试。") { _ in
        XCTFail("Unexpected audio")
      }
    }
    try await Task.sleep(nanoseconds: 150_000_000)
    let start = Date()
    client.cancel()
    task.cancel()
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
  }

  private func startFixture() async throws -> (process: Process, directory: URL, port: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mute-voice-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let portFile = directory.appendingPathComponent("port")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
      "mock_api.py")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [script.path, portFile.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    for _ in 0..<200 {
      if let port = try? String(contentsOf: portFile) { return (process, directory, port) }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    process.terminate()
    throw VoiceError.message("Local fixture did not start")
  }
}
