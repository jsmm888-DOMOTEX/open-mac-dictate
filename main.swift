// OpenMacDictate / Dictado Domotex v5.6 — Edición Titanio Turbo & Anti-Ruido DSP con Blindaje VAD
// Diseñado para macOS Tahoe / Sequoia / Apple Silicon
//
// ARQUITECTURA:
// 1. Grabación Pura PCM Hardware: Basado en AVAudioRecorder / CoreAudio HAL directo.
//    Cero dependencias de grafos de audio inestables. Cero bloqueos con auriculares Bluetooth.
// 2. Transcripción Instantánea con Whisper MLX Daemon: Motor residente en memoria GPU Metal (Large v3 Turbo + Silero VAD)
//    que transcribe audios de cualquier duración con protocolo estructurado JSON sobre socket UNIX privado.
// 3. Blindaje de Portapapeles y Respaldo Opcional: Validación estricta que previene sobrescribir el portapapeles
//    con puntos o silencio, y guardado en disco opcional (desactivado por defecto por privacidad).
// 4. Blindaje Cero Volteo de Pantalla + Detección de Pantalla Activa: No roba el foco al cambiar de Space y muestra el HUD siempre en la pantalla solicitada.
// 5. Cero Límites de Tiempo: Habla 5 segundos, 1 minuto, 5 minutos o media hora. El audio NUNCA se corta.
// 6. Medidor VU en Vivo y Feedback de Espera: Visualizador de audio y aviso durante transcripciones de audios largos.
// 7. Triple Redundancia 100% Local: Daemon Socket -> Whisper MLX CLI -> Apple SFSpeechURL (requiresOnDeviceRecognition = true).
// 8. Atajos: Control + Opción + Espacio, Tecla F8, Clic en barra de menú, y ⌥⌘N para re-pegar.

import Cocoa
import AVFoundation
import Speech
import Carbon.HIToolbox

let homeDir = FileManager.default.homeDirectoryForCurrentUser
let appSupportDir: URL = {
    let dir = homeDir.appendingPathComponent("Library/Application Support/OpenMacDictate")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return dir
}()
let logURL = homeDir.appendingPathComponent("Library/Logs/DictadoDomotex.log")
let backupTextURL = homeDir.appendingPathComponent("Library/Logs/UltimoDictado.txt")
let backupAudioURL = homeDir.appendingPathComponent("Library/Logs/UltimoDictado.wav")
let tempAudioURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("open_mac_dictate_\(ProcessInfo.processInfo.processIdentifier).wav")
let whisperSocketPath = appSupportDir.appendingPathComponent("dictado_whisper.sock").path

func resolveVenvExecutable(_ name: String) -> String {
    let candidates = [
        appSupportDir.appendingPathComponent(".venv/bin/\(name)").path,
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".venv/bin/\(name)").path,
        homeDir.appendingPathComponent(".local/bin/\(name)").path,
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)"
    ]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return candidates[0]
}

let whisperPythonPath = resolveVenvExecutable("python3")
let whisperCLIPath = resolveVenvExecutable("mlx_whisper")

var saveLastDictationHistory: Bool {
    get { UserDefaults.standard.bool(forKey: "SaveLastDictation") }
    set { UserDefaults.standard.set(newValue, forKey: "SaveLastDictation") }
}

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

func isValidText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    // Contar caracteres alfanuméricos reales
    let alphanumericCount = trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
    guard alphanumericCount >= 2 else { return false }

    // Rechazar cadenas compuestas exclusivamente de signos de puntuación y espacios
    let nonPunctuation = trimmed.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    guard !nonPunctuation.isEmpty else { return false }

    return true
}

