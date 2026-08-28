import AppKit
import SwiftUI

/// Design v2 shell (from the user's chosen design canvas): a fixed 240pt
/// sidebar that owns the traffic-light row, and a main column that shows
/// either a connection (dual pane + transfers drawer), the Transfers
/// screen, or the Serve screen. No tab strip — connections live in the
/// sidebar.
struct ContentView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 240)
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 0.5)
            mainColumn
        }
        .background(Theme.content, ignoresSafeAreaEdges: [])
        .frame(minWidth: 1060, minHeight: 640)
        .sheet(isPresented: $model.showQuickConnect) {
            QuickConnectSheet()
        }
        .modifier(FullscreenSync())
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var mainColumn: some View {
        switch model.mainPane {
        case .transfers:
            TransfersView()
        case .serve:
            ServeView()
        case .connection:
            if let tab = model.selectedTab {
                ConnectionView(tab: tab).id(tab.id)
            } else {
                EmptyPaneView()
            }
        }
    }
}

struct EmptyPaneView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.faintText)
            Text("SheepDrop")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Pick a connection in the sidebar, or press ⌘T.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.dimText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.content, ignoresSafeAreaEdges: [])
    }
}
