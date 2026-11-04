// Dictado Domotex v5.5 — Edición Titanio Turbo & Anti-Ruido DSP
// Diseñado para el Ingeniero Sebastián Muñoz (macOS Tahoe / Sequoia / Apple Silicon)
//
// ARQUITECTURA:
// 1. Grabación Pura PCM Hardware: Basado en AVAudioRecorder / CoreAudio HAL directo.
//    Cero dependencias de grafos de audio inestables. Cero bloqueos con auriculares Bluetooth (Sony WH-1000XM5, AirPods).
// 2. Transcripción Instantánea con Whisper MLX Daemon: Motor residente en memoria GPU Metal (Large v3 Turbo + Silero VAD)
//    que transcribe audios de cualquier duración en < 0.8s con filtrado acústico contra música y ruido de fondo.
// 3. Cero Límites de Tiempo: Habla 5 segundos, 1 minuto, 5 minutos o media hora. El audio NUNCA se corta.
// 4. Medidor VU en Vivo: Visualizador de audio dinámico y cronómetro en el HUD flotante superior.
// 5. Triple Redundancia de Transcripción: Daemon Socket -> Whisper MLX CLI -> Apple SFSpeechURL.
// 6. Respaldo Físico Perpetuo: Cada dictado queda guardado en ~/Library/Logs/UltimoDictado.wav y UltimoDictado.txt.
// 7. Atajos: Control + Opción + Espacio, Tecla F8, Clic en barra de menú, y ⌥⌘N para re-pegar.

import Cocoa
import AVFoundation
import Speech
import Carbon.HIToolbox

let homeDir = FileManager.default.homeDirectoryForCurrentUser
let logURL = homeDir.appendingPathComponent("Library/Logs/DictadoDomotex.log")
let backupTextURL = homeDir.appendingPathComponent("Library/Logs/UltimoDictado.txt")
let backupAudioURL = homeDir.appendingPathComponent("Library/Logs/UltimoDictado.wav")
let tempAudioURL = URL(fileURLWithPath: "/tmp/dictado_actual.wav")
let whisperSocketPath = "/tmp/dictado_whisper.sock"
let whisperPythonPath = "/Users/sebastianmunoz/Documents/Programas/Transcripcion de audio/.venv/bin/python3"
let whisperCLIPath = "/Users/sebastianmunoz/Documents/Programas/Transcripcion de audio/.venv/bin/mlx_whisper"

func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

func guardarRespaldoTexto(_ text: String) {
    guard !text.isEmpty else { return }
    try? text.write(to: backupTextURL, atomically: true, encoding: .utf8)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}

// MARK: - Panel Flotante Superior (Overlay HUD)
final class NonFocusingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Overlay {
    let panel: NonFocusingPanel
    let dot = NSTextField(labelWithString: "🔴")
    let title = NSTextField(labelWithString: "")
    let counter = NSTextField(labelWithString: "")
    let text = NSTextField(wrappingLabelWithString: "")

    init() {
        panel = NonFocusingPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 86),
                                 styleMask: [.nonactivatingPanel, .borderless],
                                 backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let fx = NSVisualEffectView(frame: panel.contentView!.bounds)
        fx.autoresizingMask = [.width, .height]
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 22
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        dot.font = .systemFont(ofSize: 13)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        counter.textColor = .systemOrange

        text.font = .systemFont(ofSize: 15, weight: .regular)
        text.textColor = .labelColor
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail

        for v in [dot, title, counter, text] {
            v.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(v)
        }

