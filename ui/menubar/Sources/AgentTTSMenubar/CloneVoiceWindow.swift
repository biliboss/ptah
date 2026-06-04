// SPDX-License-Identifier: MIT OR Apache-2.0
//
// CloneVoiceWindow.swift — v1.10.3 guided voice-clone UI.
//
// One-button UX:
//   1. User picks a slug.
//   2. User reads a Pt-BR script aloud (30-90 s).
//   3. App records, saves a WAV, spawns `agent-tts voice clone --quiet`.
//   4. App refreshes the voice catalogue + closes when done.
//
// The window is a plain `NSWindow` hosting a SwiftUI root. We intentionally
// avoid a `Window` scene because this is an `LSUIElement` app — its window
// life-cycle is managed by AppDelegate, not the SwiftUI scene graph. Using
// the AppKit shell keeps the popover-only behaviour intact.
//
// Why NOT @MainActor on the controller: NSWindowController is open AppKit;
// we just need a strong reference holder. The SwiftUI root view + model are
// @MainActor-bound which gives us the safety we need.

import AppKit
import SwiftUI
import AVFoundation
import AgentTTSMenubarCore

/// Hard-coded 30-90 s Pt-BR script. Sentence-bounded so we can highlight one
/// at a time. Mix of declarative / interrogative / exclamative + lists +
/// numbers + emotion → broadest prosody signal for the XTTS clone.
public enum CloneVoiceScript {
    public static let sentences: [String] = [
        "A voz que você está gravando agora vai virar a voz da sua agente. Fale como se estivesse explicando algo importante para um amigo querido.",
        "Você sabia que a Mel responde no WhatsApp em menos de dois segundos? Incrível, não?",
        "Vamos pensar juntos: corretor profissional precisa de três coisas — agilidade, confiança e diferenciação. Tudo isso cabe numa única assistente digital.",
        "Imagine receber um link curado às vinte e duas horas, com vinte e três imóveis selecionados, e o cliente abrir só meia hora depois. Você sabe na hora, sem ficar perguntando.",
        "Se gostou, conta pra gente. Se não gostou, conta também. A Mel só melhora ouvindo você.",
    ]
}

@MainActor
public final class CloneVoiceWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    public func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        let initial = NSRect(x: 0, y: 0, width: 520, height: 640)
        let w = NSWindow(
            contentRect: initial,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        w.title = "Clone my voice"
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self

        let onDone: () -> Void = { [weak self] in
            self?.window?.performClose(nil)
        }
        let root = CloneVoiceView(onDone: onDone)
        w.contentViewController = NSHostingController(rootView: root)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    public func windowWillClose(_ notification: Notification) {
        // Keep the controller alive — the AppDelegate strong-references us;
        // it's the window itself that goes away. Wipe the reference so a
        // second show() rebuilds a fresh instance.
        window?.delegate = nil
        window = nil
        onClose()
    }
}

// MARK: - View-model

