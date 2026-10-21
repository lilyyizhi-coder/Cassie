import Foundation
import SwiftUI

struct FocusSession: Codable, Identifiable {
    var id = UUID()
    var taskID: UUID?
    var title: String
    var expectedMinutes: Int
    var seconds: TimeInterval = 0
    var runningSince: Date?
    var createdAt = Date()
    var finishedAt: Date?

    func elapsed(at now: Date) -> TimeInterval {
        seconds + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
}

struct ProductivityData: Codable {
    var sessions: [FocusSession] = []
    var active: FocusSession?
    var completed: [String: [UUID]] = [:]
    var packing: [String: Bool] = [:]
    var customPacking: [String] = []
}

@MainActor
final class ProductivityStore: ObservableObject {
    @Published private(set) var data = ProductivityData()
    @Published var error: String?

    init() {
        do { data = try LocalStore.load(ProductivityData.self, from: "productivity.json") }
        catch let problem as CocoaError where problem.code == .fileReadNoSuchFile { }
        catch { self.error = "效率记录暂时无法读取：\(error.localizedDescription)" }
    }

    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private func commit(_ updated: ProductivityData) {
        do { try LocalStore.save(updated, to: "productivity.json"); data = updated; error = nil }
        catch { self.error = "未能保存：\(error.localizedDescription)" }
    }

    func completed(on day: Date) -> Set<UUID> { Set(data.completed[Self.dayKey(day)] ?? []) }

    func toggleCompleted(_ id: UUID, day: Date) {
        var updated = data
        let key = Self.dayKey(day)
        var ids = Set(updated.completed[key] ?? [])
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        updated.completed[key] = Array(ids)
        commit(updated)
    }

    func start(title: String, expected: Int, taskID: UUID?) {
        guard data.active == nil else { error = "请先结束当前计时。"; return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "请填写计时事项。"; return }
        var updated = data
        updated.active = FocusSession(taskID: taskID, title: name, expectedMinutes: expected, runningSince: Date())
        commit(updated)
    }

    func pauseOrResume() {
        guard var session = data.active else { return }
        if let since = session.runningSince {
            session.seconds += max(0, Date().timeIntervalSince(since)); session.runningSince = nil
        } else { session.runningSince = Date() }
        var updated = data; updated.active = session; commit(updated)
    }

    func finish() {
        guard var session = data.active else { return }
        if let since = session.runningSince { session.seconds += max(0, Date().timeIntervalSince(since)) }
        session.runningSince = nil; session.finishedAt = Date()
        var updated = data
        updated.sessions.insert(session, at: 0); updated.active = nil
        commit(updated)
    }

    func packingChecked(_ label: String, day: Date) -> Bool { data.packing[Self.dayKey(day) + label] ?? false }
    func setPacking(_ label: String, checked: Bool, day: Date) {
        var updated = data; updated.packing[Self.dayKey(day) + label] = checked; commit(updated)
    }
    func addPacking(_ label: String) {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !data.customPacking.contains(value) else { return }
        var updated = data; updated.customPacking.append(value); commit(updated)
    }
    func removePacking(_ label: String) {
        var updated = data; updated.customPacking.removeAll { $0 == label }; commit(updated)
    }
    func removeHistory(_ offsets: IndexSet) {
        var updated = data; updated.sessions.remove(atOffsets: offsets); commit(updated)
    }

    func recommendedMinutes(for title: String) -> Int? {
        let samples = data.sessions.filter { $0.title == title && $0.seconds >= 60 }.prefix(5)
        guard !samples.isEmpty else { return nil }
        return max(5, Int(ceil(samples.map(\.seconds).reduce(0, +) / Double(samples.count) / 60 / 5)) * 5)
    }
}

struct CaptureCandidate: Identifiable {
    var id: UUID { task.id }
    var task: DayTask
    var confirmed = false
    var hint: String
}

// Conservative local extraction. Every draft remains editable and needs confirmation.
enum PlanCapture {
    static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func number(_ text: String) -> Double? {
        if let value = Double(text) { return value }
        if text == "半" { return 0.5 }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if let position = text.firstIndex(of: "十") {
            let left = text[..<position].first.flatMap { digits[$0] } ?? 1
            let right = text[text.index(after: position)...].first.flatMap { digits[$0] } ?? 0
            return Double(left * 10 + right)
        }
        return text.first.flatMap { digits[$0] }.map(Double.init)
    }

    static func candidates(_ text: String, photoID: String?) -> [CaptureCandidate] {
        let segmented = text.replacingOccurrences(of: #"然后|接着|随后|再然后"#, with: "\n", options: .regularExpression)
        let parts = segmented.components(separatedBy: CharacterSet(charactersIn: "\n；;。"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.map { raw in
            var task = DayTask()
            task.title = String(raw.prefix(120))
            task.sourceText = raw; task.sourcePhotoID = photoID
            var hints = ["请确认任务名称、地图地点和用时"]
            if let match = groups(#"([0-9]+(?:\.[0-9]+)?|[一二两三四五六七八九十半]+)\s*(小时|分钟|[hH])"#, raw),
               let amount = number(match[1]) {
                let minutes = amount * (match[2] == "分钟" ? 1 : 60)
                task.duration = min(720, max(5, Int(ceil(minutes / 5)) * 5))
                hints.append("识别用时\(task.duration)分钟，请核对区间和半小时等表述")
            } else { hints.append("用时暂填30分钟，需修改或确认") }
            if let match = groups(#"(凌晨|早上|上午|中午|下午|晚上)?\s*([0-9]{1,2}|[一二两三四五六七八九十]+)\s*(?:[:：.点时])\s*([0-9]{1,2}|半|[一二三四五六七八九十]+)?"#, raw),
               let hour = number(match[2]) {
                var h = Int(hour)
                let m = match[3] == "半" ? 30 : Int(number(match[3]) ?? 0)
                if ["下午", "晚上"].contains(match[1]), h < 12 { h += 12 }
                if match[1] == "中午", h < 11 { h += 12 }
                if match[1] == "凌晨", h == 12 { h = 0 }
                if (0...23).contains(h), (0...59).contains(m) {
                    let minute = h * 60 + m
                    if raw.contains("截止") || raw.contains("前完成") || raw.contains("之前交") {
                        task.deadline = minute
                    } else if !raw.contains("大概") && !raw.contains("左右") && !raw.contains("差不多") {
                        task.fixedStart = minute
                    }
                    hints.append("识别时间\(DayPlanEngine.clock(minute))，请确认是开始还是截止")
                }
            }
            if raw.contains("明天") || raw.contains("后天") || raw.contains("月") || raw.contains("周") {
                hints.append("含日期表述，请核对上方计划日期；不会自动推断跨日安排")
            }
            return CaptureCandidate(task: task, hint: hints.joined(separator: "；"))
        }
    }
}
