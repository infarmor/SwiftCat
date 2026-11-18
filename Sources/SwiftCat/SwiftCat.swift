import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = image
        } else {
            NSApplication.shared.applicationIconImage = SwiftIconRenderer.renderIcon(size: 512)
        }
    }
}

@main
struct SwiftCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 840, minHeight: 560)
                .preferredColorScheme(.dark)
                .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1120, height: 740)
    }
}
