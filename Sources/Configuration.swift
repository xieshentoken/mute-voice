import Foundation
import Security

enum VoiceAPI: String, Codable, CaseIterable, Identifiable {
  case live, doubao, qwen, minimax
  var id: String { rawValue }
  var name: String {
    switch self {
    case .live: return "GPT-Live-1"
    case .doubao: return "Doubao TTS"
    case .qwen: return "Qwen3-TTS Realtime"
    case .minimax: return "MiniMax Speech Turbo"
    }
  }
  var defaults: APIConfiguration {
    switch self {
    case .live:
      return .init(
        endpoint: "wss://api.openai.com/v1/live/sessions", model: "gpt-live-1", voice: "marin")
    case .doubao:
      return .init(
        endpoint: "https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse",
        model: "seed-tts-2.0", voice: "zh_female_vv_uranus_bigtts")
    case .qwen:
      return .init(
        endpoint: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
        model: "qwen3-tts-flash-realtime", voice: "Cherry")
    case .minimax:
      return .init(
        endpoint: "wss://api.minimaxi.com/ws/v1/t2a_v2", model: "speech-2.8-turbo",
        voice: "male-qn-qingse")
    }
  }

  // Curated from each vendor's voice list, checked 2026-09-22 for the default model.
  // Keep API identifiers verbatim: some MiniMax voices contain spaces and parentheses.
  var voicePresets: [(id: String, label: String)] {
    switch self {
    case .live:
      return [
        ("marin", "Marin · 默认"),
        ("quartz", "Quartz · 女声 · 澳洲英语风格"),
        ("ripple", "Ripple · 男声 · 澳洲英语风格"),
        ("vesper", "Vesper · 男声 · 英国英语风格"),
        ("willow", "Willow · 女声 · 爱尔兰英语风格"),
        ("stone", "Stone · 男声 · 爱尔兰英语风格"),
        ("gleam", "Gleam · 女声 · 北美英语风格"),
        ("meridian", "Meridian · 男声 · 北美英语风格"),
      ]
    case .doubao:
      return [
        ("zh_female_vv_uranus_bigtts", "Vivi 2.0 · 女声 · 通用"),
        ("zh_female_xiaohe_uranus_bigtts", "小何 2.0 · 女声 · 通用"),
        ("zh_male_m191_uranus_bigtts", "云舟 2.0 · 男声 · 通用"),
        ("zh_male_taocheng_uranus_bigtts", "小天 2.0 · 男声 · 通用"),
        ("zh_male_liufei_uranus_bigtts", "刘飞 2.0 · 男声 · 通用"),
        ("zh_female_qingxinnvsheng_uranus_bigtts", "清新女声 2.0 · 女声 · 清新"),
        ("zh_female_cancan_uranus_bigtts", "知性灿灿 2.0 · 女声 · 知性"),
        ("zh_female_shuangkuaisisi_uranus_bigtts", "爽快思思 2.0 · 女声 · 爽快"),
        ("zh_male_ruyaqingnian_uranus_bigtts", "儒雅青年 2.0 · 男声 · 儒雅"),
        ("zh_male_cixingjieshuonan_uranus_bigtts", "磁性解说男声 2.0 · 男声 · 解说"),
      ]
    case .qwen:
      return [
        ("Cherry", "芊悦 · 女声 · 亲切自然"),
        ("Serena", "苏瑶 · 女声 · 温柔"),
        ("Ethan", "晨煦 · 男声 · 阳光温暖"),
        ("Moon", "月白 · 男声 · 率性"),
        ("Maia", "四月 · 女声 · 知性温柔"),
        ("Kai", "凯 · 男声 · 舒适"),
        ("Neil", "阿闻 · 男声 · 新闻播报"),
        ("Elias", "墨讲师 · 女声 · 知识讲解"),
        ("Andre", "安德雷 · 男声 · 磁性沉稳"),
      ]
    case .minimax:
      return [
        ("male-qn-qingse", "青涩青年 · 男声 · 青春"),
        ("male-qn-jingying", "精英青年 · 男声 · 商务"),
        ("female-shaonv", "少女 · 女声 · 青春"),
        ("female-yujie", "御姐 · 女声 · 成熟优雅"),
        ("female-chengshu", "成熟女性 · 女声 · 成熟"),
        ("female-tianmei", "甜美女性 · 女声 · 甜美"),
        ("Chinese (Mandarin)_Gentleman", "温润男声 · 男声 · 温和"),
        ("Chinese (Mandarin)_News_Anchor", "新闻女声 · 女声 · 播报"),
        ("Chinese (Mandarin)_Male_Announcer", "播报男声 · 男声 · 播报"),
        ("Chinese (Mandarin)_Warm_Girl", "温暖少女 · 女声 · 亲切"),
      ]
    }
  }

  var voiceDocumentation: URL {
    switch self {
    case .live:
      return URL(
        string: "https://developers.openai.com/api/docs/guides/live-conversations#voice-options")!
    case .doubao:
      return URL(string: "https://docs.volcengine.com/docs/DoubaoVoice/Tonelist-1?lang=zh")!
    case .qwen:
      return URL(string: "https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list")!
    case .minimax:
      return URL(string: "https://platform.minimax.io/docs/faq/system-voice-id")!
    }
  }

