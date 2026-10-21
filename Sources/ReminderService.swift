import Foundation
import SwiftUI
import UserNotifications

struct ReminderSettings: Codable, Equatable {
    var planEnabled = true
    var deadlineEnabled = true
    var deadlineLeadMinutes = 60
    var classEnabled = true
    var classWalkMinutes = 15
    var classBufferMinutes = 10
    var classHorizonDays = 3
    var sleepEnabled = true
    var sleepMinute = 23 * 60 + 30
}

extension Notification.Name {
    static let dayPlanChanged = Notification.Name("cassie.dayPlanChanged")
    static let courseEventsChanged = Notification.Name("cassie.courseEventsChanged")
}

struct PendingReminder: Identifiable {
    let id: String
    let title: String
    let body: String
    let fireDate: Date?
}

/// All reminders are local notifications; nothing is sent over the network.
@MainActor
final class ReminderStore: ObservableObject {
    @Published var settings: ReminderSettings {
        didSet {
            guard settings != oldValue else { return }
            do { try LocalStore.save(settings, to: "reminders.json") }
            catch let problem { self.error = "提醒设置未能保存：\(problem.localizedDescription)" }
            refreshAll()
        }
    }
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var upcoming: [PendingReminder] = []
    @Published var error: String?
    private var planDay: Date?
    private var planResult: DayPlanResult?
    private var planCompleted: Set<UUID> = []
    private var events: [ScheduleItem] = []
    private let center = UNUserNotificationCenter.current()

    init() {
        do { settings = try LocalStore.load(ReminderSettings.self, from: "reminders.json") }
        catch { settings = ReminderSettings() }
        let observer = NotificationCenter.default
        observer.addObserver(forName: .dayPlanChanged, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.applyPlan(note.userInfo) }
        }
        observer.addObserver(forName: .courseEventsChanged, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                self?.events = (note.userInfo?["events"] as? [ScheduleItem]) ?? []
                await self?.syncClasses()
                await self?.loadUpcoming()
            }
        }
        refreshAll()
    }

    func refreshAll() {
        Task {
            authorization = await center.notificationSettings().authorizationStatus
            await syncPlan()
            await syncClasses()
            await syncSleep()
            await loadUpcoming()
        }
    }

    func requestAuthorization() {
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                authorization = await center.notificationSettings().authorizationStatus
                if !granted { error = "未获得通知权限。可在系统设置 → 通知 → Cassie 中开启后返回本页。" }
                refreshAll()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func applyPlan(_ userInfo: [AnyHashable: Any]?) {
        planDay = userInfo?["day"] as? Date
        planResult = userInfo?["result"] as? DayPlanResult
        planCompleted = Set((userInfo?["completed"] as? [UUID]) ?? [])
        Task {
            await syncPlan()
            await loadUpcoming()
        }
    }

    private func syncPlan() async {
        await removePending(prefixes: ["plan-", "deadline-"])
        guard authorization == .authorized, settings.planEnabled || settings.deadlineEnabled,
              let day = planDay, let result = planResult else { return }
        let startOfDay = Calendar.current.startOfDay(for: day)
        let now = Date()
        for stop in result.stops where !planCompleted.contains(stop.id) {
            if settings.planEnabled {
                let depart = startOfDay.addingTimeInterval(TimeInterval(stop.depart * 60))
                await schedule("plan-\(stop.id.uuidString)",
                               title: "该出发：\(stop.task.title)",
                               body: "\(DayPlanEngine.clock(stop.depart)) 出发去\(stop.task.place?.name ?? "目标地点")，通勤约\(stop.travel.minutes)分钟，计划\(DayPlanEngine.clock(stop.start))–\(DayPlanEngine.clock(stop.end))。",
                               at: depart, now: now)
            }
            if settings.deadlineEnabled, let deadline = stop.task.deadline {
                let fire = startOfDay.addingTimeInterval(TimeInterval(max(0, deadline - settings.deadlineLeadMinutes) * 60))
                await schedule("deadline-\(stop.id.uuidString)",
                               title: "截止临近：\(stop.task.title)",
                               body: "\(DayPlanEngine.clock(deadline)) 前必须完成，剩\(settings.deadlineLeadMinutes)分钟。",
                               at: fire, now: now)
            }
        }
    }

    private func syncClasses() async {
        await removePending(prefixes: ["class-"])
        guard authorization == .authorized, settings.classEnabled else { return }
        let now = Date()
        let lead = settings.classWalkMinutes + settings.classBufferMinutes
        let horizon = now.addingTimeInterval(TimeInterval(settings.classHorizonDays * 86_400))
        for event in events where event.start > now && event.start <= horizon {
            let fire = event.start.addingTimeInterval(TimeInterval(-lead * 60))
            await schedule("class-\(event.id)",
                           title: "上课出发：\(event.title)",
                           body: "\(event.start.formatted(date: .omitted, time: .shortened)) 上课，地点\(event.location)。按走路\(settings.classWalkMinutes)分钟加\(settings.classBufferMinutes)分钟缓冲，建议现在出发。",
                           at: fire, now: now)
        }
    }

    private func syncSleep() async {
        await removePending(prefixes: ["sleep-"])
        guard authorization == .authorized, settings.sleepEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "睡觉线"
        content.body = "\(DayPlanEngine.clock(settings.sleepMinute)) 了，收尾今天的事，准备洗漱睡觉。"
        content.sound = .default
        var components = DateComponents()
        components.hour = settings.sleepMinute / 60
        components.minute = settings.sleepMinute % 60
        let request = UNNotificationRequest(identifier: "sleep-daily", content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
        try? await center.add(request)
    }

    private func schedule(_ identifier: String, title: String, body: String, at date: Date, now: Date) async {
        guard date > now else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date),
            repeats: false)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    private func removePending(prefixes: [String]) async {
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { id in prefixes.contains { id.hasPrefix($0) } }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
    }

    private func loadUpcoming() async {
        let pending = await center.pendingNotificationRequests()
        upcoming = pending
            .map { request in
                let trigger = request.trigger as? UNCalendarNotificationTrigger
                return PendingReminder(id: request.identifier, title: request.content.title,
                                       body: request.content.body, fireDate: trigger?.nextTriggerDate())
            }
            .sorted { ($0.fireDate ?? .distantFuture) < ($1.fireDate ?? .distantFuture) }
    }
}

