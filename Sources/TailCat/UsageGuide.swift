import SwiftUI
import TailCatCore

struct UsageGuide: View {
    enum Topic: String, CaseIterable, Identifiable {
        case connect = "连接设备"
        case share = "共享目录"
        case files = "收发文件"
        case troubleshoot = "排查问题"
        var id: Self { self }
    }

    let onAddRemote: () -> Void
    let onNewRule: (TunnelKind) -> Void
    @ViewState var topic: Topic = .connect

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("使用说明").font(.largeTitle.bold())
                Text("TailCat 在菜单栏运行。关闭管理窗口后规则继续运行；从菜单选择“退出”会停止由 TailCat 启动的规则。")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                Picker("使用场景", selection: $topic) {
                    ForEach(Topic.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                content
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var content: some View {
        switch topic {
        case .connect:
            GroupBox("连接对方的网页或 SSH") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. 向对方索取 tc 地址或已发布的 DNS 名称，添加为“远端”。地址等同访问凭据，请只发给信任的人。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("2. 网页使用 80 端口时，在远端详情点“打开网页”；其他端口请选择“新建转发”。例如 18080:8080 会把本机 18080 转到远端 8080。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("3. 启动转发后，访问详情中的本地地址。SSH 可在远端详情点“打开 SSH”，对方需要已开启相应服务。")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("添加远端…", action: onAddRemote)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("对方设置了访问限制？") {
                Text("先在“密钥”里创建客户端密钥，把 nodekey: 公钥交给对方加入允许列表，再在远端中选择这个密钥。SSH 登录使用单独的 SSH 公钥认证，不能用 nodekey: 公钥替代。")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .share:
            GroupBox("把本机目录分享给别人") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. 新建“服务”，选择共享目录。只让对方浏览和下载时使用“只读”；需要对方上传时再选择“读写”。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("2. 在“允许的客户端”中填写对方的 nodekey: 公钥，或从通讯录勾选。未设置允许列表时，任何持有地址的人都可能访问开放的服务。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("3. 保存并启动，把“复制完整地址”得到的地址发给对方。对方添加远端后可浏览文件，或使用“给对方的命令”。")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("新建服务…") { onNewRule(.serve) }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("长期分享或用于 DNS 时，使用已保存的服务端密钥，并建议固定中继区域；只保存密钥并不保证自动选区时地址始终相同。")
                .fixedSize(horizontal: false, vertical: true)
                .font(.callout).foregroundStyle(.secondary)
        case .files:
            GroupBox("发送文件") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("将文件拖到左侧远端，或在远端详情点“发送文件”。对方需要启动收件箱或允许写入的文件服务；发送目录时，对方也需允许接收目录。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("浏览和下载还要求对方开放可读取的文件服务。只能接收文件的收件箱不会提供文件列表；列表失败不一定表示无法发送。")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("添加远端…", action: onAddRemote)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("接收文件") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("在菜单栏点“接收…”选择目录即可开始接收，或新建收件箱调整设置。启动后复制完整地址发给对方；停止收件箱后就不再接收。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("收件箱中的“清除记录”只清除列表记录，不会删除已经收到的文件。")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("新建收件箱…") { onNewRule(.recv) }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .troubleshoot:
            GroupBox("按这个顺序检查") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. 未找到 tailcat：按提示在终端安装，然后“重新检测”；已安装到其他位置时，在设置中指定可执行文件路径。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("2. 无法连接远端：确认对方服务已启动、地址仍有效，且远端选择的客户端密钥已被对方允许。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("3. 显示“已启动”但服务打不开：这只表示本地规则已启动。用“测试连接”检查远端，再核对端口映射和对方的网页、SSH 等服务。")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("4. 仍有问题：展开规则详情中的日志，或从“…”复制诊断信息。诊断中的 tc 地址会打码，分享前仍请检查其他内容。")
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("直连、中继与测速") {
                Text("中继连接也可以正常使用。探测只反映当时的连接状态，不保证具体端口可用；“等待直连”超时也不等于对方离线。测速需要本地命令行支持 perf，且对方开放测速服务；安装支持的版本后，在设置中重新检测。")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
