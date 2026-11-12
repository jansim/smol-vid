import SwiftUI

/// SmolVid's signature purples, shared by the dial and the Compress button.
enum Theme {
    static let lavender = Color(red: 0.78, green: 0.56, blue: 1.0)
    static let violet = Color(red: 0.58, green: 0.33, blue: 0.95)
    static let grape = Color(red: 0.42, green: 0.20, blue: 0.82)

    static let purples: [Color] = [lavender, violet, grape]
}

/// A prominent, purple capsule button with a soft glow, a shimmer that sweeps across it now and then,
/// and a little lift on hover.
struct CompressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompressButton(configuration: configuration)
    }

    private struct CompressButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false
        @State private var shimmer = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background {
                    Capsule()
                        .fill(LinearGradient(
                            colors: isEnabled ? [Theme.lavender, Theme.violet, Theme.grape] : [.gray.opacity(0.55), .gray.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .overlay { shimmerBand }
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                        .brightness(pressed ? -0.08 : isHovering ? 0.05 : 0)
                }
                .clipShape(Capsule())
                .shadow(
                    color: isEnabled ? Theme.violet.opacity(isHovering ? 0.6 : 0.4) : .clear,
                    radius: isHovering ? 9 : 5,
                    y: 2
                )
                .scaleEffect(pressed ? 0.95 : isHovering && isEnabled ? 1.04 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
                .animation(.easeInOut(duration: 0.2), value: isEnabled)
                .onHover { isHovering = $0 }
                .onAppear { startShimmer() }
                .onChange(of: isEnabled) { startShimmer() }
                .onChange(of: reduceMotion) { startShimmer() }
        }

        /// A bright diagonal band that sweeps across the button, then rests before the next pass.
        private var shimmerBand: some View {
            GeometryReader { geometry in
                let width = geometry.size.width
                LinearGradient(
                    colors: [.clear, .white.opacity(0.45), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width * 0.4)
                .rotationEffect(.degrees(20))
                .offset(x: shimmer ? width * 1.2 : -width * 0.6)
            }
            .allowsHitTesting(false)
            .opacity(isEnabled && !reduceMotion ? 1 : 0)
        }

        private func startShimmer() {
            shimmer = false
            guard isEnabled, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).delay(1.6).repeatForever(autoreverses: false)) {
                shimmer = true
            }
        }
    }
}
