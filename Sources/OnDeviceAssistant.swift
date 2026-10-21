import Foundation
import FoundationModels

/// On-device Apple Intelligence helper. Everything runs on the neural engine;
/// no text ever leaves the device and no API key or account is involved.
@available(iOS 26.0, *)
@MainActor
final class OnDeviceAssistant {
    static let shared = OnDeviceAssistant()

    static var isSupported: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var availabilityText: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "端侧模型可用"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "此设备不支持 Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "请先在系统设置中开启 Apple Intelligence，然后重启 Cassie"
            default:
                return "端侧模型暂不可用，请在系统设置的 Apple Intelligence 中检查设备、语言与地区"
            }
        @unknown default:
            return "端侧模型暂不可用"
        }
    }

    func stream(_ question: String, context: String) -> AsyncThrowingStream<String, Error> {
        let session = LanguageModelSession(instructions: """
        你是 Cassie，一名浙江大学大一女生的本机语音助手。用简体中文回答，简短、口语化、先给结论。
        只依据提供的上下文回答日程、课表、任务、备忘相关的问题；上下文没有的信息直说不知道，绝不编造课程、成绩、地点、时间或人物。
        不提供医疗、法律、投资理财建议。除非用户要求列清单，回答不超过120字。
        """)
        let prompt = "当前上下文：\n\(context)\n\n用户说：\(question)"
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func extractTasks(from text: String) async throws -> [ExtractedTask] {
        let session = LanguageModelSession(instructions: """
        从用户文字中提取当天要做的事情列表。忠实原文：不添加没有提到的任务，不猜测没有说明的信息；没有任务时 tasks 为空列表。
        每个任务的字段规则：
        title 是任务名称，不超过20个字，忠实原文；
        durationMinutes 是预计用时（分钟），范围5到720，原文没说就填30；
        startClock 是固定开始时间，格式HH:MM，没有则填空字符串；
        deadlineClock 是完成截止时间，格式HH:MM，没有则填空字符串；
        placeHint 是原文提到的地点名称，没有则填空字符串。
        时间按24小时制；“下午”“晚上”换算成12小时之后的时间；只有出现“截止”“前完成”“之前交”才填 deadlineClock，否则明确说出的钟点填 startClock。
        """)
        let result = try await session.respond(to: "提取以下文字中的任务：\n\(text)",
                                              generating: ExtractedTaskList.self)
        return result.content.tasks
    }

    func candidates(from tasks: [ExtractedTask], sourceText: String, photoID: String?) -> [CaptureCandidate] {
        tasks.prefix(8).map { item in
            var task = DayTask()
            task.title = String(item.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            task.sourceText = sourceText
            task.sourcePhotoID = photoID
            task.duration = min(720, max(5, Int(ceil(Double(item.durationMinutes) / 5)) * 5))
            var hints = ["端侧模型提取，请打开确认地点与用时"]
            let hint = item.placeHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hint.isEmpty { hints.append("地点线索：\(hint)，仍需在编辑页地图确认") }
            if let deadline = Self.minutes(fromClock: item.deadlineClock) {
                task.deadline = deadline
                hints.append("识别截止\(DayPlanEngine.clock(deadline))，请核对")
            } else if let start = Self.minutes(fromClock: item.startClock) {
                task.fixedStart = start
                hints.append("识别开始\(DayPlanEngine.clock(start))，如其实是截止时间请在编辑页修改")
            }
            return CaptureCandidate(task: task, confirmed: false, hint: hints.joined(separator: "；"))
        }
    }

    private static func minutes(fromClock text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

@available(iOS 26.0, *)
@Generable
struct ExtractedTaskList {
    var tasks: [ExtractedTask] = []
}

@available(iOS 26.0, *)
@Generable
struct ExtractedTask {
    var title: String = ""
    var durationMinutes: Int = 30
    var startClock: String = ""
    var deadlineClock: String = ""
    var placeHint: String = ""
}
