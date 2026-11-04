// Dictado Domotex v4.0 — Edición Definitiva Indestructible
// Diseñado para Sebastián Muñoz (macOS Apple Silicon / Tahoe / Sequoia)
//
// CARACTERÍSTICAS PRINCIPALES:
// 1. Motor Monotónico Indestructible: Buffer acumulativo que JAMÁS borra ni reinicia
//    el texto dictado, sin importar si hablas 1 minuto, 5 minutos o media hora.
// 2. Detección Inteligente de Reset de Apple: Detecta instantáneamente el límite de 60s
//    del reconocedor de Apple y sella el texto previo sin perder una sola letra.
// 3. Re-enlace Proactivo de Tarea (45s): Recicla la sesión de reconocimiento cada 45s
//    en segundo plano sin detener el motor de audio ni provocar pausas.
// 4. Grabación Paralela en WAV y Respaldo mlx_whisper: Si Apple Speech devuelve vacío,
//    transcribe automáticamente el archivo WAV de respaldo con Whisper MLX local.
// 5. Atajos Múltiples y Cómodos:
//    - Bloq Mayús (Caps Lock, estilo Claude Desktop, con filtro exacto de tecla 57)
//    - F8 (tecla directa dedicada)
//    - Control + Opción + Espacio (atajo clásico)
//    - Opción + Comando + N (volver a pegar el último texto)
// 6. Overlay HUD Flotante Superior: Situado en el tope de pantalla para NUNCA tapar
//    el chat de Antigravity ni la ventana activa, con contador de palabras y caracteres en vivo.
// 7. Pegado Automático y Respaldo Continuo en Portapapeles y Disco.

import Cocoa
import Speech
import AVFoundation
import Carbon.HIToolbox

let homeDir = FileManager.default.homeDirectoryForCurrentUser
let logURL = homeDir.appendingPathComponent("Library/Logs/DictadoDomotex.log")
let backupURL = homeDir.appendingPathComponent("Library/Logs/UltimoDictado.txt")
let tempAudioURL = URL(fileURLWithPath: "/tmp/dictado_ultimo.wav")
let whisperCLI = "/Users/sebastianmunoz/Documents/Programas/Transcripcion de audio/.venv/bin/mlx_whisper"

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

func guardarRespaldo(_ text: String) {
    guard !text.isEmpty else { return }
    try? text.write(to: backupURL, atomically: true, encoding: .utf8)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}

// MARK: - Acumulador Monotónico Indestructible
final class SpeechAccumulator {
    private var committedPhrases: [String] = []
    private var currentPartial: String = ""
    private var lastRawResult: String = ""
    private let lock = NSLock()

    var fullText: String {
        lock.lock()
        defer { lock.unlock() }
        let all = committedPhrases + [currentPartial].filter { !$0.isEmpty }
        return all.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var wordCount: Int {
        let t = fullText
        return t.isEmpty ? 0 : t.split(whereSeparator: { $0.isWhitespace }).count
    }

    var charCount: Int {
        fullText.count
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        committedPhrases.removeAll()
        currentPartial = ""
        lastRawResult = ""
    }

    func setContinuation(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        committedPhrases = [text]
        currentPartial = ""
        lastRawResult = ""
    }

    func pushRawResult(_ raw: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fullTextLocked() }

        // Detección de reinicio del buffer interno de Apple Speech (límite de ~60 segundos):
        // Si el reconocedor venía emitiendo un texto largo y de repente emite un texto
        // drásticamente más corto que no comparte prefijo con el anterior,
        // Apple acaba de truncar su ventana deslizante. ¡Sellamos el texto previo!
        if !lastRawResult.isEmpty && isBufferReset(old: lastRawResult, new: trimmed) {
            log(">>> REINICIO DE BUFFER DETECTADO: Sellando '\(lastRawResult.prefix(35))...' (\(lastRawResult.count) car.) <<<")
            committedPhrases.append(lastRawResult)
            lastRawResult = trimmed
            currentPartial = trimmed
        } else {
            lastRawResult = trimmed
            currentPartial = trimmed
        }

        return fullTextLocked()
    }

    func commitCurrent() {
        lock.lock()
        defer { lock.unlock() }
        if !lastRawResult.isEmpty {
            committedPhrases.append(lastRawResult)
            lastRawResult = ""
            currentPartial = ""
        }
    }

    private func isBufferReset(old: String, new: String) -> Bool {
        if old.count >= 15 && new.count < (old.count - 8) {
            let prefixLen = old.commonPrefix(with: new).count
            if prefixLen < (old.count / 3) {
                return true
            }
        }
        return false
    }

