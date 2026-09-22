import AppKit
import SwiftUI

/// A quiet paper canvas with a single flowing field of colored light.
/// Keep interface surfaces neutral; this backdrop owns the chromatic accent.
struct LiquidBackdrop: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @State private var applicationIsActive = NSApplication.shared.isActive

  private var animates: Bool {
    scenePhase == .active && applicationIsActive && !reduceMotion && !reduceTransparency
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animates)) { timeline in
      Canvas(opaque: true, rendersAsynchronously: true) { context, size in
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(Path(bounds), with: .color(.white))
        guard !reduceTransparency else { return }

        let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 0.13
        let width = size.width
        let height = size.height
        let drift = sin(phase) * 0.045
        let fold = cos(phase * 0.71) * 0.07
        let colors = Gradient(stops: [
          .init(color: Color(red: 160 / 255.0, green: 224 / 255.0, blue: 171 / 255.0), location: 0),
          .init(
            color: Color(red: 160 / 255.0, green: 224 / 255.0, blue: 171 / 255.0), location: 0.26),
          .init(
            color: Color(red: 255 / 255.0, green: 172 / 255.0, blue: 46 / 255.0), location: 0.58),
          .init(color: Color(red: 165 / 255.0, green: 45 / 255.0, blue: 37 / 255.0), location: 1),
        ])
        let light = GraphicsContext.Shading.linearGradient(
          colors,
          startPoint: CGPoint(x: width * 0.24, y: height * 0.96),
          endPoint: CGPoint(x: width * 1.06, y: height * 0.40)
        )

        // Wide overlapping folds, rather than radial blobs, give the light a
        // continuous direction. Their unequal motion keeps the silhouette organic.
        for index in 0..<5 {
          let layer = Double(index)
          let offset = layer * 0.062 + sin(phase * 0.83 + layer * 0.62) * 0.018
          let thickness = 0.17 - layer * 0.014
          let band = ribbon(
            size: size, offset: offset, thickness: thickness, drift: drift, fold: fold
          )
          var glow = context
          glow.opacity = index == 0 ? 0.35 : 0.19
          glow.addFilter(.blur(radius: min(width, height) * (index == 0 ? 0.045 : 0.014)))
          glow.fill(band, with: light)

          var surface = context
          surface.opacity = index == 0 ? 0.10 : 0.12
          surface.fill(band, with: light)

          var edge = context
          edge.opacity = 0.22
          edge.addFilter(.blur(radius: 1.2))
          edge.stroke(band, with: .color(.white), lineWidth: 1.0)
        }

        // Quiet upper-left space protects the title, text entry, and reading order.
        context.fill(
          Path(bounds),
          with: .linearGradient(
            Gradient(stops: [
              .init(color: .white.opacity(0.97), location: 0),
              .init(color: .white.opacity(0.55), location: 0.40),
              .init(color: .white.opacity(0.06), location: 0.82),
              .init(color: .white.opacity(0.02), location: 1),
            ]),
            startPoint: .zero,
            endPoint: CGPoint(x: width * 0.93, y: height * 0.85)
          )
        )
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in applicationIsActive = true
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
    {
      _ in applicationIsActive = false
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func ribbon(
    size: CGSize, offset: Double, thickness: Double, drift: Double, fold: Double
  ) -> Path {
    func point(_ x: Double, _ y: Double) -> CGPoint {
      CGPoint(x: x * size.width, y: y * size.height)
    }
    var path = Path()
    path.move(to: point(-0.16, 1.16 + offset))
    path.addCurve(
      to: point(0.66 + drift, 0.87 + offset),
      control1: point(0.24, 0.56 + offset + fold),
      control2: point(0.37 + drift, 1.29 + offset - fold)
    )
    path.addCurve(
      to: point(1.13, 0.08 + offset + drift),
      control1: point(0.99 + fold, 0.40 + offset),
      control2: point(0.69 - fold, 0.34 + offset)
    )
    path.addLine(to: point(1.16, 0.08 + offset + drift + thickness))
    path.addCurve(
      to: point(0.67 + drift, 0.87 + offset + thickness),
      control1: point(0.78 - fold, 0.42 + offset + thickness),
      control2: point(1.01 + fold, 0.49 + offset + thickness)
    )
    path.addCurve(
      to: point(-0.16, 1.16 + offset + thickness),
      control1: point(0.37 + drift, 1.23 + offset + thickness - fold),
      control2: point(0.22, 0.68 + offset + thickness + fold)
    )
    path.closeSubpath()
    return path
  }
}
