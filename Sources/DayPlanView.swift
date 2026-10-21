import MapKit
import SwiftUI

@MainActor
struct DayPlanView: View {
    @EnvironmentObject private var store: DayPlanStore
    @EnvironmentObject private var tracker: ProductivityStore
    @State private var editing: DayTask?
    @State private var adding = false
    @State private var choosingOrigin = false
    @State private var capturing = false

    var body: some View {
        List {
            Section("快速开始") {
                Button("说出或粘贴清单，提取草稿", systemImage: "mic.badge.plus") { capturing = true }
                NavigationLink("现在做什么与每日简报") { DailyBriefView() }
                NavigationLink("有变化，重排剩余事项") { ReplanView() }
                NavigationLink("学习计时") { FocusView() }
            }
            Section {
                Text("列出事情与地点，我来安排顺序")
                    .font(.headline)
                Text("先满足固定时间和截止时间，再按你选的目标比较顺序。吃饭、休息和必须先做的准备，也可以列成单独任务。")
                    .font(.footnote).foregroundStyle(.secondary)
                DatePicker("哪一天", selection: $store.draft.day, displayedComponents: .date)
                DayClockPicker("开始", minute: $store.draft.startMinute)
                DayClockPicker("最晚结束", minute: $store.draft.endMinute)
                Button { choosingOrigin = true } label: {
                    LabeledContent("出发地点", value: store.draft.origin?.name ?? "选择地图位置")
                }
                Picker("交通方式", selection: $store.draft.mode) {
                    ForEach(DayTravelMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("安排目标", selection: $store.draft.objective) {
                    ForEach(DayObjective.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper("每件事后留 \(store.draft.buffer) 分钟缓冲", value: $store.draft.buffer, in: 0...30, step: 5)
                Toggle("结束后回到出发地", isOn: $store.draft.returnToOrigin)
                if store.draft.mode != .ebike {
                    Toggle("联网查询地图通勤时间", isOn: $store.draft.useMaps)
                }
            } footer: {
                Text("地图时间按当天开始时间查询，不会持续更新交通和公交班次。电动车暂按距离粗估；地图查询失败的路段也会标为粗估。地点搜索和路线查询由 Apple 地图处理。")
            }.disabled(store.isGenerating)

            Section("今天要做的事 · \(store.draft.tasks.count)/8") {
                ForEach(store.draft.tasks) { task in
                    Button { editing = task } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.title).font(.headline).foregroundStyle(.primary)
                            Text("\(task.place?.name ?? "还未选择地点") · \(task.duration)分钟")
                                .foregroundStyle(.secondary)
                            if let fixed = task.fixedStart {
                                Text("固定 \(DayPlanEngine.clock(fixed)) 开始").font(.caption).foregroundStyle(.indigo)
                            } else {
                                if let early = task.earliestStart { Text("\(DayPlanEngine.clock(early)) 后开始").font(.caption) }
                                if let deadline = task.deadline { Text("\(DayPlanEngine.clock(deadline)) 前完成").font(.caption) }
                            }
                        }
                    }
                }.onDelete { offsets in
                    let removed = Set(offsets.map { store.draft.tasks[$0].id })
                    var updated = store.draft
                    updated.tasks.remove(atOffsets: offsets)
                    for index in updated.tasks.indices {
                        updated.tasks[index].prerequisiteIDs?.removeAll { removed.contains($0) }
                    }
                    store.draft = updated
                }
                Button("添加一件事", systemImage: "plus") { adding = true }
                    .disabled(store.draft.tasks.count >= 8)
            }.disabled(store.isGenerating)

            Section {
                if store.isGenerating {
                    ProgressView(store.progress)
                    Button("取消生成") { store.cancel() }
                } else {
                    Button("制定我的 Dayplan", systemImage: "wand.and.stars") { store.generate(excluding: tracker.completed(on: store.draft.day)) }
                }
                if let error = store.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            if let result = store.result {
                Section {
                    Text("共 \(result.stops.count) 件事 · 通勤约 \(result.travelMinutes) 分钟 · \(DayPlanEngine.clock(result.finish)) 结束")
                    if let other = store.alternative {
                        if other.travelMinutes == result.travelMinutes && other.finish == result.finish {
                            Text("两个目标得到相同的通勤时长与结束时间。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("另一方案：通勤约 \(other.travelMinutes) 分钟，\(DayPlanEngine.clock(other.finish)) 结束。可比较省路与省时间的取舍。")
                                .font(.footnote)
                            Button("切换查看另一方案") { store.swapPlans() }
                        }
                    }
                    if result.approximateLegs > 0 {
                        Text("其中 \(result.approximateLegs) 段通勤为距离粗估，未考虑真实道路。出发前请留足余量。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text("这是当前时间限制与通勤估计下的推荐方案，不包含未填写的营业时间、排队和临时变化。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("推荐安排") }
                ForEach(result.stops) { stop in
                    Section {
                        Label("\(DayPlanEngine.clock(stop.depart)) 出发 · 约 \(stop.travel.minutes) 分钟\(stop.travel.approximate ? "（粗估）" : "")", systemImage: "arrow.triangle.turn.up.right.diamond")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if stop.arrive < stop.start {
                            Text("\(DayPlanEngine.clock(stop.arrive)) 到达，预留 \(stop.start - stop.arrive) 分钟等待")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("\(DayPlanEngine.clock(stop.start))–\(DayPlanEngine.clock(stop.end)) \(stop.task.title)")
                            .font(.headline)
                        if let place = stop.task.place {
                            Text(place.name)
                            Button("在地图中查看地点") { DayPlanStore.mapItem(place).openInMaps() }
                        }
                    }
                }
                if let leg = result.returnLeg {
                    Section("返程") {
                        Text("\(DayPlanEngine.clock(result.returnDepart ?? result.finish)) 出发，\(DayPlanEngine.clock(result.finish)) 回到\(store.draft.origin?.name ?? "出发地")")
                        Text("约 \(leg.minutes) 分钟\(leg.approximate ? "（粗估）" : "")").foregroundStyle(.secondary)
                    }
                }
                Section { ShareLink("分享或复制我的安排", item: store.shareText) }
            }
            Section("完成进度 · \(store.draft.day.formatted(date: .abbreviated, time: .omitted))") {
                ForEach(store.draft.tasks) { task in
                    HStack {
                        Button {
                            tracker.toggleCompleted(task.id, day: store.draft.day)
                            store.publishResult(excluding: tracker.completed(on: store.draft.day))
                        } label: {
                            Image(systemName: tracker.completed(on: store.draft.day).contains(task.id) ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.borderless).disabled(store.isGenerating)
                        Text(task.title)
                            .strikethrough(tracker.completed(on: store.draft.day).contains(task.id))
                    }
                }
                if let error = tracker.error { Text(error).foregroundStyle(.red) }
                Text("完成状态由你确认。改动任务时间、地点或名称后，请重新生成方案。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Dayplan")
        .sheet(isPresented: $capturing) { PlanCaptureView(text: "") }
        .sheet(isPresented: $choosingOrigin) {
            DayPlacePicker(regionCenter: store.draft.origin) { store.draft.origin = $0 }
        }
        .sheet(isPresented: $adding) {
            DayTaskEditor(task: DayTask(), regionCenter: store.draft.origin, otherTasks: store.draft.tasks) { store.draft.tasks.append($0) }
        }
        .sheet(item: $editing) { task in
            DayTaskEditor(task: task, regionCenter: store.draft.origin, otherTasks: store.draft.tasks.filter { $0.id != task.id }) { updated in
                if let index = store.draft.tasks.firstIndex(where: { $0.id == updated.id }) { store.draft.tasks[index] = updated }
            }
        }
    }
}

@MainActor
struct DayTaskEditor: View {
    @EnvironmentObject private var tracker: ProductivityStore
    @EnvironmentObject private var photos: PhotoIndex
    @Environment(\.dismiss) private var dismiss
    @State var task: DayTask
    let regionCenter: DayPlace?
    let otherTasks: [DayTask]
    let save: (DayTask) -> Void
    @State private var choosePlace = false
    @State private var sourcePhoto: IndexedPhoto?
    var body: some View {
        NavigationStack {
            Form {
                Section("这件事") {
                    TextField("例如：去图书馆还书", text: $task.title)
                    Button { choosePlace = true } label: { LabeledContent("地点", value: task.place?.name ?? "选择地图位置") }
                    Stepper("预计用时 \(task.duration) 分钟", value: $task.duration, in: 5...720, step: 5)
                    if let recommendation = tracker.recommendedMinutes(for: task.title) {
                        Button("参考同名事项最近平均用时：\(recommendation)分钟") { task.duration = min(720, recommendation) }
                    }
                    if let source = task.sourceText { Text("来源：" + source).font(.caption).textSelection(.enabled) }
                    if let id = task.sourcePhotoID {
                        if let photo = photos.records.first(where: { $0.id == id }), photos.canRead {
                            Button("查看来源截图") { sourcePhoto = photo }
                        } else { Text("来源图片未索引或不在当前授权范围；保留的文字副本可在上方核对。 ").font(.caption) }
                    }
                }
                Section {
                    Toggle("有固定开始时间", isOn: Binding(get: { task.fixedStart != nil }, set: { task.fixedStart = $0 ? 14 * 60 : nil }))
                    if task.fixedStart != nil {
                        DayClockPicker("固定开始", minute: Binding(get: { task.fixedStart ?? 14 * 60 }, set: { task.fixedStart = $0 }))
                    } else {
                        Toggle("限制最早开始时间", isOn: Binding(get: { task.earliestStart != nil }, set: { task.earliestStart = $0 ? 9 * 60 : nil }))
                        if task.earliestStart != nil {
                            DayClockPicker("最早开始", minute: Binding(get: { task.earliestStart ?? 9 * 60 }, set: { task.earliestStart = $0 }))
                        }
                        Toggle("有完成截止时间", isOn: Binding(get: { task.deadline != nil }, set: { task.deadline = $0 ? 18 * 60 : nil }))
                        if task.deadline != nil {
                            DayClockPicker("必须完成于", minute: Binding(get: { task.deadline ?? 18 * 60 }, set: { task.deadline = $0 }))
                        }
                    }
                } footer: { Text("营业时间可填写为最早开始与完成截止时间。固定安排会严格按指定时间开始。") }
                if !otherTasks.isEmpty {
                    Section("这些事必须先完成") {
                        ForEach(otherTasks) { prior in
                            Toggle(prior.title, isOn: Binding(get: {
                                (task.prerequisiteIDs ?? []).contains(prior.id)
                            }, set: { enabled in
                                var ids = task.prerequisiteIDs ?? []
                                ids.removeAll { $0 == prior.id }
                                if enabled { ids.append(prior.id) }
                                task.prerequisiteIDs = ids
                            }))
                        }
                    }
                }
                if !(task.prerequisiteIDs ?? []).isEmpty {
                    Button("清除这件事的所有先后关系") { task.prerequisiteIDs = nil }
                }
            }
            .navigationTitle("安排一件事")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(task); dismiss() }
                        .disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || task.place == nil)
                }
            }
            .sheet(isPresented: $choosePlace) { DayPlacePicker(regionCenter: regionCenter) { task.place = $0 } }
            .sheet(item: $sourcePhoto) { PhotoDetailView(photo: $0) }
        }
    }
}

@MainActor
struct DayPlacePicker: View {
    let regionCenter: DayPlace?
    let choose: (DayPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("城市、校区、楼宇或完整地址", text: $query).submitLabel(.search).onSubmit { Task { await search() } }
                    Button("搜索地点") { Task { await search() } }.disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if searching { ProgressView() }
                    if let error { Text(error).foregroundStyle(.secondary) }
                } footer: { Text("请核对城市和具体位置。相同名称可能有多个分店或校区。") }
                ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                    Button {
                        let coordinate = item.placemark.coordinate
                        choose(DayPlace(name: item.name ?? query, address: item.placemark.title ?? "",
                                        latitude: coordinate.latitude, longitude: coordinate.longitude))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name ?? query).foregroundStyle(.primary)
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("确认地图位置")
            .toolbar { Button("取消") { dismiss() } }
        }
    }
    private func search() async {
        guard !searching else { return }
        searching = true
        error = nil
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let center = regionCenter {
            request.region = MKCoordinateRegion(center: .init(latitude: center.latitude, longitude: center.longitude), latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        do {
            results = try await MKLocalSearch(request: request).start().mapItems
            if results.isEmpty { error = "没有找到位置，试试加上城市或完整地址。" }
        } catch { results = []; self.error = "地点搜索暂时不可用：\(error.localizedDescription)" }
    }
}

struct DayClockPicker: View {
    let title: String
    @Binding var minute: Int
    init(_ title: String, minute: Binding<Int>) { self.title = title; _minute = minute }
    var body: some View {
        DatePicker(title, selection: Binding(get: {
            Calendar.current.date(byAdding: .minute, value: minute, to: Calendar.current.startOfDay(for: Date()))!
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
    }
}
