import EventKit
import MessageUI
import Photos
import SwiftUI
import UIKit

@MainActor
struct PhotoSearchView: View {
    @EnvironmentObject private var index: PhotoIndex
    @State private var query: String
    @State private var screenshotsOnly = true
    @State private var allowCloud = false
    @State private var selected: IndexedPhoto?
    @State private var showClearConfirmation = false

    init(query: String = "") { _query = State(initialValue: query) }

    private var matches: [PhotoMatch] {
        PhotoSearch.matches(query, in: index.records)
    }

    var body: some View {
        List {
            Section("本机资料库") {
                Text("已索引 \(index.records.count) 张图片")
                Text(index.progress).font(.footnote).foregroundStyle(.secondary)
                if index.authorization == .limited {
                    Text("当前只能搜索你在系统中选给 Cassie 的照片。可在系统设置中更改范围。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("只扫描截图（关闭可扫描全部照片）", isOn: $screenshotsOnly)
                    .disabled(index.isScanning)
                Toggle("允许从 iCloud 下载原图", isOn: $allowCloud)
                    .disabled(index.isScanning)
                Text("图片文字在本机识别和保存。首次扫描请保持 Cassie 在前台；下一次扫描会跳过未改动的图片。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !index.canRead {
                    Button("授权相册访问") { Task { await index.requestAccess() } }
                } else if index.isScanning {
                    ProgressView()
                    Button("暂停扫描") { index.pause() }
                } else {
                    Button("扫描新增与改动的图片") {
                        index.start(screenshotsOnly: screenshotsOnly, allowCloudDownloads: allowCloud)
                    }
                }
                if let error = index.error { Text(error).foregroundStyle(.red) }
            }
            Section(query.isEmpty ? "最近索引的图片" : "文字匹配结果") {
                if query.isEmpty {
                    ForEach(index.records
                        .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }.prefix(30)) { photo in
                        Button { selected = photo } label: { PhotoResultRow(photo: photo, excerpt: photo.text) }
                            .buttonStyle(.plain)
                    }
                } else {
                    ForEach(matches) { match in
                        Button { selected = match.photo } label: {
                            PhotoResultRow(photo: match.photo, excerpt: match.excerpt)
                        }.buttonStyle(.plain)
                    }
                    if matches.isEmpty {
                        Text("没有找到文字匹配。可尝试截图里出现过的课程名、地址或日期。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("清除本机文字索引", role: .destructive) { showClearConfirmation = true }
                    .disabled(index.isScanning || index.records.isEmpty)
            } footer: { Text("清除索引不会删除相册里的照片。") }
        }
        .navigationTitle("截图资料")
        .searchable(text: $query, prompt: "搜索课程名、日期、地址…")
        .sheet(item: $selected) { photo in PhotoDetailView(photo: photo) }
        .confirmationDialog("清除 Cassie 保存的所有图片文字？", isPresented: $showClearConfirmation) {
            Button("清除索引", role: .destructive) { index.clear() }
        }
    }
}

@MainActor
private struct PhotoResultRow: View {
    let photo: IndexedPhoto
    let excerpt: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(photo.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "日期未知")
                .font(.caption).foregroundStyle(.secondary)
            Text(excerpt.isEmpty ? "未识别出文字，点按查看原图" : excerpt).lineLimit(3)
            Label("查看原图与完整文字", systemImage: "photo").font(.caption).foregroundStyle(.indigo)
        }.padding(.vertical, 4)
    }
}

@MainActor
struct PhotoDetailView: View {
    let photo: IndexedPhoto
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var loading = true
    @State private var capture = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let image { Image(uiImage: image).resizable().scaledToFit() }
                    else if loading { ProgressView("读取原图…") }
                    if let error { Text(error).foregroundStyle(.secondary) }
                    Text(photo.text.isEmpty ? "没有识别出文字。" : photo.text).textSelection(.enabled)
                    if !photo.text.isEmpty { ShareLink("分享识别文字", item: photo.text) }
                    if !photo.text.isEmpty {
                        Button("从这张截图提取待办", systemImage: "checklist") { capture = true }
                        Text("确认保存的任务会保留来源文字副本。清除照片索引不会删除已保存的任务副本；可在 Dayplan 删除对应任务。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding()
            }
            .navigationTitle("来源截图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .task { await load(allowCloud: false) }
            .sheet(isPresented: $capture) { PlanCaptureView(text: photo.text, photoID: photo.id) }
            .safeAreaInset(edge: .bottom) {
                if image == nil && !loading {
                    Button("尝试从 iCloud 下载并查看") { Task { await load(allowCloud: true) } }
                        .buttonStyle(.borderedProminent).padding()
                }
            }
        }
    }

    private func load(allowCloud: Bool) async {
        loading = true
        defer { loading = false }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject else {
            error = "原图已删除，或不在当前授权范围内。"
            return
        }
        do {
            let data = try await PhotoLoader.imageData(asset: asset, allowCloud: allowCloud)
            image = UIImage(data: data)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct ScheduleView: View {
    @EnvironmentObject private var schedule: CalendarService
    var body: some View {
        List {
            Section("连接 Celechron 课表") {
                Text("先在 Celechron 中将本学期课表同步到系统日历，再在这里选择对应日历。课表变动后，请在 Celechron 中重新同步。")
                    .font(.subheadline)
                Button(schedule.hasAccess ? "刷新日历" : "授权并读取系统日历") {
                    Task { await schedule.connect() }
                }
                if let error = schedule.error { Text(error).foregroundStyle(.red) }
            }
            Section("选择课表日历") {
                ForEach(schedule.calendars, id: \.calendarIdentifier) { calendar in
                    Button { schedule.toggle(calendar) } label: {
                        HStack {
                            Text(calendar.title).foregroundStyle(.primary)
                            Spacer()
                            if schedule.selectedIDs.contains(calendar.calendarIdentifier) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.indigo)
                            }
                        }
                    }
                }
                if schedule.hasAccess && schedule.calendars.isEmpty { Text("没有找到可读取的日历。") }
            }
            Section("未来两周") {
                ForEach(schedule.events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title).font(.headline)
                        Text(event.start.formatted(date: .abbreviated, time: .shortened))
                        Text(event.location).foregroundStyle(.secondary)
                    }
                }
                if schedule.events.isEmpty { Text("所选日历中没有找到课程。未选日历时不会读取其他日程。") }
            }
        }
        .navigationTitle("课表日程")
        .onAppear { schedule.refresh() }
        .refreshable { schedule.refresh() }
    }
}

@MainActor
struct NotesView: View {
    @EnvironmentObject private var notes: NoteStore
    @State private var draft = ""
    @State private var organizing: VoiceNote?
    var body: some View {
        List {
            Section("随手记") {
                TextField("要记住什么？", text: $draft, axis: .vertical)
                Button("保存到本机") { if notes.add(draft) { draft = "" } }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let error = notes.error { Text(error).foregroundStyle(.red) }
            }
            Section("我的备忘") {
                ForEach(notes.notes) { note in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note.text).textSelection(.enabled)
                        Text(note.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                        Text(note.processedAt == nil ? "待整理" : "已整理").font(.caption).foregroundStyle(.indigo)
                        HStack {
                            Button("整理进计划") { organizing = note }
                            if note.processedAt == nil { Button("仅标记已整理") { notes.markProcessed(note.id) } }
                        }.buttonStyle(.borderless)
                    }
                }.onDelete(perform: notes.delete)
            }
        }.navigationTitle("随口收件箱")
            .sheet(item: $organizing) { note in
                PlanCaptureView(text: note.text, onImported: { notes.markProcessed(note.id) })
            }
    }
}

