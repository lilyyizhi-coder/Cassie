import EventKit
import MessageUI
import Photos
import SwiftUI
import UIKit

@MainActor
struct PhotoSearchView: View {
    @EnvironmentObject private var index: PhotoIndex
    @State private var query: String
    @State private var screenshotsOnly = true
    @State private var allowCloud = false
    @State private var selected: IndexedPhoto?
    @State private var showClearConfirmation = false

    init(query: String = "") { _query = State(initialValue: query) }

    private var matches: [PhotoMatch] {
        PhotoSearch.matches(query, in: index.records)
    }

    var body: some View {
        List {
            Section("�������Ͽ�") {
                Text("������ \(index.records.count) ��ͼƬ")
                Text(index.progress).font(.footnote).foregroundStyle(.secondary)
                if index.authorization == .limited {
                    Text("��ǰֻ����������ϵͳ��ѡ�� Cassie ����Ƭ������ϵͳ�����и��ķ�Χ��")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("ֻɨ���ͼ���رտ�ɨ��ȫ����Ƭ��", isOn: $screenshotsOnly)
                    .disabled(index.isScanning)
                Toggle("������ iCloud ����ԭͼ", isOn: $allowCloud)
                    .disabled(index.isScanning)
                Text("ͼƬ�����ڱ���ʶ��ͱ��档�״�ɨ���뱣�� Cassie ��ǰ̨����һ��ɨ�������δ�Ķ���ͼƬ��")
                    .font(.footnote).foregroundStyle(.secondary)
                if !index.canRead {
                    Button("��Ȩ������") { Task { await index.requestAccess() } }
                } else if index.isScanning {
                    ProgressView()
                    Button("��ͣɨ��") { index.pause() }
                } else {
                    Button("ɨ��������Ķ���ͼƬ") {
                        index.start(screenshotsOnly: screenshotsOnly, allowCloudDownloads: allowCloud)
                    }
                }
                if let error = index.error { Text(error).foregroundStyle(.red) }
            }
            Section(query.isEmpty ? "���������ͼƬ" : "����ƥ����") {
                if query.isEmpty {
                    ForEach(index.records
                        .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }.prefix(30)) { photo in
                        Button { selected = photo } label: { PhotoResultRow(photo: photo, excerpt: photo.text) }
                            .buttonStyle(.plain)
                    }
                } else {
                    ForEach(matches) { match in
                        Button { selected = match.photo } label: {
                            PhotoResultRow(photo: match.photo, excerpt: match.excerpt)
                        }.buttonStyle(.plain)
                    }
                    if matches.isEmpty {
                        Text("û���ҵ�����ƥ�䡣�ɳ��Խ�ͼ����ֹ��Ŀγ�������ַ�����ڡ�")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("���������������", role: .destructive) { showClearConfirmation = true }
                    .disabled(index.isScanning || index.records.isEmpty)
            } footer: { Text("�����������ɾ����������Ƭ��") }
        }
        .navigationTitle("��ͼ����")
        .searchable(text: $query, prompt: "�����γ��������ڡ���ַ��")
        .sheet(item: $selected) { photo in PhotoDetailView(photo: photo) }
        .confirmationDialog("��� Cassie ���������ͼƬ���֣�", isPresented: $showClearConfirmation) {
            Button("�������", role: .destructive) { index.clear() }
        }
    }
}

@MainActor
private struct PhotoResultRow: View {
    let photo: IndexedPhoto
    let excerpt: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(photo.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "����δ֪")
                .font(.caption).foregroundStyle(.secondary)
            Text(excerpt.isEmpty ? "δʶ������֣��㰴�鿴ԭͼ" : excerpt).lineLimit(3)
            Label("�鿴ԭͼ����������", systemImage: "photo").font(.caption).foregroundStyle(.indigo)
        }.padding(.vertical, 4)
    }
}

@MainActor
private struct PhotoDetailView: View {
    let photo: IndexedPhoto
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let image { Image(uiImage: image).resizable().scaledToFit() }
                    else if loading { ProgressView("��ȡԭͼ��") }
                    if let error { Text(error).foregroundStyle(.secondary) }
                    Text(photo.text.isEmpty ? "û��ʶ������֡�" : photo.text).textSelection(.enabled)
                    if !photo.text.isEmpty { ShareLink("����ʶ������", item: photo.text) }
                }.padding()
            }
            .navigationTitle("��Դ��ͼ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("���") { dismiss() } }
            .task { await load(allowCloud: false) }
            .safeAreaInset(edge: .bottom) {
                if image == nil && !loading {
                    Button("���Դ� iCloud ���ز��鿴") { Task { await load(allowCloud: true) } }
                        .buttonStyle(.borderedProminent).padding()
                }
            }
        }
    }

    private func load(allowCloud: Bool) async {
        loading = true
        defer { loading = false }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject else {
            error = "ԭͼ��ɾ�������ڵ�ǰ��Ȩ��Χ�ڡ�"
            return
        }
        do {
            let data = try await PhotoLoader.imageData(asset: asset, allowCloud: allowCloud)
            image = UIImage(data: data)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct ScheduleView: View {
    @EnvironmentObject private var schedule: CalendarService
    var body: some View {
        List {
            Section("���� Celechron �α�") {
                Text("���� Celechron �н���ѧ�ڿα�ͬ����ϵͳ��������������ѡ���Ӧ�������α��䶯������ Celechron ������ͬ����")
                    .font(.subheadline)
                Button(schedule.hasAccess ? "ˢ������" : "��Ȩ����ȡϵͳ����") {
                    Task { await schedule.connect() }
                }
                if let error = schedule.error { Text(error).foregroundStyle(.red) }
            }
            Section("ѡ��α�����") {
                ForEach(schedule.calendars, id: \.calendarIdentifier) { calendar in
                    Button { schedule.toggle(calendar) } label: {
                        HStack {
                            Text(calendar.title).foregroundStyle(.primary)
                            Spacer()
                            if schedule.selectedIDs.contains(calendar.calendarIdentifier) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.indigo)
                            }
                        }
                    }
                }
                if schedule.hasAccess && schedule.calendars.isEmpty { Text("û���ҵ��ɶ�ȡ��������") }
            }
            Section("δ������") {
                ForEach(schedule.events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title).font(.headline)
                        Text(event.start.formatted(date: .abbreviated, time: .shortened))
                        Text(event.location).foregroundStyle(.secondary)
                    }
                }
                if schedule.events.isEmpty { Text("��ѡ������û���ҵ��γ̡�δѡ����ʱ�����ȡ�����ճ̡�") }
            }
        }
        .navigationTitle("�α��ճ�")
        .onAppear { schedule.refresh() }
        .refreshable { schedule.refresh() }
    }
}

