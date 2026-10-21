import MapKit
import SwiftUI

@MainActor
final class DayPlanStore: ObservableObject {
    @Published var draft: DayPlanDraft {
        didSet {
            result = nil
            alternative = nil
            try? LocalStore.remove("dayplan-result.json")
            do { try LocalStore.save(draft, to: "dayplan.json") }
            catch { self.error = "日程未能保存：\(error.localizedDescription)" }
            publishResult()
        }
    }
    @Published private(set) var result: DayPlanResult?
    @Published private(set) var alternative: DayPlanResult?
    @Published private(set) var isGenerating = false
    @Published private(set) var progress = ""
    @Published var error: String?
    private var generation: Task<Void, Never>?

    init() {
        do { draft = try LocalStore.load(DayPlanDraft.self, from: "dayplan.json") }
        catch let problem as CocoaError where problem.code == .fileReadNoSuchFile { draft = DayPlanDraft() }
        catch { draft = DayPlanDraft(); self.error = "暂时无法读取上次日程：\(error.localizedDescription)" }
        if let archive = try? LocalStore.load(SavedDayPlan.self, from: "dayplan-result.json"), archive.draft == draft {
            result = archive.result
            alternative = archive.alternative
        }
    }

    func generate(excluding completed: Set<UUID> = []) {
        guard !isGenerating else { return }
        error = nil
        result = nil
        alternative = nil
        let original = draft
        var input = original
        input.tasks = original.tasks.filter { !completed.contains($0.id) }.map { item in
            var remaining = item
            remaining.prerequisiteIDs = item.prerequisiteIDs?.filter { !completed.contains($0) }
            return remaining
        }
        if input.tasks.isEmpty { error = "清单为空或全部完成，无需重新规划。"; return }
        do { try DayPlanEngine.validate(input) }
        catch { self.error = error.localizedDescription; return }
        isGenerating = true
        generation = Task {
            defer { isGenerating = false; generation = nil }
            do {
                let places = [input.origin!] + input.tasks.map { $0.place! }
                let size = places.count
                var matrix = (0..<size).map { from in
                    (0..<size).map { to in DayPlanEngine.roughLeg(from: places[from], to: places[to], mode: input.mode) }
                }
                if input.useMaps, input.mode != .ebike {
                    let total = size * (size - 1)
                    var completed = 0
                    let departure = Calendar.current.date(byAdding: .minute, value: input.startMinute,
                                                         to: Calendar.current.startOfDay(for: input.day))!
                    // Sequential requests avoid a burst that could throttle MapKit.
                    for from in 0..<size {
                        for to in 0..<size where from != to {
                            try Task.checkCancellation()
                            completed += 1
                            progress = "查询地图通勤时间 \(completed) / \(total)"
                            if matrix[from][to].minutes == 0 { continue }
                            do {
                                let request = MKDirections.Request()
                                request.source = Self.mapItem(places[from])
                                request.destination = Self.mapItem(places[to])
                                request.departureDate = departure
                                switch input.mode {
                                case .walking: request.transportType = .walking
                                case .driving: request.transportType = .automobile
                                case .transit: request.transportType = .transit
                                case .ebike: break
                                }
                                let response = try await MKDirections(request: request).calculateETA()
                                try Task.checkCancellation()
                                guard response.expectedTravelTime.isFinite, response.expectedTravelTime >= 0 else { continue }
                                matrix[from][to] = DayLeg(minutes: max(1, Int(ceil(response.expectedTravelTime / 60))), approximate: false)
                            } catch is CancellationError { throw CancellationError() }
                            catch { /* Keep the clearly labelled distance estimate for this leg. */ }
                        }
                    }
                }
                progress = "比较可行顺序…"
                let routes = matrix
                let computed = try await Task.detached(priority: .userInitiated) {
                    var primary = input
                    if primary.objective == .balanced { primary.objective = .lessTravel }
                    let recommended = try DayPlanEngine.solve(primary, matrix: routes)
                    var other: DayPlanResult?
                    if input.objective == .balanced {
                        primary.objective = .earlierFinish
                        other = try DayPlanEngine.solve(primary, matrix: routes)
                    }
                    return (recommended, other)
                }.value
                try Task.checkCancellation()
                guard original == draft else { progress = "清单已变化，请重新生成"; return }
                result = computed.0
                alternative = computed.1
                saveResult()
                progress = "安排完成"
            } catch is CancellationError { progress = "已取消生成" }
            catch { self.error = error.localizedDescription; progress = "请调整清单" }
        }
    }