func guardarRespaldoTexto(_ text: String) {
    guard isValidText(text) else {
        log("guardarRespaldoTexto: Texto descartado por no contener palabras válidas ('\(text)')")
        return
    }
    if saveLastDictationHistory {
        try? text.write(to: backupTextURL, atomically: true, encoding: .utf8)
    }
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
    let fx: NSVisualEffectView
    let dot = NSTextField(labelWithString: "🔴")
    let title = NSTextField(labelWithString: "")
    let counter = NSTextField(labelWithString: "")
    let text = NSTextField(wrappingLabelWithString: "")

    private var hideWorkItem: DispatchWorkItem?
    private weak var currentTargetApp: NSRunningApplication?

    init() {
        panel = NonFocusingPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 88),
                                 styleMask: [.nonactivatingPanel, .borderless],
                                 backing: .buffered, defer: false)
        // Nivel oficial de superposición asistiva (1500): garantiza visibilidad sobre apps Fullscreen, menús y cualquier Space
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        fx = NSVisualEffectView(frame: panel.contentView!.bounds)
        fx.autoresizingMask = [.width, .height]
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 22
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1.5
        fx.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.75).cgColor
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

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    func cancelPendingHide() {
        runOnMain {
            self.hideWorkItem?.cancel()
            self.hideWorkItem = nil
        }
    }

    func scheduleHide(after seconds: TimeInterval) {
        runOnMain {
            self.hideWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.panel.orderOut(nil)
                self?.hideWorkItem = nil
            }
            self.hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    private func activeWindowCocoaRect(for app: NSRunningApplication?) -> NSRect? {
        guard let app = app,
              let primaryHeight = NSScreen.screens.first?.frame.height else {
            return nil
        }

        // 1. Consultar ventana enfocada vía Accesibilidad (más preciso en multimonitor)
        if AXIsProcessTrusted() {
            let appElem = AXUIElementCreateApplication(app.processIdentifier)
            var winObj: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &winObj) == .success,
               let win = winObj {
                let axWin = win as! AXUIElement
                var posObj: CFTypeRef?
                var sizeObj: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posObj) == .success,
                   AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeObj) == .success,
                   let posVal = posObj, let sizeVal = sizeObj {
                    var pt = CGPoint.zero
                    var sz = CGSize.zero
                    if AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
                       AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz),
                       sz.width > 40, sz.height > 40 {
                        let cocoaY = primaryHeight - pt.y - sz.height
                        return NSRect(x: pt.x, y: cocoaY, width: sz.width, height: sz.height)
                    }
                }
            }
        }

        // 2. Respaldo vía CGWindowListCopyWindowInfo para la ventana frontal visible de esa app
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let targetPID = Int(app.processIdentifier)
            for info in list {
                guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid == targetPID,
                      let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                      let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                      let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                      cgRect.width > 80, cgRect.height > 80 else {
                    continue
                }
                let cocoaY = primaryHeight - cgRect.origin.y - cgRect.size.height
                return NSRect(x: cgRect.origin.x, y: cocoaY, width: cgRect.size.width, height: cgRect.size.height)
            }
        }

        return nil
    }

    private func resolveTargetScreen(for app: NSRunningApplication?) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main }

        // Prioridad 1: Pantalla donde vive la ventana enfocada donde Sebas está dictando
        if let winRect = activeWindowCocoaRect(for: app) {
            let winCenter = NSPoint(x: winRect.midX, y: winRect.midY)
            if let centerScreen = screens.first(where: { NSMouseInRect(winCenter, $0.frame, false) }) {
                return centerScreen
            }
            var bestScreen: NSScreen?
            var bestArea: CGFloat = 0
            for scr in screens {
                let inter = NSIntersectionRect(scr.frame, winRect)
                let area = inter.width * inter.height
                if area > bestArea {
                    bestArea = area
                    bestScreen = scr
                }
            }
            if let bestScreen = bestScreen {
                return bestScreen
            }
        }

        // Prioridad 2: Pantalla actual del puntero del ratón
        let mouse = NSEvent.mouseLocation
        if let mouseScreen = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return mouseScreen
        }

        return NSScreen.main ?? screens.first
    }

    private func positionAndPresent(on screen: NSScreen?) {
        guard let screen = screen else { return }
        let vf = screen.visibleFrame
        let panelWidth = min(780.0, max(360.0, vf.width - 40.0))
        let panelHeight: CGFloat = 88.0
        let originX = vf.midX - panelWidth / 2.0
        // Ubicación prominente en la franja superior-central visible (libre de notch y de barras inferiores)
        let originY = max(vf.minY + 40.0, min(vf.maxY - panelHeight - 44.0, vf.minY + vf.height * 0.78))
        let targetFrame = NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight)

        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        panel.setFrame(targetFrame, display: true)
        panel.alphaValue = 1.0
        panel.setIsVisible(true)
        panel.orderFrontRegardless()
    }

    private func updateBorder(for dotIcon: String) {
        switch dotIcon {
        case "🔴":
            fx.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
        case "🟡":
            fx.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.8).cgColor
        case "🟢":
            fx.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.8).cgColor
        default:
            fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        }
    }

    func show(status: String, initialText: String = "…", stats: String = "", targetApp: NSRunningApplication? = nil) {
        runOnMain {
            self.hideWorkItem?.cancel()
            self.hideWorkItem = nil
            if let app = targetApp {
                self.currentTargetApp = app
            }
            self.dot.stringValue = "🔴"
            self.updateBorder(for: "🔴")
            self.title.stringValue = status
            self.counter.stringValue = stats
            self.text.stringValue = initialText

            let screen = self.resolveTargetScreen(for: self.currentTargetApp ?? NSWorkspace.shared.frontmostApplication)
            self.positionAndPresent(on: screen)
            if let scr = screen {
                log("HUD mostrado en pantalla '\(scr.localizedName)' frame=\(scr.frame) visible=\(scr.visibleFrame) pos=\(self.panel.frame.origin)")
            }
        }
    }

    func update(status: String? = nil, text t: String? = nil, stats: String? = nil, dotIcon: String? = nil) {
        runOnMain {
            if let d = dotIcon {
                self.dot.stringValue = d
                self.updateBorder(for: d)
            }
            if let s = status { self.title.stringValue = s }
            if let st = stats { self.counter.stringValue = st }
            if let t = t { self.text.stringValue = t.isEmpty ? "…" : t }
            if !self.panel.isVisible {
                let screen = self.resolveTargetScreen(for: self.currentTargetApp ?? NSWorkspace.shared.frontmostApplication)
                self.positionAndPresent(on: screen)
            } else {
                self.panel.orderFrontRegardless()
            }
        }
    }

    func hide() {
        runOnMain {
            self.hideWorkItem?.cancel()
            self.hideWorkItem = nil
            self.panel.orderOut(nil)
        }
    }
}

