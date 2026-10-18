import SwiftUI

/// The island, drawn from `IslandMotion`'s springs in window coordinates (origin top-left).
struct IslandView: View {
    @ObservedObject var island: IslandController
    @ObservedObject var pip: PiPController
    @ObservedObject var motion: IslandMotion
    @ObservedObject var glow: AmbientGlow
    let sink: FrameSink

    var body: some View {
        let metrics = island.metrics
        let panel = metrics.panelFrame()
        let centerX = metrics.screenFrame.midX - panel.minX
        let top = metrics.topInset
        let width = motion[.width], height = motion[.height]
        let frame = CGRect(x: centerX - width / 2, y: top, width: width, height: height)
        let outline = PlacedShape(base: IslandShape(topRadius: motion[.topRadius], bottomRadius: motion[.bottomRadius],
                                                    bump: max(0, motion[.bump]), bumpWidth: metrics.bumpWidth),
                                  frame: frame)
        let content = motion[.content]
        let expanded = island.isExpanded

        ZStack(alignment: .topLeading) {
            AmbientGlowView(glow: glow, motion: motion, centerX: centerX, top: top, menuBarHeight: metrics.menuBarHeight)

            outline
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35 * Double(min(max((height - 60) / 200, 0), 1))), radius: 18, y: 8)

            ZStack(alignment: .topLeading) {
                Text(pip.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(pip.isPlaying ? 0.95 : 0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: max(0, motion[.titleW]), height: max(0, motion[.titleH]), alignment: .leading)
                    .placed(x: centerX + motion[.titleX], y: top + motion[.titleY], width: motion[.titleW], height: motion[.titleH])

                let video = CGRect(x: centerX + motion[.videoX], y: top + motion[.videoY],
                                   width: max(1, motion[.videoW]), height: max(1, motion[.videoH]))
                VideoSurface(sink: sink, cornerRadius: max(0, motion[.videoRadius]), desaturation: Double(motion[.desaturate]))
                    .placed(video)

                Color.clear
                    .contentShape(Rectangle())
                    .placed(video)
                    .onTapGesture { pip.togglePlay() }

                // Chrome's window doesn't report progress or play state.
                ProgressRing(progress: pip.progress, isPlaying: pip.isPlaying)
                    .opacity(pip.features.progress ? 1 : 0)
                    .placed(x: centerX + motion[.ringX], y: top + motion[.ringY], width: motion[.ringSize], height: motion[.ringSize])

                ProgressBar(progress: pip.progress)
                    .frame(width: max(0, motion[.barW]), height: max(0, motion[.barH]))
                    .scaleEffect(x: max(0.001, motion[.barGrow]), y: 1, anchor: .leading)
                    .opacity(pip.features.progress ? Double(motion[.barAlpha]) : 0)
                    .placed(x: centerX + motion[.barX], y: top + motion[.barY], width: motion[.barW], height: motion[.barH])

                if expanded, let scrubbed = island.scrubbed {
                    Text(scrubbed == 0 ? "0 s" : scrubbed > 0 ? "+\(scrubbed) s" : "−\(-scrubbed) s")
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .position(x: video.midX, y: video.midY)
                        .transition(.opacity)
                }

                if expanded, let marker = island.videoMarker {
                    VideoMarker(progress: island.videoMarkerProgress)
                        .position(x: video.minX + video.width * marker.x, y: video.minY + video.height * marker.y)
                        .animation(.easeInOut(duration: 0.4), value: marker)
                }

                ControlsRow(pip: pip, motion: motion)
                    .placed(x: centerX + motion[.controlsX], y: top + motion[.controlsY], width: motion[.controlsW], height: 32)
                    .allowsHitTesting(expanded)
            }
            .opacity(Double(content))
            .clipShape(outline)
            .animation(.easeOut(duration: 0.15), value: island.scrubbed == nil)

            let eyes = motion[.eyes]
            if eyes > 0.02 {
                let inside = motion.eyesInside
                let bump = max(0, motion[.bump])
                MascotEyes(openness: Double(eyes * (inside ? 1 : min(bump / 7, 1))), look: motion[.eyeLook])
                    .position(x: centerX, y: inside ? top + height / 2 : top + height + bump / 2)
            }
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
        .opacity(Double(min(max(motion[.opacity], 0), 1)))
    }
}

private extension View {
    func placed(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        frame(width: max(0, width), height: max(0, height))
            .position(x: x + max(0, width) / 2, y: y + max(0, height) / 2)
    }

