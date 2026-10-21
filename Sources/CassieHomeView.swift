import SwiftUI

@MainActor
struct CassieHomeView: View {
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var photos: PhotoIndex
    @EnvironmentObject private var notes: NoteStore
    @EnvironmentObject private var schedule: CalendarService
    @EnvironmentObject private var planner: DayPlanStore
    @EnvironmentObject private var tracker: ProductivityStore
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
    @State private var thinking = false

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
                    NavigationLink(value: Destination.brief) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("今天与下一步").font(.headline)
                            TimelineView(.periodic(from: Date(), by: 30)) { context in
                                Text(planner.nextStep(completed: tracker.completed(on: planner.draft.day), now: context.date))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text("\(notes.notes.filter { $0.processedAt == nil }.count)条记录待整理 · 查看每日简报")
                                .font(.caption).foregroundStyle(.indigo)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                            .background(.background, in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain)
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
                        feature("Dayplan", "安排今天的事情与路线", "list.bullet.clipboard", .dayplan)
                        feature("每日简报", "课表、下一步与截止事项", "sun.max", .brief)
                        feature("学习计时", "记录实际用时与进度", "timer", .focus)
                        feature("出门准备", "按计划核对要带的东西", "backpack", .packing)
                        feature("个人资料问答", "找截图、记录和课表原文", "doc.text.magnifyingglass", .personal(""))
                        feature("截图资料", "搜索文字，查看原图", "text.viewfinder", .photos(""))
                        feature("课表日程", "连接 Celechron 课表", "calendar", .schedule)
                        feature("随口收件箱", "先记住，再整理进计划", "tray", .notes)
                        feature("消息草稿", "编辑并交给系统发送", "message", .messages)
                        feature("自动提醒", "任务出发、上课出发与睡觉线", "bell.badge", .reminders)
                        feature("打开豆包", "配置快捷指令", "square.grid.2x2", .connections)
                        feature("台铃智能", "连接官方控车指令", "bicycle", .connections)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("试着这样说").font(.headline)
                        Text("“下一节课是什么”\n“找一下含考试日期的截图”\n“记一下明天带充电器”\n“我今天要去图书馆做卷子两小时”\n“打开豆包”\n其他任何问题会交给端侧模型（iOS 26 且开启 Apple Intelligence 时）")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        .background(.background, in: RoundedRectangle(cornerRadius: 20))
                    Text("开发预览版 · 清单提取和资料查询以本机规则为主，端侧 AI 结果也需核对后保存。天气、翻译仍待接入。")
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
                case .dayplan: DayPlanView()
                case .capture(let text): PlanCaptureView(text: text)
                case .brief: DailyBriefView()
                case .focus: FocusView()
                case .packing: PackingView()
                case .replan: ReplanView()
                case .reminders: ReminderSettingsView()
                case .personal(let query): PersonalSearchView(query: query)
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
            if thinking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("端侧模型思考中，数据不离开手机…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom) {
                TextField("也可以在这里输入", text: $input, axis: .vertical)
                    .lineLimit(1...5).submitLabel(.send).onSubmit { submit(input) }
                Button { submit(input) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speech.isListening || speech.isStarting || thinking)
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
        guard !speech.isListening, !speech.isStarting, !thinking else { return }
        let text = raw.replacingOccurrences(of: #"^\s*[Cc]assie[，,：:\s]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = text
        matchCount = 0
        if ["晚半小时", "推迟", "没做完", "重排", "重新安排", "计划有变"].contains(where: text.contains) {
            answer("请确认现在的地点、重新开始时间和还需多久。我会跳过已完成事项，保留其余时间限制后重新规划。")
            path.append(.replan)
        } else if ["下一步", "现在该干什么", "现在做什么", "每日简报", "今天概览"].contains(where: text.contains) {
            answer(planner.nextStep(completed: tracker.completed(on: planner.draft.day)))
            path.append(.brief)
        } else if text.contains("暂停计时") || text.contains("继续计时") {
            guard let active = tracker.data.active else { answer("当前没有正在计时的事项。"); return }
            let needsChange = text.contains("暂停") ? active.runningSince != nil : active.runningSince == nil
            if needsChange { tracker.pauseOrResume() }
            answer(tracker.error ?? (text.contains("暂停") ? "计时已暂停。" : "计时已继续。"))
        } else if text.contains("结束计时") || text.contains("停止计时") {
            guard tracker.data.active != nil else { answer("当前没有正在计时的事项。"); return }
            tracker.finish(); answer(tracker.error ?? "已记录这次用时，任务是否完成请在计划中确认。")
        } else if text.contains("计时") || text.contains("专注") {
            answer("选择计划中的事项或填写名称，即可开始计时。")
            path.append(.focus)
        } else if ["带什么", "出门准备", "出门清单"].contains(where: text.contains) {
            answer("打开了出门准备清单，请按实际需要核对。")
            path.append(.packing)
        } else if ["提醒", "睡觉线", "别睡太晚"].contains(where: text.contains) {
            answer("可以在自动提醒里开关任务出发、上课出发和睡觉线通知，全部在本机发送。")
            path.append(.reminders)
        } else if ["我今天要", "今天要做", "今天我要", "帮我安排：", "帮我安排，", "整理成计划"].contains(where: text.contains) {
            answer("先从这段话提取任务草稿，请逐项核对地点、时长和时间限制后加入计划。")
            path.append(.capture(text))
        } else if ["dayplan", "day plan", "安排今天", "规划今天", "今日计划", "制定日程"].contains(where: text.lowercased().contains) {
            answer("可直接说出清单提取草稿，也可以逐项填写后生成安排。")
            path.append(.dayplan)
        } else if ["找资料", "查资料", "个人资料", "哪张", "那张", "考试安排在哪"].contains(where: text.contains) {
            answer("我会检索已索引的照片、随口记录与所选课表原文，点开来源核对。")
            path.append(.personal(text))
        } else if ["截图", "照片", "相册", "找图"].contains(where: text.contains) {
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
        } else if text.contains("收件箱") || text.contains("整理记录") {
            answer("打开随口收件箱，可把记录整理进计划。")
            path.append(.notes)
        } else if text.contains("备忘") || text.contains("我记了什么") || text.contains("昨天说") {
            let found = text.contains("昨天") ? notes.notes.filter { Calendar.current.isDateInYesterday($0.createdAt) } : notes.notes
            answer(found.isEmpty ? "没有找到对应的备忘。" : found.prefix(5).map(\.text).joined(separator: "；"))
        } else if text.contains("回复") || text.contains("消息") {
            answer("可以在消息草稿页编辑回复，并交给系统消息界面确认发送。")
            path.append(.messages)
        } else {
            handleOpenQuestion(text)
        }
    }

    private func handleOpenQuestion(_ text: String) {
        guard #available(iOS 26.0, *), OnDeviceAssistant.isSupported else {
            if #available(iOS 26.0, *) {
                answer("自由对话需要端侧模型，当前不可用：\(OnDeviceAssistant.availabilityText)。也可以说“我今天要…”，或问“现在做什么”“今天带什么”。")
            } else {
                answer("可以说“我今天要…；然后…”，或问“现在做什么”“今天带什么”。也可以查课表、搜截图、记备忘。自由对话需要 iOS 26 与 Apple Intelligence。")
            }
            return
        }
        thinking = true
        let context = assistantContext()
        Task { @MainActor in
            var full = ""
            do {
                for try await partial in OnDeviceAssistant.shared.stream(text, context: context) {
                    full = partial
                    reply = partial
                }
                if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    full = "端侧模型没有返回内容，请换一种说法再试。"
                    reply = full
                }
                if readReplies { speech.speak(full) }
            } catch {
                answer("端侧模型暂时无法回答（\(error.localizedDescription)）。可以说“我今天要…”，或问“现在做什么”。")
            }
            thinking = false
        }
    }

    private func assistantContext() -> String {
        var parts: [String] = []
        parts.append("现在时间：" + Date().formatted(date: .abbreviated, time: .shortened))
        if Calendar.current.isDateInToday(planner.draft.day) {
            if planner.result != nil {
                parts.append("今天的 Dayplan 方案：\n" + planner.shareText)
            } else if !planner.draft.tasks.isEmpty {
                parts.append("今天清单（尚未生成方案）：" + planner.draft.tasks.map { "\($0.title)（\($0.duration)分钟）" }.joined(separator: "、"))
            }
            let done = tracker.completed(on: planner.draft.day)
            if !done.isEmpty {
                parts.append("已确认完成：" + planner.draft.tasks.filter { done.contains($0.id) }.map(\.title).joined(separator: "、"))
            }
        }
        if let next = schedule.events.first(where: { $0.start > Date() }) {
            parts.append("下一节课：\(next.title)，\(next.start.formatted(date: .abbreviated, time: .shortened))，地点\(next.location)")
        }
        let pendingNotes = notes.notes.filter { $0.processedAt == nil }.prefix(3).map(\.text)
        if !pendingNotes.isEmpty { parts.append("待整理记录：" + pendingNotes.joined(separator: "；")) }
        return parts.joined(separator: "\n")
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
        case photos(String), schedule, notes, messages, connections, dayplan
        case capture(String), brief, focus, packing, replan, personal(String), reminders
    }
}
