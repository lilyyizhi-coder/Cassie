import SwiftUI

@main
@MainActor
struct CassieApp: App {
    @StateObject private var speech = SpeechService()
    @StateObject private var photos = PhotoIndex()
    @StateObject private var notes = NoteStore()
    @StateObject private var schedule = CalendarService()
    @StateObject private var dayplan = DayPlanStore()
    @StateObject private var productivity = ProductivityStore()

    var body: some Scene {
        WindowGroup {
            CassieHomeView()
                .environmentObject(speech)
                .environmentObject(photos)
                .environmentObject(notes)
                .environmentObject(schedule)
                .environmentObject(dayplan)
                .environmentObject(productivity)
        }
    }
}
