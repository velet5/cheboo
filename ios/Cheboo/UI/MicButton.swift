import SwiftUI

struct MicButton: View {
    let isRecording: Bool
    let isConnecting: Bool
    let level: Float
    let action: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var ringRotation: Double = 0

    private let size: CGFloat = 96

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer reactive halo while recording
                if isRecording {
                    Circle()
                        .fill(.red.opacity(0.12))
                        .frame(
                            width: size + 36 + CGFloat(level) * 56,
                            height: size + 36 + CGFloat(level) * 56
                        )
                        .animation(.easeOut(duration: 0.08), value: level)
                }

                // Soft pulse
                Circle()
                    .strokeBorder(
                        isRecording ? Color.red.opacity(0.35) : Color.accentColor.opacity(0.35),
                        lineWidth: 1
                    )
                    .frame(width: size + 20, height: size + 20)
                    .scaleEffect(pulseScale)
                    .opacity(2 - pulseScale)

                // Core button
                Circle()
                    .fill(
                        LinearGradient(
                            colors: coreColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .shadow(
                        color: (isRecording ? Color.red : Color.accentColor).opacity(0.35),
                        radius: 14,
                        y: 6
                    )

                if isConnecting {
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: size - 14, height: size - 14)
                        .rotationEffect(.degrees(ringRotation))
                        .onAppear {
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                                ringRotation = 360
                            }
                        }
                }

                Image(systemName: iconName)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
                    .scaleEffect(isRecording ? 1.05 : 1.0)
            }
        }
        .buttonStyle(MicPressStyle())
        .onAppear { startPulse() }
        .onChange(of: isRecording) { _, _ in startPulse() }
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    private var iconName: String {
        if isRecording { return "stop.fill" }
        return "mic.fill"
    }

    private var coreColors: [Color] {
        if isRecording {
            return [Color(red: 0.95, green: 0.32, blue: 0.40), Color(red: 0.84, green: 0.18, blue: 0.32)]
        }
        return [Color.accentColor, Color.accentColor.opacity(0.78)]
    }

    private func startPulse() {
        pulseScale = 1.0
        guard isRecording else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            pulseScale = 1.6
        }
    }
}

private struct MicPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
