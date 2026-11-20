#if os(iOS)
import Foundation
import UIKit
import VChatCore

/// The daemon owns the POST from the outset; switching apps never replays a chat or a tool call.
@MainActor final class BackgroundReplyTransfers: NSObject, @preconcurrency URLSessionDataDelegate {
    static let identifier = "vchat.background-replies.v1"
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration? = nil) {
        self.configuration = configuration ?? Self.backgroundConfiguration()
        super.init()
    }
    private static func backgroundConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        return config
    }
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

    struct Receipt: Codable, Sendable {
        var error: String?
        var stopped = false
    }
    struct Ticket {
        let directory: URL
        let events: AsyncStream<Receipt>
        fileprivate let output: AsyncStream<Receipt>.Continuation
    }
    private var tickets: [String: Ticket] = [:]
    private var tasks: [String: URLSessionTask] = [:]
    private var delivered = Set<String>()
    private var completion: (() -> Void)?
    private var finishedEvents = false
    private var root: URL!

    func handleWake(_ completion: @escaping () -> Void) {
        self.completion = completion
        finishWakeIfReady()
    }
    func finishWakeIfReady() {
        guard finishedEvents, delivered.isEmpty, let completion else { return }
        finishedEvents = false; self.completion = nil; completion()
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        finishedEvents = true
        finishWakeIfReady()
    }
    func configure(at directory: URL, jobs: [BackgroundReplyJob]) async throws -> [String: Ticket] {
        root = directory.appendingPathComponent("ReplyTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let ids = Set(jobs.map(\.id))
        for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !ids.contains(item.lastPathComponent) {
            try? FileManager.default.removeItem(at: item)
        }
        for id in ids { _ = makeTicket(id) }
        let restored = tickets
        let running = await session.allTasks
        for task in running {
            guard let id = task.taskDescription, ids.contains(id) else { task.cancel(); continue }
            tasks[id] = task
        }
        for (id, ticket) in restored {
            if let data = try? Data(contentsOf: ticket.directory.appendingPathComponent("receipt")),
               let receipt = try? JSONDecoder().decode(Receipt.self, from: data) {
                deliver(receipt, for: id)
            } else if tasks[id] == nil {
                deliver(Receipt(error: "后台请求已中断，可在原消息上重新生成"), for: id)
            }
        }
        return restored
    }
    private func makeTicket(_ id: String) -> Ticket {
        let (events, output) = AsyncStream<Receipt>.makeStream()
        let ticket = Ticket(directory: root.appendingPathComponent(id, isDirectory: true), events: events, output: output)
        tickets[id] = ticket
        return ticket
    }
    nonisolated private static func prepare(_ request: ChatRequest, directory: URL) async throws -> URLRequest {
        var call = try request.urlRequest(streaming: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        guard let body = call.httpBody else { throw ClientError.invalidConfiguration }; try body.write(to: directory.appendingPathComponent("post"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        call.httpBody = nil
        return call
    }
    func submit(_ job: BackgroundReplyJob, request: ChatRequest, room: ChatRoom) async -> Ticket {
        let ticket = makeTicket(job.id)
        do {
            let call = try await Self.prepare(request, directory: ticket.directory)
            if room.cancelled { deliver(Receipt(stopped: true), for: job.id); return ticket }
            let task = session.uploadTask(with: call, fromFile: ticket.directory.appendingPathComponent("post"))
            task.taskDescription = job.id; tasks[job.id] = task
            task.resume()
        } catch {
            deliver(Receipt(error: error.localizedDescription), for: job.id)
        }
        return ticket
    }
    func cancel(_ id: String) {
        tasks[id]?.cancel()
        deliver(Receipt(stopped: true), for: id)
    }

    // Response bytes can arrive in several callbacks, even across a process relaunch.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = dataTask.taskDescription, let ticket = tickets[id], !delivered.contains(id) else { return }
        do {
            let url = ticket.directory.appendingPathComponent("response")
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
            let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
            let length = try file.seekToEnd()
            guard length + UInt64(data.count) <= 16_000_000 else { throw ClientError.tooLarge }
            try file.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            deliver(Receipt(error: error.localizedDescription), for: id)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let message: String?
        if error != nil { message = "后台请求未完成，请检查网络后重试" }
        else if let status, !(200..<300).contains(status) { message = ClientError.http(status).localizedDescription }
        else if status == nil { message = ClientError.invalidResponse.localizedDescription }
        else { message = nil }
        deliver(Receipt(error: message), for: id)
    }
    private func deliver(_ receipt: Receipt, for id: String) {
        guard let ticket = tickets[id], delivered.insert(id).inserted else { return }
        // Keep a receipt until the SQLite transaction commits. Relaunch can replay that commit, never the POST.
        try? JSONEncoder().encode(receipt).write(to: ticket.directory.appendingPathComponent("receipt"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        ticket.output.yield(receipt); ticket.output.finish()
    }
    nonisolated static func readReply(_ directory: URL) async throws -> FinishedReply {
        try FinishedReply(data: Data(contentsOf: directory.appendingPathComponent("response"), options: .mappedIfSafe))
    }
    func acknowledge(_ id: String, committed: Bool) {
        if let ticket = tickets.removeValue(forKey: id), committed { try? FileManager.default.removeItem(at: ticket.directory) }
        tasks[id] = nil; delivered.remove(id)
        finishWakeIfReady()
    }
}

extension ChatViewModel {
    func restoreBackgroundReplies(store: ChatStore, root: URL) async throws {
        let jobs = try await store.backgroundReplies()
        let tickets = try await replyTransfers.configure(at: root, jobs: jobs)
        for job in jobs {
            guard let ticket = tickets[job.id] else { continue }
            let room: ChatRoom
            if let existing = rooms[job.topicID] { room = existing }
            else {
                room = ChatRoom(id: job.topicID, messages: try await store.messages(topicID: job.topicID))
                let draft = try await store.records(TopicDraft.self, kind: "draft").first { $0.id == room.id }
                room.draft = draft?.text ?? ""; room.attachments = draft?.attachments ?? []
                rooms[room.id] = room
            }
            room.busy = true; room.receivesInBackground = true; room.backgroundJobID = job.id
            room.connection = "正在等待后台回复"
            room.generation = Task {
                await collectBackgroundReply(job, ticket: ticket, room: room, store: store)
                room.busy = false; room.generation = nil
            }
        }
    }
    func collectBackgroundReply(_ job: BackgroundReplyJob, ticket: BackgroundReplyTransfers.Ticket, room: ChatRoom, store: ChatStore) async {
        var committed = false
        defer {
            room.backgroundJobID = nil
            replyTransfers.acknowledge(job.id, committed: committed)
        }
        for await receipt in ticket.events {
            var issue = receipt.error
            var reply: FinishedReply?
            if !receipt.stopped && issue == nil {
                do { reply = try await BackgroundReplyTransfers.readReply(ticket.directory) }
                catch { issue = "未收到完整的 AI 回复" }
            }
            let stopped = receipt.stopped || room.cancellation == .stopped
            do {
                let record: StoredMessage?
                do { record = try await store.finishBackgroundReply(job, reply: stopped ? nil : reply, stopped: stopped) }
                catch ClientError.tooLarge {
                    issue = ClientError.tooLarge.localizedDescription
                    record = try await store.finishBackgroundReply(job, reply: nil)
                }
                committed = true
                guard let record else { return }
                if let message = room.messages.first(where: { $0.id == record.id }) {
                    message.text = record.content; message.reasoning = record.reasoning; message.status = record.status
                }
                if record.status == "complete" {
                    if let id = job.userID { room.messages.first { $0.id == id }?.status = "complete" }
                    room.connection = "回复完成"
                    await ReplyPresentation.end(job.id, phase: .complete)
                    await ReplyPresentation.notify(job)
                } else {
                    room.connection = stopped ? "已停止" : "已中断"
                    room.error = stopped ? nil : issue
                    await ReplyPresentation.end(job.id, phase: stopped ? .stopped : .interrupted)
                }
                room.pendingCount = room.messages.filter { $0.status == "pending" }.count
            } catch {
                room.error = "本机保存失败：" + error.localizedDescription
                await ReplyPresentation.end(job.id, phase: .interrupted)
            }
            return
        }
    }
}
#endif