  var help: String {
    switch self {
    case .live:
      return "实验性朗读：Live 是对话模型，可能改写原文，且没有逐句完成事件。说完后点击停止结束会话，最长 180 秒。仅发送合成的静音输入，不采集麦克风。"
    case .doubao:
      return "填写豆包语音控制台的 API Key。旧版凭证可填写 App ID，并在密钥栏填写 Access Token。资源 ID 必须与音色匹配。"
    case .qwen:
      return "默认北京端点。新加坡账号请改为 wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime；模型和密钥须属于相同地域。"
    case .minimax:
      return "默认国内端点。国际账号请改为 wss://api.minimax.io/ws/v1/t2a_v2。模型、音色 ID 可按账号权限修改。"
    }
  }
  var documentation: URL {
    let value: String
    switch self {
    case .live: value = "https://developers.openai.com/api/docs/guides/voice-websockets?api=live"
    case .doubao: value = "https://www.volcengine.com/docs/6561/1598757"
    case .qwen:
      value =
        "https://help.aliyun.com/zh/model-studio/interactive-process-of-qwen-tts-realtime-synthesis"
    case .minimax: value = "https://platform.minimaxi.com/docs/api-reference/speech-t2a-websocket"
    }
    return URL(string: value)!
  }
}

struct APIConfiguration: Codable, Equatable {
  var endpoint: String
  var model: String
  var voice: String
  var appID: String = ""

  func url(for api: VoiceAPI, allowLocalTest: Bool = false) throws -> URL {
    guard
      var parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.fragment == nil
    else {
      throw VoiceError.message("请输入完整的 API 地址，不要把密钥放入地址。")
    }
    let requiredScheme = api == .doubao ? "https" : "wss"
    let local = allowLocalTest && ["127.0.0.1", "localhost"].contains(host)
    guard
      parts.scheme == requiredScheme || (local && parts.scheme == (api == .doubao ? "http" : "ws"))
    else {
      throw VoiceError.message("此接口地址必须以 \(requiredScheme):// 开头。")
    }
    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw VoiceError.message("请填写模型（或资源 ID）和音色 ID。")
    }
    if api == .live, parts.query != nil {
      throw VoiceError.message("Live 会话地址不接受查询参数；请在模型栏配置模型。")
    }
    if api == .qwen {
      var query = (parts.queryItems ?? []).filter { $0.name != "model" }
      query.append(.init(name: "model", value: model))
      parts.queryItems = query
    }
    guard let url = parts.url else { throw VoiceError.message("API 地址无效。") }
    return url
  }

  // Bind secrets to the configured destination, so switching hosts cannot reuse a saved key.
  func credentialAccount(for api: VoiceAPI) -> String {
    let parts = URLComponents(string: endpoint)
    return "\(api.rawValue):\(parts?.host?.lowercased() ?? "invalid"):\(parts?.port ?? 443)"
  }
}

struct AppConfiguration: Codable, Equatable {
  var selected: VoiceAPI = .qwen
  var providers: [String: APIConfiguration] = [:]
  var outputUID = ""
  var monitorUID: String?  // Missing in older preferences means use the current system speaker.
  subscript(api: VoiceAPI) -> APIConfiguration {
    get { providers[api.rawValue] ?? api.defaults }
    set { providers[api.rawValue] = newValue }
  }

  static func load(from defaults: UserDefaults = .standard) -> AppConfiguration {
    guard let data = defaults.data(forKey: "mute-voice.configuration.v1"),
      let config = try? JSONDecoder().decode(Self.self, from: data)
    else { return .init() }
    return config
  }
  func save(to defaults: UserDefaults = .standard) throws {
    defaults.set(try JSONEncoder().encode(self), forKey: "mute-voice.configuration.v1")
  }
}

enum Keychain {
  private static let service = "local.frontspark.mute-voice.api"
  static func read(account: String) async throws -> String {
    // Keychain access may wait for an OS authorization dialog after a development rebuild.
    // Never run that wait on the main actor.
    try await Task.detached { try readBlocking(account: account) }.value
  }
  private static func readBlocking(account: String) throws -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess, let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw VoiceError.message("无法读取钥匙串（\(status)）。请在 API 配置中重新保存密钥。")
    }
    return value
  }
  static func save(_ key: String, account: String) async throws {
    try await Task.detached { try saveBlocking(key, account: account) }.value
  }
  private static func saveBlocking(_ key: String, account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
    ]
    let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw VoiceError.message("无法删除钥匙串密钥（\(status)）。")
      }
      return
    }
    let values: [String: Any] = [kSecValueData as String: Data(clean.utf8)]
    var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      var item = query.merging(values) { _, new in new }
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw VoiceError.message("无法保存钥匙串密钥（\(status)）。配置尚未生效。")
    }
  }
}

enum VoiceError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let message) = self { return message }
    return nil
  }
}
