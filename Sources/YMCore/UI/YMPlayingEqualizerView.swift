import SwiftUI

/// Animated equalizer indicator with 4 bouncing vertical bars.
/// Represents an actively playing track with smooth, non-repeating organic motion.
public struct YMPlayingEqualizerView: View {
    public let color: Color
    public let barWidth: CGFloat
    public let maxHeight: CGFloat
    public let minHeight: CGFloat
    public let isPlaying: Bool

    @UIState private var isAnimating: Bool = false

    public init(
        color: Color = YMTheme.accent,
        barWidth: CGFloat = 2.5,
        maxHeight: CGFloat = 14,
        minHeight: CGFloat = 3,
        isPlaying: Bool = true
    ) {
        self.color = color
        self.barWidth = barWidth
        self.maxHeight = maxHeight
        self.minHeight = minHeight
        self.isPlaying = isPlaying
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            barView(from: 0.25, to: 0.95, duration: 0.42)
            barView(from: 0.40, to: 0.70, duration: 0.65)
            barView(from: 0.20, to: 1.00, duration: 0.35)
            barView(from: 0.35, to: 0.85, duration: 0.52)
        }
        .frame(height: maxHeight, alignment: .bottom)
        .onAppear {
            if isPlaying {
                isAnimating = true
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                isAnimating = true
            } else {
                isAnimating = false
            }
        }
    }

    @ViewBuilder
    private func barView(from minScale: CGFloat, to maxScale: CGFloat, duration: Double) -> some View {
        let currentScale = isAnimating ? maxScale : minScale
        RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(color)
            .frame(
                width: barWidth,
                height: isPlaying ? max(minHeight, maxHeight * currentScale) : minHeight
            )
            .animation(
                isPlaying
                    ? .easeInOut(duration: duration).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: isAnimating
            )
    }
}