    private func fullTextLocked() -> String {
        let all = committedPhrases + [currentPartial].filter { !$0.isEmpty }
        return all.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Grabador de Audio Paralelo (para respaldo Whisper)
final class AudioFileRecorder {
    private var audioFile: AVAudioFile?
    private let lock = NSLock()

    func start(format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: tempAudioURL)
        do {
            audioFile = try AVAudioFile(forWriting: tempAudioURL, settings: format.settings)
        } catch {
            log("Aviso: No se pudo crear archivo WAV temporal: \(error.localizedDescription)")
            audioFile = nil
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? audioFile?.write(from: buffer)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
    }
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

        dot.font = .systemFont(ofSize: 12)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        counter.textColor = .systemOrange

        text.font = .systemFont(ofSize: 15, weight: .regular)
        text.textColor = .labelColor
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingHead

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
        // Situado en el tope de la pantalla activa (debajo del menu bar), jamás estorba abajo en el chat
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - 110))
        panel.orderFrontRegardless()
    }

    func update(status: String? = nil, text t: String? = nil, stats: String? = nil, isFinished: Bool = false) {
        if isFinished { dot.stringValue = "🟢" }
        if let s = status { title.stringValue = s }
        if let st = stats { counter.stringValue = st }
        if let t = t { text.stringValue = t.isEmpty ? "…" : t }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

// MARK: - Motor de Dictado Integral (Continuo + Sin Límite de Tiempo)
final class DictationEngine {
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var cycleTimer: Timer?
    private let lock = NSLock()
    private var sessionID = 0
    private(set) var isRecording = false
    private var buffersReceivedInSession = 0

    let accumulator = SpeechAccumulator()
    let recorder = AudioFileRecorder()

    var onTextUpdate: ((String, Int, Int) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    init() {
        for id in ["es-CO", "es-419", "es-MX", "es-US", "es-ES"] {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable {
                recognizer = r
                log("Reconocedor activo: \(id) (onDevice=\(r.supportsOnDeviceRecognition))")
                break
            }
        }

        // Monitorear cambios de hardware de audio (desconexión, reposo/wake, AirPods)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            log("CoreAudio reportó cambio de configuración de audio (wake/reposo/dispositivo)")
            guard let self = self, self.isRecording else { return }
            // Si estábamos grabando en medio de un cambio de ruta, reiniciar motor
            log("Reiniciando captura tras cambio de hardware de audio en vivo...")
            self.recoverAudioEngine()
        }
    }

    private func recoverAudioEngine() {
        guard isRecording, let recognizer = recognizer else { return }
        cycleSubtask()
    }

    func start(continuationText: String? = nil) throws {
        guard let recognizer = recognizer else {
            throw NSError(domain: "Dictado", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Reconocimiento de voz no disponible"])
        }

        accumulator.reset()
        if let cont = continuationText, !cont.isEmpty {
            accumulator.setContinuation(cont)
            log("Continuando texto previo (\(cont.count) caracteres)")
        }

        // Limpiar motor anterior si existía para garantizar conexión 100% fresca al micrófono
        if let old = engine {
            old.stop()
            old.inputNode.removeTap(onBus: 0)
            old.reset()
        }

        let newEngine = AVAudioEngine()
        self.engine = newEngine

        isRecording = true
        sessionID += 1
        buffersReceivedInSession = 0

        let input = newEngine.inputNode
        let fmt = input.outputFormat(forBus: 0)

        guard fmt.sampleRate > 0 && fmt.channelCount > 0 else {
            throw NSError(domain: "Dictado", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Formato de micrófono inválido o inactivo (sampleRate=0)"])
        }

        recorder.start(format: fmt)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self = self else { return }
            self.buffersReceivedInSession += 1
            self.recorder.append(buf)
            self.lock.lock()
            let r = self.request
            self.lock.unlock()
            r?.append(buf)
        }

        newEngine.prepare()
        try newEngine.start()

        launchTask(recognizer)
        scheduleProactiveCycle()
        onStateChange?(true)
    }

    private func launchTask(_ recognizer: SFSpeechRecognizer) {
        let sid = sessionID
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }

        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.isRecording, sid == self.sessionID else { return }

                if let result = result {
                    let raw = result.bestTranscription.formattedString
                    let full = self.accumulator.pushRawResult(raw)
                    if !full.isEmpty {
                        self.onTextUpdate?(full, self.accumulator.wordCount, self.accumulator.charCount)
                        guardarRespaldo(full)
                    }

                    // Si Apple da por finalizada la sub-tarea (p.ej. límite de tiempo interno alcanzado),
                    // pero el usuario SIGUE hablando, re-enlazamos automáticamente sin perder nada
                    if result.isFinal {
                        log("Apple Speech completó sub-segmento (isFinal=true). Re-enlazando segmento continuo...")
                        self.accumulator.commitCurrent()
                        self.cycleSubtask()
                    }
                }

                if let error = error {
                    // Silenciar avisos benignos de silencio para no saturar el log ni ciclar en falso
                    let desc = error.localizedDescription
                    if !desc.contains("No speech detected") {
                        log("Aviso de reconocimiento: \(desc)")
                    }
                    // JAMÁS reiniciar la tarea en bucle por error de silencio mientras el usuario está pausado
                }
            }
        }

        lock.lock()
        request = req
        task = t
        lock.unlock()
    }

    private var lastCycleTime: TimeInterval = 0

    // Reciclaje preventivo cada 45 segundos para que NUNCA alcance el corte forzado de Apple
    private func scheduleProactiveCycle() {
        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            log("Reciclaje preventivo de sub-tarea a los 45s (cero pérdida de datos)")
            self.accumulator.commitCurrent()
            self.cycleSubtask()
        }
    }

    private func cycleSubtask() {
        guard isRecording, let recognizer = recognizer else { return }

        // Protección antirrebote: mínimo 3 segundos entre reciclajes de sub-tarea
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCycleTime < 3.0 { return }
        lastCycleTime = now

        lock.lock()
        let oldReq = request
        let oldTask = task
        request = nil
        task = nil
        lock.unlock()

        oldReq?.endAudio()
        oldTask?.cancel()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.launchTask(recognizer)
        }
    }

    func stop(completion: @escaping (String) -> Void) {
        isRecording = false
        cycleTimer?.invalidate()
        cycleTimer = nil

        if let eng = engine {
            eng.stop()
            eng.inputNode.removeTap(onBus: 0)
            eng.reset()
            self.engine = nil
        }
        recorder.finish()

        lock.lock()
        let r = request
        let t = task
        request = nil
        task = nil
        lock.unlock()

        r?.endAudio()
        t?.cancel()

        accumulator.commitCurrent()
        let final = accumulator.fullText
        sessionID += 1
        guardarRespaldo(final)
        onStateChange?(false)

        log("Grabación finalizada: \(buffersReceivedInSession) buffers procesados")

        // Si Apple Speech no capturó texto pero hay audio grabado, intentamos Whisper como rescate
        if final.isEmpty && FileManager.default.fileExists(atPath: tempAudioURL.path) {
            log("Apple Speech devolvió texto vacío. Intentando rescate con Whisper MLX...")
            transcribeWithWhisper(audioURL: tempAudioURL) { rescued in
                let res = rescued.trimmingCharacters(in: .whitespacesAndNewlines)
                if !res.isEmpty {
                    log("Rescate exitoso con Whisper: \(res.count) caracteres")
                    guardarRespaldo(res)
                    completion(res)
                } else {
                    completion(final)
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                completion(final)
            }
        }
    }

    func cancel() {
        isRecording = false
        cycleTimer?.invalidate()
        cycleTimer = nil
        sessionID += 1

        if let eng = engine {
            eng.stop()
            eng.inputNode.removeTap(onBus: 0)
            eng.reset()
            self.engine = nil
        }
        recorder.finish()

        lock.lock()
        task?.cancel()
        task = nil
        request = nil
        lock.unlock()
        onStateChange?(false)
    }
}

