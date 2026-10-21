import Foundation

struct DayPlace: Codable, Hashable, Identifiable {
    var id: String { "\(latitude),\(longitude)" }
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
}

enum DayTravelMode: String, Codable, CaseIterable, Identifiable {
    case walking = "步行", ebike = "电动车", transit = "公交地铁", driving = "驾车"
    var id: String { rawValue }
}

enum DayObjective: String, Codable, CaseIterable, Identifiable {
    case balanced = "同时比较两个目标"
    case lessTravel = "尽量少跑路", earlierFinish = "尽量早点做完"
    var id: String { rawValue }
}

struct DayTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var place: DayPlace?
    var duration = 30
    var fixedStart: Int?
    var earliestStart: Int?
    var deadline: Int?
    var prerequisiteIDs: [UUID]?
}

struct DayPlanDraft: Codable, Equatable {
    var day = Calendar.current.startOfDay(for: Date())
    var startMinute = 9 * 60
    var endMinute = 20 * 60
    var origin: DayPlace?
    var mode = DayTravelMode.walking
    var objective = DayObjective.balanced
    var buffer = 5
    var returnToOrigin = false
    var useMaps = true
    var tasks: [DayTask] = []
}

struct DayLeg: Equatable {
    var minutes: Int
    var approximate: Bool
}

struct DayPlanStop: Identifiable, Equatable {
    let task: DayTask
    let depart: Int
    let arrive: Int
    let start: Int
    let end: Int
    let travel: DayLeg
    var id: UUID { task.id }
}

struct DayPlanResult: Equatable {
    let stops: [DayPlanStop]
    let finish: Int
    let travelMinutes: Int
    let returnLeg: DayLeg?
    let returnDepart: Int?
    let approximateLegs: Int
}

enum DayPlanError: LocalizedError {
    case invalid(String), impossible(String)
    var errorDescription: String? {
        switch self { case .invalid(let text), .impossible(let text): return text }
    }
}

