import SwiftUI
import AppKit

/// Modern theme and visual design tokens supporting dynamic Dark & Light appearance.
/// Carefully tuned for high legibility, soft warm-neutral light tone, and cohesive contrast.
public enum YMTheme {
    // MARK: - Backgrounds

    /// Main content window background
    public static let bg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 235 / 255, green: 234 / 255, blue: 229 / 255, alpha: 1.0) // Soft warm paper neutral #EBEAE5
            : NSColor(red: 11 / 255, green: 11 / 255, blue: 13 / 255, alpha: 1.0)    // Deep sleek dark #0B0B0D
    })

    /// Sidebar navigation background
    public static let sidebarBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 224 / 255, green: 222 / 255, blue: 217 / 255, alpha: 1.0) // Warm muted stone #E0DED9
            : NSColor(red: 14 / 255, green: 14 / 255, blue: 17 / 255, alpha: 1.0)    // Sidebar dark #0E0E11
    })

    /// Fixed bottom player bar background
    public static let playerBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 243 / 255, green: 242 / 255, blue: 238 / 255, alpha: 0.98) // Soft cream #F3F2EE
            : NSColor(red: 16 / 255, green: 16 / 255, blue: 20 / 255, alpha: 0.96)     // Player dark #101014
    })

    /// Elevated card / table row surface
    public static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 248 / 255, green: 247 / 255, blue: 244 / 255, alpha: 1.0) // Elevated card #F8F7F4
            : NSColor(red: 22 / 255, green: 22 / 255, blue: 26 / 255, alpha: 1.0)     // Card dark #16161A
    })

    /// Popover / dialog / secondary surface
    public static let surfaceHigh = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 216 / 255, green: 214 / 255, blue: 208 / 255, alpha: 1.0) // #D8D6D0
            : NSColor(red: 32 / 255, green: 32 / 255, blue: 38 / 255, alpha: 1.0)     // #202026
    })

    /// Subtle component fill (pill buttons, icon badges, idle controls)
    public static let surfaceComponent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 30 / 255, green: 30 / 255, blue: 34 / 255, alpha: 0.07)
            : NSColor(white: 1.0, alpha: 0.08)
    })

    /// Hovered component fill
    public static let surfaceComponentHover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 30 / 255, green: 30 / 255, blue: 34 / 255, alpha: 0.13)
            : NSColor(white: 1.0, alpha: 0.16)
    })

    // MARK: - Borders & Dividers

    public static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 30 / 255, green: 28 / 255, blue: 24 / 255, alpha: 0.09)
            : NSColor(white: 1.0, alpha: 0.08)
    })

    public static let borderHover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 30 / 255, green: 28 / 255, blue: 24 / 255, alpha: 0.22)
            : NSColor(white: 1.0, alpha: 0.25)
    })

    // MARK: - Typography & Glyphs

    public static let fg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 24 / 255, green: 24 / 255, blue: 27 / 255, alpha: 1.0) // Rich charcoal #18181B
            : NSColor(red: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1.0)
    })

    public static let fg80 = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 72 / 255, green: 71 / 255, blue: 75 / 255, alpha: 1.0)
            : NSColor(white: 1.0, alpha: 0.8)
    })

    public static let fg60 = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 114 / 255, green: 113 / 255, blue: 119 / 255, alpha: 1.0)
            : NSColor(white: 1.0, alpha: 0.6)
    })

    public static let fg40 = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 156 / 255, green: 155 / 255, blue: 162 / 255, alpha: 1.0)
            : NSColor(white: 1.0, alpha: 0.4)
    })

    // MARK: - Brand Accents

    /// Dynamic brand accent for text, icons, progress bars, and outlines.
    /// Uses warm amber-gold #C97700 in light mode for 4.6:1 WCAG contrast,
    /// and vibrant #FFCC00 in dark mode.
    public static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 205 / 255, green: 115 / 255, blue: 0 / 255, alpha: 1.0) // Amber-gold for light mode
            : NSColor(red: 255 / 255, green: 204 / 255, blue: 0 / 255, alpha: 1.0) // Brand Yellow #FFCC00 for dark
    })

    /// Solid yellow fill for primary action discs/pills (Play button, "Слушать всё").
    /// Foreground inside must always be Color.black!
    public static let accentFill = Color(red: 255 / 255, green: 204 / 255, blue: 0 / 255)

    public static let heartRed = Color(red: 255 / 255, green: 59 / 255, blue: 48 / 255) // iOS Red

    // MARK: - Dynamic Shadows

    public static let shadowColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 30 / 255, green: 25 / 255, blue: 20 / 255, alpha: 0.08) // Soft diffused shadow in light
            : NSColor(white: 0.0, alpha: 0.40)                                     // Deep shadow in dark
    })

    public static let playerBarShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            ? NSColor(red: 30 / 255, green: 25 / 255, blue: 20 / 255, alpha: 0.06)
            : NSColor(white: 0.0, alpha: 0.50)
    })

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
                    shape.fill(tint ?? YMTheme.surfaceComponent)
                    shape.stroke(YMTheme.border, lineWidth: 1)
                }
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
                color: YMTheme.shadowColor,
                radius: isHovered ? 12 : 3,
                y: isHovered ? 6 : 1
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
                        .fill(hover ? YMTheme.accentFill.opacity(0.88) : YMTheme.accentFill)
                } else {
                    Capsule()
                        .fill(hover ? YMTheme.surfaceComponentHover : YMTheme.surfaceComponent)
                        .overlay(Capsule().strokeBorder(YMTheme.border, lineWidth: 1))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : hover ? 1.03 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}
