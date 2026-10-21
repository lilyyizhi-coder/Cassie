import SwiftUI

@main
@MainActor
struct CassieApp: App {
    @StateObject private var speech = SpeechService()
    @StateObject private var photos = PhotoIndex()
    @StateObject private var notes = NoteStore()
    @StateObject private var schedule = CalendarService()

    var body: some Scene {
        WindowGroup {
            CassieHomeView()
                .environmentObject(speech)
                .environmentObject(photos)
                .environmentObject(notes)
                .environmentObject(schedule)
        }
    }
}
