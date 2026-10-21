import SwiftUI

@MainActor
struct PlanCaptureView: View {
    @EnvironmentObject private var planner: DayPlanStore
    @EnvironmentObject private var speech: SpeechService
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    var photoID: String? = nil
    var onImported: (() -> Void)? = nil
    @State private var candidates: [CaptureCandidate] = []
    @State private var editing: DayTask?
    @State private var message: String?
    @State private var aiWorking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $text).frame(minHeight: 150)
                    Button(speech.isListening ? "结束录音" : "说出今天要做的事", systemImage: "mic") {
                        if speech.isListening { speech.stop(submit: true) }
                        else { Task { await speech.start { text = $0; candidates = [] } } }
                    }.disabled(speech.isStarting)
                    if speech.isListening { Text(speech.transcript).foregroundStyle(.secondary) }
                    if let error = speech.error { Text(error).foregroundStyle(.red) }
                    Button("提取待确认草稿") { candidates = PlanCapture.candidates(text, photoID: photoID); message = nil }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speech.isListening || aiWorking)
                    aiExtractButton
                } header: { Text(photoID == nil ? "一句话或每行一件事" : "截图文字转待办") }
                  footer: { Text("本机规则提取，以换行、句号、分号或“然后”分段。复杂表述可改用端侧 AI 提取；两种结果都需逐项核对，不会自动解答题目。") }
                Section {
                    LabeledContent("加入哪天的计划", value: planner.draft.day.formatted(date: .abbreviated, time: .omitted))
                    Text("如需安排其他日期，请先在 Dayplan 修改日期。这里追加任务，不覆盖已有清单。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !candidates.isEmpty {
                    Section("逐项确认，可左滑删除无关文字") {
                        ForEach(candidates) { candidate in
                            Button { editing = candidate.task } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(candidate.task.title, systemImage: candidate.confirmed ? "checkmark.circle.fill" : "pencil.circle")
                                    Text(candidate.confirmed ? "已确认 · \(candidate.task.place?.name ?? "") · \(candidate.task.duration)分钟" : candidate.hint)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.onDelete { candidates.remove(atOffsets: $0) }
                    }
                    Section {
                        Button("将全部已核对事项加入计划") { importTasks() }
                            .disabled(candidates.isEmpty || candidates.contains { !$0.confirmed } || planner.isGenerating)
                        Text("请逐项打开、确认地点与时长后保存。最多保留8件事，需先删除无关文字。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let message { Section { Text(message).foregroundStyle(.red) } }
            }
            .navigationTitle("清单草稿")
            .toolbar { Button("关闭") { dismiss() } }
            .sheet(item: $editing) { task in
                DayTaskEditor(task: task, regionCenter: planner.draft.origin,
                              otherTasks: planner.draft.tasks + candidates.map(\.task).filter { $0.id != task.id }) { updated in
                    if let index = candidates.firstIndex(where: { $0.id == updated.id }) {
                        candidates[index].task = updated; candidates[index].confirmed = true
                    }
                }
            }
            .onDisappear { if speech.isListening { speech.stop(submit: false) } }
        }
    }

    @ViewBuilder
    private var aiExtractButton: some View {
        if #available(iOS 26.0, *) {
            if OnDeviceAssistant.isSupported {
                Button(aiWorking ? "端侧 AI 提取中…" : "用端侧 AI 提取（复杂表述）", systemImage: "sparkles") {
                    aiWorking = true
                    message = nil
                    let source = text
                    Task { @MainActor in
                        do {
                            let extracted = try await OnDeviceAssistant.shared.extractTasks(from: source)
                            candidates = OnDeviceAssistant.shared.candidates(from: extracted, sourceText: source, photoID: photoID)
                            if candidates.isEmpty { message = "端侧模型没有提取到任务，请修改文字或改用规则提取。" }
                        } catch {
                            message = "端侧模型提取失败（\(error.localizedDescription)），可改用规则提取。"
                        }
                        aiWorking = false
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speech.isListening || aiWorking)
            } else {
                Text("端侧 AI 当前不可用：\(OnDeviceAssistant.availabilityText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func importTasks() {
        guard !planner.isGenerating else { message = "请先结束正在生成的方案。"; return }
        guard planner.draft.tasks.count + candidates.count <= 8 else { message = "加入后超过8件事，请先精简清单。"; return }
        var updated = planner.draft
        updated.tasks += candidates.map(\.task)
        do {
            // Validate tasks before import; origin can still be chosen later.
            var validation = updated
            validation.origin = updated.origin ?? candidates.first?.task.place
            try DayPlanEngine.validate(validation)
            try LocalStore.save(updated, to: "dayplan.json")
            planner.draft = updated
            onImported?()
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

@MainActor
struct DailyBriefView: View {
    @EnvironmentObject private var planner: DayPlanStore
    @EnvironmentObject private var tracker: ProductivityStore
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var notes: NoteStore

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            List {
                Section("现在与下一步") {
                    Text(planner.nextStep(completed: tracker.completed(on: planner.draft.day), now: context.date))
                    NavigationLink("打开计划与进度") { DayPlanView() }
                    NavigationLink("安排有变，重排剩余事项") { ReplanView() }
                }
                Section("今天剩余的课程") {
                    if !calendar.hasAccess || calendar.selectedIDs.isEmpty {
                        NavigationLink("连接并选择课表日历") { ScheduleView() }
                    } else {
                        let events = calendar.events.filter { Calendar.current.isDateInToday($0.start) && $0.end > context.date }
                        ForEach(events) { event in
                            VStack(alignment: .leading) {
                                Text(event.title).font(.headline)
                                Text("\(event.start.formatted(date: .omitted, time: .shortened)) · \(event.location)").font(.subheadline)
                                if Calendar.current.isDateInToday(planner.draft.day),
                                   let result = planner.result,
                                   result.stops.contains(where: { stop in
                                       let start = Calendar.current.date(byAdding: .minute, value: stop.start, to: Calendar.current.startOfDay(for: planner.draft.day))!
                                       let end = Calendar.current.date(byAdding: .minute, value: stop.end, to: Calendar.current.startOfDay(for: planner.draft.day))!
                                       return !tracker.completed(on: planner.draft.day).contains(stop.id) && start < event.end && end > event.start
                                   }) {
                                    Text("与 Dayplan 任务有时间重叠，请调整清单。课程尚未自动参与排程。")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        if events.isEmpty { Text("所选日历里今天没有剩余课程。") }
                    }
                }
                Section("计划中的截止事项") {
                    if !Calendar.current.isDateInToday(planner.draft.day) { Text("当前 Dayplan 不是今天。") }
                    else {
                        let tasks = planner.draft.tasks.filter { $0.deadline != nil && !tracker.completed(on: planner.draft.day).contains($0.id) }
                        ForEach(tasks) { task in Text("\(DayPlanEngine.clock(task.deadline!)) 前 · \(task.title)") }
                        if tasks.isEmpty { Text("未填写待完成的截止事项。") }
                    }
                }
                Section("收件箱与出门准备") {
                    Text("\(notes.notes.filter { $0.processedAt == nil }.count) 条随口记录待整理")
                    NavigationLink("整理随口收件箱") { NotesView() }
                    NavigationLink("检查今天要带什么") { PackingView() }
                    NavigationLink("学习计时与用时记录") { FocusView() }
                }
            }
        }
        .navigationTitle("每日简报")
        .onAppear { calendar.refresh() }
        .refreshable { calendar.refresh() }
    }
}

@MainActor
struct FocusView: View {
    @EnvironmentObject private var tracker: ProductivityStore
    @EnvironmentObject private var planner: DayPlanStore
    @State private var title = ""
    @State private var expected = 30
    @State private var selectedID: UUID?

    var body: some View {
        List {
            if let session = tracker.data.active {
                Section("正在计时 · \(session.title)") {
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        let elapsed = Int(session.elapsed(at: context.date))
                        Text(String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60))
                            .font(.largeTitle.monospacedDigit())
                        Text("预计\(session.expectedMinutes)分钟 · \(session.runningSince == nil ? "已暂停" : "进行中")")
                    }
                    Button(session.runningSince == nil ? "继续" : "暂停") { tracker.pauseOrResume() }
                    Button("结束并记录用时") { tracker.finish() }
                    Text("结束计时不会自动把任务标为完成。锁屏或切到其他 App 后按实际经过时间计算；主动暂停可排除休息。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("开始学习或工作") {
                    TextField("例如：微积分测试卷", text: $title)
                    Stepper("预计\(expected)分钟", value: $expected, in: 5...720, step: 5)
                    if let recommendation = tracker.recommendedMinutes(for: title) {
                        Button("采用同名事项最近记录均值：\(recommendation)分钟") { expected = min(720, recommendation) }
                    }
                    Button("开始计时") { tracker.start(title: title, expected: expected, taskID: selectedID) }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("或选择当前计划的事项") {
                    ForEach(planner.draft.tasks.filter { !tracker.completed(on: planner.draft.day).contains($0.id) }) { task in
                        Button(task.title) { title = task.title; expected = task.duration; selectedID = task.id }
                    }
                }
            }
            if let error = tracker.error { Section { Text(error).foregroundStyle(.red) } }
            Section("历史记录 · 左滑删除") {
                ForEach(tracker.data.sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title)
                        Text("预计\(session.expectedMinutes)分钟，实际\(Int(ceil(session.seconds / 60)))分钟 · \(session.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.onDelete(perform: tracker.removeHistory)
                if tracker.data.sessions.isEmpty { Text("尚无完成的计时记录。") }
            }
        }.navigationTitle("学习与工作计时")
    }
}

@MainActor
struct ReplanView: View {
    @EnvironmentObject private var planner: DayPlanStore
    @EnvironmentObject private var tracker: ProductivityStore
    @State private var minute = 0
    @State private var origin: DayPlace?
    @State private var choosingOrigin = false
    @State private var taskID: UUID?
    @State private var remaining = 30
    @State private var relaxSelectedFixed = false
    @State private var submitted = false

    var body: some View {
        List {
            Section {
                Text("先在计划页标记已完成事项。重新规划会跳过这些事项，保留其他任务的固定时间、截止时间和当天最晚结束时间。")
                DayClockPicker("从几点重新安排", minute: $minute)
                Button(origin?.name ?? "确认现在的出发地点") { choosingOrigin = true }
                Picker("哪件事还没做完", selection: $taskID) {
                    Text("不修改任务时长").tag(UUID?.none)
                    ForEach(planner.draft.tasks.filter { !tracker.completed(on: planner.draft.day).contains($0.id) }) { task in
                        Text(task.title).tag(Optional(task.id))
                    }
                }
                if taskID != nil {
                    Stepper("还需\(remaining)分钟", value: $remaining, in: 5...720, step: 5)
                    Toggle("允许调整这件事原来的固定开始时间", isOn: $relaxSelectedFixed)
                }
                Text("请按实际位置选择出发点。课程冲突可在每日简报核对，尚不会自动转成排程限制。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("按以上信息重排剩余事项") {
                    planner.draft.origin = origin
                    planner.draft.startMinute = minute
                    if let index = planner.draft.tasks.firstIndex(where: { $0.id == taskID }) {
                        planner.draft.tasks[index].duration = remaining
                        if relaxSelectedFixed { planner.draft.tasks[index].fixedStart = nil }
                    }
                    planner.generate(excluding: tracker.completed(on: planner.draft.day))
                    submitted = true
                }.disabled(origin == nil || planner.isGenerating)
            } header: { Text(planner.draft.day.formatted(date: .abbreviated, time: .omitted)) }
            if planner.isGenerating { Section { ProgressView(planner.progress); Button("取消") { planner.cancel() } } }
            if let error = planner.error { Section { Text(error).foregroundStyle(.red) } }
            if submitted, planner.result != nil { Section { NavigationLink("查看更新后的计划") { DayPlanView() } } }
        }
        .navigationTitle("计划有变化")
        .onAppear {
            if Calendar.current.isDateInToday(planner.draft.day) {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
                minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            } else { minute = planner.draft.startMinute }
        }
        .sheet(isPresented: $choosingOrigin) { DayPlacePicker(regionCenter: planner.draft.origin) { origin = $0 } }
    }
}

@MainActor
struct PackingView: View {
    @EnvironmentObject private var tracker: ProductivityStore
    @EnvironmentObject private var planner: DayPlanStore
    @EnvironmentObject private var calendar: CalendarService
    @State private var custom = ""
    private var suggestions: [String] {
        let text = planner.draft.tasks.map(\.title).joined(separator: " ")
        var items = ["手机", "校园卡", "宿舍钥匙"]
        if text.contains("图书馆") || text.contains("电脑") || text.contains("学习") || text.contains("卷") {
            items += ["所需书本、试卷与笔", "电脑及充电器（按需）"]
        }
        if planner.draft.mode == .ebike { items += ["头盔", "确认车辆电量和充电位置"] }
        if text.contains("提交") || text.contains("交材料") || text.contains("办") { items.append("核对待交材料与证件") }
        if calendar.events.contains(where: { Calendar.current.isDate($0.start, inSameDayAs: planner.draft.day) }) {
            items.append("当天课程的教材与用品")
        }
        return items
    }
    var body: some View {
        List {
            Section {
                ForEach(suggestions, id: \.self) { label in item(label) }
            } header: { Text(planner.draft.day.formatted(date: .abbreviated, time: .omitted)) }
              footer: { Text("根据任务关键词和所选课表生成参考清单，请按需勾选。勾选状态按计划日期保存；没有读取天气或判断物品是否真的带齐。") }
            Section("自己补充") {
                TextField("还需要带什么", text: $custom)
                Button("加入清单") { tracker.addPacking(custom); custom = "" }
                ForEach(tracker.data.customPacking, id: \.self) { label in item(label) }
                    .onDelete { offsets in
                        let labels = offsets.map { tracker.data.customPacking[$0] }
                        labels.forEach { tracker.removePacking($0) }
                    }
            }
            if let error = tracker.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("出门准备").onAppear { calendar.refresh() }
    }
    private func item(_ label: String) -> some View {
        Toggle(label, isOn: Binding(get: { tracker.packingChecked(label, day: planner.draft.day) },
                                   set: { tracker.setPacking(label, checked: $0, day: planner.draft.day) }))
    }
}

@MainActor
struct PersonalSearchView: View {
    @EnvironmentObject private var photos: PhotoIndex
    @EnvironmentObject private var notes: NoteStore
    @EnvironmentObject private var calendar: CalendarService
    @State var query: String = ""
    @State private var selected: IndexedPhoto?
    private var noteMatches: [PhotoMatch] {
        PhotoSearch.matches(query, in: notes.notes.map {
            IndexedPhoto(id: $0.id.uuidString, createdAt: $0.createdAt, modifiedAt: nil, text: $0.text, isScreenshot: false)
        })
    }
    var body: some View {
        List {
            Section {
                Text("从已授权并索引的照片、随口记录和所选课表中找原文。当前为文字检索，不会把片段推断为已确认事实。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !photos.canRead { NavigationLink("先授权并索引照片") { PhotoSearchView() } }
            }
            Section("截图原文与来源") {
                ForEach(PhotoSearch.matches(query, in: photos.records)) { match in
                    Button { selected = match.photo } label: {
                        VStack(alignment: .leading) {
                            Text(match.excerpt).foregroundStyle(.primary)
                            Text("\(match.photo.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "日期未知") · 打开原图核对")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("随口记录原文") {
                ForEach(noteMatches) { match in
                    VStack(alignment: .leading) {
                        Text(match.photo.text).textSelection(.enabled)
                        Text(match.photo.createdAt?.formatted() ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("所选课表") {
                ForEach(calendar.events.filter { !query.isEmpty && ($0.title.contains(query) || $0.location.contains(query)) }) { event in
                    Text("\(event.title) · \(event.start.formatted()) · \(event.location)")
                }
                if query.isEmpty { Text("输入问题或关键词开始搜索。") }
            }
        }.navigationTitle("个人资料问答")
            .searchable(text: $query, prompt: "考试、课程名、地址或关键词")
            .sheet(item: $selected) { PhotoDetailView(photo: $0) }
            .onAppear { photos.refreshAuthorization(); calendar.refresh() }
    }
}
