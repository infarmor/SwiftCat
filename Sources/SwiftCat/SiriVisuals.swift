import SwiftUI
import AppKit

public struct SwiftCatAnimations {
    public static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82, blendDuration: 0)
    public static let smooth = Animation.easeInOut(duration: 0.22)
    public static let textTicker = Animation.linear(duration: 0.02)
}

public struct VisualEffectView: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode
    
    public init(material: NSVisualEffectView.Material = .sidebar, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }
    
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }
    
    public func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}

public struct MinimalCursorView: View {
    @State private var isVisible = true
    
    public var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.cyan.opacity(0.85))
            .frame(width: 2, height: 15)
            .opacity(isVisible ? 1 : 0)
            .animation(Animation.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: isVisible)
            .onAppear {
                isVisible = false
            }
    }
}

public struct SiriColors {
    public static let background = Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.90)
    public static let sidebarBackground = Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.78)
    public static let cardBackground = Color(white: 0.16).opacity(0.55)
    public static let activeCard = Color(white: 0.22).opacity(0.72)
    public static let inputBarBackground = Color(white: 0.13).opacity(0.70)
    public static let textPrimary = Color.white.opacity(0.94)
    public static let textSecondary = Color.white.opacity(0.50)
    public static let border = Color.white.opacity(0.09)
    public static let glassHighlight = Color.white.opacity(0.18)
}