@MainActor
struct ConnectionsView: View {
    @AppStorage("doubaoShortcut") private var doubao = ""
    @AppStorage("tailgShortcut") private var tailg = ""
    @State private var status: String?
    var body: some View {
        Form {
            Section("打开豆包") {
                Text("在系统“快捷指令”中新建指令，添加“打开 App”动作并选择豆包。把指令名称填在这里。")
                TextField("快捷指令名称，例如：打开豆包", text: $doubao)
                Button("运行打开豆包指令") { Task { await run(doubao) } }
                    .disabled(doubao.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("台铃智能") {
                Text("在台铃智能或系统“快捷指令”的 App 动作列表里，确认你的车辆是否提供解锁动作。将对应动作保存为快捷指令，再填入名称。")
                TextField("已配置的车辆解锁指令名称", text: $tailg)
                Text("Cassie 会在你确认后启动这条指令。最终解锁是否成功，由台铃智能和车辆反馈；Cassie 不会把“打开快捷指令”当作解锁成功。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("接入方式") {
                LabeledContent("课表", value: "Celechron → 系统日历")
                LabeledContent("打开 App", value: "系统快捷指令")
                LabeledContent("控车", value: "台铃智能官方动作")
            }
            if let status { Section { Text(status) } }
        }
        .navigationTitle("App 与设备")
    }

    private func run(_ name: String) async {
        let opened = await ShortcutService.run(name: name)
        status = opened ? "已请求系统运行快捷指令，请查看系统的运行结果。" : "未能打开快捷指令，请检查名称和系统 App。"
    }
}

@MainActor
struct MessageDraftView: View {
    @State private var recipient = ""
    @State private var text = ""
    @State private var showComposer = false
    @State private var result: String?
    var body: some View {
        Form {
            Section {
                TextField("收件人手机号（可留空）", text: $recipient).keyboardType(.phonePad)
                TextField("输入或用键盘听写回复内容", text: $text, axis: .vertical).lineLimit(4...10)
                Button("检查并打开系统消息界面") { showComposer = true }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !MFMessageComposeViewController.canSendText())
                if !MFMessageComposeViewController.canSendText() { Text("当前设备无法使用系统消息编辑器；你仍可分享草稿到其他 App。") }
                ShareLink("分享草稿到其他 App", item: text).disabled(text.isEmpty)
            } header: { Text("准备回复") }
              footer: { Text("发送在系统消息界面里确认。此页面不会读取微信或系统消息的聊天记录。") }
            if let result { Section { Text(result) } }
        }
        .navigationTitle("消息草稿")
        .sheet(isPresented: $showComposer) {
            MessageComposer(recipients: recipient.isEmpty ? [] : [recipient], messageBody: text) { outcome in
                showComposer = false
                switch outcome {
                case .sent: result = "消息已交给系统发送，送达状态请查看消息 App。"
                case .cancelled: result = "已取消发送，草稿仍保留在此页面。"
                case .failed: result = "系统未能发送，请检查连接后重试。"
                @unknown default: result = "请在消息 App 中查看发送结果。"
                }
            }
        }
    }
}

@MainActor
private struct MessageComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let messageBody: String
    let completion: (MessageComposeResult) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = messageBody
        controller.messageComposeDelegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) { }
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let completion: (MessageComposeResult) -> Void
        init(completion: @escaping (MessageComposeResult) -> Void) { self.completion = completion }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            completion(result)
        }
    }
}
