import AudioToolbox
import AVFoundation
import CoreBluetooth
import CoreHaptics
import CoreMotion
import Flutter
import MediaPlayer
import PDFKit
import UIKit

/// Idioma de los mensajes nativos; lo fija la app con "setLanguage" ("es" o "en").
enum SlideLang {
    static var es = false
    static func t(_ spanish: String, _ english: String) -> String { es ? spanish : english }
}

/// Puente nativo de Zlide para iOS.
///
/// - Botones de volumen: iOS no da acceso directo, así que se observa `outputVolume` de la sesión
///   de audio y se regresa el volumen a 50 % después de cada pulsación (así siempre hay margen
///   para detectar subir y bajar). Un `MPVolumeView` invisible oculta el indicador del sistema.
/// - Bluetooth: iOS no permite que una app sea un teclado Bluetooth, así que el iPhone anuncia
///   un servicio BLE propio al que se conecta la app de escritorio de Zlide.
/// - Giroscopio para apuntar moviendo el teléfono.
public class SlideNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CBPeripheralManagerDelegate {

    // Deben coincidir con lib/common/protocol.dart
    private static let serviceUUID = CBUUID(string: "7B1D0001-5C3F-4E8A-9D7A-2F6B1C0E5A10")
    private static let commandUUID = CBUUID(string: "7B1D0002-5C3F-4E8A-9D7A-2F6B1C0E5A10")

    private var sink: FlutterEventSink?

    // ---- volumen
    private var captureVolume = false
    private var volumeObservation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var lastVolume: Float = 0.5
    private var ignoreUntil = Date.distantPast
    private var originalVolume: Float?
    /// Detectar cuánto se mantiene presionado (solo si hay una acción configurada para eso):
    /// iOS no avisa al soltar, pero mientras se mantiene el volumen sigue cambiando; un rato
    /// sin cambios = se soltó.
    private var detectHold = false
    private var pressUp: Bool?
    private var releaseTimer: Timer?
    private static let releaseGap: TimeInterval = 0.5

    // ---- giroscopio
    private var motion: CMMotionManager?
    private var lastMotion: TimeInterval = 0

    // ---- BLE
    private var peripheral: CBPeripheralManager?
    private var commandChar: CBMutableCharacteristic?
    private var bleWanted = false
    private var serviceAdded = false
    private var subscribers = Set<UUID>()
    private var pending: [Data] = []
    private var seq: UInt8 = 0

