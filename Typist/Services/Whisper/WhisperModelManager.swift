import Foundation
import os

private let logger = Logger(subsystem: "jp.kw2.Typist", category: "WhisperModel")

enum WhisperModelState: Equatable {
    case idle
    case downloading(progress: Double)
    case loading
    case ready(path: String)
    case error(String)
}

@Observable @MainActor
final class WhisperModelManager {
    var state: WhisperModelState = .idle

    private static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
    private static let modelFileName = "ggml-large-v3-turbo-q5_0.bin"

    private static var cacheDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Caches/models/whisper", isDirectory: true)
    }

    static var modelPath: URL {
        cacheDirectory.appendingPathComponent(modelFileName)
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    func ensureModel() async throws -> String {
        let path = Self.modelPath

        if FileManager.default.fileExists(atPath: path.path) {
            logger.info("Model found at cache: \(path.path)")
            return path.path
        }

        try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)

        state = .downloading(progress: 0)
        logger.info("Downloading model...")

        let localURL = try await download(from: Self.modelURL, to: path)
        return localURL.path
    }

    private func download(from remoteURL: URL, to destination: URL) async throws -> URL {
        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                self?.state = .downloading(progress: progress)
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (tempURL, response) = try await session.download(from: remoteURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WhisperModelError.downloadFailed(statusCode: code)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        logger.info("Download complete: \(destination.path)")
        return destination
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled by the async download(from:) call
    }
}

enum WhisperModelError: LocalizedError {
    case downloadFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let code):
            return "Whisper model download failed (HTTP \(code))"
        }
    }
}
