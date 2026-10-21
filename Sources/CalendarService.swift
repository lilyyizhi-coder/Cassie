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
                error = "����ϵͳ�����������������ʣ����ܲ�ѯͬ����Ŀα���"
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
                             title: event.title ?? "δ�����γ�", location: event.location ?? "δ��д�ص�",
                             start: event.startDate, end: event.endDate)
            }
        error = nil
    }

    func nextClassAnswer(now: Date = Date()) -> String {
        refresh()
        guard hasAccess else { return "�����ڿα�ҳ��Ȩ�������ʣ���ѡ�� Celechron ͬ���Ŀα�������" }
        guard !selectedIDs.isEmpty else { return "��ѡ�� Celechron ͬ����ϵͳ�������Ǹ��α�������" }
        if let current = events.first(where: { $0.start <= now && $0.end > now }) {
            let minutes = max(1, Int(ceil(current.end.timeIntervalSince(now) / 60)))
            let next = events.first(where: { $0.start > now })
            let suffix = next.map { "��һ����\($0.title)��\($0.start.formatted(date: .abbreviated, time: .shortened))��ʼ���ص�\($0.location)��" } ?? "δ�����ܵ���ѡ������û���ҵ���һ�ڿΡ�"
            return "��ǰ��\(current.title)��Լ\(minutes)���Ӻ������" + suffix
        }
        guard let next = events.first(where: { $0.start > now }) else {
            return "δ�����ܵ���ѡ������û���ҵ��γ̣���ȷ�� Celechron ��ͬ����ѧ�ڿα���"
        }
        let minutes = max(1, Int(ceil(next.start.timeIntervalSince(now) / 60)))
        return "��һ����\(next.title)��\(next.start.formatted(date: .abbreviated, time: .shortened))��ʼ������Լ\(minutes)���ӣ��ص�\(next.location)��"
    }
}
