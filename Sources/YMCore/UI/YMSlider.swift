import SwiftUI

/// Custom ultra-sleek macOS slider for audio progress scrubbing and volume control.
/// Replaces standard AppKit/SwiftUI blue sliders with a modern, smooth, interactive bar.
public struct YMSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let activeColor: Color
    let trackColor: Color
    let height: CGFloat
    let onEditingChanged: ((Bool) -> Void)?

    @UIState private var isHovered = false
    @UIState private var isDragging = false
    @UIState private var dragLocationRatio: CGFloat? = nil

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        activeColor: Color = YMTheme.accent,
        trackColor: Color = YMTheme.surfaceComponentHover,
        height: CGFloat = 4,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.activeColor = activeColor
        self.trackColor = trackColor
        self.height = height
        self.onEditingChanged = onEditingChanged
    }

    private var normalizedProgress: CGFloat {
        if let dragRatio = dragLocationRatio {
            return min(max(dragRatio, 0), 1)
        }
        let total = range.upperBound - range.lowerBound
        guard total > 0 else { return 0 }
        let current = value - range.lowerBound
        return CGFloat(min(max(current / total, 0), 1))
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let barHeight: CGFloat = (isHovered || isDragging) ? height + 2 : height

            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(trackColor)
                    .frame(height: barHeight)

                // Active Progress Fill
                Capsule()
                    .fill(activeColor)
                    .frame(width: max(0, width * normalizedProgress), height: barHeight)

                // Knob Handle (expands on hover/drag)
                if isHovered || isDragging {
                    Circle()
                        .fill(Color(nsColor: .white))
                        .overlay(Circle().strokeBorder(YMTheme.borderHover, lineWidth: 0.5))
                        .frame(width: 10, height: 10)
                        .shadow(color: YMTheme.shadowColor, radius: 3, x: 0, y: 1)
                        .offset(x: max(0, min(width - 10, (width * normalizedProgress) - 5)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.85), value: normalizedProgress)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        let ratio = gesture.location.x / width
                        let clampedRatio = min(max(ratio, 0), 1)
                        dragLocationRatio = clampedRatio
                        let total = range.upperBound - range.lowerBound
                        let newValue = range.lowerBound + Double(clampedRatio) * total
                        value = newValue
                    }
                    .onEnded { gesture in
                        let ratio = gesture.location.x / width
                        let clampedRatio = min(max(ratio, 0), 1)
                        let total = range.upperBound - range.lowerBound
                        let finalValue = range.lowerBound + Double(clampedRatio) * total
                        value = finalValue
                        dragLocationRatio = clampedRatio
                        isDragging = false
                        onEditingChanged?(false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            dragLocationRatio = nil
                        }
                    }
            )
        }
        .frame(height: 16)
        .onHover { inside in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isHovered = inside
            }
        }
    }
}