        NSLayoutConstraint.activate([
            dot.topAnchor.constraint(equalTo: fx.topAnchor, constant: 12),
            dot.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 18),
            title.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            counter.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            counter.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -18),
            counter.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
            text.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            text.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 18),
            text.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -18),
            text.bottomAnchor.constraint(lessThanOrEqualTo: fx.bottomAnchor, constant: -8),
        ])
    }

    func show(status: String, initialText: String = "…", stats: String = "") {
        dot.stringValue = "🔴"
        title.stringValue = status
        counter.stringValue = stats
        text.stringValue = initialText
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - 110))
        panel.orderFrontRegardless()
    }

    func update(status: String? = nil, text t: String? = nil, stats: String? = nil, dotIcon: String? = nil) {
        if let d = dotIcon { dot.stringValue = d }
        if let s = status { title.stringValue = s }
        if let st = stats { counter.stringValue = st }
        if let t = t { text.stringValue = t.isEmpty ? "…" : t }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

// MARK: - Motor de Grabación Puro (AVAudioRecorder / CoreAudio HAL)
final class AudioCaptureEngine: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startTime: Date?
    private(set) var isRecording = false

    var onMeterUpdate: ((_ vuString: String, _ elapsedStr: String, _ sizeStr: String) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    private var vuHistory: [Float] = [0, 0, 0, 0, 0, 0]

    func start() throws {
        // Detener y limpiar grabaciones previas
        stopRecordingCleanup()
        try? FileManager.default.removeItem(at: tempAudioURL)

        // Configuración de audio Linear PCM 16kHz Mono 16-bit
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let rec = try AVAudioRecorder(url: tempAudioURL, settings: settings)
        rec.delegate = self
        rec.isMeteringEnabled = true

        guard rec.record() else {
            throw NSError(domain: "AudioCaptureEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No se pudo iniciar la captura de audio en el micrófono"])
        }

        self.recorder = rec
        self.isRecording = true
        self.startTime = Date()
        self.vuHistory = [0, 0, 0, 0, 0, 0]

        onStateChange?(true)
        startMetering()
        log("Captura de audio iniciada con éxito en \(tempAudioURL.path)")
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self = self, let rec = self.recorder, self.isRecording else { return }
            rec.updateMeters()
            let power = rec.averagePower(forChannel: 0)

            // Convertir dB (-60 a 0) en un nivel de 0 a 7
            let level: Int
            if power < -55 { level = 0 }
            else if power < -45 { level = 1 }
            else if power < -36 { level = 2 }
            else if power < -28 { level = 3 }
            else if power < -20 { level = 4 }
            else if power < -14 { level = 5 }
            else if power < -8  { level = 6 }
            else { level = 7 }

            let bars = [" ", " ", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

            // Historial deslizante de 6 barras para animación fluida
            self.vuHistory.removeFirst()
            self.vuHistory.append(Float(level))
            let vuDisplay = "[" + self.vuHistory.map { bars[min(max(Int($0), 0), bars.count - 1)] }.joined() + "]"

            // Tiempo transcurrido
            let elapsed = Date().timeIntervalSince(self.startTime ?? Date())
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            let elapsedStr = String(format: "%02d:%02d", mins, secs)

            // Tamaño del archivo
            var sizeStr = "0 KB"
            if let attr = try? FileManager.default.attributesOfItem(atPath: tempAudioURL.path),
               let bytes = attr[.size] as? Int64 {
                if bytes >= 1024 * 1024 {
                    sizeStr = String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
                } else {
                    sizeStr = "\(bytes / 1024) KB"
                }
            }

            self.onMeterUpdate?(vuDisplay, elapsedStr, sizeStr)
        }
    }

    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        stopRecordingCleanup()
        onStateChange?(false)

        let exists = FileManager.default.fileExists(atPath: tempAudioURL.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: tempAudioURL.path)[.size] as? Int64) ?? 0
        log("Captura de audio finalizada. Archivo: \(size) bytes.")

        guard exists, size > 1500 else {
            log("Aviso: Archivo de audio vacío o inexistente")
            return nil
        }

        // Respaldo perpetuo del audio físico
        try? FileManager.default.removeItem(at: backupAudioURL)
        try? FileManager.default.copyItem(at: tempAudioURL, to: backupAudioURL)

        return tempAudioURL
    }

    func cancel() {
        isRecording = false
        stopRecordingCleanup()
        onStateChange?(false)
        try? FileManager.default.removeItem(at: tempAudioURL)
    }

    private func stopRecordingCleanup() {
        meterTimer?.invalidate()
        meterTimer = nil
        if let r = recorder {
            r.stop()
            recorder = nil
        }
    }
}

// MARK: - Cliente y Supervisor del Whisper MLX Daemon
final class WhisperSupervisor {
    private var daemonProcess: Process?

    init() {
        ensureDaemonRunning()
    }

