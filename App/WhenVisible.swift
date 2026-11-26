import AppKit
import SwiftUI

/// Shows `content` only while its window is actually visible on screen.
///
/// SwiftUI keeps closed windows (dashboard, settings) and hidden menu bar popovers alive, and their
/// views keep re-rendering on every sample even though nobody sees them. While the window is hidden
/// or fully covered, this keeps just an empty placeholder of the same size, so nothing observes the
/// store. When the window shows up again, the content is created anew.
struct WhenVisible<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var visible = true
    @State private var size: CGSize = .zero
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if visible {
                content()
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { size = g.size }
                            .onChange(of: g.size) { _, new in size = new }
                    })
            } else {
                Color.clear.frame(width: size.width, height: size.height)
            }
        }
        .background(WindowReader { w in
            guard w !== window else { return }
            window = w
            update()
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { n in
            if let window, (n.object as? NSWindow) === window { update() }
        }
    }

    private func update() {
        let now = window.map { $0.occlusionState.contains(.visible) } ?? true
        if now != visible { visible = now }
    }
}