@MainActor
public final class CloneVoiceModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case recording
        case finishedRecording
        case processing
        case done(slug: String)
        case failed(message: String)
    }

    @Published public var slug: String = ""
    @Published public var phase: Phase = .idle
    @Published public var elapsed: TimeInterval = 0
    @Published public var meter: Float = 0
    @Published public var currentSentence: Int = 0
    @Published public var processingLog: String = ""
    @Published public var recordedURL: URL?

    public let recorder = VoiceRecorder()
    private var meterTimer: Timer?
    private var sentenceTimer: Timer?
    // Stash the spawn so we can kill it if the user cancels.
    private var cloneProcess: Process?
    // v1.10.4: persist staged path so a failed clone exposes a "Show in Finder"
    // affordance. Cleared on cancel().
    @Published public var stagedURLForDebug: URL?

    public init() {}

    public var slugIsValid: Bool {
        Self.isValidSlug(slug)
    }

    public var canRecord: Bool {
        switch phase {
        case .idle, .finishedRecording, .failed:
            return slugIsValid
        default:
            return false
        }
    }

    public var canSave: Bool {
        if case .finishedRecording = phase, recordedURL != nil, slugIsValid { return true }
        return false
    }

    /// Mirror of `voice.zig::validateSlug`: [a-z0-9-]{1,32}.
    public static func isValidSlug(_ s: String) -> Bool {
        if s.isEmpty || s.count > 32 { return false }
        for ch in s {
            let isLower = ("a"..."z").contains(ch)
            let isDigit = ("0"..."9").contains(ch)
            if !(isLower || isDigit || ch == "-") { return false }
        }
        return true
    }

    /// Begin recording. Triggers permission flow on first call.
    public func toggleRecord() {
        switch phase {
        case .recording:
            stopRecording()
        default:
            if !VoiceRecorder.hasPermission {
                phase = .requestingPermission
                VoiceRecorder.requestPermission { [weak self] granted in
                    Task { @MainActor in
                        guard let self = self else { return }
                        if granted {
                            self.startRecording()
                        } else {
                            self.phase = .permissionDenied
                        }
                    }
                }
            } else {
                startRecording()
            }
        }
    }

    private func startRecording() {
        do {
            let url = try recorder.start()
            recordedURL = url
            elapsed = 0
            meter = 0
            currentSentence = 0
            processingLog = ""
            phase = .recording
            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickMeter() }
            }
            // Auto-advance the highlighted sentence every ~7 s so the user
            // sees progress through the script. The script is 5 sentences so
            // 5×7 ≈ 35 s; that lands inside the 20-120 s sweet spot the
            // voice.zig validator enforces.
            sentenceTimer?.invalidate()
            sentenceTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    if self.currentSentence < CloneVoiceScript.sentences.count - 1 {
                        self.currentSentence += 1
                    }
                }
            }
        } catch {
            phase = .failed(message: String(describing: error))
        }
    }

    private func tickMeter() {
        elapsed = recorder.duration()
        meter = recorder.peakLevel()
    }

    private func stopRecording() {
        meterTimer?.invalidate()
        meterTimer = nil
        sentenceTimer?.invalidate()
        sentenceTimer = nil
        do {
            let result = try recorder.stop()
            recordedURL = result.url
            elapsed = result.duration
            phase = .finishedRecording
        } catch {
            phase = .failed(message: String(describing: error))
        }
    }

    /// Spawn `agent-tts voice clone --sample <wav> --name <slug> --quiet`.
    /// Streams stdout + stderr into `processingLog` so the user sees the
    /// XTTS sidecar's chatter live.
    public func saveAndClone() {
        guard let sample = recordedURL, slugIsValid else { return }

        // Copy the WAV to the well-known staging path so a `voice list` after
        // a crash can still find the source.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        let stageDir = "\(home)/.cache/agent-tts/voices"
        try? FileManager.default.createDirectory(atPath: stageDir, withIntermediateDirectories: true)
        let stagedURL = URL(fileURLWithPath: "\(stageDir)/.tmp-\(slug).wav")
        try? FileManager.default.removeItem(at: stagedURL)
        do {
            try FileManager.default.copyItem(at: sample, to: stagedURL)
        } catch {
            phase = .failed(message: "Could not stage WAV: \(error.localizedDescription)")
            return
        }

        // v1.10.4 diagnostic: log staged WAV size so the user can verify
        // the recording produced bytes before XTTS gets blamed for a silent fail.
        let stagedSize: Int = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: stagedURL.path),
               let n = attrs[.size] as? Int { return n }
            return 0
        }()
        stagedURLForDebug = stagedURL

        phase = .processing
        processingLog = "Staged WAV: \(stagedURL.path) (\(stagedSize) bytes)\n"
        processingLog += "Spawning agent-tts voice clone…\n"

        let proc = Process()
        // Prefer the canonical install location, fall back to the one in the
        // PATH so dev environments that use `swift run` still work.
        let candidates = [
            "/opt/homebrew/bin/agent-tts",
            "/usr/local/bin/agent-tts",
        ]
        var binPath: String? = nil
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            binPath = c
            break
        }
        if binPath == nil {
            // Falls through to `/usr/bin/env agent-tts` if nothing on the
            // standard locations — `Process()` doesn't search PATH unless
            // we use `env`.
            proc.launchPath = "/usr/bin/env"
            proc.arguments = [
                "agent-tts", "voice", "clone",
                "--sample", stagedURL.path,
                "--name", slug,
                "--quiet",
            ]
        } else {
            proc.launchPath = binPath
            proc.arguments = [
                "voice", "clone",
                "--sample", stagedURL.path,
                "--name", slug,
                "--quiet",
            ]
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Stream stdout. The --quiet contract delivers `OK\t<slug>` on success.
        let mySlug = slug
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self.processingLog.append(s)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self.processingLog.append(s)
            }
        }

        proc.terminationHandler = { p in
            Task { @MainActor in
                self.processingLog.append("\n--- subprocess exited with code \(p.terminationStatus) ---\n")
                if p.terminationStatus == 0 {
                    self.phase = .done(slug: mySlug)
                } else {
                    self.phase = .failed(message: "Clone failed (exit \(p.terminationStatus)). See log above.")
                }
            }
        }

        do {
            try proc.run()
            cloneProcess = proc
        } catch {
            phase = .failed(message: "Could not launch agent-tts: \(error.localizedDescription)")
        }
    }

    public func cancel() {
        if let p = cloneProcess, p.isRunning { p.terminate() }
        cloneProcess = nil
        recorder.cancel()
        meterTimer?.invalidate(); meterTimer = nil
        sentenceTimer?.invalidate(); sentenceTimer = nil
        phase = .idle
        recordedURL = nil
        processingLog = ""
        stagedURLForDebug = nil
        elapsed = 0
        meter = 0
        currentSentence = 0
    }

    /// v1.10.4: open the staged WAV in Finder so the user can verify the
    /// recording actually captured audio. Useful when the XTTS sidecar
    /// reports a failure and we want to rule out the recorder.
    public func revealStagedWAV() {
        guard let url = stagedURLForDebug,
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - View

public struct CloneVoiceView: View {
    @StateObject private var model = CloneVoiceModel()
    let onDone: () -> Void

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            slugRow
            Divider()
            scriptBlock
            Divider()
            recordingRow
            Divider()
            statusRow
            if !model.processingLog.isEmpty {
                logBlock
            }
            Spacer(minLength: 8)
            buttonRow
        }
        .padding(16)
        .frame(width: 520, height: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Clone my voice")
                .font(.system(size: 16, weight: .semibold))
            Text("Record 30-90 seconds of Pt-BR speech. The XTTS-v2 sidecar will turn it into a cloned voice you can use from any agent-tts client.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var slugRow: some View {
        HStack(spacing: 8) {
            Text("Slug")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 60, alignment: .leading)
            TextField("my-voice", text: $model.slug)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .disabled(disableInputs)
            if !model.slug.isEmpty && !model.slugIsValid {
                Text("[a-z0-9-]{1,32}")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
            } else {
                Text("[a-z0-9-]{1,32}")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var scriptBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Read aloud, naturally")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(CloneVoiceScript.sentences.enumerated()), id: \.offset) { idx, sentence in
                    Text(sentence)
                        .font(.system(size: 14))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(idx == model.currentSentence ? Color.accentColor.opacity(0.18) : Color.clear)
                        .cornerRadius(3)
                }
            }
        }
    }

    private var recordingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(action: model.toggleRecord) {
                    HStack(spacing: 6) {
                        Image(systemName: isActuallyRecording ? "stop.fill" : "record.circle")
                            .foregroundColor(isActuallyRecording ? .white : .red)
                        Text(isActuallyRecording ? "Stop" : "Record")
                            .foregroundColor(isActuallyRecording ? .white : .primary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(isActuallyRecording ? Color.red : Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(!canTapRecord)

                Text(formatElapsed(model.elapsed))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)

                // VU meter — width tracks peak.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(NSColor.separatorColor).opacity(0.4))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.green)
                            .frame(width: CGFloat(model.meter) * geo.size.width)
                    }
                }
                .frame(height: 8)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var logBlock: some View {
        ScrollView {
            Text(model.processingLog)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(height: 100)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(4)
    }

    private var buttonRow: some View {
        HStack {
            Button("Cancel") {
                model.cancel()
                onDone()
            }
            .keyboardShortcut(.cancelAction)
            // v1.10.4: surface staged WAV in Finder when something went wrong,
            // so the user can verify the recording before blaming XTTS.
            if model.stagedURLForDebug != nil {
                Button("Show WAV in Finder") {
                    model.revealStagedWAV()
                }
            }
            Spacer()
            if isDone {
                Button("Done") {
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Save & Clone") {
                    model.saveAndClone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
        }
    }

    // MARK: - Helpers

    private var disableInputs: Bool {
        switch model.phase {
        case .recording, .processing:
            return true
        default:
            return false
        }
    }

    private var isActuallyRecording: Bool {
        if case .recording = model.phase { return true }
        return false
    }

    private var canTapRecord: Bool {
        switch model.phase {
        case .processing, .done, .requestingPermission:
            return false
        case .permissionDenied:
            return false
        default:
            return model.slugIsValid
        }
    }

    private var isDone: Bool {
        if case .done = model.phase { return true }
        return false
    }

    private var statusColor: Color {
        switch model.phase {
        case .idle:                  return .gray
        case .requestingPermission:  return .orange
        case .permissionDenied:      return .red
        case .recording:             return .red
        case .finishedRecording:     return .blue
        case .processing:            return .orange
        case .done:                  return .green
        case .failed:                return .red
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle:                  return "Idle. Pick a slug and tap Record to start."
        case .requestingPermission:  return "Asking for microphone access…"
        case .permissionDenied:      return "Microphone access denied. Open System Settings → Privacy & Security → Microphone, enable agent-tts, then reopen this window."
        case .recording:             return "Recording… read the script aloud."
        case .finishedRecording:     return "Recording saved. Click Save & Clone to spawn the XTTS sidecar (~20-30 s cold)."
        case .processing:            return "Processing — XTTS sidecar running…"
        case .done(let slug):        return "Saved. \(slug) is now available in the voice picker."
        case .failed(let m):         return "Failed: \(m)"
        }
    }

    private func formatElapsed(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