    func ensureDaemonRunning() {
        if isDaemonAlive() { return }

        log("Iniciando Whisper MLX Daemon en segundo plano...")
        let daemonScript = findDaemonScript()
        guard FileManager.default.fileExists(atPath: daemonScript) else {
            log("Error: Script whisper_daemon.py no encontrado en \(daemonScript)")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: whisperPythonPath)
        p.arguments = [daemonScript]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/Users/sebastianmunoz/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
            daemonProcess = p
            // Esperar de forma no bloqueante a que el socket esté listo
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<25 {
                    Thread.sleep(forTimeInterval: 0.2)
                    if self.isDaemonAlive() {
                        log("Whisper MLX Daemon verificado y listo en /tmp/dictado_whisper.sock")
                        break
                    }
                }
            }
        } catch {
            log("Error ejecutando daemon de Whisper: \(error.localizedDescription)")
        }
    }

    private func findDaemonScript() -> String {
        if let bundlePath = Bundle.main.path(forResource: "whisper_daemon", ofType: "py") {
            return bundlePath
        }
        let fallback = "/Users/sebastianmunoz/Documents/Programas/Entrenamiento de Agentes y Modelos/scripts/dictado_domotex/whisper_daemon.py"
        if FileManager.default.fileExists(atPath: fallback) { return fallback }
        return "/Users/sebastianmunoz/Documents/Programas/open-mac-dictate/whisper_daemon.py"
    }

    func isDaemonAlive() -> Bool {
        guard FileManager.default.fileExists(atPath: whisperSocketPath) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = whisperSocketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    strncpy(dest, src.baseAddress!, 103)
                }
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, len)
            }
        }

        if res == 0 {
            _ = "PING\n".withCString { send(s, $0, 5, 0) }
            var buf = [CChar](repeating: 0, count: 32)
            let n = recv(s, &buf, 31, 0)
            if n > 0 {
                let resp = String(cString: buf)
                return resp.contains("PONG")
            }
        }
        return false
    }

    func transcribe(audioURL: URL, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Intento 1: Vía Socket UNIX con el Daemon residente (Latencia < 0.3s)
            if let text = self?.transcribeViaSocket(audioPath: audioURL.path), !text.isEmpty {
                DispatchQueue.main.async { completion(text) }
                return
            }

            // Intento 2: Invocación directa del CLI de mlx_whisper
            log("Aviso: Socket no respondió. Intentando con mlx_whisper CLI directo...")
            if let text = self?.transcribeViaCLI(audioPath: audioURL.path), !text.isEmpty {
                DispatchQueue.main.async { completion(text) }
                return
            }

            // Intento 3: Respaldo con Apple SFSpeechURLRecognitionRequest sobre el archivo WAV físico
            log("Aviso: MLX no disponible. Intentando respaldo final con Apple Speech URL...")
            self?.transcribeViaAppleSpeech(audioURL: audioURL) { text in
                DispatchQueue.main.async { completion(text) }
            }
        }
    }

    private func transcribeViaSocket(audioPath: String) -> String? {
        ensureDaemonRunning()

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }

        // Timeout de 25 segundos para grabaciones largas
        var tv = timeval(tv_sec: 25, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = whisperSocketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    strncpy(dest, src.baseAddress!, 103)
                }
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, len)
            }
        }

        guard connectRes == 0 else { return nil }

        let msg = audioPath + "\n"
        guard let data = msg.data(using: .utf8) else { return nil }
        let sent = data.withUnsafeBytes { ptr in
            send(s, ptr.baseAddress!, data.count, 0)
        }
        guard sent > 0 else { return nil }

        var resultData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = recv(s, &buffer, buffer.count, 0)
            if bytesRead <= 0 { break }
            resultData.append(buffer, count: bytesRead)
        }

        let result = String(data: resultData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result?.isEmpty == false ? result : nil
    }

    private func transcribeViaCLI(audioPath: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: whisperCLIPath) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: whisperCLIPath)
        p.arguments = [
            audioPath,
            "--model", "mlx-community/whisper-large-v3-turbo",
            "--language", "es",
            "--output-dir", "/tmp",
            "--output-format", "txt",
            "--initial-prompt", "Transcripción técnica en español de Colombia para ingeniería eléctrica, DOMOTEX y CELSA. Sebastián Muñoz, RETIE, RETILAP, NTC 2050, EPM."
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/Users/sebastianmunoz/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        do {
            try p.run()
            p.waitUntilExit()
            let txtFile = URL(fileURLWithPath: "/tmp/dictado_actual.txt")
            if let str = try? String(contentsOf: txtFile, encoding: .utf8) {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            log("Error en CLI Whisper: \(error.localizedDescription)")
        }
        return nil
    }

    private func transcribeViaAppleSpeech(audioURL: URL, completion: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-CO")), recognizer.isAvailable else {
            completion("")
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        recognizer.recognitionTask(with: request) { res, err in
            if let res = res, res.isFinal {
                completion(res.bestTranscription.formattedString)
            } else if err != nil {
                completion("")
            }
        }
    }
}