@MainActor
struct NotesView: View {
    @EnvironmentObject private var notes: NoteStore
    @State private var draft = ""
    var body: some View {
        List {
            Section("���ּ�") {
                TextField("Ҫ��סʲô��", text: $draft, axis: .vertical)
                Button("���浽����") { if notes.add(draft) { draft = "" } }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let error = notes.error { Text(error).foregroundStyle(.red) }
            }
            Section("�ҵı���") {
                ForEach(notes.notes) { note in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note.text).textSelection(.enabled)
                        Text(note.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                }.onDelete(perform: notes.delete)
            }
        }.navigationTitle("��������")
    }
}

@MainActor
struct ConnectionsView: View {
    @AppStorage("doubaoShortcut") private var doubao = ""
    @AppStorage("tailgShortcut") private var tailg = ""
    @State private var status: String?
    var body: some View {
        Form {
            Section("�򿪶���") {
                Text("��ϵͳ�����ָ����½�ָ����ӡ��� App��������ѡ�񶹰�����ָ�������������")
                TextField("���ָ�����ƣ����磺�򿪶���", text: $doubao)
                Button("���д򿪶���ָ��") { Task { await run(doubao) } }
                    .disabled(doubao.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("̨������") {
                Text("��̨�����ܻ�ϵͳ�����ָ��� App �����б��ȷ����ĳ����Ƿ��ṩ��������������Ӧ��������Ϊ���ָ����������ơ�")
                TextField("�����õĳ�������ָ������", text: $tailg)
                Text("Cassie ������ȷ�Ϻ���������ָ����ս����Ƿ�ɹ�����̨�����ܺͳ���������Cassie ����ѡ��򿪿��ָ����������ɹ���")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("���뷽ʽ") {
                LabeledContent("�α�", value: "Celechron �� ϵͳ����")
                LabeledContent("�� App", value: "ϵͳ���ָ��")
                LabeledContent("�س�", value: "̨�����ܹٷ�����")
            }
            if let status { Section { Text(status) } }
        }
        .navigationTitle("App ���豸")
    }

    private func run(_ name: String) async {
        let opened = await ShortcutService.run(name: name)
        status = opened ? "������ϵͳ���п��ָ���鿴ϵͳ�����н����" : "δ�ܴ򿪿��ָ��������ƺ�ϵͳ App��"
    }
}

@MainActor
struct MessageDraftView: View {
    @State private var recipient = ""
    @State private var text = ""
    @State private var showComposer = false
    @State private var result: String?
    var body: some View {
        Form {
            Section {
                TextField("�ռ����ֻ��ţ������գ�", text: $recipient).keyboardType(.phonePad)
                TextField("������ü�����д�ظ�����", text: $text, axis: .vertical).lineLimit(4...10)
                Button("��鲢��ϵͳ��Ϣ����") { showComposer = true }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !MFMessageComposeViewController.canSendText())
                if !MFMessageComposeViewController.canSendText() { Text("��ǰ�豸�޷�ʹ��ϵͳ��Ϣ�༭�������Կɷ����ݸ嵽���� App��") }
                ShareLink("�����ݸ嵽���� App", item: text).disabled(text.isEmpty)
            } header: { Text("׼���ظ�") }
              footer: { Text("������ϵͳ��Ϣ������ȷ�ϡ���ҳ�治���ȡ΢�Ż�ϵͳ��Ϣ�������¼��") }
            if let result { Section { Text(result) } }
        }
        .navigationTitle("��Ϣ�ݸ�")
        .sheet(isPresented: $showComposer) {
            MessageComposer(recipients: recipient.isEmpty ? [] : [recipient], messageBody: text) { outcome in
                showComposer = false
                switch outcome {
                case .sent: result = "��Ϣ�ѽ���ϵͳ���ͣ��ʹ�״̬��鿴��Ϣ App��"
                case .cancelled: result = "��ȡ�����ͣ��ݸ��Ա����ڴ�ҳ�档"
                case .failed: result = "ϵͳδ�ܷ��ͣ��������Ӻ����ԡ�"
                @unknown default: result = "������Ϣ App �в鿴���ͽ����"
                }
            }
        }
    }
}

@MainActor
private struct MessageComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let messageBody: String
    let completion: (MessageComposeResult) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = messageBody
        controller.messageComposeDelegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) { }
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let completion: (MessageComposeResult) -> Void
        init(completion: @escaping (MessageComposeResult) -> Void) { self.completion = completion }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            completion(result)
        }
    }
}
