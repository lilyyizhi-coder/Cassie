import SwiftUI

@MainActor
struct CassieHomeView: View {
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var photos: PhotoIndex
    @EnvironmentObject private var notes: NoteStore
    @EnvironmentObject private var schedule: CalendarService
    @ObservedObject private var route = AppRoute.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("doubaoShortcut") private var doubaoShortcut = ""
    @AppStorage("tailgShortcut") private var tailgShortcut = ""
    @AppStorage("readReplies") private var readReplies = true
    @State private var input = ""
    @State private var reply = ""
    @State private var path: [Destination] = []
    @State private var confirmUnlock = false
    @State private var matchCount = 0
    @State private var lastSearch = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cassie").font(.largeTitle.bold())
                            Text("���ճ�С�½�����").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { readReplies.toggle(); if !readReplies { speech.silence() } } label: {
                            Image(systemName: readReplies ? "speaker.wave.2" : "speaker.slash")
                                .font(.title2).padding(12)
                        }.accessibilityLabel(readReplies ? "�ر���������" : "������������")
                    }
                    voiceCard
                    if let error = speech.error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if !reply.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(reply).textSelection(.enabled)
                            if matchCount > 0 {
                                Button("�鿴 \(matchCount) ��ƥ����ԭͼ") { path.append(.photos(lastSearch)) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                            .background(.background, in: RoundedRectangle(cornerRadius: 20))
                    }
                    Text("���ù���").font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        feature("��ͼ����", "�������֣��鿴ԭͼ", "text.viewfinder", .photos(""))
                        feature("�α��ճ�", "���� Celechron �α�", "calendar", .schedule)
                        feature("��������", "��ڼ��£������ڱ���", "note.text", .notes)
                        feature("��Ϣ�ݸ�", "�༭������ϵͳ����", "message", .messages)
                        feature("�򿪶���", "���ÿ��ָ��", "square.grid.2x2", .connections)
                        feature("̨������", "���ӹٷ��س�ָ��", "bicycle", .connections)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("��������˵").font(.headline)
                        Text("����һ�ڿ���ʲô��\n����һ�º��������ڵĽ�ͼ��\n����һ��������������\n���򿪶�����")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        .background(.background, in: RoundedRectangle(cornerRadius: 20))
                    Text("����Ԥ���� �� ��ǰ֧�ֱ���ָ�����ͼ�������������������롢ѧϰ���������ɶಽ�Ի����ڽ��롣")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Cassie")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .photos(let query): PhotoSearchView(query: query)
                case .schedule: ScheduleView()
                case .notes: NotesView()
                case .messages: MessageDraftView()
                case .connections: ConnectionsView()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                photos.refreshAuthorization()
                schedule.refresh()
                startFromShortcutIfNeeded()
            } else if phase == .background {
                speech.stop(submit: false)
                speech.silence()
                photos.pause()
            }
        }
        .onChange(of: route.startVoice) { _, value in
            if value { startFromShortcutIfNeeded() }
        }
        .task { startFromShortcutIfNeeded() }
        .alert("���г�������ָ�", isPresented: $confirmUnlock) {
            Button("ȡ��", role: .cancel) { }
            Button("ȷ������") { Task { await runShortcut(tailgShortcut, vehicle: true) } }
        } message: { Text("�����������õġ�\(tailgShortcut)�����ָ���ȷ������Ӧ��Ҫ�����ĳ�����") }
    }

    private var voiceCard: some View {
        VStack(spacing: 16) {
            Button {
                if speech.isListening { speech.stop(submit: true) }
                else { Task { await beginVoice() } }
            } label: {
                Image(systemName: speech.isListening ? "stop.fill" : "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 80, height: 80)
                    .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading,
                                               endPoint: .bottomTrailing), in: Circle())
            }
            .disabled(speech.isStarting)
            .accessibilityLabel(speech.isListening ? "����¼�����ύ" : "��ʼ��������")
            Text(speech.isListening ? "���������㰴�������ύ" : speech.isStarting ? "����׼��������" : "���¿�ʼ˵��")
                .font(.headline)
            if speech.isListening { Text(speech.transcript).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(alignment: .bottom) {
                TextField("Ҳ��������������", text: $input, axis: .vertical)
                    .lineLimit(1...5).submitLabel(.send).onSubmit { submit(input) }
                Button { submit(input) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speech.isListening || speech.isStarting)
                    .accessibilityLabel("�ύ����")
            }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }.padding(22).frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 24))
    }

    private func feature(_ title: String, _ subtitle: String, _ symbol: String, _ destination: Destination) -> some View {
        Button { path.append(destination) } label: {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.indigo)
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading).padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }

    private func submit(_ raw: String) {
        guard !speech.isListening, !speech.isStarting else { return }
        let text = raw.replacingOccurrences(of: #"^\s*[Cc]assie[��,��:\s]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = text
        matchCount = 0
        if ["��ͼ", "��Ƭ", "���", "��ͼ"].contains(where: text.contains) {
            guard photos.canRead else {
                answer("�����ڽ�ͼ����ҳ��Ȩ�����ʣ���ɨ��ͼƬ��������������")
                path.append(.photos(text)); return
            }
            let matches = PhotoSearch.matches(text, in: photos.records)
            lastSearch = text
            matchCount = matches.count
            if let best = matches.first {
                answer("�ҵ���ؽ�ͼ��\(best.photo.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "����δ֪")�Ľ�ͼ��д�ţ�\(best.excerpt)������Դ�ԭͼ�˶ԡ�")
            } else {
                answer("��������ͼƬ��û���ҵ�����ƥ�䡣����ɨ����ᣬ����ý�ͼ�ϳ��ֹ��Ĵ��")
                path.append(.photos(text))
            }
        } else if ["�½�", "��һ��", "�α�", "ʲô��"].contains(where: text.contains) {
            answer(schedule.nextClassAnswer())
        } else if text.contains("�򿪶���") {
            guard !doubaoShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                answer("�������ô򿪶����Ŀ��ָ�����ơ�")
                path.append(.connections); return
            }
            Task { await runShortcut(doubaoShortcut, vehicle: false) }
        } else if text.contains("����"), text.contains("��") || text.contains("̨��") {
            guard !tailgShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                answer("��������̨�������ṩ�ĳ����������ָ�")
                path.append(.connections); return
            }
            speech.silence(); confirmUnlock = true
        } else if text.hasPrefix("��һ��") || text.hasPrefix("��ס") || text.hasPrefix("���Ҽ�") {
            let note = text.replacingOccurrences(of: #"^(��һ��|��ס|���Ҽ���|���Ҽ�)[��,��:\s]*"#, with: "", options: .regularExpression)
            if notes.add(note) { answer("�Ѽ��ڱ��������\(note)") }
            else { answer(notes.error ?? "�������Ҫ��ס�ľ������ݡ�") }
        } else if text.contains("����") || text.contains("�Ҽ���ʲô") || text.contains("����˵") {
            let found = text.contains("����") ? notes.notes.filter { Calendar.current.isDateInYesterday($0.createdAt) } : notes.notes
            answer(found.isEmpty ? "û���ҵ���Ӧ�ı�����" : found.prefix(5).map(\.text).joined(separator: "��"))
        } else if text.contains("�ظ�") || text.contains("��Ϣ") {
            answer("��������Ϣ�ݸ�ҳ�༭�ظ���������ϵͳ��Ϣ����ȷ�Ϸ��͡�")
            path.append(.messages)
        } else {
            answer("��һ����Բ�ѯ�α���������ͼ���֡��Ǳ������򿪶��������������õ�̨��ָ����ɶԻ����������ܻ��ڿ����С�")
        }
    }

    private func answer(_ text: String) {
        reply = text
        if readReplies { speech.speak(text) }
    }

    private func runShortcut(_ name: String, vehicle: Bool) async {
        let opened = await ShortcutService.run(name: name)
        reply = opened
            ? (vehicle ? "����������̨��ָ��Ƿ�����ɹ�������̨�����ܺͳ�������Ϊ׼��" : "���������д򿪶���ָ���鿴���ָ���ִ�н����")
            : "δ�ܴ򿪿��ָ�����������ϵͳ App��"
    }

    private func beginVoice() async {
        await speech.start { text in input = text; submit(text) }
    }

    private func startFromShortcutIfNeeded() {
        guard route.startVoice, scenePhase == .active else { return }
        route.startVoice = false
        path = []
        Task { await beginVoice() }
    }

    private enum Destination: Hashable {
        case photos(String), schedule, notes, messages, connections
    }
}