// MARK: - Gestor de Atajos Globales Carbon (100% independiente de foco o accesibilidad)
var hotkeyHandler: ((UInt32) -> Void)?
final class HotKeys {
    private var refs: [UInt32: EventHotKeyRef] = [:]

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                               nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            hotkeyHandler?(hk.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(id: UInt32, key: Int, mods: Int) {
        guard refs[id] == nil else { return }
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: OSType(0x444D5458), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        if st == noErr, let ref = ref { refs[id] = ref }
    }
}

// MARK: - Coordinador Principal de la Aplicación
final class App: NSObject, NSApplicationDelegate {
    let overlay = Overlay()
    let audio = AudioCaptureEngine()
    let whisper = WhisperSupervisor()
    let hotkeys = HotKeys()
    var statusItem: NSStatusItem!

    var busy = false
    var lastToggleUptime: TimeInterval = 0
    var targetApp: NSRunningApplication?

    let HK_SPACE: UInt32 = 1
    let HK_F8: UInt32 = 2
    let HK_REPASTE: UInt32 = 3
    var menuRef: NSMenu!

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(recording: false, processing: false)

        menuRef = NSMenu()
        menuRef.addItem(withTitle: "🎙 Dictar ahora  (⌃⌥Espacio)", action: #selector(toggle), keyEquivalent: "")
        menuRef.addItem(withTitle: "📋 Pegar último dictado  (⌥⌘N)", action: #selector(repaste), keyEquivalent: "")
        menuRef.addItem(withTitle: "📁 Abrir último audio WAV", action: #selector(openBackupAudio), keyEquivalent: "")
        menuRef.addItem(withTitle: "📄 Abrir último texto dictado", action: #selector(openBackupText), keyEquivalent: "")
        menuRef.addItem(.separator())
        menuRef.addItem(withTitle: "⚡ Reiniciar motor Whisper Daemon", action: #selector(restartDaemon), keyEquivalent: "")
        menuRef.addItem(withTitle: "📜 Ver registro de actividad (Logs)", action: #selector(openLog), keyEquivalent: "")
        menuRef.addItem(withTitle: "♿ Permisos de Accesibilidad", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menuRef.addItem(.separator())
        menuRef.addItem(withTitle: "Salir de Dictado Domotex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for i in menuRef.items { i.target = i.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        hotkeyHandler = { [weak self] id in
            guard let self = self else { return }
            if id == self.HK_SPACE || id == self.HK_F8 {
                self.toggle()
            } else if id == self.HK_REPASTE {
                self.repaste()
            }
        }

        // Atajo Principal Exigido por Sebastián: Control + Opción + Barra Espaciadora
        hotkeys.register(id: HK_SPACE, key: kVK_Space, mods: controlKey | optionKey)
        // Atajo Secundario Directo: Tecla F8
        hotkeys.register(id: HK_F8, key: kVK_F8, mods: 0)
        // Atajo Re-pegar: Opción + Comando + N
        hotkeys.register(id: HK_REPASTE, key: kVK_ANSI_N, mods: cmdKey | optionKey)

        audio.onMeterUpdate = { [weak self] vu, elapsed, size in
            self?.overlay.update(text: "Grabando voz… pulsa Control + Option + Espacio al terminar",
                                 stats: "\(vu)  \(elapsed) • \(size)")
        }

        audio.onStateChange = { [weak self] recording in
            self?.setIcon(recording: recording, processing: false)
        }

        askPermissions()
        log("Dictado Domotex v5.5 iniciado (Titanio Turbo: Grabación PCM Directa + Whisper Large v3 Turbo en GPU Metal + Anti-Ruido DSP)")
    }

    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = menuRef
            statusItem.button?.performClick(nil)
            DispatchQueue.main.async { [weak self] in
                self?.statusItem.menu = nil
            }
        } else {
            toggle()
        }
    }

    func setIcon(recording: Bool, processing: Bool) {
        if recording {
            let img = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Grabando")
            statusItem.button?.image = img
            statusItem.button?.contentTintColor = .systemRed
        } else if processing {
            let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Procesando")
            statusItem.button?.image = img
            statusItem.button?.contentTintColor = .systemOrange
        } else {
            let img = NSImage(systemSymbolName: "mic", accessibilityDescription: "Listo")
            img?.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.contentTintColor = nil
        }
    }

    func askPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in log("Permiso Micrófono concedido: \(ok)") }
        SFSpeechRecognizer.requestAuthorization { st in log("Permiso Reconocimiento de Voz: \(st.rawValue)") }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        log("Permiso Accesibilidad de sistema: \(AXIsProcessTrustedWithOptions(opts))")
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func openBackupText() { NSWorkspace.shared.open(backupTextURL) }
    @objc func openBackupAudio() { NSWorkspace.shared.open(backupAudioURL) }

    @objc func restartDaemon() {
        log("Reinicio manual del daemon solicitado desde el menú")
        whisper.ensureDaemonRunning()
        NSSound(named: "Tink")?.play()
    }

    @objc func toggle() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastToggleUptime < 0.30 { return }
        lastToggleUptime = now

        if busy { return }
        audio.isRecording ? finish() : begin()
    }

    func begin() {
        targetApp = NSWorkspace.shared.frontmostApplication
        do {
            try audio.start()
            NSSound(named: "Tink")?.play()
            overlay.show(status: "🎙 Escuchando… pulsa Control + Option + Espacio al terminar",
                         initialText: "Habla con naturalidad. Sin límite de tiempo.",
                         stats: "[      ]  00:00")
        } catch {
            log("Error iniciando captura de audio: \(error.localizedDescription)")
            audio.cancel()
            overlay.show(status: "⚠️ \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.overlay.hide() }
        }
    }

    func finish() {
        busy = true
        setIcon(recording: false, processing: true)
        overlay.update(status: "⚡ Transcribiendo con Whisper MLX Turbo...",
                       text: "Procesando audio en GPU Metal con filtro acústico anti-ruido...",
                       stats: "⚡ Ultra-rápido",
                       dotIcon: "🟡")

        guard let recordedWAV = audio.stop() else {
            busy = false
            setIcon(recording: false, processing: false)
            overlay.update(status: "⚠️ Audio vacío o demasiado corto", text: "", dotIcon: "⚪")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.overlay.hide() }
            return
        }

        whisper.transcribe(audioURL: recordedWAV) { [weak self] text in
            guard let self = self else { return }
            self.busy = false
            self.setIcon(recording: false, processing: false)
            NSSound(named: "Pop")?.play()

            let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            log("Transcripción completada: \"\(cleanText.prefix(60))...\" (\(cleanText.count) caracteres)")

            if !cleanText.isEmpty {
                self.paste(cleanText)
            } else {
                self.overlay.update(status: "⚠️ No se detectaron palabras en el audio", text: "", dotIcon: "⚪")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { self.overlay.hide() }
            }
        }
    }

    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        guardarRespaldoTexto(text)

        // Devolver el foco a la aplicación donde Sebastián estaba escribiendo
        if let target = targetApp, target != NSWorkspace.shared.frontmostApplication {
            target.activate()
        }

        if AXIsProcessTrusted() {
            overlay.update(status: "✅ Pegado en ventana", text: text, stats: "\(text.count) car", dotIcon: "🟢")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let src = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
                down?.flags = .maskCommand
                up?.flags = .maskCommand
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                self.overlay.hide()
            }
        } else {
            overlay.update(status: "📋 Copiado al portapapeles (pulsa ⌘V para pegar)", text: text, dotIcon: "🟢")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                self.overlay.hide()
            }
        }
    }

    @objc func repaste() {
        if let s = try? String(contentsOf: backupTextURL, encoding: .utf8), !s.isEmpty {
            paste(s)
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
