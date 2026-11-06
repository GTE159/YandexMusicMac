import SwiftUI
import AppKit

/// Modern theme and visual design tokens supporting dynamic Dark & Light appearance.
public enum YMTheme {
    public static let bg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 246 / 255, green: 246 / 255, blue: 248 / 255, alpha: 1.0)
            : NSColor(red: 11 / 255, green: 11 / 255, blue: 13 / 255, alpha: 1.0)
    })

    public static let sidebarBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 236 / 255, green: 236 / 255, blue: 240 / 255, alpha: 1.0)
            : NSColor(red: 14 / 255, green: 14 / 255, blue: 17 / 255, alpha: 1.0)
    })

    public static let playerBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 255 / 255, green: 255 / 255, blue: 255 / 255, alpha: 0.98)
            : NSColor(red: 16 / 255, green: 16 / 255, blue: 20 / 255, alpha: 0.96)
    })

    public static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1.0)
            : NSColor(red: 22 / 255, green: 22 / 255, blue: 26 / 255, alpha: 1.0)
    })

    public static let surfaceHigh = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 230 / 255, green: 230 / 255, blue: 236 / 255, alpha: 1.0)
            : NSColor(red: 32 / 255, green: 32 / 255, blue: 38 / 255, alpha: 1.0)
    })

    public static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(white: 0.0, alpha: 0.08)
            : NSColor(white: 1.0, alpha: 0.08)
    })

    public static let borderHover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(white: 0.0, alpha: 0.22)
            : NSColor(white: 1.0, alpha: 0.25)
    })

    public static let fg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 20 / 255, green: 20 / 255, blue: 24 / 255, alpha: 1.0)
            : NSColor(red: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1.0)
    })

    public static let fg80 = fg.opacity(0.8)
    public static let fg60 = fg.opacity(0.6)
    public static let fg40 = fg.opacity(0.4)

    public static let accent = Color(red: 255 / 255, green: 204 / 255, blue: 0 / 255) // Yandex Yellow #FFCC00
    public static let heartRed = Color(red: 255 / 255, green: 59 / 255, blue: 48 / 255) // iOS Red

    public static let cornerRadiusLarge: CGFloat = 14
    public static let cornerRadiusMedium: CGFloat = 10
    public static let cornerRadiusSmall: CGFloat = 6
}

// MARK: - Glass & Translucency Modifiers

public struct YMGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?

    public func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill((tint ?? .black).opacity(0.35))
                    shape.stroke(YMTheme.border, lineWidth: 1)
                }
                .environment(\.colorScheme, .dark)
            }
    }
}

public extension View {
    func ymGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(YMGlassModifier(shape: shape, interactive: interactive, tint: tint))
    }

    func ymGlassCapsule(interactive: Bool = false, tint: Color? = nil) -> some View {
        ymGlass(in: Capsule(), interactive: interactive, tint: tint)
    }

    func ymScreenBackground() -> some View {
        background(YMTheme.bg.ignoresSafeArea())
    }
}

// MARK: - Interactive Card Hover Modifier

public struct YMCardHoverModifier: ViewModifier {
    @UIState private var isHovered = false
    let cornerRadius: CGFloat
    let scale: CGFloat

    public init(cornerRadius: CGFloat = YMTheme.cornerRadiusMedium, scale: CGFloat = 1.04) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? scale : 1.0)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isHovered ? YMTheme.borderHover : Color.clear, lineWidth: 1.5)
            }
            .shadow(
                color: Color.black.opacity(isHovered ? 0.45 : 0.15),
                radius: isHovered ? 16 : 4,
                y: isHovered ? 8 : 2
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isHovered)
            .onHover { inside in
                isHovered = inside
            }
    }
}

public extension View {
    func ymCardHover(cornerRadius: CGFloat = YMTheme.cornerRadiusMedium, scale: CGFloat = 1.03) -> some View {
        modifier(YMCardHoverModifier(cornerRadius: cornerRadius, scale: scale))
    }
}

// MARK: - Buttons

/// Glass pill button with hover scaling and icon
public struct YMGlassPillButtonStyle: ButtonStyle {
    public var primary: Bool = false
    public var height: CGFloat = 32

    @UIState private var hover = false

    public init(primary: Bool = false, height: CGFloat = 32) {
        self.primary = primary
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? Color.black : YMTheme.fg)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background {
                if primary {
                    Capsule()
                        .fill(hover ? Color.white : YMTheme.accent)
                } else {
                    Capsule()
                        .fill(hover ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                        .overlay(Capsule().strokeBorder(YMTheme.border, lineWidth: 1))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : hover ? 1.03 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}
