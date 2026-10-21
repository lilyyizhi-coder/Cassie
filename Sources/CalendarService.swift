import EventKit
import SwiftUI

struct ScheduleItem: Identifiable {
    let id: String
    let title: String
    let location: String
    let start: Date
    let end: Date
}

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var events: [ScheduleItem] = []
    @Published var error: String?
    @Published private(set) var hasAccess = false
    @Published private(set) var selectedIDs: Set<String> = []
    private let store = EKEventStore()
    private let selectionKey = "courseCalendarIDs"

    init() {
        selectedIDs = Set(UserDefaults.standard.stringArray(forKey: selectionKey) ?? [])
    }

    func connect() async {
        do {
            guard try await store.requestFullAccessToEvents() else {
                error = "请在系统设置中允许日历访问，才能查询同步后的课表。"
                return
            }
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func refresh() {
        hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard hasAccess else { calendars = []; events = []; return }
        store.reset()
        calendars = store.calendars(for: .event)
        let available = Set(calendars.map(\.calendarIdentifier))
        selectedIDs.formIntersection(available)
        UserDefaults.standard.set(Array(selectedIDs), forKey: selectionKey)
        loadEvents()
    }

    func toggle(_ calendar: EKCalendar) {
        let id = calendar.calendarIdentifier
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
        UserDefaults.standard.set(Array(selectedIDs), forKey: selectionKey)
        loadEvents()
    }

    private func loadEvents() {
        defer { NotificationCenter.default.post(name: .courseEventsChanged, object: nil, userInfo: ["events": events]) }
        guard hasAccess else { events = []; return }
        let chosen = calendars.filter { selectedIDs.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { events = []; return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 14, to: now)!
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: chosen)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                ScheduleItem(id: "\(event.eventIdentifier ?? UUID().uuidString)-\(event.startDate.timeIntervalSince1970)",
                             title: event.title ?? "未命名课程", location: event.location ?? "未填写地点",
                             start: event.startDate, end: event.endDate)
            }
        error = nil
    }

    func nextClassAnswer(now: Date = Date()) -> String {
        refresh()
        guard hasAccess else { return "请先在课表页授权日历访问，并选择 Celechron 同步的课表日历。" }
        guard !selectedIDs.isEmpty else { return "请选择 Celechron 同步到系统日历的那个课表日历。" }
        if let current = events.first(where: { $0.start <= now && $0.end > now }) {
            let minutes = max(1, Int(ceil(current.end.timeIntervalSince(now) / 60)))
            let next = events.first(where: { $0.start > now })
            let suffix = next.map { "下一节是\($0.title)，\($0.start.formatted(date: .abbreviated, time: .shortened))开始，地点\($0.location)。" } ?? "未来两周的所选日历里没有找到下一节课。"
            return "当前是\(current.title)，约\(minutes)分钟后结束。" + suffix
        }
        guard let next = events.first(where: { $0.start > now }) else {
            return "未来两周的所选日历里没有找到课程，请确认 Celechron 已同步本学期课表。"
        }
        let minutes = max(1, Int(ceil(next.start.timeIntervalSince(now) / 60)))
        return "下一节是\(next.title)，\(next.start.formatted(date: .abbreviated, time: .shortened))开始，还有约\(minutes)分钟，地点\(next.location)。"
    }
}
