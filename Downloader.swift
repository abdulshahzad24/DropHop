import Foundation

/// Downloads one file to a temporary location and reports progress.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private struct Handler {
        var progress: (Double) -> Void
        var cont: CheckedContinuation<URL, Error>
    }

    private var session: URLSession!
    private var handlers: [Int: Handler] = [:]
    private let lock = NSLock()

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func download(_ request: URLRequest, progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let task = session.downloadTask(with: request)
            lock.lock()
            handlers[task.taskIdentifier] = Handler(progress: progress, cont: cont)
            lock.unlock()
            task.resume()
        }
    }

    private func handler(for task: URLSessionTask) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[task.taskIdentifier]
    }

    private func finish(_ task: URLSessionTask, _ result: Result<URL, Error>) {
        lock.lock()
        let h = handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        h?.cont.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        handler(for: downloadTask)?.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(downloadTask, .failure(http.statusCode == 401 ? SyncError.unauthorized
                                                                 : SyncError.http(http.statusCode)))
            return
        }
        // The system deletes `location` when this method returns, so move it right away.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            finish(downloadTask, .success(staged))
        } catch {
            finish(downloadTask, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(task, .failure(error)) }
    }
}
