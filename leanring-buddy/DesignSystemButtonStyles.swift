//
//  DesignSystemButtonStyles.swift
//  leanring-buddy
//
//  All `ButtonStyle` conformers Pace uses, in tier order — primary,
//  secondary, tertiary, text, outlined, destructive, icon. Pulled out
//  of the main `DesignSystem.swift` so the tokens-and-namespace file
//  stays focused, and so each style sits next to its peers.
//
//  All styles share three rules:
//  1. Pointer cursor on hover (via `NSCursor.pointingHand` or
//     `PointerCursorView()` for icon buttons).
//  2. 0.97 scale on press for tactile feedback.
//  3. State colours pulled from `DS.Colors` — never hard-coded — so the
//     palette can shift in one place.
//

import AppKit
import SwiftUI

// MARK: - Button Styles

/// Primary button — the main call-to-action per screen.
/// Accent-colored background with white text. One per view maximum.
/// Used for: "start"/"resume", "let's go", "continue", "verify completion".
struct DSPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    // Separate state for the scale expansion so it animates on a slower,
    // more gradual timeline (0.6s) than the background color snap (0.15s).
    @State private var isHoverScaleExpanded = false

    // Whether the hover glow shadow is active. Builds up gradually (0.6s)
    // on hover entry, fades out faster (0.3s) on exit.
    @State private var isHoverGlowActive = false

    // Continuously toggles while hovered to drive a gentle breathing pulse
    // in the glow shadow. Creates a living, organic feel — like the button
    // is softly glowing, not just statically lit.
    @State private var isGlowBreathingIn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, isFullWidth ? 0 : 20)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            // Hover glow — builds up gradually, then gently breathes while hovered.
            // The breathing oscillates opacity and radius on a slow 2.5s loop,
            // creating a candle-flame-like "alive" quality rather than a static highlight.
            .shadow(
                color: DS.Colors.accent.opacity(
                    isHoverGlowActive ? (isGlowBreathingIn ? 0.32 : 0.18) : 0
                ),
                radius: isHoverGlowActive ? (isGlowBreathingIn ? 16 : 10) : 0
            )
            // Hover: gradually expand to 1.03. Press: snap down to 0.97.
            .scaleEffect(configuration.isPressed ? 0.97 : (isHoverScaleExpanded ? 1.03 : 1.0))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                // Background color — fast snap so the button feels responsive
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }

                // Scale — slow, gradual expansion (like the button is swelling)
                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverScaleExpanded = hovering
                }

                // Glow — builds up gradually on entry, fades faster on exit
                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverGlowActive = hovering
                }

                // Breathing glow loop — gentle pulse while hovered.
                // The 2.5s cycle keeps it feeling organic, not mechanical.
                if hovering {
                    withAnimation(
                        .easeInOut(duration: 2.5)
                        .repeatForever(autoreverses: true)
                    ) {
                        isGlowBreathingIn = true
                    }
                } else {
                    // Override the repeating animation with a finite one to stop cleanly
                    withAnimation(.easeOut(duration: 0.3)) {
                        isGlowBreathingIn = false
                    }
                }

                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            // Pressed: brighten slightly beyond hover
            return DS.Colors.accentHover.blendedWithWhite(fraction: DS.StateLayer.pressed)
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

/// Secondary button — supporting actions, less visual weight than primary.
/// Surface-colored background with primary text. Used for: action buttons
/// (download, open link), embedded element buttons.
struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

/// Tertiary/ghost button — low-emphasis actions with subtle hover background.
/// Transparent at rest, shows surface fill on hover. Used for: navigation
/// links, sidebar items, medium-low emphasis actions.
struct DSTertiaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.accentHover
                    : isHovered
                        ? DS.Colors.accentText
                        : DS.Colors.textSecondary
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return Color.clear
        }
    }
}

/// Text button — the lowest-emphasis button style. No background on any
/// state, not even hover. Only the text color changes. Used for: "restart",
/// "skip", "cancel", and other truly minimal inline actions where a
/// background would add too much visual weight.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Outlined button — medium emphasis, used where a border helps define
/// the button's bounds. Used for: display selector, copy prompt.
struct DSOutlinedButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return DS.Colors.surface1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle
        }
    }
}

