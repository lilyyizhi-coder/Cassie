import NaturalLanguage
import Photos
import SwiftUI
import UIKit
import Vision

struct IndexedPhoto: Codable, Identifiable {
    let id: String
    let createdAt: Date?
    let modifiedAt: Date?
    let text: String
    let isScreenshot: Bool
}

struct PhotoMatch: Identifiable {
    let photo: IndexedPhoto
    let excerpt: String
    let score: Int
    var id: String { photo.id }
}

enum PhotoSearch {
    static func matches(_ query: String, in photos: [IndexedPhoto]) -> [PhotoMatch] {
        let cleaned = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = cleaned
        let stopWords: Set<String> = ["帮", "我", "帮我", "找", "一下", "找一下", "找找", "的", "了", "里", "里面", "照片", "截图", "相关", "信息", "请", "一张", "那张"]
        var terms: Set<String> = []
        tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            let term = String(cleaned[range])
            if !stopWords.contains(term), term.count > 1 || term.rangeOfCharacter(from: .decimalDigits) != nil {
                terms.insert(term)
            }
            return true
        }
        if terms.isEmpty { terms.insert(cleaned) }
        return photos.compactMap { photo in
            let normalized = photo.text.lowercased()
            let matching = terms.filter { normalized.contains($0) }
            let fullMatch = normalized.contains(cleaned)
            guard fullMatch || !matching.isEmpty else { return nil }
            let score = matching.reduce(0) { $0 + $1.count } + (fullMatch ? 30 : 0)
            let lines = photo.text.components(separatedBy: .newlines)
            let evidence = lines.first { line in matching.contains { line.lowercased().contains($0) } }
            return PhotoMatch(photo: photo, excerpt: String((evidence ?? photo.text).prefix(240)), score: score)
        }
        .sorted {
            if $0.score == $1.score { return ($0.photo.createdAt ?? .distantPast) > ($1.photo.createdAt ?? .distantPast) }
            return $0.score > $1.score
        }
        .prefix(30).map { $0 }
    }
}

@MainActor
final class PhotoIndex: ObservableObject {
    @Published private(set) var records: [IndexedPhoto] = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress = "尚未扫描"
    @Published private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var error: String?
    private var scanTask: Task<Void, Never>?
    private let fileName = "photo-index.json"

    init() {
        do { records = try LocalStore.load([IndexedPhoto].self, from: fileName) }
        catch let problem as CocoaError where problem.code == .fileReadNoSuchFile { }
        catch { self.error = "索引暂时无法读取：\(error.localizedDescription)" }
        refreshAuthorization()
    }

    var canRead: Bool { authorization == .authorized || authorization == .limited }

    func requestAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refreshAuthorization()
        if !canRead { error = "未获得相册权限。请在系统设置中允许访问，或选择要查找的照片。" }
    }

    // Revalidate cached OCR when the app becomes active. Removed assets and
    // photos no longer in a limited selection must also disappear from search.
    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else {
            scanTask?.cancel()
            records = []
            do { try LocalStore.remove(fileName) }
            catch { self.error = "清理旧索引失败：\(error.localizedDescription)" }
            return
        }
        let accessible = PHAsset.fetchAssets(with: .image, options: nil)
        var allowed: Set<String> = []
        accessible.enumerateObjects { asset, _, _ in allowed.insert(asset.localIdentifier) }
        let visible = records.filter { allowed.contains($0.id) }
        if visible.count != records.count {
            scanTask?.cancel()
            records = visible
            save()
        }
    }

    func start(screenshotsOnly: Bool, allowCloudDownloads: Bool) {
        guard !isScanning else { return }
        refreshAuthorization()
        guard canRead else { error = "请先授权相册访问。"; return }
        error = nil
        isScanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isScanning = false; self.scanTask = nil }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetched = PHAsset.fetchAssets(with: .image, options: options)
            var assets: [PHAsset] = []
            fetched.enumerateObjects { asset, _, _ in
                if !screenshotsOnly || asset.mediaSubtypes.contains(.photoScreenshot) { assets.append(asset) }
            }
            var index = Dictionary(uniqueKeysWithValues: self.records.map { ($0.id, $0) })
            var skipped = 0
            do {
                for (offset, asset) in assets.enumerated() {
                    try Task.checkCancellation()
                    self.progress = "正在处理 \(offset + 1) / \(assets.count)"
                    let old = index[asset.localIdentifier]
                    if old != nil, old?.modifiedAt == asset.modificationDate { continue }
                    do {
                        let data = try await PhotoLoader.imageData(asset: asset, allowCloud: allowCloudDownloads)
                        try Task.checkCancellation()
                        let text = try await Self.recognize(data)
                        try Task.checkCancellation()
                        index[asset.localIdentifier] = IndexedPhoto(
                            id: asset.localIdentifier, createdAt: asset.creationDate,
                            modifiedAt: asset.modificationDate, text: text,
                            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot))
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        // Do not retain old text if an edited original can no longer be read.
                        index.removeValue(forKey: asset.localIdentifier)
                        skipped += 1
                    }
                    if (offset + 1).isMultiple(of: 20) {
                        self.records = Array(index.values)
                        self.save()
                    }
                }
                self.progress = "扫描完成，共 \(assets.count) 张，跳过 \(skipped) 张"
            } catch {
                self.progress = "扫描已暂停，下次会跳过已处理的照片"
            }
            // Recheck permissions before committing, including cancellation on revoke.
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .authorized || status == .limited {
                let available = PHAsset.fetchAssets(with: .image, options: nil)
                var IDs: Set<String> = []
                available.enumerateObjects { asset, _, _ in IDs.insert(asset.localIdentifier) }
                self.records = index.values.filter { IDs.contains($0.id) }
                self.save()
            } else { self.refreshAuthorization() }
        }
    }

    func pause() { scanTask?.cancel() }

    func clear() {
        // Only available while no scan is running, so a finishing scan cannot
        // accidentally recreate a cleared index.
        guard !isScanning else { return }
        do {
            try LocalStore.remove(fileName)
            records = []
            progress = "本机索引已清除"
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        do { try LocalStore.save(records, to: fileName) }
        catch { self.error = "索引未能保存：\(error.localizedDescription)" }
    }

    private nonisolated static func recognize(_ data: Data) async throws -> String {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["zh-Hans", "en-US"].filter { supported.contains($0) }
            let handler = VNImageRequestHandler(data: data, options: [:])
            try handler.perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}

enum PhotoLoader {
    static func imageData(asset: PHAsset, allowCloud: Bool) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowCloud
            // A single final callback is expected with highQualityFormat.
            PHImageManager.default().requestImage(for: asset,
                targetSize: CGSize(width: 2048, height: 2048), contentMode: .aspectFit,
                options: options) { image, info in
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                if let data = image?.jpegData(compressionQuality: 0.9) {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? PhotoError.unavailable)
                }
            }
        }
    }

    enum PhotoError: LocalizedError {
        case unavailable
        var errorDescription: String? { "无法读取图片；可能仅存于 iCloud，或相册权限发生了变化。" }
    }
}
