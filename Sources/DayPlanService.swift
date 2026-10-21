import MapKit
import SwiftUI

@MainActor
final class DayPlanStore: ObservableObject {
    @Published var draft: DayPlanDraft {
        didSet {
            result = nil
            alternative = nil
            do { try LocalStore.save(draft, to: "dayplan.json") }
            catch { self.error = "日程未能保存：\(error.localizedDescription)" }
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
    }

    func generate() {
        guard !isGenerating else { return }
        error = nil
        result = nil
        alternative = nil
        let input = draft
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
                guard input == draft else { progress = "清单已变化，请重新生成"; return }
                result = computed.0
                alternative = computed.1
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
