# Mute Voice

**English** · [简体中文](#简体中文)

A standalone macOS "type-to-speak" app: type text, and it is synthesized and injected into a meeting through the BlackHole virtual microphone.

```text
Text → Enter / Send → selected speech API → bounded PCM buffer → synchronized playback
                                                        ├─ BlackHole → Tencent Meeting
                                                        └─ local headphones / speakers
```

The main window offers a text field, API configuration, pause/resume, and send; while sending, the same button becomes Stop.

It depends only on macOS 14+, Apple system frameworks, and an installed BlackHole. It does not require FrontSpark, VoiceStudio, a Python model server, Node, or Rust, and it does not modify the FrontSpark virtual microphone or the Tencent Meeting process.

## Usage

1. Open `build/Mute Voice.app`, or install the DMG published under **Releases**.
2. In "API configuration", pick a provider, enter that provider's key, then choose a voice from the "Voice" dropdown and save. Model and voice already have defaults.
3. After installing [BlackHole 2ch](https://existential.audio/blackhole/), refresh and select BlackHole in the configuration. Install the driver per the official instructions; the app never installs or restarts system audio.
4. In Tencent Meeting, select the same BlackHole as the microphone and unmute yourself. Leave the computer's speaker output on its original device; do not set it to BlackHole.
5. "Local monitor" defaults to the system headphones/speakers that were active when the utterance started, or you can pick a device explicitly. Generated audio goes to both BlackHole and that device.
6. Type text, then press Enter or click Send. Shift+Enter inserts a newline. Enter used to commit an IME candidate does not send.
7. When the network stalls, click "Pause": meeting output and local monitoring pause together while TTS keeps generating into memory; the UI shows the buffered seconds. Click "Resume" to play back in the original order. You can also pause first, then send text, and resume once it shows "generated" — full-sentence playback is steadier that way.
8. Esc or "Stop" cancels generation and discards pending audio; closing the window also stops. Pause keeps audio, stop discards it.

Text is retained after sending so you can edit or resend it. Only one utterance is processed at a time, up to 2000 characters; the API connection is capped at 180 seconds and audio generation at 180 seconds. While paused, at most ~17 MB of mono float PCM is retained; after generation finishes you can stay paused without holding the API connection (see the GPT-Live caveat below). Partially played sentences are never retried automatically, and no history or recordings are saved. The physical microphone and meeting audio are never captured. Only text you explicitly submit is sent to the configured speech API; please tell participants that synthesized speech is being used.

## The four APIs

| Provider | Default model / resource | Protocol | Completion |
| --- | --- | --- | --- |
| GPT-Live-1 | `gpt-live-1` | Live WebSocket, `session.start` / `session.output_audio.delta` | manual stop, or the 180 s cap |
| Doubao TTS | `seed-tts-2.0` | V3 HTTP SSE, Base64 PCM | success end event / `code=20000000` |
| Qwen3-TTS Realtime | `qwen3-tts-flash-realtime` | DashScope WebSocket, commit mode | session finished after `response.audio.done` |
| MiniMax Speech Turbo | `speech-2.8-turbo` | T2A WebSocket, hex PCM | `task_finish` / `task_finished` after `is_final` |

**GPT-Live-1 is an experimental reading integration.** It is a conversational model, so the prompt cannot guarantee verbatim reading. There is no official per-sentence audio-completion event, so the app never guesses completion from silence or transcription gaps — stop manually once you have finished speaking. While connected it sends locally generated zero-value PCM on a clock to advance the Live session; it does not open the microphone or run delegated model tasks. Stopping tears down the transport immediately without waiting for a final billing event; the MVP shows no billing amounts. Choose one of the other three dedicated TTS providers when you need verbatim reading and automatic completion.

Every interface requests **24 kHz, mono, 16-bit little-endian raw PCM**. The output layer reassembles samples split across network chunks, buffers them in memory, and copies them to stereo; two AVAudioEngines read the same samples, start or resume at the same host time, and each resamples to the BlackHole and monitor device rates. Bluetooth headphone latency is not guaranteed to match the meeting output exactly. Only PCM is accepted; MP3/WAV file headers are never treated as sample data.

### Configuration details

- The voice dropdown ships with 37 presets: 9 Qwen, 10 Doubao, 10 MiniMax, 8 GPT-Live, showing display names and voice styles. Each provider keeps its own selected voice; switching providers does not overwrite another provider's choice.
- Presets are checked against the default model. For other models, or for private or cloned voices, choose "Custom voice ID…" and enter the ID from the provider. Existing custom IDs are preserved verbatim; "Restore defaults for this API" only resets the current provider. GPT-Live region labels come from the official English style descriptions; Chinese pronunciation needs an actual listening test.
- Doubao: new-style `X-Api-Key` by default; if you fill in an App ID it switches to `X-Api-App-Id` + `X-Api-Access-Key`, and the key field then holds the Access Token. The resource ID must match the voice; the default voice is `zh_female_vv_uranus_bigtts`.
- Qwen: Beijing `wss://dashscope.aliyuncs.com/api-ws/v1/realtime` by default; use `wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime` for Singapore. Key, region, and model entitlement must match. The app adds the model query parameter.
- MiniMax: mainland `wss://api.minimaxi.com/ws/v1/t2a_v2` by default; international `wss://api.minimax.io/ws/v1/t2a_v2`.
- Live: `wss://api.openai.com/v1/live/sessions` by default, with the model in the session config; no Realtime query parameter and no `/audio/speech`.
- You may change endpoints to reach services that **implement the same protocol**; changing only the URL cannot turn an arbitrary vendor into one of the four protocols.
- Keys are stored in the macOS Keychain per provider and destination host; switching hosts requires configuring a key for that host. Clearing the key and saving deletes it. Ordinary preferences contain only endpoints, models, voices, device UIDs, and similar settings.
- After rebuilding a development build, reading a stored key may wait for macOS Keychain authorization. The UI shows a read prompt; complete the authorization in the system window. If you do not edit the key, saving other settings does not overwrite it. Keychain work runs in the background, so the main window can still stop or close while waiting.

## Build and checks

All commands run in this directory, and caches and artifacts stay here too:

```sh
make bootstrap  # verify the Swift toolchain
make dev        # build, sign, and open the app
make test       # unit tests + local mock API protocol tests
make lint       # Swift format check, Python syntax check
make build      # produce build/Mute Voice.app without installing drivers
make dist       # wrap the signed app into Mute-Voice-<version>.dmg
make devices    # read-only list of BlackHole output devices
make verify-audio # optional hardware regression: send a test tone to BlackHole and check full playback and stop
.build/verify-audio --pause --monitor .build/pause-monitor.json # pause buffering + local monitoring hardware regression
```

Build dependencies are Xcode 26 / Command Line Tools with the macOS 26 SDK, plus Python 3 (packaging and tests only); the app itself still runs on macOS 14+. The produced app uses an ad-hoc local signature, and the `.dmg` is notarization-free: distributing it publicly requires Developer ID signing and notarization, and this project does not pretend to be a notarized distribution. Recipients of an ad-hoc-signed build must open it via right-click → Open, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine "/Applications/Mute Voice.app"
```

The current build is a thin **arm64** (Apple Silicon) binary; Intel Macs need a separate or universal build.

The UI follows the monopo saigon reference: light black-and-white typography, a square-cornered input area, capsule buttons, over a slow green–amber–crimson flowing gradient. macOS 26 uses native Liquid Glass; macOS 14–15 fall back to system materials. The backdrop is capped at 24 fps and stops when the app is inactive or "Reduce motion" is on; "Reduce transparency" switches to a solid background. The configuration panel scrolls, and save actions and validation errors stay visible.

The app icon source is `mute voice logo.png` in this directory (a square PNG of at least 1024 × 1024). Packaging generates the standard macOS icon sizes and `MuteVoice.icns` and writes them into the app resources; the original PNG is left unchanged.

## Code boundaries

- `Sources/MuteVoiceApp.swift`: SwiftUI window, API configuration, IME input handling, single utterance and stop.
- `Sources/LiquidBackdrop.swift`: local Canvas gradient flow and low-motion/background power handling.
- `Sources/Configuration.swift`: configuration, validation, and Keychain for the four APIs.
- `Sources/StreamingTTS.swift`: requests, stream parsing, termination, and timeouts for the four real protocols.
- `Sources/AudioOutput.swift`: device enumeration and fixed routing, PCM reassembly and bounded buffering, dual-path synchronized playback, pause and stop.
- `Tests/`: verified with synthetic PCM and a local HTTP/WebSocket server; no real API access and no writes to audio devices.

First output buffering is about 100 ms and the device pending queue is capped at about 500 ms; the rest of the generated audio stays in a bounded memory buffer, so network generation and playback advance independently. Real-time audio callbacks are handled by the system audio engine. On normal completion the local pending buffer is drained and the audio devices are released. Stop, closing the window, or removing either output device releases both of this app's audio outputs and clears the pending buffer without switching devices automatically. Monitoring rejects virtual and aggregate outputs so audio is not fed back into BlackHole.

After binding devices the app waits for the audio engine to be ready before connecting to the API. Asynchronous macOS device notifications can stop the engine shortly after launch; the app restarts it only a limited number of times, and only when no text has been submitted and nothing is playing. If a device fails during an actual utterance the app still stops immediately and does not replay what was already spoken.

BlackHole is a shared virtual device; stopping this app only stops this app's sound and does not change other apps' volume or the system mute state. Audio already read, encoded, or transmitted by Tencent Meeting cannot be recalled. "Send complete" in the UI means local playback finished, not that every participant confirmed receipt.

## Verification boundaries

Automated tests cover request shapes and event ordering for the four protocols, chunked PCM, SSE, half-sample truncation, network interruption, secret redaction in error messages, redirect refusal, cancellation waits, device UIDs, and IME Enter.

Authentication against real services, model entitlements, first-packet latency, Chinese pronunciation, and how it sounds on the other end of BlackHole → Tencent Meeting require the user to configure real accounts and install BlackHole. Passing against the mock API does not mean a provider and meeting path has passed end to end.

Verify with a second participant account using one short sentence and one long sentence: confirm long sentences stream while generating, no trailing audio is swallowed on normal completion, playback does not continue after Stop, and audio does not fall back to the speakers when a device is unplugged. Record API first packet, local first frame, first sound on the other end, and stop latency separately.

### Local verification record (2026-09-14 to 09-15)

- After a restart, `BlackHole 2ch` was detected with UID `BlackHole2ch_UID`, two channels at 48 kHz; the system default output stayed on the MacBook Pro speakers.
- `make test`: 16 passed (including pause buffer ordering, audio caps, monitor device isolation, and legacy configuration compatibility); `make lint`, `make build`, and the app signature check passed.
- The hardware loopback used the production `PCMOutput` code with 24 kHz PCM16 input, and BlackHole read back 48 kHz Float32. After fixing an interruption caused by asynchronous device notifications at startup, it passed three times in a row.
- All three runs read back the full ~1.01 s test tone (10 ms level buckets) with a peak of about 0.050, i.e. −26 dBFS; stopping with pending audio read back silence after about 20–31 ms. That measurement includes bucket precision and local scheduling error and does not represent latency on the other end of Tencent Meeting.
- Raw measurements live locally in `.build/pcm-loopback-repeat-*.json` and store only levels and timing, never raw audio. Re-run with `make verify-audio`; it plays a synthetic tone into BlackHole and should be run when no meeting is using that device.
- With user approval, one utterance — "你好，这是 Mute Voice 的语音测试。" — was generated with the existing Qwen Beijing configuration, and the app showed "send complete". The corresponding level capture window did not cover the actual send period, so that run only confirms the app call and the playback-complete state, not evidence of listening on the other end. No paid interface was called again.
- After pause/resume was added, synthetic audio verified: nothing is emitted while initially paused, generation continues and completes during the pause, and the full two seconds are output after resume; BlackHole read back two bursts totaling about 2.03 s (10 ms buckets). With local speaker monitoring enabled, both paths completed playback. Records are in `.build/pause-monitor-loopback.json`.
- Listening on the other end of Tencent Meeting still needs a real test; the other three providers have only mock protocol verification.

2026-09-22 voice and UI update: 17 tests passed, including non-default presets and custom voice IDs for the four protocols, covering the spaces and parentheses in MiniMax IDs; `make lint`, `make build`, and the signature check passed. Added animated graphics, native glass controls, and a user-supplied app icon. Only local mock services were used; no paid API was called.

### Voice references (checked 2026-09-22)

- [Qwen official voice list](https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list)
- [Doubao official voice list](https://docs.volcengine.com/docs/DoubaoVoice/Tonelist-1?lang=zh): only 2.0 voices that match `seed-tts-2.0` are selected.
- [MiniMax official voice catalog](https://github.com/MiniMax-AI/skills/blob/main/skills/frontend-dev/references/minimax-voice-catalog.md), [system voice list](https://platform.minimax.io/docs/faq/system-voice-id)
- [GPT-Live official voice options](https://developers.openai.com/api/docs/guides/live-conversations#voice-options)

## Interface references (checked 2026-09-14)

- [OpenAI Live WebSocket](https://developers.openai.com/api/docs/guides/voice-websockets?api=live), [session lifecycle and reading boundaries](https://developers.openai.com/api/docs/guides/live-conversations)
- [Doubao V3 HTTP/SSE](https://www.volcengine.com/docs/6561/1598757), [ByteDance official SSE example](https://github.com/bytedance/agentkit-samples/blob/main/skills/byted-text-to-speech/scripts/text_to_speech.py)
- [Qwen Realtime protocol](https://www.alibabacloud.com/help/en/model-studio/interactive-process-of-qwen-tts-realtime-synthesis), [client events](https://www.alibabacloud.com/help/en/model-studio/qwen-tts-realtime-client-events)
- [MiniMax T2A WebSocket](https://platform.minimax.io/docs/api-reference/speech-t2a-websocket)
- [BlackHole official repository](https://github.com/ExistentialAudio/BlackHole)

---

## 简体中文

独立 macOS 打字发言应用。主窗口提供输入框、API 配置、暂停／继续、发送；发送中同一按钮变为停止。

```text
文字 → Enter / 发送 → 所选语音 API → 有界 PCM 缓存 → 同步播放
                                             ├─ BlackHole → 腾讯会议
                                             └─ 本机耳机 / 扬声器
```

仅依赖 macOS 14+、Apple 系统框架和已安装的 BlackHole。无需运行 FrontSpark、VoiceStudio、Python 模型服务、Node 或 Rust。不修改 FrontSpark 虚拟麦克风或腾讯会议进程。

### 使用

1. 打开 `build/Mute Voice.app`，或安装 **Releases** 中发布的 DMG。
2. 在“API 配置”中选择服务商，填写该服务商的密钥，再从“音色”下拉框选择声音并保存。模型和音色已提供默认值。
3. 安装 [BlackHole 2ch](https://existential.audio/blackhole/) 后，在配置中刷新并选择 BlackHole。安装驱动按官方说明进行，应用不会自动安装或重启系统音频。
4. 腾讯会议的麦克风选择同一个 BlackHole，并取消会议内静音；电脑的扬声器输出保留原设备，不要设置为 BlackHole。
5. “本机监听”默认使用本次发言开始时的系统耳机／扬声器，也可以指定设备。生成的声音同时送到 BlackHole 和该设备。
6. 输入文字，Enter 或点击发送。Shift+Enter 换行。中文输入法选词的 Enter 不发送。
7. 网络卡顿时点击“暂停”：会议输出和本机监听同时暂停，TTS 继续生成到内存；界面显示缓存秒数。点击“继续”后按原顺序播放。也可以先点击暂停，再发送文字，等显示“已生成”后点继续，整句播放会更稳定。
8. Esc 或“停止”取消生成并清空待播音频；关闭窗口也会停止。暂停保留音频，停止丢弃音频。

文字在发送后保留，便于修改或重发。一次只处理一条发言，最长 2000 字；API 连接最多 180 秒，生成音频最多 180 秒。暂停时最多保留约 17 MB 的单声道浮点 PCM；生成完毕后可以继续暂停，不必维持 API 连接（GPT-Live 的完成限制见下文）。不会自动重试已部分播出的句子，也不保存历史或录音。不采集物理麦克风或会议声音。只有主动提交的文字会传到配置的语音 API；请告知参会者正在使用合成语音。

### 四种 API

| 服务商 | 默认模型 / 资源 | 协议 | 完成方式 |
| --- | --- | --- | --- |
| GPT-Live-1 | `gpt-live-1` | Live WebSocket，`session.start` / `session.output_audio.delta` | 手动停止，或 180 秒上限 |
| Doubao TTS | `seed-tts-2.0` | V3 HTTP SSE，Base64 PCM | 成功结束事件 / `code=20000000` |
| Qwen3-TTS Realtime | `qwen3-tts-flash-realtime` | DashScope WebSocket，commit 模式 | `response.audio.done` 后结束会话 |
| MiniMax Speech Turbo | `speech-2.8-turbo` | T2A WebSocket，十六进制 PCM | `is_final` 后 `task_finish` / `task_finished` |

**GPT-Live-1 是实验性朗读接入。** 它是对话模型，提示词不能保证逐字朗读。官方没有逐句音频完成事件，因此应用不把静音或转录间隔猜成完成；说完后请手动停止。连接期间按时钟发送本地产生的零值 PCM，以推进 Live 会话，不打开麦克风，也不运行委派的模型任务。停止会立即断开传输，不等待最终计费事件；MVP 不展示计费金额。对逐字朗读和自动结束有要求时选择另三个专用 TTS。

各接口均请求 **24 kHz、单声道、16 位小端原始 PCM**。输出层重组跨网络分块的样本，缓存在内存并复制到立体声；两个 AVAudioEngine 读取同一份样本，以同一主机时间开始或继续播放，并各自重采样到 BlackHole 和监听设备的采样率。蓝牙耳机本身的延迟不保证与会议输出完全一致。只接受 PCM，不把 MP3/WAV 文件头当采样数据。

#### 配置细节

- 音色下拉框内置 37 个预设：Qwen 9 个、Doubao 10 个、MiniMax 10 个、GPT-Live 8 个，显示名称和声线风格。每家服务商分别保存所选音色，切换服务商不会覆盖其他家的选择。
- 预设按默认模型核对；其他模型、私人或克隆音色可选“自定义音色 ID…”并填写服务商提供的 ID。已有自定义 ID 会原样保留；“恢复此接口默认值”只重置当前服务商。GPT-Live 的地域标签来自官方英语风格描述，中文发音效果需实际试听。
- 豆包：默认新版 `X-Api-Key`；填写 App ID 后改用 `X-Api-App-Id` + `X-Api-Access-Key`，密钥栏此时填 Access Token。资源 ID 与音色必须匹配；默认音色为 `zh_female_vv_uranus_bigtts`。
- Qwen：默认北京 `wss://dashscope.aliyuncs.com/api-ws/v1/realtime`；新加坡用 `wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime`。密钥、地域、模型权限必须匹配。模型查询参数由应用添加。
- MiniMax：默认国内 `wss://api.minimaxi.com/ws/v1/t2a_v2`；国际用 `wss://api.minimax.io/ws/v1/t2a_v2`。
- Live：默认 `wss://api.openai.com/v1/live/sessions`，模型放在会话配置中，不添加 Realtime 查询参数或使用 `/audio/speech`。
- 可更改端点以接入**实现相同协议**的服务；仅改变 URL 不能把任意供应商转换为四种协议之一。
- 密钥按服务商和目标主机存入 macOS 钥匙串，切换主机需要为该主机配置密钥。清空密钥并保存可删除它。普通偏好只包含端点、模型、音色、设备 UID 等设置。
- 开发版重新构建后，读取已存密钥可能等待 macOS 钥匙串授权。界面会显示读取提示；在系统窗口完成授权即可。未编辑密钥时，保存其他配置不会覆盖原密钥。钥匙串操作在后台执行，等待时主窗口仍可停止或关闭。

### 构建与检查

所有命令在本目录运行，缓存和产物也在本目录：

```sh
make bootstrap  # 验证 Swift 工具链
make dev        # 构建、签名并打开应用
make test       # 单元测试 + 本机模拟 API 协议测试
make lint       # Swift 格式检查、Python 语法检查
make build      # 生成 build/Mute Voice.app，不安装驱动
make dist       # 把已签名应用打成 Mute-Voice-<版本>.dmg
make devices    # 只读列出 BlackHole 输出设备
make verify-audio # 可选硬件回归：向 BlackHole 发测试音并检测完整播放、停止
.build/verify-audio --pause --monitor .build/pause-monitor.json # 暂停缓存 + 本机监听硬件回归
```

构建依赖包含 macOS 26 SDK 的 Xcode 26 / Command Line Tools 及 Python 3（仅用于打包和测试）；应用运行仍支持 macOS 14+。生成的应用使用 ad-hoc 本机签名，DMG 也未公证：对外正式分发需要 Developer ID 签名和公证，本项目不冒充已公证发行版。收到 ad-hoc 签名构建的机器需要用右键 →“打开”，或清除隔离标记：

```sh
xattr -dr com.apple.quarantine "/Applications/Mute Voice.app"
```

当前构建是 **arm64**（Apple 芯片）单架构二进制；Intel Mac 需要另出 Intel 或 universal 构建。

界面按 monopo saigon 参考采用浅色黑白排版、直角输入区和胶囊按钮，背景为绿—琥珀—深红的缓慢流光。macOS 26 使用原生 Liquid Glass，macOS 14–15 回退为系统材质。背景最多 24 fps；应用失活或开启“减少动态效果”时停止动画，开启“减少透明度”时使用纯色背景。配置面板可以滚动，保存操作和校验错误固定可见。

应用图标源文件为本目录 `mute voice logo.png`（至少 1024 × 1024 的正方形 PNG）。打包时自动生成标准 macOS 图标尺寸和 `MuteVoice.icns`，写入应用资源；原 PNG 保持不变。

### 代码边界

- `Sources/MuteVoiceApp.swift`：SwiftUI 窗口、API 配置、IME 输入处理、单条发言与停止。
- `Sources/LiquidBackdrop.swift`：本地 Canvas 流光及低动态/后台节能处理。
- `Sources/Configuration.swift`：四个 API 的配置、校验与钥匙串。
- `Sources/StreamingTTS.swift`：四种真实协议的请求、流解析、终止与超时。
- `Sources/AudioOutput.swift`：设备枚举和固定路由、PCM 重组和有界缓存、双路同步播放、暂停和停止。
- `Tests/`：用合成 PCM 和本机 HTTP/WebSocket 服务器验证；不访问真实 API、不向音频设备写入。

输出首次缓冲约 100 ms，设备待播队列上限约 500 ms；其余生成音频留在有界内存缓存，网络生成与播放独立推进。实时音频回调由系统音频引擎负责。正常结束排空本地待播缓冲后释放音频设备。停止、关闭窗口、移除任一输出设备时释放本应用两路音频输出并清空待播缓冲，不自动更换设备。监听拒绝虚拟和聚合输出，避免再次回送到 BlackHole。

绑定设备后先等待音频引擎就绪，再连接 API。macOS 异步设备通知可能在启动后停掉引擎；应用只在尚未提交文字、尚未播放时有限次重新启动。实际发言中设备失效仍立即停止，不重放已经说出的内容。

BlackHole 是共享虚拟设备；本应用停止只停止本应用的声音，不修改其他应用的音量或系统设备静音。已经被腾讯会议读取、编码或传送的音频无法撤回。界面“发送完成”表示本地播放完成，不表示所有参会者确认收到。

### 验证边界

自动测试覆盖四种协议的请求形状与事件顺序、分块 PCM、SSE、半样本截断、网络中断、密钥错误脱敏、禁止重定向、取消等待、设备 UID 和 IME Enter。

真实服务的鉴权、模型权限、首包延迟、中文读音及 BlackHole → 腾讯会议另一端的听感，需要用户配置实际账号、安装 BlackHole 后实测。模拟 API 通过不等于供应商和会议端到端已经通过。

建议使用另一参会账号验证一条短句及一条长句，确认长句边生成边播放、正常结束不吞尾音、按停止后不续播、设备拔除后不转到扬声器。分别记录 API 首包、本地首帧、另一端首声和停止延迟。

#### 本机验证记录（2026-09-14 至 09-15）

- 重启后识别到 `BlackHole 2ch`，UID 为 `BlackHole2ch_UID`，双声道、48 kHz；系统默认输出保持 MacBook Pro 扬声器。
- `make test`：16 项通过（含暂停缓存顺序、音频上限、监听设备隔离、旧配置兼容）；`make lint`、`make build` 和应用签名检查通过。
- 硬件回环使用生产代码 `PCMOutput`，输入 24 kHz PCM16，BlackHole 实际读回 48 kHz Float32。修复启动时异步设备通知引发的中断后，连续三次通过。
- 三次均完整读回约 1.01 秒的测试音（10 ms 电平统计分桶），峰值约 0.050，即 −26 dBFS；有待播音频时停止，约 20–31 ms 后读回静音。该测量包含分桶精度和本机调度误差，不能代表腾讯会议另一端延迟。
- 原始测量位于本机 `.build/pcm-loopback-repeat-*.json`，只保存电平和时间，不保存原始音频。复测用 `make verify-audio`；它会向 BlackHole 播放合成测试音，应在没有会议使用该设备时运行。
- 已经用户批准，使用现有 Qwen 北京配置生成一次“你好，这是 Mute Voice 的语音测试。”，应用显示“发送完成”。对应电平采集窗口未覆盖实际发送时段，所以该次只确认应用调用及播放完成状态，不作为另一端收听证据。未重复调用收费接口。
- 新增暂停／继续后，以合成音验证：初始暂停不发声，暂停期间继续追加并完成生成，恢复后完整输出两秒音频；BlackHole 读回两段合计约 2.03 秒（10 ms 分桶）。开启本机扬声器监听时，两路播放均完成。记录见 `.build/pause-monitor-loopback.json`。
- 腾讯会议另一端收听仍需实测；另三个服务商仅完成模拟协议验证。

2026-09-22 音色和界面更新：17 项测试通过，包括四种协议的非默认预设与自定义音色 ID，包含 MiniMax ID 中的空格和括号；`make lint`、`make build` 和签名检查通过。新增动态图形、原生玻璃控件和用户提供的应用图标。仅使用本机模拟服务，不调用收费 API。

#### 音色资料（2026-09-22 核对）

- [Qwen 官方音色列表](https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list)
- [Doubao 官方音色列表](https://docs.volcengine.com/docs/DoubaoVoice/Tonelist-1?lang=zh)：仅选择 2.0 区域、匹配 `seed-tts-2.0` 的音色。
- [MiniMax 官方音色目录](https://github.com/MiniMax-AI/skills/blob/main/skills/frontend-dev/references/minimax-voice-catalog.md)、[系统音色列表](https://platform.minimax.io/docs/faq/system-voice-id)
- [GPT-Live 官方音色选项](https://developers.openai.com/api/docs/guides/live-conversations#voice-options)

### 接口依据（2026-09-14 核对）

- [OpenAI Live WebSocket](https://developers.openai.com/api/docs/guides/voice-websockets?api=live)、[会话生命周期和朗读边界](https://developers.openai.com/api/docs/guides/live-conversations)
- [豆包 V3 HTTP/SSE](https://www.volcengine.com/docs/6561/1598757)、[字节跳动官方 SSE 示例](https://github.com/bytedance/agentkit-samples/blob/main/skills/byted-text-to-speech/scripts/text_to_speech.py)
- [Qwen Realtime 协议](https://www.alibabacloud.com/help/en/model-studio/interactive-process-of-qwen-tts-realtime-synthesis)、[客户端事件](https://www.alibabacloud.com/help/en/model-studio/qwen-tts-realtime-client-events)
- [MiniMax T2A WebSocket](https://platform.minimax.io/docs/api-reference/speech-t2a-websocket)
- [BlackHole 官方仓库](https://github.com/ExistentialAudio/BlackHole)
