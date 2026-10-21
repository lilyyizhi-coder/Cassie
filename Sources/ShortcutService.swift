import AppIntents
import SwiftUI
import UIKit

@MainActor
final class AppRoute: ObservableObject {
    static let shared = AppRoute()
    @Published var startVoice = false
}

struct TalkToCassieIntent: AppIntent {
    static var title: LocalizedStringResource = "和 Cassie 说话"
    static var description = IntentDescription("打开 Cassie 并开始一次语音请求。")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { AppRoute.shared.startVoice = true }
        return .result()
    }
}

struct CassieShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToCassieIntent(),
                    phrases: ["和 \(.applicationName) 说话", "打开 \(.applicationName)"],
                    shortTitle: "和 Cassie 说话", systemImageName: "waveform")
    }
}

enum ShortcutService {
    @MainActor
    static func run(name: String) async -> Bool {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: cleaned)]
        guard let url = components.url else { return false }
        return await UIApplication.shared.open(url)
    }
}
