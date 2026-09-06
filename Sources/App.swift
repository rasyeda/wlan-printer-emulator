import SwiftUI
import AppKit

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    @Published var jobs: [PrintJob] = []
    @Published var selection: PrintJob.ID?
    @Published var state: PrinterState = .ready {
        didSet {
            server.state = state
            status = state == .ready ? listeningDescription
                : "Pretending the printer is \(state.rawValue.lowercased()) — \(state.detail)"
        }
    }
    @Published var paperWidth: PaperWidth = .mm80
    /// Defaults to 9100, the raw-print convention. `-port 9101` on the command
    /// line (or in UserDefaults) overrides it, which helps when something else
    /// already owns 9100 on this machine.
    @Published var port: UInt16 = {
        let stored = UserDefaults.standard.integer(forKey: "port")
        return stored > 0 && stored < 65536 ? UInt16(stored) : 9100
    }()
    /// 1 = one virtual printer, 2 = a second one on the next port, so a
    /// cashier and a kitchen printer can be paired at the same time.
    @Published var printerCount: Int = 1
    @Published var status: String = "Starting…"
    @Published var probeCount = 0
    @Published var showTrace = false
    @Published var failed = false
    @Published var livePorts: [UInt16] = []

    let outputFolder: URL
    private let server: PrinterServer

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("WlanPrinterEmulator/jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        outputFolder = base
        server = PrinterServer(outputFolder: base)

        server.onJob = { [weak self] job in
            guard let self else { return }
            self.jobs.insert(job, at: 0)
            self.selection = job.id
            self.status = "\(job.name) · \(job.byteCount) bytes from \(job.source)"
        }
        server.onProbe = { [weak self] host, _ in
            guard let self else { return }
            self.probeCount += 1
            self.status = "Discovery probe from \(host) · \(self.probeCount) total"
        }
        server.onError = { [weak self] port, message in
            guard let self else { return }
            self.livePorts.removeAll { $0 == port }
            self.failed = true
            self.status = "Port \(port) is unavailable — \(message). "
                + "Another process may already be using it; try a different port."
        }
        server.onWaiting = { [weak self] port, message in
            guard let self else { return }
            self.status = "Port \(port) is not free yet — \(message). "
                + "Waiting; pick another port if this persists."
        }
        server.onListening = { [weak self] port in
            guard let self else { return }
            if !self.livePorts.contains(port) { self.livePorts.append(port) }
            self.livePorts.sort()
            self.failed = false
            self.refreshStatus()
        }
        restart()
    }

    var ports: [UInt16] {
        printerCount == 2 ? [port, port + 1] : [port]
    }

    var listeningDescription: String {
        let ips = Net.localAddresses().map(\.ip)
        let portList = livePorts.map(String.init).joined(separator: " and ")
        if ips.isEmpty { return "Listening on port \(portList)" }
        return "Ready on \(ips.joined(separator: ", ")) · port \(portList)"
    }

    func restart() {
        failed = false
        livePorts.removeAll { !ports.contains($0) }
        server.state = state
        server.start(ports: ports)
        refreshStatus()
    }

    /// A port that is already listening fires no new callback, so the status has
    /// to be derived from what is live versus what was asked for — otherwise it
    /// stays on "Starting…" forever after a change that reused a live port.
    func refreshStatus() {
        guard !failed else { return }
        let pending = ports.filter { !livePorts.contains($0) }
        status = pending.isEmpty
            ? listeningDescription
            : "Starting on port \(pending.map(String.init).joined(separator: ", "))…"
    }

    var selectedJob: PrintJob? {
        jobs.first { $0.id == selection }
    }

    func clear() {
        jobs.removeAll()
        selection = nil
    }

    func revealFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outputFolder.path)
    }
}

enum PaperWidth: String, CaseIterable, Identifiable {
    case mm58 = "58 mm"
    case mm80 = "80 mm"
    var id: String { rawValue }
    var points: CGFloat { self == .mm58 ? 300 : 384 }
    var columns: Int { self == .mm58 ? 32 : 48 }
}

// MARK: - App

