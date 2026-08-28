import SwiftUI

/// The Transfers screen (design v2): every live transfer plus the session
/// history, with a today total in the footer.
struct TransfersView: View {
    @ObservedObject private var model = AppModel.shared

    private var liveTabs: [SessionTab] {
        model.tabs.filter { $0.sftp?.transfer != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneStrip {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dimText)
                Text("Transfers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                Spacer(minLength: 0)
                if !model.transferHistory.isEmpty {
                    Button("Clear history") { model.transferHistory.removeAll() }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                }
            }

            if liveTabs.isEmpty && model.transferHistory.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Theme.faintText)
                    Text("No transfers yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text2)
                    Text("Uploads and downloads from every connection land here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dimText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.content)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(liveTabs) { tab in
                            LiveTransferRow(tab: tab)
                        }
                        ForEach(model.transferHistory) { record in
                            HistoryTransferRow(record: record)
                        }
                    }
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.content)
            }

            HStack {
                Text(todaySummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dimText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Theme.header, ignoresSafeAreaEdges: [])
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairlineSoft).frame(height: 0.5)
            }
        }
        .background(Theme.content, ignoresSafeAreaEdges: [])
    }

    private var todaySummary: String {
        let calendar = Calendar.current
        let today = model.transferHistory.filter { calendar.isDateInToday($0.finished) }
        guard !today.isEmpty else { return "Nothing transferred today" }
        let failed = today.filter(\.failed).count
        let suffix = failed == 0 ? "" : " · \(failed) failed"
        return "\(today.count) transfers today\(suffix)"
    }
}