    func cancel() { generation?.cancel() }

    func swapPlans() {
        guard let other = alternative, let current = result else { return }
        result = other
        alternative = current
        saveResult()
    }

    private func saveResult() {
        guard let result else { return }
        do { try LocalStore.save(SavedDayPlan(draft: draft, result: result, alternative: alternative), to: "dayplan-result.json") }
        catch { self.error = "方案未能保存：\(error.localizedDescription)" }
        publishResult()
    }

    func publishResult(excluding completed: Set<UUID> = []) {
        var userInfo: [AnyHashable: Any] = ["day": draft.day, "completed": Array(completed)]
        if let result { userInfo["result"] = result }
        NotificationCenter.default.post(name: .dayPlanChanged, object: nil, userInfo: userInfo)
    }

    func nextStep(completed: Set<UUID>, now: Date = Date()) -> String {
        guard Calendar.current.isDate(draft.day, inSameDayAs: now) else { return "当前计划不是今天，请先切换日期。" }
        guard let result else { return "还没有可用方案。请先在 Dayplan 确认清单并生成。" }
        let pending = result.stops.filter { !completed.contains($0.id) }
        guard let stop = pending.first else { return "今天计划里的任务都完成了。" }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let prefix = minute < stop.depart ? "下一步安排" : minute < stop.start ? "接下来去" : minute <= stop.end ? "现在的安排" : "有任务尚未完成，原时间已过"
        let countdown = minute < stop.depart ? "距计划出发还有\(stop.depart - minute)分钟。" : minute >= stop.start && minute <= stop.end ? "按计划剩余\(stop.end - minute)分钟。" : ""
        let following = pending.dropFirst().first.map { "之后：\($0.task.title)。" } ?? "这是最后一项待完成任务。"
        return "\(prefix)：\(stop.task.title)，地点\(stop.task.place?.name ?? "待确认")，计划\(DayPlanEngine.clock(stop.start))至\(DayPlanEngine.clock(stop.end))。\(countdown)\(minute > stop.end ? "请确认进度或重新规划后续。" : "")\(following)"
    }

    static func mapItem(_ place: DayPlace) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: place.latitude, longitude: place.longitude)))
        item.name = place.name
        return item
    }

    var shareText: String {
        guard let result else { return "" }
        var lines = ["Cassie Dayplan · \(draft.day.formatted(date: .abbreviated, time: .omitted))",
                     "出发：\(draft.origin?.name ?? "") · \(DayPlanEngine.clock(draft.startMinute)) · \(draft.mode.rawValue)"]
        for stop in result.stops {
            lines.append("\(DayPlanEngine.clock(stop.start))–\(DayPlanEngine.clock(stop.end)) \(stop.task.title) · \(stop.task.place?.name ?? "")（通勤约\(stop.travel.minutes)分钟）")
        }
        if draft.returnToOrigin { lines.append("\(DayPlanEngine.clock(result.finish)) 返回出发地") }
        lines.append("通勤共约\(result.travelMinutes)分钟；\(result.approximateLegs)段使用距离粗估。实际路况和营业时间请核对。")
        return lines.joined(separator: "\n")
    }
}

private struct SavedDayPlan: Codable {
    let draft: DayPlanDraft
    let result: DayPlanResult
    var alternative: DayPlanResult?
}
