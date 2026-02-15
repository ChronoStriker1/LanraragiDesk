import SwiftUI

struct DebugFrameNumberModifier: ViewModifier {
    @AppStorage("debug.showFrameNumbers") private var enabled: Bool = false
    let number: Int

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if enabled {
                Text("\(number)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func debugFrameNumber(_ number: Int) -> some View {
        modifier(DebugFrameNumberModifier(number: number))
    }
}