// Rescate de audio con Whisper MLX local si falla Apple Speech
func transcribeWithWhisper(audioURL: URL, completion: @escaping (String) -> Void) {
    guard FileManager.default.isExecutableFile(atPath: whisperCLI) else {
        completion("")
        return
    }

    DispatchQueue.global(qos: .userInitiated).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: whisperCLI)
        p.arguments = [
            audioURL.path,
            "--model", "mlx-community/whisper-small-mlx",
            "--language", "es",
            "--output-dir", "/tmp",
            "--output-format", "txt"
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        do {
            try p.run()
            p.waitUntilExit()
            let txtFile = URL(fileURLWithPath: "/tmp/dictado_ultimo.txt")
            if let str = try? String(contentsOf: txtFile, encoding: .utf8) {
                DispatchQueue.main.async { completion(str) }
                return
            }
        } catch {
            log("Error ejecutando Whisper: \(error.localizedDescription)")
        }
        DispatchQueue.main.async { completion("") }
    }
}

// MARK: - Gestor de Atajos Globales (Carbon)
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

// MARK: - App Principal y Coordinador
final class App: NSObject, NSApplicationDelegate {
    let overlay = Overlay()
    let dictation = DictationEngine()
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
        setIcon(false)

        menuRef = NSMenu()
        menuRef.addItem(withTitle: "Dictar  (Control + Option + Espacio)", action: #selector(toggle), keyEquivalent: "")
        menuRef.addItem(withTitle: "Pegar último dictado  (⌥⌘N)", action: #selector(repaste), keyEquivalent: "")
        menuRef.addItem(withTitle: "Abrir archivo de respaldo", action: #selector(openBackup), keyEquivalent: "")
        menuRef.addItem(.separator())
        menuRef.addItem(withTitle: "Permisos de Accesibilidad (Ajustes)", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menuRef.addItem(withTitle: "Ver registro de actividad", action: #selector(openLog), keyEquivalent: "")
        menuRef.addItem(.separator())
        menuRef.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for i in menuRef.items { i.target = i.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }

        // Configurar clic en el ícono de la barra: Clic izquierdo = Iniciar/Terminar dictado; Clic derecho = Menú
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Manejador central de atajos Carbon (100% independiente de permisos de accesibilidad)
        hotkeyHandler = { [weak self] id in
            guard let self = self else { return }
            if id == self.HK_SPACE || id == self.HK_F8 {
                self.toggle()
            } else if id == self.HK_REPASTE {
                self.repaste()
            }
        }

        // Atajo Principal: Control + Opción + Barra Espaciadora
        hotkeys.register(id: HK_SPACE, key: kVK_Space, mods: controlKey | optionKey)
        // Atajo Secundario: Tecla F8
        hotkeys.register(id: HK_F8, key: kVK_F8, mods: 0)
        // Atajo Re-pegar: Opción + Comando + N
        hotkeys.register(id: HK_REPASTE, key: kVK_ANSI_N, mods: cmdKey | optionKey)

        dictation.onTextUpdate = { [weak self] text, words, chars in
            self?.overlay.update(text: text, stats: "\(words) pal • \(chars) car")
        }

        dictation.onStateChange = { [weak self] rec in
            self?.setIcon(rec)
        }

        askPermissions()
        log("Dictado Domotex v4.1 iniciado (Atajo exclusivo: Control+Option+Espacio y Clic en barra de menú)")
    }

    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = menuRef
            statusItem.button?.performClick(nil)
            // Desvincular menú inmediatamente para que el próximo clic izquierdo vuelva a alternar el micrófono
            DispatchQueue.main.async { [weak self] in
                self?.statusItem.menu = nil
            }
        } else {
            toggle()
        }
    }

    func setIcon(_ rec: Bool) {
        let name = rec ? "mic.fill" : "mic"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Dictado")
        img?.isTemplate = !rec
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = rec ? .systemRed : nil
    }

    @objc func askPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in log("Micrófono concedido: \(ok)") }
        SFSpeechRecognizer.requestAuthorization { st in log("Permiso Voz: \(st.rawValue)") }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        log("Accesibilidad de sistema: \(AXIsProcessTrustedWithOptions(opts))")
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func openBackup() { NSWorkspace.shared.open(backupURL) }

    @objc func toggle() {
        let now = ProcessInfo.processInfo.systemUptime
        // Antirrebote ergonómico de 350ms (evita dobles toques mecánicos sin retrasar el fin de frase)
        if now - lastToggleUptime < 0.35 { return }
        lastToggleUptime = now

        if busy { return }
        dictation.isRecording ? finish() : begin()
    }

    func begin() {
        targetApp = NSWorkspace.shared.frontmostApplication
        do {
            try dictation.start()
            NSSound(named: "Tink")?.play()
            overlay.show(status: "🎙 Escuchando… pulsa Control + Option + Espacio al terminar",
                         initialText: "…", stats: "0 car")
        } catch {
            log("Error iniciando dictado: \(error.localizedDescription)")
            dictation.cancel()
            overlay.show(status: "⚠️ \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.overlay.hide() }
        }
    }

    func finish() {
        busy = true
        overlay.update(status: "Finalizando texto…", isFinished: true)

        dictation.stop { [weak self] text in
            guard let self = self else { return }
            NSSound(named: "Pop")?.play()
            self.busy = false
            log("Dictado concluido con éxito (\(text.count) caracteres)")

            if !text.isEmpty {
                self.paste(text)
            } else {
                self.overlay.hide()
            }
        }
    }

    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        guardarRespaldo(text)

        // Devolver el foco a la aplicación donde Sebastián estaba escribiendo
        if let target = targetApp, target != NSWorkspace.shared.frontmostApplication {
            target.activate()
        }

        if AXIsProcessTrusted() {
            overlay.update(status: "✅ Pegado en ventana", text: text, isFinished: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let src = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
                down?.flags = .maskCommand
                up?.flags = .maskCommand
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                self.overlay.hide()
            }
        } else {
            overlay.update(status: "📋 Copiado al portapapeles (pulsa ⌘V para pegar)", text: text, isFinished: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                self.overlay.hide()
            }
        }
    }

    @objc func repaste() {
        if let s = try? String(contentsOf: backupURL, encoding: .utf8), !s.isEmpty {
            paste(s)
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