enum DayPlanEngine {
    static func validate(_ draft: DayPlanDraft) throws {
        guard (1...8).contains(draft.tasks.count) else {
            throw DayPlanError.invalid("请添加 1 到 8 件事。第一版会比较全部可行顺序。")
        }
        guard draft.origin != nil, draft.tasks.allSatisfy({ $0.place != nil }) else {
            throw DayPlanError.invalid("请先确认出发地点和每件事的地图位置。")
        }
        let places = [draft.origin!] + draft.tasks.map { $0.place! }
        guard places.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite && (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }) else {
            throw DayPlanError.invalid("地点坐标无效，请重新选择地图位置。")
        }
        guard draft.startMinute >= 0, draft.endMinute <= 1440,
              draft.startMinute < draft.endMinute, (0...60).contains(draft.buffer) else {
            throw DayPlanError.invalid("请检查当天的开始、结束时间与缓冲时长。")
        }
        guard Set(draft.tasks.map(\.id)).count == draft.tasks.count else {
            throw DayPlanError.invalid("任务编号重复，请重新添加对应事项。")
        }
        for task in draft.tasks {
            guard (task.prerequisiteIDs ?? []).allSatisfy({ id in id != task.id && draft.tasks.contains(where: { $0.id == id }) }) else {
                throw DayPlanError.invalid("“\(task.title)”依赖的事项已删除或无效，请重新选择先做的事。")
            }
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...720).contains(task.duration) else {
                throw DayPlanError.invalid("每件事都需要名称和 1 到 720 分钟的预计时长。")
            }
            let earliest = task.fixedStart ?? task.earliestStart ?? draft.startMinute
            let latest = task.fixedStart.map { $0 + task.duration } ?? task.deadline ?? draft.endMinute
            guard earliest >= 0, latest <= 1440, earliest + task.duration <= latest else {
                throw DayPlanError.invalid("“\(task.title)”的时间限制与预计时长冲突。")
            }
        }
    }

    // Matrix node 0 is the origin; nodes 1...n correspond to task indices.
    // Exhaustive search is bounded to eight tasks; all time constraints are hard.
    static func solve(_ draft: DayPlanDraft, matrix: [[DayLeg]]) throws -> DayPlanResult {
        try validate(draft)
        let count = draft.tasks.count
        guard matrix.count == count + 1,
              matrix.allSatisfy({ $0.count == count + 1 && $0.allSatisfy({ $0.minutes >= 0 }) }) else {
            throw DayPlanError.invalid("通勤时间数据不完整，请重新生成方案。")
        }
        var best: DayPlanResult?

        func preferred(_ candidate: DayPlanResult, over old: DayPlanResult) -> Bool {
            if draft.objective == .lessTravel {
                return candidate.travelMinutes == old.travelMinutes
                    ? candidate.finish < old.finish : candidate.travelMinutes < old.travelMinutes
            }
            return candidate.finish == old.finish
                ? candidate.travelMinutes < old.travelMinutes : candidate.finish < old.finish
        }

        func visit(node: Int, time: Int, used: Int, stops: [DayPlanStop], travel: Int, approximate: Int) {
            if let best {
                if draft.objective == .lessTravel && travel > best.travelMinutes { return }
                if draft.objective == .earlierFinish && time > best.finish { return }
            }
            if stops.count == count {
                let leg = draft.returnToOrigin ? matrix[node][0] : nil
                let depart = leg.map { _ in time + draft.buffer }
                let end = depart.map { $0 + (leg?.minutes ?? 0) } ?? time
                guard end <= draft.endMinute else { return }
                let candidate = DayPlanResult(stops: stops, finish: end,
                    travelMinutes: travel + (leg?.minutes ?? 0), returnLeg: leg, returnDepart: depart,
                    approximateLegs: approximate + (leg?.approximate == true ? 1 : 0))
                if best == nil || preferred(candidate, over: best!) { best = candidate }
                return
            }
            for index in 0..<count where used & (1 << index) == 0 {
                let task = draft.tasks[index]
                guard (task.prerequisiteIDs ?? []).allSatisfy({ id in
                    guard let prior = draft.tasks.firstIndex(where: { $0.id == id }) else { return false }
                    return used & (1 << prior) != 0
                }) else { continue }
                let leg = matrix[node][index + 1]
                let depart = time + (stops.isEmpty ? 0 : draft.buffer)
                let arrive = depart + leg.minutes
                let start = max(arrive, task.fixedStart ?? task.earliestStart ?? draft.startMinute)
                let end = start + task.duration
                let deadline = min(task.fixedStart.map { $0 + task.duration } ?? task.deadline ?? draft.endMinute,
                                   draft.endMinute)
                guard end <= deadline else { continue }
                let stop = DayPlanStop(task: task, depart: depart, arrive: arrive, start: start, end: end, travel: leg)
                visit(node: index + 1, time: end, used: used | (1 << index), stops: stops + [stop],
                      travel: travel + leg.minutes, approximate: approximate + (leg.approximate ? 1 : 0))
            }
        }
        visit(node: 0, time: draft.startMinute, used: 0, stops: [], travel: 0, approximate: 0)
        guard let best else {
            let fixed = draft.tasks.filter { $0.fixedStart != nil }.sorted { $0.fixedStart! < $1.fixedStart! }
            for (first, second) in zip(fixed, fixed.dropFirst()) {
                if first.fixedStart! + first.duration > second.fixedStart! {
                    throw DayPlanError.impossible("固定安排冲突：“\(first.title)”与“\(second.title)”时间重叠。请调整后重新规划。")
                }
            }
            throw DayPlanError.impossible("按当前通勤估计，无法完成全部事项。请检查任务是否相互依赖、固定时间、截止时间和任务时长，或延长当天安排。没有自动删掉任何任务。")
        }
        return best
    }

    static func roughLeg(from: DayPlace, to: DayPlace, mode: DayTravelMode) -> DayLeg {
        let r = Double.pi / 180
        let deltaLat = (to.latitude - from.latitude) * r
        let deltaLon = (to.longitude - from.longitude) * r
        let h = pow(sin(deltaLat / 2), 2) + cos(from.latitude * r) * cos(to.latitude * r) * pow(sin(deltaLon / 2), 2)
        let km = 6371 * 2 * asin(sqrt(min(1, max(0, h))))
        if km < 0.02 { return DayLeg(minutes: 0, approximate: false) }
        let speed: Double
        let overhead: Int
        switch mode {
        case .walking: speed = 4.5; overhead = 0
        case .ebike: speed = 15; overhead = 2
        case .transit: speed = 18; overhead = 10
        case .driving: speed = 25; overhead = 5
        }
        return DayLeg(minutes: max(1, Int(ceil(km * 1.35 / speed * 60)) + overhead), approximate: true)
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