@main
struct WlanPrinterEmulatorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("WLAN Printer", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 1020, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Clear Job List") { model.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                Button("Show Job Files in Finder") { model.revealFolder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - Content

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ControlStrip()
            splitView
            StatusBar()
        }
    }

    /// The strip and status bar are siblings of the split view, not safe-area
    /// insets on it: an inset floats above the panes, so the sidebar list and
    /// the receipt scroll view end up underneath it.
    private var splitView: some View {
        NavigationSplitView {
            JobList()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            Group {
                if let job = model.selectedJob {
                    ReceiptDetail(job: job)
                } else {
                    EmptyState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .toolbar { Toolbar() }
    }
}

/// The toolbar holds only actions. Settings live in the ControlStrip below it,
/// where there is room for a written label beside every control — a crowded
/// toolbar collapses into an overflow menu and hides exactly those labels.
struct Toolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem {
            Toggle(isOn: $model.showTrace) {
                Label("Commands", systemImage: "list.bullet.rectangle")
            }
            .labelStyle(.titleAndIcon)
            .help("Show the ESC/POS commands the app sent for the selected job, "
                  + "decoded line by line, below the receipt")
        }
        ToolbarItem {
            Button { model.revealFolder() } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .labelStyle(.titleAndIcon)
            .help("Open the folder holding the raw bytes, decoded trace and "
                  + "images for every job received")
        }
        ToolbarItem {
            Button { model.clear() } label: {
                Label("Clear List", systemImage: "xmark.circle")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.jobs.isEmpty)
            .help("Empty the job list in this window. "
                  + "The saved files on disk are not deleted.")
        }
    }
}

