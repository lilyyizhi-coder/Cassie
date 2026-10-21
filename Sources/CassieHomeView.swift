import SwiftUI

@MainActor
struct CassieHomeView: View {
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var photos: PhotoIndex
    @EnvironmentObject private var notes: NoteStore
    @EnvironmentObject private var schedule: CalendarService
    @ObservedObject private var route = AppRoute.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("doubaoShortcut") private var doubaoShortcut = ""
    @AppStorage("tailgShortcut") private var tailgShortcut = ""
    @AppStorage("readReplies") private var readReplies = true
    @State private var input = ""
    @State private var reply = ""
    @State private var path: [Destination] = []
    @State private var confirmUnlock = false
    @State private var matchCount = 0
    @State private var lastSearch = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cassie").font(.largeTitle.bold())
                            Text("把日常小事交给我").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { readReplies.toggle(); if !readReplies { speech.silence() } } label: {
                            Image(systemName: readReplies ? "speaker.wave.2" : "speaker.slash")
                                .font(.title2).padding(12)
                        }.accessibilityLabel(readReplies ? "关闭语音播报" : "开启语音播报")
                    }
                    voiceCard
                    if let error = speech.error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if !reply.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(reply).textSelection(.enabled)
                            if matchCount > 0 {
                                Button("查看 \(matchCount) 个匹配与原图") { path.append(.photos(lastSearch)) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                            .background(.background, in: RoundedRectangle(cornerRadius: 20))
                    }
                    Text("常用功能").font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        feature("截图资料", "搜索文字，查看原图", "text.viewfinder", .photos(""))
                        feature("课表日程", "连接 Celechron 课表", "calendar", .schedule)
                        feature("语音备忘", "随口记下，保存在本机", "note.text", .notes)
                        feature("消息草稿", "编辑并交给系统发送", "message", .messages)
                        feature("打开豆包", "配置快捷指令", "square.grid.2x2", .connections)
                        feature("台铃智能", "连接官方控车指令", "bicycle", .connections)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("试着这样说").font(.headline)
                        Text("“下一节课是什么”\n“找一下含考试日期的截图”\n“记一下明天带充电器”\n“打开豆包”")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        .background(.background, in: RoundedRectangle(cornerRadius: 20))
                    Text("开发预览版 · 当前支持本机指令与截图文字搜索。天气、翻译、学习整理和自由多步对话正在接入。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Cassie")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .photos(let query): PhotoSearchView(query: query)
                case .schedule: ScheduleView()
                case .notes: NotesView()
                case .messages: MessageDraftView()
                case .connections: ConnectionsView()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                photos.refreshAuthorization()
                schedule.refresh()
                startFromShortcutIfNeeded()
            } else if phase == .background {
                speech.stop(submit: false)
                speech.silence()
                photos.pause()
            }
        }
        .onChange(of: route.startVoice) { _, value in
            if value { startFromShortcutIfNeeded() }
        }
        .task { startFromShortcutIfNeeded() }
        .alert("运行车辆解锁指令？", isPresented: $confirmUnlock) {
            Button("取消", role: .cancel) { }
            Button("确认运行") { Task { await runShortcut(tailgShortcut, vehicle: true) } }
        } message: { Text("将运行你配置的“\(tailgShortcut)”快捷指令。请确认它对应你要解锁的车辆。") }
    }

    private var voiceCard: some View {
        VStack(spacing: 16) {
            Button {
                if speech.isListening { speech.stop(submit: true) }
                else { Task { await beginVoice() } }
            } label: {
                Image(systemName: speech.isListening ? "stop.fill" : "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 80, height: 80)
                    .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading,
                                               endPoint: .bottomTrailing), in: Circle())
            }
            .disabled(speech.isStarting)
            .accessibilityLabel(speech.isListening ? "结束录音并提交" : "开始语音请求")
            Text(speech.isListening ? "正在听，点按结束并提交" : speech.isStarting ? "正在准备语音…" : "按下开始说话")
                .font(.headline)
            if speech.isListening { Text(speech.transcript).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(alignment: .bottom) {
                TextField("也可以在这里输入", text: $input, axis: .vertical)
                    .lineLimit(1...5).submitLabel(.send).onSubmit { submit(input) }
                Button { submit(input) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speech.isListening || speech.isStarting)
                    .accessibilityLabel("提交请求")
            }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }.padding(22).frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 24))
    }

    private func feature(_ title: String, _ subtitle: String, _ symbol: String, _ destination: Destination) -> some View {
        Button { path.append(destination) } label: {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.indigo)
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading).padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }

    private func submit(_ raw: String) {
        guard !speech.isListening, !speech.isStarting else { return }
        let text = raw.replacingOccurrences(of: #"^\s*[Cc]assie[，,：:\s]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = text
        matchCount = 0
        if ["截图", "照片", "相册", "找图"].contains(where: text.contains) {
            guard photos.canRead else {
                answer("请先在截图资料页授权相册访问，再扫描图片建立文字索引。")
                path.append(.photos(text)); return
            }
            let matches = PhotoSearch.matches(text, in: photos.records)
            lastSearch = text
            matchCount = matches.count
            if let best = matches.first {
                answer("找到相关截图。\(best.photo.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "日期未知")的截图中写着：\(best.excerpt)。你可以打开原图核对。")
            } else {
                answer("已索引的图片里没有找到文字匹配。请先扫描相册，或改用截图上出现过的词语。")
                path.append(.photos(text))
            }
        } else if ["下节", "下一节", "课表", "什么课"].contains(where: text.contains) {
            answer(schedule.nextClassAnswer())
        } else if text.contains("打开豆包") {
            guard !doubaoShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                answer("请先配置打开豆包的快捷指令名称。")
                path.append(.connections); return
            }
            Task { await runShortcut(doubaoShortcut, vehicle: false) }
        } else if text.contains("解锁"), text.contains("车") || text.contains("台铃") {
            guard !tailgShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                answer("请先连接台铃智能提供的车辆解锁快捷指令。")
                path.append(.connections); return
            }
            speech.silence(); confirmUnlock = true
        } else if text.hasPrefix("记一下") || text.hasPrefix("记住") || text.hasPrefix("帮我记") {
            let note = text.replacingOccurrences(of: #"^(记一下|记住|帮我记下|帮我记)[，,：:\s]*"#, with: "", options: .regularExpression)
            if notes.add(note) { answer("已记在本机备忘里：\(note)") }
            else { answer(notes.error ?? "请告诉我要记住的具体内容。") }
        } else if text.contains("备忘") || text.contains("我记了什么") || text.contains("昨天说") {
            let found = text.contains("昨天") ? notes.notes.filter { Calendar.current.isDateInYesterday($0.createdAt) } : notes.notes
            answer(found.isEmpty ? "没有找到对应的备忘。" : found.prefix(5).map(\.text).joined(separator: "；"))
        } else if text.contains("回复") || text.contains("消息") {
            answer("可以在消息草稿页编辑回复，并交给系统消息界面确认发送。")
            path.append(.messages)
        } else {
            answer("这一版可以查询课表、搜索截图文字、记备忘、打开豆包和启动已配置的台铃指令。自由对话与其他功能还在开发中。")
        }
    }

    private func answer(_ text: String) {
        reply = text
        if readReplies { speech.speak(text) }
    }

    private func runShortcut(_ name: String, vehicle: Bool) async {
        let opened = await ShortcutService.run(name: name)
        reply = opened
            ? (vehicle ? "已请求运行台铃指令；是否解锁成功，请以台铃智能和车辆反馈为准。" : "已请求运行打开豆包指令，请查看快捷指令的执行结果。")
            : "未能打开快捷指令，请检查配置与系统 App。"
    }

    private func beginVoice() async {
        await speech.start { text in input = text; submit(text) }
    }

    private func startFromShortcutIfNeeded() {
        guard route.startVoice, scenePhase == .active else { return }
        route.startVoice = false
        path = []
        Task { await beginVoice() }
    }

    private enum Destination: Hashable {
        case photos(String), schedule, notes, messages, connections
    }
}
