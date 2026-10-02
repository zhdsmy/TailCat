import SwiftUI
import TailCatCore

struct TransfersView: View {
    @EnvironmentObject var manager: RuleManager

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.tr("文件传输")).font(.title2)
                    Spacer()
                    Button(L10n.tr("清除已结束")) { manager.transfers.clearFinished() }
                        .disabled(!manager.transfers.items.contains { !$0.state.isActive })
                }
                Text(L10n.tr("切换页面不会中断传输；退出 TailCat 会取消正在进行的任务。记录仅保留到本次退出。"))
                    .font(.caption).foregroundStyle(.secondary)
                if manager.transfers.items.isEmpty {
                    Text(L10n.tr("暂无传输。可从远端页面发送文件，或拖入侧栏的远端。"))
                        .foregroundStyle(.secondary).padding(.vertical)
                }
                ForEach(manager.transfers.items) { item in
                    GroupBox { TransferRow(item: item) }
                }
            }.padding()
        }
    }
}

struct TransferRow: View {
    @EnvironmentObject var manager: RuleManager
    let item: FileTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Diagnostics.mask(item.label), systemImage: directionIcon)
                .font(.callout).lineLimit(2).help(Diagnostics.mask(item.label))
            Text(Diagnostics.mask(item.remote.name)).font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { status; Spacer(); actions }
                VStack(alignment: .leading, spacing: 6) { status; actions }
            }
            if case .failed(let message) = item.state {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var directionIcon: String {
        switch item.operation {
        case .upload: return "arrow.up.doc"
        case .download: return "arrow.down.doc"
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            if item.state.isActive { ProgressView().controlSize(.small) }
            Text(item.state.label)
            if item.state.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in elapsed(at: context.date) }
            } else {
                elapsed(at: item.endedAt ?? item.startedAt)
            }
        }.font(.caption)
    }

    private func elapsed(at date: Date) -> some View {
        Text(L10n.tr("已用时 %@ 秒", String(max(0, Int(date.timeIntervalSince(item.startedAt))))))
            .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if item.state.isActive {
                Button(L10n.tr("取消")) { manager.transfers.cancel(item.id) }
                    .disabled(item.state == .cancelling)
            } else if item.state != .succeeded {
                Button(L10n.tr("重试")) { manager.transfers.retry(item.id) }
            }
            if let url = item.downloadedURL {
                Button(L10n.tr("在 Finder 中显示")) { Panels.revealInFinder(url) }
            }
        }.fixedSize()
    }
}
