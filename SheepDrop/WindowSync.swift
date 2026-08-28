import AppKit
import SwiftUI

/// Fullscreen tracking for the traffic-light spacer. Uses notification
/// publishers, not the block-based NotificationCenter API — the blocks are
/// @Sendable and trip Swift 6 sending checks on Notification/NSWindow;
/// SheepTerm's ContentView settled on this same shape.
///
/// will* drives the animation early (before the styleMask flips); the did*
/// pair is the safety net for aborted or restored transitions that skip
/// will* (styleMask only reflects the final state once the transition ends).
struct FullscreenSync: ViewModifier {
    @ObservedObject private var model = AppModel.shared

    func body(content: Content) -> some View {
        content
            .onAppear {
                model.isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
                set(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
                set(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                set(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                set(false)
            }
    }

    private func set(_ fullscreen: Bool) {
        guard model.isFullScreen != fullscreen else { return }
        // No animation: animating the traffic-light spacer height made the
        // sidebar lag and briefly overlap the red/yellow/green buttons during
        // the fullscreen transition. Snap it instead.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.isFullScreen = fullscreen }
    }
}