@MainActor
struct ReminderSettingsView: View {
    @EnvironmentObject private var reminders: ReminderStore

    var body: some View {
        List {
            Section("通知权限") {
                switch reminders.authorization {
                case .authorized:
                    Label("已允许通知", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied:
                    Text("系统已拒绝通知。请在系统设置 → 通知 → Cassie 中开启，再回到本页。")
                        .foregroundStyle(.red)
                case .notDetermined:
                    Button("允许 Cassie 发送通知") { reminders.requestAuthorization() }
                default:
                    Text("当前通知状态不可用，请在系统设置中检查 Cassie 的通知权限。")
                }
            }
            Section {
                Toggle("任务出发提醒", isOn: $reminders.settings.planEnabled)
                Toggle("作业截止提醒", isOn: $reminders.settings.deadlineEnabled)
                if reminders.settings.deadlineEnabled {
                    Stepper("截止前 \(reminders.settings.deadlineLeadMinutes) 分钟提醒",
                            value: $reminders.settings.deadlineLeadMinutes, in: 10...240, step: 10)
                }
            } header: {
                Text("任务与截止")
            } footer: {
                Text("按已生成的 Dayplan 方案，在每段出发时间和截止时间前发本机通知。生成、重排方案或在计划页勾选完成后自动重新安排；没有方案时不提醒。")
            }
            Section {
                Toggle("上课出发提醒", isOn: $reminders.settings.classEnabled)
                if reminders.settings.classEnabled {
                    Stepper("去教室走路约 \(reminders.settings.classWalkMinutes) 分钟",
                            value: $reminders.settings.classWalkMinutes, in: 5...60, step: 5)
                    Stepper("再提前 \(reminders.settings.classBufferMinutes) 分钟缓冲",
                            value: $reminders.settings.classBufferMinutes, in: 0...30, step: 5)
                    Picker("只提醒未来", selection: $reminders.settings.classHorizonDays) {
                        Text("1 天内的课").tag(1)
                        Text("2 天内的课").tag(2)
                        Text("3 天内的课").tag(3)
                        Text("7 天内的课").tag(7)
                    }
                }
            } header: {
                Text("上课出发")
            } footer: {
                Text("按所选课表的上课时间倒推。换教室也按同一设置提醒；不读取实时位置，走路分钟数请按你最远的教学楼调整。")
            }
            Section("睡觉线") {
                Toggle("每日睡觉线提醒", isOn: $reminders.settings.sleepEnabled)
                if reminders.settings.sleepEnabled {
                    DayClockPicker("每天提醒时间", minute: $reminders.settings.sleepMinute)
                }
            }
            Section("接下来会响的提醒 · \(reminders.upcoming.count)") {
                ForEach(reminders.upcoming) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(item.body).font(.caption).foregroundStyle(.secondary)
                        if let date = item.fireDate {
                            Text(date.formatted()).font(.caption).foregroundStyle(.indigo)
                        }
                    }
                }
                if reminders.upcoming.isEmpty {
                    Text("暂无已排定的提醒。允许通知并生成计划或选择课表后，这里会列出接下来会响的提醒。")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = reminders.error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("自动提醒")
        .onAppear { reminders.refreshAll() }
    }
}