    // ---- conversión a PDF
    private var converter: PresentationConverter?
    private var haptics: CHHapticEngine?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SlideNativePlugin()
        let channel = FlutterMethodChannel(name: "slide_native", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        let events = FlutterEventChannel(name: "slide_native/events", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    // MARK: - Flutter

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { self.sink?(event) }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "setLanguage":
            SlideLang.es = (args?["lang"] as? String) == "es"
            result(nil)
        case "setVolumeCapture":
            setVolumeCapture((args?["enabled"] as? Bool) ?? false)
            result(nil)
        case "setVolumeHold":
            detectHold = (args?["enabled"] as? Bool) ?? false
            if !detectHold { releaseVolume() }
            result(nil)
        case "setMotion":
            result(setMotion((args?["enabled"] as? Bool) ?? false))
        case "bleStart":
            bleStart()
            result(nil)
        case "bleStop":
            bleStop()
            result(nil)
        case "bleSend":
            let cmd = (args?["cmd"] as? Int) ?? 0
            let arg = args?["arg"] as? Int
            result(bleSend(UInt8(clamping: cmd), arg: arg))
        case "vibrate":
            vibrate(
                count: (args?["count"] as? Int) ?? 1,
                ms: (args?["ms"] as? Int) ?? 550,
                strength: (args?["strength"] as? Double) ?? 1)
            result(nil)
        case "hidSupported":
            result(false)
        case "dndStatus", "setDnd":
            // iOS no deja que una app active Concentración / No molestar: la app lo explica
            result("unsupported")
        case "openDndSettings":
            result(false)
        case "renderPdfPage":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "BAD_ARGS", message: "path", details: nil))
                return
            }
            let page = (args?["page"] as? Int) ?? 1
            let width = (args?["width"] as? Int) ?? 1280
            DispatchQueue.global(qos: .userInitiated).async {
                let out = SlideNativePlugin.renderPdfPage(path: path, page: page, width: width)
                DispatchQueue.main.async { result(out) }
            }
        case "converterAvailable":
            result(true)
        case "converterStatus":
            result(["available": true])
        case "convertToPdf":
            guard let input = args?["input"] as? String, let output = args?["output"] as? String else {
                result(FlutterError(code: "BAD_ARGS", message: SlideLang.t("Faltan datos para convertir", "Missing conversion data"), details: nil))
                return
            }
            if converter != nil {
                result(FlutterError(code: "BUSY", message: SlideLang.t("Ya hay una conversión en curso", "A conversion is already running"), details: nil))
                return
            }
            let conv = PresentationConverter()
            converter = conv
            conv.convert(
                input: URL(fileURLWithPath: input),
                output: URL(fileURLWithPath: output),
                aspect: args?["aspect"] as? Double,
                expected: args?["expected"] as? Int
            ) { [weak self] res in
                self?.converter = nil
                switch res {
                case .success:
                    result(nil)
                case .failure(let e):
                    result(FlutterError(code: "CONVERT_FAILED", message: e.localizedDescription, details: nil))
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Giroscopio

    /// Mientras se apunta: manda {type: motion, wx, wy, wz (rad/s), ux, uy, uz (arriba), dt (s)}.
    /// Devuelve false si el teléfono no tiene giroscopio.
    private func setMotion(_ on: Bool) -> Bool {
        motion?.stopDeviceMotionUpdates()
        motion = nil
        guard on else { return true }
        let m = CMMotionManager()
        guard m.isDeviceMotionAvailable else { return false }
        m.deviceMotionUpdateInterval = 1.0 / 60
        lastMotion = 0
        m.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let self, let dm else { return }
            let dt = self.lastMotion == 0 ? 0 : dm.timestamp - self.lastMotion
            self.lastMotion = dm.timestamp
            guard dt > 0, dt < 0.2 else { return }
            let r = dm.rotationRate, g = dm.gravity
            // La gravedad de iOS apunta hacia el suelo; se manda hacia arriba, como en Android
            self.sink?([
                "type": "motion", "wx": r.x, "wy": r.y, "wz": r.z,
                "ux": -g.x, "uy": -g.y, "uz": -g.z, "dt": dt,
            ])
        }
        motion = m
        return true
    }

    // MARK: - Volumen

    private func setVolumeCapture(_ on: Bool) {
        if on == captureVolume { return }
        captureVolume = on
        let session = AVAudioSession.sharedInstance()
        if on {
            do {
                try session.setCategory(.ambient, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                NSLog("SlideNative: no se pudo activar la sesión de audio: \(error)")
            }
            installVolumeView()
            originalVolume = session.outputVolume
            // Llevar a la mitad para poder detectar tanto subir como bajar
            resetVolume()
            volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let self = self, let v = change.newValue else { return }
                DispatchQueue.main.async { self.volumeChanged(v) }
            }
        } else {
            releaseVolume()
            volumeObservation?.invalidate()
            volumeObservation = nil
            if let v = originalVolume { setSystemVolume(v) }
            originalVolume = nil
            volumeView?.removeFromSuperview()
            volumeView = nil
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func volumeChanged(_ v: Float) {
        guard captureVolume else { return }
        let prev = lastVolume
        lastVolume = v
        if abs(v - prev) < 0.001 { return }
        let up = v > prev
        if !detectHold {
            // Cambios provocados por nuestro propio reset: ignorar
            if Date() < ignoreUntil { return }
            emit(["type": "volume", "dir": up ? "up" : "down", "phase": "down"])
            emit(["type": "volume", "dir": up ? "up" : "down", "phase": "up"])
            resetVolume()
            return
        }
        // Nuestro propio reset (siempre a la mitad; una pulsación nunca cae justo ahí)
        if abs(v - 0.5) < 0.001 { return }
        if pressUp == nil {
            if Date() < ignoreUntil { return }
            pressUp = up
            emit(["type": "volume", "dir": up ? "up" : "down", "phase": "down"])
        }
        // Sigue presionado mientras el volumen siga cambiando
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: Self.releaseGap, repeats: false) { [weak self] _ in
            self?.releaseVolume()
        }
        resetVolume()
    }

    private func releaseVolume() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        guard let up = pressUp else { return }
        pressUp = nil
        emit(["type": "volume", "dir": up ? "up" : "down", "phase": "up"])
    }

    private func resetVolume() {
        ignoreUntil = Date().addingTimeInterval(0.25)
        lastVolume = 0.5
        setSystemVolume(0.5)
    }

    private func setSystemVolume(_ v: Float) {
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        // El slider de MPVolumeView necesita un ciclo del run loop tras crearse
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            slider.setValue(v, animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }

    private func installVolumeView() {
        guard volumeView == nil, let window = SlideNativePlugin.keyWindow() else { return }
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        volumeView = view
    }

    /// Una página del PDF como JPEG (vista de dibujo del modo Navegador). [page] empieza en 1.
    static func renderPdfPage(path: String, page: Int, width: Int) -> Any {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), doc.pageCount > 0 else {
            return FlutterError(code: "RENDER_FAILED", message: SlideLang.t("No se pudo abrir el PDF", "Could not open the PDF"), details: nil)
        }
        let index = max(0, min(page - 1, doc.pageCount - 1))
        guard let p = doc.page(at: index) else {
            return FlutterError(code: "RENDER_FAILED", message: "page", details: nil)
        }
        let box = p.bounds(for: .cropBox)
        let rotated = p.rotation % 180 != 0
        let pw = rotated ? box.height : box.width
        let ph = rotated ? box.width : box.height
        let w = CGFloat(max(64, min(width, 2400)))
        let h = max(1, (w * ph / pw).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let thumb = p.thumbnail(of: CGSize(width: w, height: h), for: .cropBox)
            thumb.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let data = img.jpegData(compressionQuality: 0.9) else {
            return FlutterError(code: "RENDER_FAILED", message: "jpeg", details: nil)
        }
        return ["bytes": FlutterStandardTypedData(bytes: data), "width": Int(w), "height": Int(h), "pages": doc.pageCount]
    }

    static func keyWindow() -> UIWindow? {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    // MARK: - BLE periférico

    private func bleStart() {
        bleWanted = true
        if peripheral == nil {
            peripheral = CBPeripheralManager(delegate: self, queue: nil)
        } else {
            startAdvertisingIfReady()
        }
    }

    /// Al pasar a segundo plano solo se deja de anunciar: el servicio y la suscripción de la PC
    /// se conservan, así al volver a la app los comandos funcionan de inmediato.
    private func bleStop() {
        bleWanted = false
        guard let pm = peripheral else { return }
        if pm.isAdvertising { pm.stopAdvertising() }
        pending.removeAll()
        emitBle("stopped")
    }

    /// [arg] (opcional) viaja en 2 bytes más: el número de diapositiva de "ir a".
    private func bleSend(_ cmd: UInt8, arg: Int? = nil) -> Bool {
        guard let pm = peripheral, let ch = commandChar, !subscribers.isEmpty else { return false }
        seq = seq &+ 1
        var bytes = [seq, cmd]
        if let a = arg {
            let v = UInt16(clamping: a)
            bytes += [UInt8(v >> 8), UInt8(v & 0xFF)]
        }
        let data = Data(bytes)
        if !pm.updateValue(data, for: ch, onSubscribedCentrals: nil) {
            pending.append(data) // cola llena: se reenvía en peripheralManagerIsReady
        }
        return true
    }

    /// Aviso discreto del cronómetro: [count] vibraciones de [ms] con intensidad [strength] (0–1).
    /// Al máximo, o sin Core Haptics, la vibración del sistema: la misma de una notificación.
    private func vibrate(count: Int, ms: Int, strength: Double) {
        let n = max(1, count)
        let duration = max(0.02, Double(ms) / 1000)
        if strength < 0.95 && CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            do {
                if haptics == nil {
                    let engine = try CHHapticEngine()
                    engine.resetHandler = { [weak engine] in try? engine?.start() }
                    haptics = engine
                }
                try haptics?.start()
                // 250 ms de pausa entre pulsos, como en Android
                let events = (0..<n).map { i in
                    CHHapticEvent(
                        eventType: .hapticContinuous,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(min(1, max(0, strength)))),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                        ],
                        relativeTime: (duration + 0.25) * Double(i),
                        duration: duration)
                }
                let player = try haptics?.makePlayer(with: CHHapticPattern(events: events, parameters: []))
                try player?.start(atTime: CHHapticTimeImmediate)
                return
            } catch {
                NSLog("slide_native.vibrate: \(error)")
            }
        }
        for i in 0..<n {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65 * Double(i)) {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }

    private func startAdvertisingIfReady() {
        guard bleWanted, let pm = peripheral, pm.state == .poweredOn else { return }
        if !serviceAdded {
            let ch = CBMutableCharacteristic(
                type: SlideNativePlugin.commandUUID,
                properties: [.notify, .read],
                value: nil,
                permissions: [.readable])
            let service = CBMutableService(type: SlideNativePlugin.serviceUUID, primary: true)
            service.characteristics = [ch]
            commandChar = ch
            pm.add(service) // continúa en didAdd
            return
        }
        if !pm.isAdvertising {
            pm.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [SlideNativePlugin.serviceUUID],
                CBAdvertisementDataLocalNameKey: "Zlide",
            ])
        }
        emitBle(subscribers.isEmpty ? "advertising" : "connected")
    }

    private func emitBle(_ state: String) {
        emit(["type": "ble", "state": state, "centrals": subscribers.count])
    }

    public func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        switch pm.state {
        case .poweredOn:
            serviceAdded = false
            startAdvertisingIfReady()
        case .poweredOff:
            subscribers.removeAll()
            serviceAdded = false
            emitBle("poweredOff")
        case .unauthorized:
            emitBle("unauthorized")
        case .unsupported:
            emitBle("unsupported")
        default:
            emitBle("unknown")
        }
    }

    public func peripheralManager(_ pm: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            NSLog("SlideNative: no se pudo agregar el servicio BLE: \(error)")
            emitBle("error")
            return
        }
        serviceAdded = true
        startAdvertisingIfReady()
    }

    public func peripheralManagerDidStartAdvertising(_ pm: CBPeripheralManager, error: Error?) {
        if let error = error {
            NSLog("SlideNative: no se pudo anunciar: \(error)")
            emitBle("error")
        }
    }

    public func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        subscribers.insert(central.identifier)
        emitBle("connected")
    }

    public func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers.remove(central.identifier)
        emitBle(subscribers.isEmpty ? "advertising" : "connected")
    }

    public func peripheralManagerIsReady(toUpdateSubscribers pm: CBPeripheralManager) {
        guard let ch = commandChar else { return }
        while let data = pending.first {
            if pm.updateValue(data, for: ch, onSubscribedCentrals: nil) {
                pending.removeFirst()
            } else {
                return
            }
        }
    }

    public func peripheralManager(_ pm: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        request.value = Data([seq, 0])
        pm.respond(to: request, withResult: .success)
    }
}
