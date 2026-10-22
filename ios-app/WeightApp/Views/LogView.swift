import SwiftUI
import UIKit

/// 运行日志：出现「点了没反应」之类问题时，直接复制发给开发者定位
struct LogView: View {
    @State private var entries: [String] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Text("暂无日志")
                    .foregroundColor(.secondary)
            } else {
                ForEach(entries, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = entries.reversed().joined(separator: "\n")
                        Haptics.success()
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        AppLogger.shared.clear()
                        entries = []
                        Haptics.tap()
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            entries = Array(AppLogger.shared.entries.reversed())
        }
    }
}