/// Full-width settings row. Every control is preceded by a written label saying
/// what it changes, so nothing depends on recognising an icon.
struct ControlStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var content: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Text("Pretend printer is:").foregroundStyle(.secondary).fixedSize()
                Picker("Pretend printer is", selection: $model.state) {
                    ForEach(PrinterState.allCases) { state in
                        Text(state.rawValue).tag(state)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(PrinterState.allCases
                    .map { "\($0.rawValue): \($0.detail)" }
                    .joined(separator: "\n"))
            }

            Divider().frame(height: 16)

            PortField()

            Divider().frame(height: 16)

            HStack(spacing: 6) {
                Text("Paper:").foregroundStyle(.secondary).fixedSize()
                Picker("Paper width", selection: $model.paperWidth) {
                    ForEach(PaperWidth.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Width of the paper roll to draw receipts on. "
                      + "Match it to the printer you are emulating.")
            }

        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Port picker. 9100 is the raw-print convention, but it is often already taken
/// on a developer machine, so the field has to be editable, the change has to
/// be obviously applicable, and a bind failure has to be visible.
struct PortField: View {
    @EnvironmentObject var model: AppModel
    @State private var text = "9100"
    @FocusState private var focused: Bool

    private var edited: Bool { text != String(model.port) }

    var body: some View {
        HStack(spacing: 6) {
            Text("Port:").foregroundStyle(.secondary).fixedSize()
            TextField("9100", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                .onSubmit(apply)
                .help("TCP port this fake printer listens on. "
                      + "9100 is the standard raw-printing port. "
                      + "Type a new one and press Return to switch.")

            // Only shown once the value differs, so it reads as "apply this".
            if edited {
                Button("Apply", action: apply)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Restart the printer on port \(text)")
            }

            Picker("Number of printers", selection: Binding(
                get: { model.printerCount },
                set: { model.printerCount = $0; model.restart() }
            )) {
                Text("1 printer · port \(String(model.port))").tag(1)
                Text("2 printers · ports \(String(model.port)) + \(String(model.port + 1))").tag(2)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Run a second fake printer on the next port, so you can pair a "
                  + "cashier printer and a kitchen printer at the same time and "
                  + "check that each receipt goes to the right one.")
        }
        .onAppear { text = String(model.port) }
    }

    private func apply() {
        guard let value = UInt16(text), value > 0 else {
            text = String(model.port)      // reject nonsense, restore the live port
            return
        }
        model.port = value
        model.restart()
        focused = false
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.failed
                  ? "exclamationmark.triangle.fill" : model.state.symbol)
                .foregroundStyle(model.failed ? Color.red
                                 : (model.state == .ready ? Color.green : Color.orange))
                .font(.system(size: 11))
            Text(model.status)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if model.probeCount > 0 {
                Text("\(model.probeCount) probes")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "printer.dotmatrix")
                .font(.system(size: 42, weight: .thin))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Waiting for a print job")
                    .font(.title3.weight(.medium))
                Text("This window pretends to be a network receipt printer. "
                     + "Anything printed to it appears here instead of on paper.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("In the app you are testing, add a WiFi/LAN printer at:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(Net.localAddresses(), id: \.ip) { iface in
                    HStack(spacing: 8) {
                        Text("\(iface.ip):\(String(model.port))")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                        Text("(\(iface.name))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                if Net.localAddresses().isEmpty {
                    Text("No network interface found — is WiFi on?")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(40)
    }
}

// MARK: - Job list

struct JobList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.jobs) { job in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(job.name).font(.system(size: 12, weight: .semibold,
                                                    design: .monospaced))
                        Spacer()
                        Text(job.timeLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(job.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(job.byteCount) bytes · \(job.source)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
                .tag(job.id)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.jobs.isEmpty {
                Text("No jobs yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Receipt

struct ReceiptDetail: View {
    @EnvironmentObject var model: AppModel
    let job: PrintJob

    var body: some View {
        VSplitView {
            ScrollView {
                VStack(spacing: 18) {
                    if let tsc = job.tscText {
                        TSCView(text: tsc)
                    } else {
                        ForEach(Array(job.sheets.enumerated()), id: \.offset) { index, sheet in
                            PaperView(blocks: sheet, width: model.paperWidth)
                            if index < job.sheets.count - 1 { TearLine() }
                        }
                    }
                }
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            if model.showTrace {
                TraceView(lines: job.trace)
                    .frame(minHeight: 120, idealHeight: 190)
            }
        }
    }
}

struct PaperView: View {
    let blocks: [Block]
    let width: PaperWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, paper: width)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(width: width.points, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
    }
}

struct BlockView: View {
    let block: Block
    let paper: PaperWidth

    var body: some View {
        switch block {
        case .text(let text, let style):
            ReceiptLine(text: text, style: style)
        case .image(let bitmap, let name):
            if let cg = bitmap.cgImage() {
                // The paper view is one point per printer dot, so an image is
                // drawn at its own dot size and only shrunk if it overflows.
                let maxWidth = paper.points - 32
                let scale = min(1, maxWidth / CGFloat(bitmap.width))
                Image(decorative: cg, scale: 1, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(bitmap.width) * scale,
                           height: CGFloat(bitmap.height) * scale)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 5)
                    .help("\(name) · \(bitmap.width)×\(bitmap.height) dots")
            }
        case .note(let text):
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color(red: 0.72, green: 0.11, blue: 0.16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
        case .cut:
            EmptyView()
        }
    }
}

/// One printed line. A thermal printer scales the glyph cell, so width and
/// height multipliers are independent — height maps to point size, width to a
/// horizontal scale on top of it.
struct ReceiptLine: View {
    let text: String
    let style: Style

    private var size: CGFloat { 11 * CGFloat(style.heightMul) }

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: size,
                          weight: style.bold ? .bold : .regular,
                          design: .monospaced))
            .underline(style.underline)
            .foregroundStyle(style.invert ? Color.white : Color.black)
            .background(style.invert ? Color.black : Color.clear)
            .scaleEffect(x: CGFloat(style.widthMul) / CGFloat(style.heightMul), y: 1,
                         anchor: anchor)
            .frame(maxWidth: .infinity, alignment: alignment)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var alignment: Alignment {
        switch style.align {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private var anchor: UnitPoint {
        switch style.align {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

struct TearLine: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<28, id: \.self) { _ in
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 1.5)
            }
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "scissors")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .offset(x: 18)
        }
    }
}

struct TSCView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("TSC / TSPL label job", systemImage: "barcode")
                .font(.callout.weight(.medium))
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(maxWidth: 520, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(.black)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct TraceView: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(for line: String) -> Color {
        if line.contains("***") { return .orange }
        if line.contains("->") { return .green }
        if line.contains("unhandled") { return .secondary }
        return .primary
    }
}
