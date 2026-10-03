import SwiftUI
import TailCatCore

struct MappingEditor: View {
    @Binding var text: String
    @ViewState private var textMode: Bool
    @ViewState private var rows: [Row]
    let focus: FocusState<RuleEditorField?>.Binding

    private struct Row: Identifiable {
        var id = UUID()
        var local: String
        var host: String
        var target: String
        var value: String { host.isEmpty ? "\(local):\(target)" : "\(local):\(host):\(target)" }
    }

    init(text: Binding<String>, focus: FocusState<RuleEditorField?>.Binding) {
        _text = text
        self.focus = focus
        let parsed = Self.parse(text.wrappedValue)
        _rows = State(initialValue: parsed ?? [])
        _textMode = State(initialValue: parsed == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.tr("使用文本语法"), isOn: $textMode)
                .onChange(of: textMode) { enabled in
                    if !enabled {
                        if let parsed = Self.parse(text) { rows = parsed }
                        else { textMode = true }
                    }
                }
            if textMode {
                TextEditor(text: $text).font(.body.monospaced()).frame(height: 80)
                    .focused(focus, equals: .mappings)
                if Self.parse(text) == nil {
                    Text(L10n.tr("请先修正映射格式，再切换到分栏输入。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach($rows) { $row in
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("本地端口")).font(.caption)
                            TextField(L10n.tr("本地端口"), text: $row.local, prompt: Text("0"))
                                .labelsHidden().textFieldStyle(.roundedBorder)
                                .focused(focus, equals: .mappings)
                        }.frame(minWidth: 75)
                        Image(systemName: "arrow.right").padding(.top, 23)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("目标端口")).font(.caption)
                            TextField(L10n.tr("目标端口"), text: $row.target, prompt: Text("8080"))
                                .labelsHidden().textFieldStyle(.roundedBorder)
                        }.frame(minWidth: 75)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("目标 IP（可选）")).font(.caption)
                            TextField(L10n.tr("目标 IP（可选）"), text: $row.host, prompt: Text("192.168.1.10"))
                                .labelsHidden().textFieldStyle(.roundedBorder)
                        }.frame(minWidth: 130)
                        Button {
                            let id = row.id
                            rows.removeAll { $0.id == id }
                            syncText()
                        } label: { Image(systemName: "minus.circle") }
                            .help(L10n.tr("删除映射")).accessibilityLabel(L10n.tr("删除映射"))
                            .padding(.top, 18)
                    }
                    .onChange(of: row.value) { _ in syncText() }
                }
                Button(L10n.tr("添加端口映射")) {
                    rows.append(Row(local: "0", host: "", target: "8080"))
                    syncText()
                }
                Text(L10n.tr("本地端口填 0 可自动分配；目标 IP 留空表示远端设备本身。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: text) { value in
            // Clipboard imports must replace the row draft too, without changing row identities while typing.
            if !textMode, value != rows.map(\.value).joined(separator: "\n") {
                if let parsed = Self.parse(value) { rows = parsed } else { textMode = true }
            }
        }
    }

    private func syncText() { text = rows.map(\.value).joined(separator: "\n") }

    private static func parse(_ text: String) -> [Row]? {
        var result: [Row] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let spec = MappingSpec.parse(String(line)) else { return nil }
            result.append(Row(local: String(spec.localPort), host: spec.remoteHost ?? "", target: String(spec.remotePort)))
        }
        return result
    }
}

enum RuleEditorField: Hashable {
    case name, address, key, mappings, bind, services, ssh, files, command, allow, listen

    static func field(for issue: RuleIssue) -> Self {
        switch issue {
        case .emptyName: return .name
        case .invalidAddress: return .address
        case .invalidKey: return .key
        case .noMappings, .invalidMapping, .openBrowserNeedsOneMapping: return .mappings
        case .invalidBind: return .bind
        case .noServices, .invalidService, .serveMappingUnsupported, .capabilitiesPending: return .services
        case .sshNeedsAuthorizedKeys, .invalidAuthorizedKeys, .unsupportedKeySource, .sshConflict: return .ssh
        case .filesNeedsDirectory, .invalidDirectory: return .files
        case .invalidExec: return .command
        case .invalidAllow: return .allow
        case .invalidListen: return .listen
        }
    }
}
