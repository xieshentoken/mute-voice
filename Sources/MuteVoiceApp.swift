import AppKit
import SwiftUI

@main
enum Launcher {
  @MainActor static func main() {
    if CommandLine.arguments.contains("--devices") {
      let data = (try? JSONEncoder().encode(AudioDestination.blackHoles())) ?? Data("[]".utf8)
      print(String(decoding: data, as: UTF8.self))
      return
    }
    MuteVoiceApp.main()
  }
}

struct MuteVoiceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = SpeechModel()
  var body: some Scene {
    Window("Mute Voice", id: "main") {
      SpeakView(model: model)
        .preferredColorScheme(.light)
        .onAppear { delegate.model = model }
    }
    .defaultSize(width: 680, height: 500)
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appSettings) {
        Button("API 配置…") { model.showConfiguration = true }
          .keyboardShortcut(",")
          .disabled(model.isSending)
      }
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: SpeechModel?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    model?.stop()
    return .terminateNow
  }
}

@MainActor final class SpeechModel: ObservableObject {
  @Published var text = ""
  @Published var configuration = AppConfiguration.load()
  @Published var isSending = false
  @Published var showConfiguration = false
  @Published var status = "Enter 发送 · Shift+Enter 换行"
  @Published var hasError = false
  @Published var isPaused = false
  @Published var isGenerating = false
  @Published var bufferedSeconds = 0.0
  private let output = PCMOutput()
  private var client: StreamingTTS?
  private var task: Task<Void, Never>?
  private var progress: Task<Void, Never>?
  private var generation = UUID()

  init() {
    output.onFailure = { [weak self] message in
      self?.stop()
      self?.hasError = true
      self?.status = message
    }
  }

  var displayStatus: String {
    if isPaused {
      guard isSending else { return "先生成再播放 · 发送后点击继续" }
      let length = String(format: "%.1f", bufferedSeconds)
      return isGenerating ? "已暂停播放 · 缓存 \(length) 秒 · 正在生成…" : "已生成 · 缓存 \(length) 秒 · 点击继续播放"
    }
    if isSending && !isGenerating {
      return "播放中 · 剩余 \(String(format: "%.1f", bufferedSeconds)) 秒"
    }
    return status
  }

  func togglePause() {
    isPaused.toggle()
    output.setPaused(isPaused)
  }

  func send() {
    guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard text.count <= 2000 else {
      hasError = true
      status = "单次发言最多 2000 字，请分段发送。"
      return
    }
    let api = configuration.selected
    let config = configuration[api]
    let phrase = text
    do {
      _ = try config.url(for: api)
      // Validate the route before connecting to a billable API.
      _ = try AudioDestination.resolve(configuration.outputUID, from: AudioDestination.blackHoles())
      _ = try AudioDestination.monitor(configuration.monitorUID ?? "")
      let outputUID = configuration.outputUID
      let monitorUID = configuration.monitorUID ?? ""
      let client = StreamingTTS()
      self.client = client
      let token = UUID()
      generation = token
      isSending = true
      isGenerating = true
      hasError = false
      status = "正在读取钥匙串 · 如有系统提示请确认…"
      progress = Task { [weak self] in
        do {
          while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let self, self.generation == token else { return }
            self.bufferedSeconds = self.output.bufferedSeconds
          }
        } catch {}
      }
      task = Task { [weak self] in
        guard let self else { return }
        do {
          let key = try await Keychain.read(account: config.credentialAccount(for: api))
          try Task.checkCancellation()
          guard self.generation == token else { return }
          guard !key.isEmpty else { throw VoiceError.message("请点击 API 配置，填写当前服务商的密钥。") }
          self.status = "正在准备 BlackHole…"
          try await self.output.prepare(
            uid: outputUID, monitorUID: monitorUID, paused: self.isPaused)
          guard self.generation == token else { return }
          self.status = "正在连接 \(api.name)…"
          try await client.run(api: api, config: config, key: key, text: phrase) {
            [weak self] bytes in
            guard let self, self.generation == token, self.isSending else {
              throw CancellationError()
            }
            self.status = api == .live ? "正在发言 · Live 说完后请点击停止" : "正在向 BlackHole 发送语音…"
            try await self.output.append(bytes)
          }
          guard self.generation == token else { return }
          self.isGenerating = false
          self.client = nil
          try await self.output.finish()
          self.status = "发送完成 · \(api.name)"
        } catch is CancellationError {
          guard self.generation == token else { return }
          self.status = "已停止"
        } catch {
          guard self.generation == token else { return }
          self.status = error.localizedDescription
          self.hasError = true
        }
        guard self.generation == token else { return }
        self.output.stop()
        self.progress?.cancel()
        self.progress = nil
        self.isSending = false
        self.isPaused = false
        self.isGenerating = false
        self.bufferedSeconds = 0
        self.client = nil
        self.task = nil
      }
    } catch {
      output.stop()
      hasError = true
      status = error.localizedDescription
    }
  }

  func stop() {
    generation = UUID()
    output.stop()
    client?.cancel()
    task?.cancel()
    progress?.cancel()
    progress = nil
    client = nil
    task = nil
    isSending = false
    isPaused = false
    isGenerating = false
    bufferedSeconds = 0
    hasError = false
    status = "已停止 · 草稿已保留"
  }
}