    func placed(_ rect: CGRect) -> some View {
        placed(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

/// The video's colors, blurred into a soft light under the expanded island. Kept below the
/// menu bar so it doesn't tint the menu titles next to the island.
private struct AmbientGlowView: View {
    @ObservedObject var glow: AmbientGlow
    @ObservedObject var motion: IslandMotion
    let centerX: CGFloat
    let top: CGFloat
    let menuBarHeight: CGFloat

    /// Strength at full expansion.
    private let intensity = 0.75

    var body: some View {
        let alpha = glow.isEnabled ? Double(min(max(motion[.glow], 0), 1) * min(max(motion[.content], 0), 1)) * intensity : 0
        if alpha > 0.004, let image = glow.image {
            let w = motion[.videoW] * 1.5, h = motion[.videoH] * 1.7
            let x = centerX + motion[.videoX] + motion[.videoW] / 2, y = top + motion[.videoY] + motion[.videoH] / 2 + 40
            GeometryReader { proxy in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: max(1, w), height: max(1, h))
                    .mask(Ellipse().fill(RadialGradient(stops: [.init(color: .white, location: 0.55), .init(color: .clear, location: 1)],
                                                        center: .center, startRadius: 0, endRadius: max(w, h) / 2)))
                    .blur(radius: 40)
                    .saturation(1.5)
                    .brightness(0.06)
                    .position(x: x, y: y)
                    .opacity(alpha)
                    .mask(
                        VStack(spacing: 0) {
                            Color.clear.frame(height: menuBarHeight)
                            LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: 40)
                            Color.white
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    )
            }
            .allowsHitTesting(false)
        }
    }
}

/// The gaze target drawn on the video during calibration and the gaze test.
private struct VideoMarker: View {
    var progress: Double

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.45)).frame(width: 40, height: 40)
            Circle().stroke(Theme.accent.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle().fill(Theme.accent).frame(width: 10, height: 10)
        }
        .frame(width: 34, height: 34)
        .allowsHitTesting(false)
    }
}

private struct ProgressRing: View {
    var progress: Double?
    var isPlaying: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.22), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress ?? 0)
                .stroke(Color.white.opacity(isPlaying ? 0.95 : 0.35), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "pause.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.8))
                .opacity(isPlaying ? 0 : 1)
                .scaleEffect(isPlaying ? 0.5 : 1)
        }
        .padding(1.25)
        .animation(.linear(duration: 0.5), value: progress)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPlaying)
    }
}

private struct ProgressBar: View {
    var progress: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white.opacity(0.9))
                    .frame(width: proxy.size.width * (progress ?? 0))
            }
        }
        .animation(.linear(duration: 0.5), value: progress)
    }
}

private struct ControlsRow: View {
    @ObservedObject var pip: PiPController
    @ObservedObject var motion: IslandMotion

    var body: some View {
        HStack(spacing: 0) {
            let features = pip.features
            control(0, shown: features.close) { IconButton(symbol: "xmark", size: 12, help: "Close Picture in Picture") { pip.close() } }
            Spacer()
            HStack(spacing: 26) {
                control(1, shown: features.skip) {
                    IconButton(symbol: "gobackward.10", size: 15, rotation: -40 * motion[.spinBack], help: "Back 10 seconds") {
                        motion.spin(forward: false)
                        pip.skip(forward: false)
                    }
                }
                control(2, shown: features.playPause) {
                    IconButton(symbol: pip.isPlaying ? "pause.fill" : "play.fill", size: 18, help: "Play / Pause") { pip.togglePlay() }
                        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: pip.isPlaying)
                }
                control(3, shown: features.skip) {
                    IconButton(symbol: "goforward.10", size: 15, rotation: 40 * motion[.spinForward], help: "Forward 10 seconds") {
                        motion.spin(forward: true)
                        pip.skip(forward: true)
                    }
                }
            }
            Spacer()
            control(4, shown: features.back) {
                IconButton(symbol: "pip.exit", size: 14, help: pip.source == .chrome ? "Show the Tab in Chrome" : "Back to Safari") {
                    pip.returnToApp()
                }
            }
        }
        .padding(.horizontal, 4)
    }

    /// Each control fades up into place on its own spring. A control the window doesn't
    /// support keeps its place but isn't drawn.
    private func control<Content: View>(_ index: Int, shown: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        let p = min(max(motion.control(index), 0), 1)
        return content()
            .opacity(shown ? Double(p) : 0)
            .allowsHitTesting(shown)
            .offset(y: (1 - p) * 10)
            .blur(radius: p < 0.99 ? (1 - p) * 5 : 0)
    }
}

private struct IconButton: View {
    let symbol: String
    let size: CGFloat
    var rotation: CGFloat = 0
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .rotationEffect(.degrees(Double(rotation)))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.8))
                .frame(width: 30, height: 28)
                .background(
                    Circle()
                        .fill(Color.white.opacity(hovering ? 0.13 : 0))
                        .frame(width: 32, height: 32)
                )
                .animation(.easeOut(duration: 0.15), value: hovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Buttons sink a little while pressed.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }
}
