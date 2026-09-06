import Foundation
import Network

// MARK: - Job

enum PrinterState: String, CaseIterable, Identifiable {
    case ready = "Working"
    case offline = "Switched off"
    case stalled = "Jammed"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .ready: return "printer.fill"
        case .offline: return "poweroff"
        case .stalled: return "exclamationmark.triangle.fill"
        }
    }

    var detail: String {
        switch self {
        case .ready:
            return "Accepts jobs and prints them normally."
        case .offline:
            return "Refuses every connection, like a printer that is powered off "
                + "or off the network. Use it to test the app's error handling."
        case .stalled:
            return "Accepts the job then stops reading half-way, like a paper jam. "
                + "Use it to test print timeouts and retries."
        }
    }
}

struct PrintJob: Identifiable {
    let id = UUID()
    let name: String
    let date: Date
    let source: String
    let port: UInt16
    let byteCount: Int
    let elapsed: TimeInterval
    var blocks: [Block] = []
    var trace: [String] = []
    var tscText: String?
    var imageCount = 0
    var folder: URL

    var summary: String {
        if tscText != nil { return "TSC label job" }
        return imageCount > 0
            ? "Receipt · \(imageCount) image\(imageCount == 1 ? "" : "s")"
            : "Receipt"
    }

    var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// Blocks split into sheets at every cut, with a trailing blank sheet dropped.
    var sheets: [[Block]] {
        var result: [[Block]] = []
        var current: [Block] = []
        for block in blocks {
            if case .cut = block {
                result.append(current)
                current = []
            } else {
                current.append(block)
            }
        }
        result.append(current)
        while result.count > 1, let last = result.last, !Self.hasContent(last) {
            result.removeLast()
        }
        return result
    }

    private static func hasContent(_ sheet: [Block]) -> Bool {
        sheet.contains { block in
            switch block {
            case .image, .note: return true
            case .text(let t, _): return !t.trimmingCharacters(in: .whitespaces).isEmpty
            case .cut: return false
            }
        }
    }
}

// MARK: - Server

/// A raw TCP listener that behaves like a network thermal printer on port 9100.
///
/// The app under test only ever writes; it never reads a reply, so accepting the
/// connection and consuming bytes is the whole protocol. A connection that sends
/// nothing is a discovery probe (NetworkAnalyzer.discover2 connect-scans the
/// subnet), not a job.
final class PrinterServer {
    private var listeners: [UInt16: NWListener] = [:]
    private let queue = DispatchQueue(label: "printer.server", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _state: PrinterState = .ready

    var onJob: ((PrintJob) -> Void)?
    var onProbe: ((String, UInt16) -> Void)?
    var onError: ((UInt16, String) -> Void)?
    var onListening: ((UInt16) -> Void)?
    var onWaiting: ((UInt16, String) -> Void)?

    var outputFolder: URL

    var state: PrinterState {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _state }
        set { stateLock.lock(); _state = newValue; stateLock.unlock() }
    }

    init(outputFolder: URL) {
        self.outputFolder = outputFolder
    }

    /// Bring the set of listening ports in line with `ports`.
    ///
    /// Only the difference is applied: a port that is already listening is left
    /// completely alone. Cancelling and immediately re-binding the same port
    /// races the socket still being torn down, which surfaces as a spurious
    /// bind failure.
    func start(ports: [UInt16]) {
        let desired = Set(ports)
        for (port, listener) in listeners where !desired.contains(port) {
            listener.cancel()
            listeners[port] = nil
        }
        for port in ports where listeners[port] == nil {
            open(port)
        }
    }

    private func open(_ port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn, port: port)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.report { self.onListening?(port) }
                case .failed(let error):
                    self.listeners[port] = nil
                    self.report { self.onError?(port, error.localizedDescription) }
                case .waiting(let error):
                    // Network.framework parks a listener here on a transient
                    // bind conflict and retries silently. Without this case the
                    // UI waits forever for a "ready" that may never come.
                    self.report { self.onWaiting?(port, error.localizedDescription) }
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.start(queue: queue)
            listeners[port] = listener
        } catch {
            report { self.onError?(port, error.localizedDescription) }
        }
    }

    /// Every callback crosses to the main queue here. Publishing SwiftUI state
    /// from the network queue aborts the process inside AppKit's menu update.
    private func report(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    func stop() {
        listeners.values.forEach { $0.cancel() }
        listeners = [:]
    }

    var activePorts: [UInt16] { listeners.keys.sorted() }

    private func accept(_ conn: NWConnection, port: UInt16) {
        if state == .offline {
            conn.cancel()
            return
        }
        let started = Date()
        var buffer = [UInt8]()
        var finished = false
        conn.start(queue: queue)

        func finish() {
            guard !finished else { return }
            finished = true
            conn.cancel()
            let host = Self.describe(conn.endpoint)
            if buffer.isEmpty {
                self.report { self.onProbe?(host, port) }
                return
            }
            let job = self.buildJob(bytes: buffer, host: host, port: port, started: started)
            self.report { self.onJob?(job) }
        }

        // A print stream ends when the app disconnects; a short idle also ends it,
        // which keeps a client that holds the socket open from hanging the job.
        func armIdleTimer() {
            queue.asyncAfter(deadline: .now() + 2.5) {
                if !buffer.isEmpty { finish() }
            }
        }

        func receive() {
            if state == .stalled && buffer.count >= 512 {
                queue.asyncAfter(deadline: .now() + 30) { finish() }
                return
            }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(contentsOf: data)
                    armIdleTimer()
                }
                if isComplete || error != nil {
                    finish()
                } else {
                    receive()
                }
            }
        }
        receive()
        armIdleTimer()
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            let s = "\(host)"
            return s.components(separatedBy: "%").first ?? s
        }
        return "\(endpoint)"
    }

    // MARK: - Job assembly

    private func buildJob(bytes: [UInt8], host: String, port: UInt16, started: Date) -> PrintJob {
        let name = Self.nextJobName()
        let folder = outputFolder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(bytes).write(to: folder.appendingPathComponent("raw.bin"))

        var job = PrintJob(name: name, date: Date(), source: host, port: port,
                           byteCount: bytes.count,
                           elapsed: Date().timeIntervalSince(started),
                           folder: folder)

        if looksLikeTSC(bytes) {
            let text = String(decoding: bytes, as: UTF8.self)
            job.tscText = text
            job.trace = ["TSC / TSPL label job", ""] + text.components(separatedBy: "\n")
        } else {
            let dec = EscPosDecoder(data: bytes, outDir: folder, jobName: name).run()
            job.blocks = dec.blocks
            job.trace = dec.trace
            job.imageCount = dec.imageCount
        }

        let header = "\(name)  from \(host)  port \(port)  \(bytes.count) bytes"
        let text = ([header, ""] + job.trace).joined(separator: "\n")
        try? text.write(to: folder.appendingPathComponent("trace.txt"),
                        atomically: true, encoding: .utf8)
        return job
    }

    private static var counter = 0
    private static let counterLock = NSLock()

    private static func nextJobName() -> String {
        counterLock.lock(); defer { counterLock.unlock() }
        counter += 1
        return String(format: "job-%04d", counter)
    }
}

// MARK: - Addresses

enum Net {
    /// IPv4 addresses of live interfaces, so the user knows what to pair against.
    static func localAddresses() -> [(name: String, ip: String)] {
        var result: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let name = String(cString: ptr.pointee.ifa_name)
                result.append((name, String(cString: host)))
            }
        }
        return result
    }
}