/// Destructive button — for dangerous/irreversible actions (close session, delete).
/// Red-tinted background that intensifies on hover and press.
struct DSDestructiveButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                isHovered || configuration.isPressed
                    ? .white
                    : DS.Colors.destructiveText
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.40)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.30)
        } else {
            return DS.Colors.destructive.opacity(0.10)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

/// Icon-only button — compact circular button for utility actions.
/// Used for: close button (x), send message, small toolbar actions.
struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isDestructiveOnHover: Bool = false
    var tooltipText: String? = nil

    /// Controls horizontal alignment of the tooltip relative to the button.
    /// Use `.leading` for buttons near the left edge of the window (tooltip extends right),
    /// `.trailing` for buttons near the right edge (tooltip extends left),
    /// and `.center` for buttons in the middle.
    var tooltipAlignment: Alignment = .center

    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    func makeBody(configuration: Configuration) -> some View {
        // The body was inlining a deeply nested overlay/Group/ZStack
        // chain that exceeded Swift's type-inference budget after this
        // struct was lifted into its own file. Factor each subview into
        // a separate helper so each closure body stays small.
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundColor(iconColor(isPressed: configuration.isPressed))
            .frame(width: size, height: size)
            .background(circleBackground(isPressed: configuration.isPressed))
            .overlay(circleBorder(isPressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Circle())
            // Cursor change via AppKit cursor rects — more reliable than
            // NSCursor.push/pop because cursor rects are managed at the
            // window level and don't conflict with SwiftUI's internal
            // cursor handling.
            .overlay(PointerCursorView())
            .onHover(perform: handleHoverChange)
            // Tooltip overlay extracted to a helper so the body stays
            // tractable for the Swift type-checker.
            .overlay(tooltipOverlay, alignment: tooltipAlignment)
    }

    private func circleBackground(isPressed: Bool) -> some View {
        Circle()
            .fill(circleBackgroundColor(isPressed: isPressed))
    }

    private func circleBorder(isPressed: Bool) -> some View {
        Circle()
            .stroke(circleBorderColor(isPressed: isPressed), lineWidth: 1)
    }

    private func handleHoverChange(hovering: Bool) {
        isHovered = hovering
        // Show the tooltip after a delay (like native tooltips), hide immediately
        tooltipShowWorkItem?.cancel()
        if hovering {
            let workItem = DispatchWorkItem {
                withAnimation(.easeOut(duration: 0.15)) {
                    isTooltipVisible = true
                }
            }
            tooltipShowWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
        } else {
            withAnimation(.easeOut(duration: 0.1)) {
                isTooltipVisible = false
            }
        }
    }

    /// Custom styled tooltip — positioned above the button with enough
    /// gap not to overlap. `.allowsHitTesting(false)` keeps it from
    /// stealing the button's hover state.
    @ViewBuilder
    private var tooltipOverlay: some View {
        if isTooltipVisible, let text = tooltipText, !text.isEmpty {
            tooltipBubble(text: text)
                .fixedSize()
                .offset(y: -(size / 2 + 20))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func tooltipBubble(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tooltipBubbleFill)
            .overlay(tooltipBubbleStroke)
            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.26), radius: 4, x: 0, y: 2)
    }

    private var tooltipBubbleFill: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(DS.Colors.surface3.opacity(0.85))
    }

    private var tooltipBubbleStroke: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.20), lineWidth: 0.8)

            RoundedRectangle(cornerRadius: 6)
                .trim(from: 0, to: 0.5)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        }
    }

    private func iconColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return .white
        }
        if isPressed {
            return DS.Colors.textPrimary
        } else if isHovered {
            return DS.Colors.textPrimary
        } else {
            return DS.Colors.textSecondary
        }
    }

    private func circleBackgroundColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover {
            if isPressed {
                return DS.Colors.destructive.opacity(0.40)
            } else if isHovered {
                return DS.Colors.destructive.opacity(0.30)
            } else {
                return DS.Colors.surface2
            }
        }
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }

    private func circleBorderColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructive.opacity(0.30)
        }
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle.opacity(0.5)
        }
    }
}