// MARK: - Motor de Grabación Puro (AVAudioRecorder / CoreAudio HAL)
final class AudioCaptureEngine: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startTime: Date?
    private(set) var isRecording = false
    private(set) var lastRecordingDuration: TimeInterval = 0

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
        self.lastRecordingDuration = 0
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
        lastRecordingDuration = Date().timeIntervalSince(self.startTime ?? Date())
        stopRecordingCleanup()
        onStateChange?(false)

        let exists = FileManager.default.fileExists(atPath: tempAudioURL.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: tempAudioURL.path)[.size] as? Int64) ?? 0
        log("Captura de audio finalizada: \(String(format: "%.2f", lastRecordingDuration))s (\(size) bytes)")

        // Descartar grabaciones accidentales de menos de 0.4s o menos de 10 KB
        guard exists, lastRecordingDuration >= 0.4, size >= 10000 else {
            log("Aviso: Audio descartado por ser demasiado corto (\(String(format: "%.2f", lastRecordingDuration))s, \(size) bytes)")
            try? FileManager.default.removeItem(at: tempAudioURL)
            return nil
        }

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
struct DaemonResponse: Decodable {
    let status: String
    let text: String?
    let reason: String?
    let duration: Double?
    let inference_time: Double?
    let message: String?
}

enum SocketResult {
    case success(text: String, duration: Double, inferenceTime: Double)
    case noSpeech(reason: String)
    case error(message: String)
    case socketUnavailable
}