struct SpeakView: View {
  @ObservedObject var model: SpeechModel
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 10) {
          Text("MUTE VOICE")
            .font(.system(size: 10, weight: .medium)).tracking(3)
          Text("让文字发声。")
            .font(.system(size: 42, weight: .light)).tracking(-1.5)
        }
        Spacer()
        Button {
          model.showConfiguration = true
        } label: {
          Label("API 配置", systemImage: "slider.horizontal.3")
            .padding(.horizontal, 6)
        }
        .voiceButton()
        .disabled(model.isSending)
        .accessibilityIdentifier("apiConfiguration")
      }
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text("输入你想说的话").tracking(1)
          Spacer()
          Text("\(model.text.count) / 2000").monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        ZStack(alignment: .topLeading) {
          SendTextView(text: $model.text, onSend: model.send, onStop: model.stop)
          if model.text.isEmpty {
            Text("从这一句开始…")
              .font(.system(size: 22, weight: .light))
              .foregroundStyle(Color.black.opacity(0.4))
              .padding(.leading, 5).padding(.top, 6)
              .allowsHitTesting(false)
          }
        }
        .frame(minHeight: 110)
      }
      .padding(24)
      .voiceSurface()
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 8) {
          Image(systemName: model.hasError ? "exclamationmark.circle" : "waveform")
          Text(model.displayStatus)
            .lineLimit(3)
            .accessibilityIdentifier("speechStatus")
        }
        .font(.system(size: 12))
        .foregroundStyle(model.hasError ? Color.black : Color.black.opacity(0.65))
        .frame(maxWidth: .infinity, alignment: .leading)
        HStack(alignment: .center, spacing: 12) {
          Text("ENTER 发送\nSHIFT + ENTER 换行")
            .font(.system(size: 10)).tracking(0.8)
            .lineSpacing(5).foregroundStyle(.secondary)
          Spacer(minLength: 12)
          playbackControls
        }
      }
    }
    .padding(32)
    .frame(minWidth: 560, minHeight: 420)
    .background { LiquidBackdrop().ignoresSafeArea() }
    .sheet(isPresented: $model.showConfiguration) { ConfigurationView(model: model) }
    .onDisappear { model.stop() }
  }

  @ViewBuilder private var playbackControls: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: 16) { playbackButtons }
    } else {
      playbackButtons
    }
  }

  private var playbackButtons: some View {
    HStack(spacing: 12) {
      Button {
        model.togglePause()
      } label: {
        Label(
          model.isPaused ? "继续" : "暂停", systemImage: model.isPaused ? "play.fill" : "pause.fill"
        ).frame(minWidth: 62)
      }
      .voiceButton()
      .help("暂停会议输出和本机监听，TTS 继续生成；也可先暂停，再发送文字。")
      .accessibilityIdentifier("pauseSpeech")
      Button {
        if model.isSending { model.stop() } else { model.send() }
      } label: {
        Label(
          model.isSending ? "停止" : "发送",
          systemImage: model.isSending ? "stop.fill" : "arrow.up.right"
        )
        .fontWeight(.semibold)
        .frame(minWidth: 70)
      }
      .voiceButton()
      .disabled(
        !model.isSending && model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
      .accessibilityIdentifier("sendSpeech")
    }
  }
}

extension View {
  @ViewBuilder fileprivate func voiceButton() -> some View {
    if #available(macOS 26.0, *) {
      self.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
    } else {
      self.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
    }
  }

  @ViewBuilder fileprivate func voiceSurface() -> some View {
    if #available(macOS 26.0, *) {
      self.glassEffect(.regular, in: Rectangle())
    } else {
      self.background(.regularMaterial, in: Rectangle())
        .overlay(Rectangle().strokeBorder(.white.opacity(0.75), lineWidth: 1))
    }
  }
}

