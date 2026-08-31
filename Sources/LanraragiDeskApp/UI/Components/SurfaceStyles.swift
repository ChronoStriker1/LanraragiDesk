import SwiftUI

/// Shared geometry so cards, sidebar rows, and empty states stay in step.
enum AppSurface {
    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 18
    static let rowRadius: CGFloat = 8
}

extension View {
    /// Material panel with a hairline border and a soft lift, for grouped content.
    func cardSurface(padding: CGFloat = AppSurface.cardPadding) -> some View {
        modifier(CardSurface(padding: padding, elevated: true))
    }

    /// Flat sibling of `cardSurface` for placeholder regions that fill their container.
    func emptyStatePanel() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(CardSurface(padding: 0, elevated: false))
    }
}

private struct CardSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    let padding: CGFloat
    let elevated: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppSurface.cardRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.thinMaterial, in: shape)
            .overlay {
                shape.strokeBorder(
                    Color(nsColor: .separatorColor).opacity(contrast == .increased ? 0.95 : 0.45),
                    lineWidth: 1
                )
            }
            .shadow(
                color: .black.opacity(elevated ? 0.10 : 0),
                radius: elevated ? 8 : 0,
                x: 0,
                y: elevated ? 2 : 0
            )
    }
}

/// Sidebar rows are quiet by default and accent-tinted when selected.
struct SidebarNavButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isSelected: isSelected)
    }

    private struct Row: View {
        @Environment(\.colorSchemeContrast) private var contrast

        let configuration: ButtonStyleConfiguration
        let isSelected: Bool

        @State private var isHovering: Bool = false

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: AppSurface.rowRadius, style: .continuous)
        }

        private var fill: Color {
            let boost = contrast == .increased ? 0.12 : 0.0
            if isSelected {
                return Color.accentColor.opacity((configuration.isPressed ? 0.26 : 0.16) + boost)
            }
            if configuration.isPressed {
                return Color.primary.opacity(0.12 + boost)
            }
            return Color.primary.opacity(isHovering ? 0.07 + boost : 0)
        }

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill, in: shape)
                .overlay {
                    if isSelected, contrast == .increased {
                        shape.strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1)
                    }
                }
                .contentShape(shape)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.12), value: isSelected)
        }
    }
}