enum TranscriptionOutcome {
    case success(String)
    case noSpeech(String)
    case failure(String)
}

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
        env["PATH"] = "\(homeDir.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
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
                        log("Whisper MLX Daemon verificado y listo en \(whisperSocketPath)")
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
        let appSupportScript = appSupportDir.appendingPathComponent("whisper_daemon.py").path
        if FileManager.default.fileExists(atPath: appSupportScript) { return appSupportScript }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("whisper_daemon.py").path
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

    func transcribe(audioURL: URL, completion: @escaping (TranscriptionOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Intento 1: Vía Socket UNIX con el Daemon residente (Latencia < 0.3s)
            let socketRes = self.transcribeViaSocket(audioPath: audioURL.path)
            switch socketRes {
            case .success(let text, _, _):
                DispatchQueue.main.async { completion(.success(text)) }
                return

            case .noSpeech(let reason):
                log("Daemon determinó no_speech (razón: \(reason)). Omitiendo fallback para evitar alucinaciones.")
                DispatchQueue.main.async { completion(.noSpeech(reason)) }
                return

            case .error(let msg):
                log("Aviso: Daemon retornó error: \(msg). Verificando si procede fallback...")

            case .socketUnavailable:
                log("Aviso: Socket del daemon no respondió o no está disponible.")
            }

            // Intento 2: Invocación directa del CLI de mlx_whisper (solo para audios válidos >= 30 KB)
            let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
            if size >= 30000 {
                log("Intentando con mlx_whisper CLI directo (audio: \(size) bytes)...")
                if let text = self.transcribeViaCLI(audioPath: audioURL.path), isValidText(text) {
                    DispatchQueue.main.async { completion(.success(text)) }
                    return
                }
            } else {
                log("Audio menor a 30 KB (\(size) bytes). Omitiendo fallback CLI para evitar alucinaciones.")
                DispatchQueue.main.async { completion(.noSpeech("audio_too_small")) }
                return
            }

            // Intento 3: Respaldo con Apple SFSpeechURLRecognitionRequest
            log("Aviso: MLX no disponible. Intentando respaldo con Apple Speech URL...")
            self.transcribeViaAppleSpeech(audioURL: audioURL) { text in
                if isValidText(text) {
                    DispatchQueue.main.async { completion(.success(text)) }
                } else {
                    DispatchQueue.main.async { completion(.noSpeech("apple_speech_empty")) }
                }
            }
        }
    }

    private func transcribeViaSocket(audioPath: String) -> SocketResult {
        ensureDaemonRunning()

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return .socketUnavailable }
        defer { close(s) }

        // Timeout de 60 segundos para grabaciones largas
        var tv = timeval(tv_sec: 60, tv_usec: 0)
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

        guard connectRes == 0 else { return .socketUnavailable }

        let reqDict = ["action": "transcribe", "audio_path": audioPath]
        guard let reqData = try? JSONSerialization.data(withJSONObject: reqDict),
              let reqStr = String(data: reqData, encoding: .utf8) else {
            return .socketUnavailable
        }
        let msg = reqStr + "\n"
        guard let data = msg.data(using: .utf8) else { return .socketUnavailable }
        let sent = data.withUnsafeBytes { ptr in
            send(s, ptr.baseAddress!, data.count, 0)
        }
        guard sent > 0 else { return .socketUnavailable }

        var resultData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = recv(s, &buffer, buffer.count, 0)
            if bytesRead <= 0 { break }
            resultData.append(buffer, count: bytesRead)
        }

        if let json = try? JSONDecoder().decode(DaemonResponse.self, from: resultData) {
            if json.status == "ok", let t = json.text, isValidText(t) {
                return .success(text: t, duration: json.duration ?? 0, inferenceTime: json.inference_time ?? 0)
            } else if json.status == "no_speech" {
                return .noSpeech(reason: json.reason ?? "vad_gate")
            } else if json.status == "error" {
                return .error(message: json.message ?? "daemon_error")
            } else {
                return .noSpeech(reason: "unrecognized_status")
            }
        }

        let rawStr = String(data: resultData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawStr.isEmpty {
            return .noSpeech(reason: "empty_socket_response")
        }
        if isValidText(rawStr) {
            return .success(text: rawStr, duration: 0, inferenceTime: 0)
        }
        return .noSpeech(reason: "invalid_raw_text")
    }

    private func transcribeViaCLI(audioPath: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: whisperCLIPath) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: audioPath)[.size] as? Int64) ?? 0
        guard size >= 30000 else { return nil }

        let outDir = FileManager.default.temporaryDirectory
        let baseName = URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent
        let txtFile = outDir.appendingPathComponent("\(baseName).txt")
        try? FileManager.default.removeItem(at: txtFile)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: whisperCLIPath)
        p.arguments = [
            audioPath,
            "--model", "mlx-community/whisper-large-v3-turbo",
            "--language", "es",
            "--output-dir", outDir.path,
            "--output-format", "txt",
            "--initial-prompt", "Transcripción técnica en español e inglés para ingeniería y desarrollo de software."
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(homeDir.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        do {
            try p.run()
            p.waitUntilExit()
            defer { try? FileManager.default.removeItem(at: txtFile) }
            if let str = try? String(contentsOf: txtFile, encoding: .utf8) {
                let clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if isValidText(clean) {
                    return clean
                }
            }
        } catch {
            log("Error en CLI Whisper: \(error.localizedDescription)")
        }
        return nil
    }

    private func transcribeViaAppleSpeech(audioURL: URL, completion: @escaping (String) -> Void) {
        let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
        guard size >= 30000 else {
            completion("")
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-CO")), recognizer.isAvailable else {
            completion("")
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true

        recognizer.recognitionTask(with: request) { res, err in
            if let res = res, res.isFinal {
                let str = res.bestTranscription.formattedString
                completion(isValidText(str) ? str : "")
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
    var lastExternalApp: NSRunningApplication?

    let HK_SPACE: UInt32 = 1
    let HK_F8: UInt32 = 2
    let HK_REPASTE: UInt32 = 3
    var menuRef: NSMenu!

    func applicationDidFinishLaunching(_ n: Notification) {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = front
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastExternalApp = app
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(recording: false, processing: false)

        menuRef = NSMenu()
        menuRef.addItem(withTitle: "🎙 Dictar ahora  (⌃⌥Espacio)", action: #selector(toggle), keyEquivalent: "")
        menuRef.addItem(withTitle: "📋 Pegar último dictado  (⌥⌘N)", action: #selector(repaste), keyEquivalent: "")
        let saveItem = NSMenuItem(title: "💾 Guardar último dictado en disco", action: #selector(toggleSaveHistory(_:)), keyEquivalent: "")
        saveItem.state = saveLastDictationHistory ? .on : .off
        menuRef.addItem(saveItem)
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
        log("Dictado Domotex v5.6 iniciado (Titanio Turbo: Grabación PCM Directa + Whisper Large v3 Turbo en GPU Metal + Anti-Ruido DSP + Blindaje VAD)")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log("Reopen recibido: usuario hizo clic en la aplicación (Dock / Finder / Spotlight). Alternando dictado y mostrando barra HUD...")
        toggle()
        return true
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

    @objc func toggleSaveHistory(_ sender: NSMenuItem) {
        saveLastDictationHistory.toggle()
        sender.state = saveLastDictationHistory ? .on : .off
        log("Guardado de último dictado en disco: \(saveLastDictationHistory ? "activado" : "desactivado")")
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
        if now - lastToggleUptime < 0.35 { return }
        lastToggleUptime = now

        if busy {
            log("Atajo presionado mientras el sistema está transcribiendo. Mostrando aviso de espera.")
            NSSound(named: "Tink")?.play()
            overlay.update(
                status: "⏳ Procesando tu dictado anterior, un momento...",
                text: "El modelo está transcribiendo en GPU Metal. Por favor espera a que termine.",
                dotIcon: "🟡"
            )
            return
        }

        audio.isRecording ? finish() : begin()
    }

    func begin() {
        let front = NSWorkspace.shared.frontmostApplication
        if let front = front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApp = front
            lastExternalApp = front
        } else {
            targetApp = lastExternalApp
        }
        log("Iniciando dictado. App destino: \(targetApp?.localizedName ?? "Desconocida") (\(targetApp?.bundleIdentifier ?? "sin bundle"))")
        do {
            try audio.start()
            NSSound(named: "Tink")?.play()
            overlay.show(status: "🎙 Escuchando… pulsa Control + Option + Espacio al terminar",
                         initialText: "Habla con naturalidad. Sin límite de tiempo.",
                         stats: "[      ]  00:00",
                         targetApp: targetApp)
        } catch {
            log("Error iniciando captura de audio: \(error.localizedDescription)")
            audio.cancel()
            overlay.show(status: "⚠️ \(error.localizedDescription)", targetApp: targetApp)
            overlay.scheduleHide(after: 2.5)
        }
    }

    func finish() {
        busy = true
        setIcon(recording: false, processing: true)

        guard let recordedWAV = audio.stop() else {
            busy = false
            setIcon(recording: false, processing: false)
            overlay.update(status: "⚪ Grabación demasiado corta", text: "Habla al menos 1 segundo.", dotIcon: "⚪")
            overlay.scheduleHide(after: 1.8)
            return
        }

        let durationSec = audio.lastRecordingDuration
        let mins = Int(durationSec) / 60
        let secs = Int(durationSec) % 60
        let durationStr = String(format: "%02d:%02d", mins, secs)

        let statusHeader: String
        let statusDetail: String
        if durationSec >= 30 {
            let timeStr = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
            statusHeader = "⚡ Transcribiendo audio de \(timeStr)..."
            statusDetail = "⏳ Transcripción en curso con Whisper MLX Turbo... por favor espera un momento"
        } else {
            statusHeader = "⚡ Transcribiendo (\(durationStr))..."
            statusDetail = "Procesando audio en GPU Metal con filtro acústico anti-ruido..."
        }

        overlay.update(status: statusHeader,
                       text: statusDetail,
                       stats: "⚡ MLX Turbo",
                       dotIcon: "🟡")

        whisper.transcribe(audioURL: recordedWAV) { [weak self] outcome in
            guard let self = self else { return }
            self.busy = false
            self.setIcon(recording: false, processing: false)

            switch outcome {
            case .success(let text):
                let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isValidText(cleanText) else {
                    log("Aviso: Transcripción recibida pero no contiene texto alfanumérico válido: '\(cleanText)'")
                    self.overlay.update(status: "⚪ No se detectaron palabras", text: "", dotIcon: "⚪")
                    self.overlay.scheduleHide(after: 1.8)
                    return
                }

                if saveLastDictationHistory {
                    try? FileManager.default.removeItem(at: backupAudioURL)
                    try? FileManager.default.copyItem(at: recordedWAV, to: backupAudioURL)
                }

                NSSound(named: "Pop")?.play()
                log("Transcripción exitosa: \"\(cleanText.prefix(60))...\" (\(cleanText.count) caracteres)")
                self.paste(cleanText)

            case .noSpeech(let reason):
                log("Cero voz detectada en audio (\(reason)). Preservando portapapeles y archivo de respaldo.")
                self.overlay.update(status: "⚪ No se detectó voz",
                                    text: "No se identificaron palabras claras. Tu portapapeles previo se mantiene intacto.",
                                    dotIcon: "⚪")
                self.overlay.scheduleHide(after: 2.0)

            case .failure(let err):
                log("Error en transcripción: \(err)")
                self.overlay.update(status: "⚠️ Error en transcripción", text: err, dotIcon: "🔴")
                self.overlay.scheduleHide(after: 2.5)
            }
        }
    }

    func paste(_ text: String) {
        guard isValidText(text) else {
            log("paste: Intento de pegar texto inválido ignorado: '\(text)'")
            return
        }
        guardarRespaldoTexto(text)

        // BLINDAJE CERO VOLTEO DE PANTALLA:
        // Nunca forzamos target.activate() sobre otras apps para no voltear el Space si Sebas cambió de escritorio mientras hablaba.
        // Solo devolvemos foco a lastExternalApp si la app frontal actual fuese Dictado Domotex por clic en Dock/Spotlight.
        let currentApp = NSWorkspace.shared.frontmostApplication
        if currentApp?.bundleIdentifier == Bundle.main.bundleIdentifier, let fallback = lastExternalApp {
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: fallback)
                fallback.activate()
            } else {
                fallback.activate(options: .activateIgnoringOtherApps)
            }
        }
        log("Pegando texto en pantalla actual sin volteo. App activa: \(currentApp?.localizedName ?? "Ninguna") (App al inicio: \(targetApp?.localizedName ?? "Ninguna"))")

        if AXIsProcessTrusted() {
            overlay.update(status: "✅ Pegado en ventana", text: text, stats: "\(text.count) car", dotIcon: "🟢")
            // Delay rápido de 140ms para asentar portapapeles sin voltear pantalla
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                let src = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
                down?.flags = .maskCommand
                up?.flags = .maskCommand
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
            overlay.scheduleHide(after: 1.8)
        } else {
            overlay.update(status: "📋 Copiado al portapapeles (pulsa ⌘V para pegar)", text: text, dotIcon: "🟢")
            overlay.scheduleHide(after: 2.8)
        }
    }

    @objc func repaste() {
        if let s = try? String(contentsOf: backupTextURL, encoding: .utf8), isValidText(s) {
            log("Re-pegado manual (⌥⌘N): \"\(s.prefix(60))...\" (\(s.count) caracteres)")
            paste(s)
        } else {
            log("Re-pegado ignorado: no hay texto válido en \(backupTextURL.path)")
            overlay.show(status: "⚪ No hay texto previo para pegar", targetApp: lastExternalApp)
            overlay.scheduleHide(after: 1.8)
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
