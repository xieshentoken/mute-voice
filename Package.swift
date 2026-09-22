// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MuteVoice",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "MuteVoice", targets: ["MuteVoice"])],
  targets: [
    .executableTarget(name: "MuteVoice", path: "Sources"),
    .testTarget(
      name: "MuteVoiceTests", dependencies: ["MuteVoice"], path: "Tests",
      exclude: ["mock_api.py"]),
  ]
)