struct ConfigurationView: View {
  @ObservedObject var model: SpeechModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft: AppConfiguration
  @State private var keys: [String: String] = [:]
  @State private var editedKeys: Set<String> = []
  @State private var devices: [AudioDestination] = []
  @State private var monitors: [AudioDestination] = []
  @State private var error = ""
  @State private var isSaving = false
  @State private var loadingAccount: String?
  @State private var customVoiceAPIs: Set<VoiceAPI> = []
  private var api: VoiceAPI { draft.selected }
  private var config: APIConfiguration { draft[api] }
  private var account: String { config.credentialAccount(for: api) }
  private var usesCustomVoice: Bool {
    customVoiceAPIs.contains(api) || !api.voicePresets.contains(where: { $0.id == config.voice })
  }
  private var voiceSelection: Binding<String> {
    Binding(
      get: { usesCustomVoice ? "__custom__" : config.voice },
      set: { value in
        if value == "__custom__" {
          customVoiceAPIs.insert(api)
        } else {
          customVoiceAPIs.remove(api)
          draft[api].voice = value
        }
      })
  }

  init(model: SpeechModel) {
    self.model = model
    _draft = State(initialValue: model.configuration)
  }
  private func field(_ path: WritableKeyPath<APIConfiguration, String>) -> Binding<String> {
    Binding(get: { draft[api][keyPath: path] }, set: { draft[api][keyPath: path] = $0 })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text("SETTINGS / VOICE")
          .font(.system(size: 10, weight: .medium)).tracking(2.5)
        Text("API 配置").font(.system(size: 32, weight: .light))
      }
      .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          apiForm
            .padding(20)
            .voiceSurface()
          if loadingAccount == account {
            Text("正在读取已存密钥，请处理 macOS 钥匙串提示。未编辑密钥时，保存不会覆盖原密钥。")
              .font(.caption).foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 12) {
            Text(api.help)
            Text("预设对应 \(api.defaults.model)。其他模型或克隆音色可选择“自定义音色 ID”。")
          }
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 16) {
            Link("接口文档 ↗", destination: api.documentation).foregroundColor(.black)
            Link("音色列表 ↗", destination: api.voiceDocumentation).foregroundColor(.black)
            Spacer()
            Button("恢复此接口默认值") {
              draft[api] = api.defaults
              customVoiceAPIs.remove(api)
            }
            .buttonStyle(.plain)
          }
          .font(.system(size: 11))
          .disabled(isSaving)
          Divider()
          Text("声音去向").font(.system(size: 11, weight: .medium)).tracking(1)
          routingForm
          VStack(alignment: .leading, spacing: 12) {
            Text("你会同时听到发给会议的语音。暂停会保留音频并继续生成；停止会取消生成并清空缓存。")
            Text("腾讯会议 → 设置 → 音频 → 麦克风，选择相同的 BlackHole 并取消会议静音。电脑的扬声器输出保持原设备。")
            if devices.isEmpty {
              Link(
                "获取 BlackHole 2ch ↗",
                destination: URL(string: "https://existential.audio/blackhole/")!)
            }
            Text("密钥仅存 macOS 钥匙串。只向所选 API 提交已发送的文字；不保存发言记录。请让参会者知晓你正在使用合成语音。")
          }
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28).padding(.bottom, 24)
      }
      Divider().padding(.horizontal, 28)
      VStack(alignment: .leading, spacing: 12) {
        if !error.isEmpty {
          Label(error, systemImage: "exclamationmark.circle")
            .font(.caption).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        footer
      }
      .padding(.horizontal, 28).padding(.vertical, 20)
    }
    .frame(
      width: 620,
      height: min(
        700, ((NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 100)
    )
    .background { LiquidBackdrop().opacity(0.32).ignoresSafeArea() }
    .preferredColorScheme(.light)
    .task {
      devices = AudioDestination.blackHoles()
      monitors = AudioDestination.outputs().filter(\.canMonitor)
    }
    .task(id: account) {
      let currentAccount = account
      guard keys[currentAccount] == nil else { return }
      loadingAccount = currentAccount
      defer { if loadingAccount == currentAccount { loadingAccount = nil } }
      do {
        let key = try await Keychain.read(account: currentAccount)
        guard !Task.isCancelled, !editedKeys.contains(currentAccount) else { return }
        keys[currentAccount] = key
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
  }

  private var apiForm: some View {
    Form {
      Picker("服务商", selection: $draft.selected) {
        ForEach(VoiceAPI.allCases) { api in Text(api.name).tag(api) }
      }
      TextField("接口地址", text: field(\.endpoint))
        .accessibilityIdentifier("apiEndpoint")
      TextField(api == .doubao ? "资源 ID" : "模型", text: field(\.model))
      Picker("音色", selection: voiceSelection) {
        ForEach(api.voicePresets, id: \.id) { voice in Text(voice.label).tag(voice.id) }
        Divider()
        Text("自定义音色 ID…").tag("__custom__")
      }
      .id(api)
      .accessibilityIdentifier("voicePreset")
      if usesCustomVoice {
        TextField("自定义音色 ID", text: field(\.voice))
          .accessibilityIdentifier("customVoiceID")
      } else {
        Text("音色 ID：\(config.voice)")
          .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      SecureField(
        api == .doubao && !config.appID.isEmpty ? "Access Token" : "API Key",
        text: Binding(
          get: { keys[account] ?? "" },
          set: {
            keys[account] = $0
            editedKeys.insert(account)
          })
      )
      .accessibilityIdentifier("apiKey")
      if api == .doubao { TextField("App ID（旧版可选）", text: field(\.appID)) }
    }
    .textFieldStyle(.squareBorder)
    .disabled(isSaving)
  }

  private var routingForm: some View {
    Form {
      HStack {
        Picker("音频输出", selection: $draft.outputUID) {
          Text(devices.isEmpty ? "未发现 BlackHole" : "自动选择 BlackHole").tag("")
          ForEach(devices) { device in Text(device.name).tag(device.id) }
          if !draft.outputUID.isEmpty && !devices.contains(where: { $0.id == draft.outputUID }) {
            Text("原设备不可用").tag(draft.outputUID)
          }
        }
        Button("刷新", systemImage: "arrow.clockwise") {
          devices = AudioDestination.blackHoles()
          monitors = AudioDestination.outputs().filter(\.canMonitor)
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
      }
      Picker(
        "本机监听", selection: Binding(get: { draft.monitorUID ?? "" }, set: { draft.monitorUID = $0 })
      ) {
        Text("系统当前耳机 / 扬声器").tag("")
        ForEach(monitors) { device in Text(device.name).tag(device.id) }
        if let uid = draft.monitorUID, !uid.isEmpty, !monitors.contains(where: { $0.id == uid }) {
          Text("原监听设备不可用").tag(uid)
        }
      }
    }
    .disabled(isSaving)
  }

  @ViewBuilder private var footer: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: 16) { footerButtons }
    } else {
      footerButtons
    }
  }

  private var footerButtons: some View {
    HStack(spacing: 12) {
      Spacer()
      Button("取消") { dismiss() }
        .voiceButton().keyboardShortcut(.cancelAction).disabled(isSaving)
      Button(isSaving ? "保存中…" : "保存") { Task { await save() } }
        .voiceButton().disabled(isSaving)
    }
  }
  private func save() async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      _ = try config.url(for: api)
      // Validate before writing. Only explicitly edited secrets are updated or removed.
      let encoded = try JSONEncoder().encode(draft)
      let changedKeys = editedKeys.map { ($0, keys[$0] ?? "") }
      let savedDraft = draft
      for (account, key) in changedKeys { try await Keychain.save(key, account: account) }
      UserDefaults.standard.set(encoded, forKey: "mute-voice.configuration.v1")
      model.configuration = savedDraft
      model.hasError = false
      model.status = "\(api.name) · Enter 发送"
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

// NSTextView is used to preserve IME composition: the Enter that confirms a Chinese candidate
// must not also submit speech. Shift+Enter inserts a newline; Escape cancels an active send.
struct SendTextView: NSViewRepresentable {
  @Binding var text: String
  var onSend: () -> Void
  var onStop: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    let view = InputTextView()
    view.isRichText = false
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.font = .systemFont(ofSize: 22, weight: .light)
    view.textColor = .labelColor
    view.drawsBackground = false
    view.textContainerInset = NSSize(width: 0, height: 6)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(
      width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
    view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
    view.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.setAccessibilityLabel("发言输入框")
    view.setAccessibilityIdentifier("speechInput")
    view.delegate = context.coordinator
    view.onSend = onSend
    view.onStop = onStop
    scroll.documentView = view
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let view = scroll.documentView as? InputTextView else { return }
    if view.string != text && !view.hasMarkedText() { view.string = text }
    view.onSend = onSend
    view.onStop = onStop
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: SendTextView
    init(_ parent: SendTextView) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      if let view = notification.object as? NSTextView { parent.text = view.string }
    }
  }
}

final class InputTextView: NSTextView {
  var onSend: (() -> Void)?
  var onStop: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if !hasMarkedText() {
      if [36, 76].contains(event.keyCode) && !event.modifierFlags.contains(.shift) {
        onSend?()
        return
      }
      if event.keyCode == 53 {
        onStop?()
        return
      }
    }
    super.keyDown(with: event)
  }
}
