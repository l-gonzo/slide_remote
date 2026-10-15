import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../common/pptx_notes.dart';
import '../common/protocol.dart';
import '../common/theme.dart';
import 'browser_server.dart';
import 'native_bridge.dart';
import 'wifi_client.dart';

enum Mode { bluetooth, wifi, browser }

/// Estado del modo Bluetooth (Android = teclado HID, iOS = BLE hacia la app de escritorio).
enum BtState { unknown, unavailable, off, noPermission, idle, connecting, connected, waiting }

/// Toda la lógica del control remoto. La UI solo escucha y llama métodos.
class RemoteController extends ChangeNotifier {
  RemoteController() {
    wifi.addListener(notifyListeners);
    wifi.onNotes = _onPcNotes;
    browser.addListener(_onBrowserChanged);
  }

  final wifi = WifiClient();
  final browser = BrowserServer();

  final bool isAndroid = Platform.isAndroid;
  final bool isIOS = Platform.isIOS;

  late SharedPreferences _prefs;
  StreamSubscription<Map<String, Object?>>? _nativeSub;
  bool _ready = false;
  bool _foreground = false;

  Mode mode = Mode.bluetooth;
  bool invert = false;
  bool arrows = false;

  // ---- Bluetooth
  BtState btState = BtState.unknown;
  String? btDeviceName; // PC conectada (Android)
  String? btMessage;
  List<BtDevice> bonded = const [];
  String? selectedAddress;
  bool _btAuto = false;

  // ---- notas del presentador (.pptx)
  // Hay dos fuentes: un .pptx elegido en el teléfono, o las que manda la app de escritorio
  // por WiFi (el archivo se queda en la PC). En el modo WiFi mandan las de la PC si las hay.
  List<SlideInfo>? _localDeck;
  String? _localName;
  int _localTotal = 0;
  int _localSlide = 0;
  int _localStep = 0;

  List<SlideInfo>? _pcDeck;
  String? _pcName;
  int _pcTotal = 0;
  int _pcSlide = 0;
  int _pcStep = 0;
  int _pcVersion = -1; // versión de las notas que ya se descargaron de la PC
  bool _pcFetching = false;
  String? _pcFor; // PC de la que vienen (host)

  bool deckLoading = false;
  int _lastBrowserPage = 0;

  /// true si las notas que se ven vienen de la app de escritorio.
  bool get notesFromPc => mode == Mode.wifi && _pcDeck != null;

  List<SlideInfo>? get deck => notesFromPc ? _pcDeck : _localDeck;
  String? get deckName => notesFromPc ? _pcName : _localName;
  int get _deckTotal => notesFromPc ? _pcTotal : _localTotal;

  /// Índice en [deck] (solo diapositivas visibles).
  int get slide => notesFromPc ? _pcSlide : _localSlide;
  set slide(int v) {
    if (notesFromPc) {
      _pcSlide = v;
    } else {
      _localSlide = v;
    }
  }

  /// Clics de animación ya dados en la diapositiva actual.
  int get step => notesFromPc ? _pcStep : _localStep;
  set step(int v) {
    if (notesFromPc) {
      _pcStep = v;
    } else {
      _localStep = v;
    }
  }

  // ---- conversión a PDF (modo Navegador)
  bool converting = false;
  String? convertingName;

  SlideInfo? get currentSlide => (deck == null || deck!.isEmpty) ? null : deck![slide];
  SlideInfo? get nextSlide => (deck == null || slide + 1 >= deck!.length) ? null : deck![slide + 1];

  /// En el modo Navegador la página la reporta el navegador; en los demás se cuenta.
  bool get slideIsExact => mode == Mode.browser && browser.viewers > 0;

  // ---- avisos para la UI
  final _nudges = StreamController<String>.broadcast();
  Stream<String> get nudges => _nudges.stream;

  /// Contadores que la UI usa para animar los botones.
  final pulseNext = ValueNotifier<int>(0);
  final pulsePrev = ValueNotifier<int>(0);

  bool get ready => _ready;

  // ================================================================ ciclo de vida

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    mode = Mode.values.firstWhere((m) => m.name == _prefs.getString('mode'), orElse: () => Mode.bluetooth);
    invert = _prefs.getBool('invert') ?? false;
    arrows = _prefs.getBool('arrows') ?? false;
    selectedAddress = _prefs.getString('bt_addr');
    _btAuto = _prefs.getBool('bt_auto') ?? false;
    wifi.preferredName = _prefs.getString('wifi_name');
    final host = _prefs.getString('wifi_host');
    if (host != null) {
      await wifi.select(PcEntry(
        name: wifi.preferredName ?? host,
        host: host,
        port: _prefs.getInt('wifi_port') ?? kUdpPort,
        manual: _prefs.getBool('wifi_manual') ?? false,
      ));
    }
    await _restorePdf();
    await _restoreNotes();

    _nativeSub = NativeBridge.events.listen(_onNative);
    _ready = true;
    notifyListeners();
    await onForeground();
  }

  @override
  void dispose() {
    _nativeSub?.cancel();
    wifi.dispose();
    browser.dispose();
    _nudges.close();
    super.dispose();
  }

  /// La app volvió al frente: capturar volumen y reconectar el modo actual.
  Future<void> onForeground() async {
    // Diálogos del sistema (permisos, "hacer visible") también disparan onResume: ignorar
    if (!_ready || _foreground) return;
    _foreground = true;
    await NativeBridge.setVolumeCapture(true);
    await WakelockPlus.enable();
    await _startMode(mode, resumed: true);
  }

  /// La app pasó a segundo plano: soltar el volumen y la PC.
  Future<void> onBackground() async {
    if (!_ready || !_foreground) return;
    _foreground = false;
    await NativeBridge.setVolumeCapture(false);
    await WakelockPlus.disable();
    await _stopTransports(keepBrowser: true);
  }

  Future<void> setMode(Mode m) async {
    if (m == mode) return;
    await _stopTransports(keepBrowser: m == Mode.browser);
    if (mode == Mode.browser && m != Mode.browser) await browser.stop();
    mode = m;
    await _prefs.setString('mode', m.name);
    notifyListeners();
    if (_foreground) await _startMode(m);
  }

  Future<void> _startMode(Mode m, {bool resumed = false}) async {
    switch (m) {
      case Mode.bluetooth:
        await _startBluetooth();
      case Mode.wifi:
        await wifi.start();
      case Mode.browser:
        if (resumed && isIOS) {
          await browser.restart();
        } else {
          await browser.start();
        }
        await browser.refreshUrls();
    }
  }

  Future<void> _stopTransports({required bool keepBrowser}) async {
    if (isAndroid) await NativeBridge.hidPause();
    if (isIOS) await NativeBridge.bleStop();
    await wifi.stop();
    if (!keepBrowser) await browser.stop();
    if (btState == BtState.connected || btState == BtState.connecting || btState == BtState.waiting) {
      btState = BtState.idle;
    }
    notifyListeners();
  }

  // ================================================================ envío

  void onVolume(bool up) => send(forward: invert ? !up : up);

  Future<void> send({required bool forward}) async {
    (forward ? pulseNext : pulsePrev).value++;
    final cmd = Cmd.of(forward: forward, arrows: arrows);
    switch (mode) {
      case Mode.bluetooth:
        if (isAndroid) {
          if (await NativeBridge.hidSend(hidUsageFor(cmd))) return _advance(forward);
          if (await NativeBridge.hidReconnect()) {
            _nudge('Reconectando con la PC…');
          } else {
            _nudge('Conecta tu PC primero');
          }
        } else {
          if (await NativeBridge.bleSend(cmd)) return _advance(forward);
          _nudge('Abre Slide Remote en la PC para conectar');
        }
      case Mode.wifi:
        if (wifi.target == null) return _nudge('Elige tu PC');
        final sent = wifi.send(cmd);
        if (sent) _advance(forward);
        if (!sent) {
          _nudge('No se pudo enviar');
        } else if (!wifi.online) {
          _nudge('La PC no responde. ¿Está abierta Slide Remote?');
        }
      case Mode.browser:
        if (!browser.hasPdf) return _nudge('Primero elige tu presentación');
        if (!browser.go(forward ? 1 : -1)) _nudge('Abre la dirección en el navegador de la PC');
    }
  }

  void _nudge(String msg) {
    if (!_nudges.isClosed) _nudges.add(msg);
  }

  // ================================================================ ajustes

  Future<void> setInvert(bool v) async {
    invert = v;
    await _prefs.setBool('invert', v);
    notifyListeners();
  }

  Future<void> setArrows(bool v) async {
    arrows = v;
    await _prefs.setBool('arrows', v);
    notifyListeners();
  }

  // ================================================================ Bluetooth

  Future<void> _startBluetooth() async {
    if (isIOS) {
      btState = BtState.waiting;
      notifyListeners();
      await NativeBridge.bleStart();
      return;
    }
    if (!await NativeBridge.hidSupported()) {
      btState = BtState.unavailable;
      btMessage = 'Este teléfono no soporta el modo teclado Bluetooth';
      notifyListeners();
      return;
    }
    if (!await NativeBridge.requestBtPermissions()) {
      btState = BtState.noPermission;
      notifyListeners();
      return;
    }
    if (!await NativeBridge.btEnabled()) {
      btState = BtState.off;
      notifyListeners();
      return;
    }
    await refreshBonded();
    await NativeBridge.hidStart(_btAuto ? selectedAddress : null);
  }

  Future<void> retryBluetooth() => _startBluetooth();

  Future<void> refreshBonded() async {
    bonded = await NativeBridge.hidBonded();
    if (selectedAddress == null || bonded.every((d) => d.address != selectedAddress)) {
      selectedAddress = bonded.isNotEmpty ? bonded.first.address : null;
    }
    notifyListeners();
  }

  void selectDevice(String? address) {
    selectedAddress = address;
    notifyListeners();
  }

  Future<void> connectSelected() async {
    final addr = selectedAddress;
    if (addr == null) return _nudge('Primero empareja tu PC');
    await NativeBridge.hidConnect(addr);
  }

  Future<void> disconnectBluetooth() async {
    _btAuto = false;
    await _prefs.setBool('bt_auto', false);
    await NativeBridge.hidDisconnect();
  }

  Future<void> pairNew() => NativeBridge.makeDiscoverable();

  void _onNative(Map<String, Object?> e) {
    switch (e['type']) {
      case 'volume':
        if (_foreground) onVolume(e['dir'] == 'up');
      case 'hid':
        _onHid(e);
      case 'ble':
        _onBle(e);
      case 'discoverable':
        if (e['ok'] == true) _nudge('Visible por 2 min: empareja desde la configuración Bluetooth de la PC');
    }
  }

  void _onHid(Map<String, Object?> e) {
    final name = e['name'] as String?;
    final address = e['address'] as String?;
    btMessage = e['message'] as String?;
    btDeviceName = name;
    btState = switch (e['state']) {
      'UNAVAILABLE' => BtState.unavailable,
      'OFF' => BtState.off,
      'CONNECTING' => BtState.connecting,
      'CONNECTED' => BtState.connected,
      _ => BtState.idle,
    };
    if (btState == BtState.connected && address != null) {
      selectedAddress = address;
      _btAuto = true;
      _prefs.setString('bt_addr', address);
      _prefs.setBool('bt_auto', true);
      if (bonded.every((d) => d.address != address)) refreshBonded();
    }
    notifyListeners();
  }

  void _onBle(Map<String, Object?> e) {
    btMessage = null;
    btState = switch (e['state']) {
      'connected' => BtState.connected,
      'advertising' => BtState.waiting,
      'poweredOff' => BtState.off,
      'unauthorized' => BtState.noPermission,
      'unsupported' => BtState.unavailable,
      'stopped' => BtState.idle,
      _ => btState,
    };
    notifyListeners();
  }

  // ================================================================ WiFi

  Future<void> selectPc(PcEntry pc) async {
    if (wifi.target?.key != pc.key) _dropPcNotes();
    await wifi.select(pc);
    await _prefs.setString('wifi_name', pc.name);
    await _prefs.setString('wifi_host', pc.host);
    await _prefs.setInt('wifi_port', pc.port);
    await _prefs.setBool('wifi_manual', pc.manual);
  }

  // ================================================================ Navegador

  Future<File> _pdfStore() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/presentacion.pdf');
  }

  Future<void> _restorePdf() async {
    final name = _prefs.getString('pdf_name');
    if (name == null) return;
    final f = await _pdfStore();
    if (await f.exists()) await browser.setPdf(f, name);
  }

  /// Formatos que se pueden elegir en el modo Navegador.
  List<String> get presentationExtensions =>
      ['pdf', ..._mobileNotesExtensions, 'ppt', if (isIOS) 'key'];

  /// En el teléfono el selector de archivos filtra por tipo MIME y no reconoce extensiones
  /// raras (.fodp, .otp…): solo las comunes.
  static const _mobileNotesExtensions = ['pptx', 'ppsx', 'odp'];

  /// Modo Navegador: elige PDF o presentación. Las presentaciones se convierten a PDF
  /// dentro del teléfono y, si es .pptx, también se cargan sus notas.
  Future<void> pickPresentation() async {
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: presentationExtensions);
    if (picked == null) return;
    final name = picked.name;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final bytes = await picked.readAsBytes();
    final dir = await getApplicationSupportDirectory();
    final dest = await _pdfStore();

    if (ext == 'pdf') {
      await dest.writeAsBytes(bytes, flush: true);
      await _prefs.setString('pdf_name', name);
      await browser.setPdf(dest, name);
      return;
    }

    converting = true;
    convertingName = name;
    notifyListeners();
    final input = File('${dir.path}/entrada.$ext');
    final output = File('${dir.path}/convertido.pdf');
    try {
      await input.writeAsBytes(bytes, flush: true);

      // Notas del mismo archivo (.pptx, .odp y afines; .ppt y .key no se pueden leer directo)
      PptxDeck? info;
      if (kNotesExtensions.contains(ext)) {
        try {
          info = await PptxNotes.parse(bytes);
          await _loadNotes(bytes, name, quiet: true);
        } catch (_) {
          info = null; // sin notas, pero se intenta convertir igual
        }
      }

      final (available, reason) = await NativeBridge.converterStatus();
      if (!available) {
        _nudge(reason == null
            ? 'Esta versión no incluye el convertidor. Elige la presentación exportada a PDF.'
            : 'Convertidor no disponible: $reason');
        return;
      }
      if (await output.exists()) await output.delete();
      await NativeBridge.convertToPdf(
        input: input.path,
        output: output.path,
        aspect: info?.aspect,
        expected: info?.total,
      );
      await output.copy(dest.path);
      await _prefs.setString('pdf_name', name);
      await browser.setPdf(dest, name);
      if (deck != null && kNotesExtensions.contains(ext)) _nudge('Listo: presentación convertida y notas cargadas');
    } on PlatformException catch (e) {
      _nudge('No se pudo convertir: ${e.message ?? e.code}');
    } catch (e) {
      _nudge('No se pudo convertir: $e');
    } finally {
      converting = false;
      convertingName = null;
      try {
        if (await input.exists()) await input.delete();
        if (await output.exists()) await output.delete();
      } catch (_) {}
      notifyListeners();
    }
  }

  // ================================================================ notas

  /// Igual que PowerPoint/Keynote: "siguiente" primero recorre las animaciones de la
  /// diapositiva; "anterior" desde el inicio regresa a la diapositiva previa ya completa.
  void _advance(bool forward) {
    final d = deck;
    if (d == null || d.isEmpty) return;
    if (forward) {
      if (step < d[slide].clicks) {
        step++;
      } else if (slide < d.length - 1) {
        slide++;
        step = 0;
      }
    } else {
      if (step > 0) {
        step--;
      } else if (slide > 0) {
        slide--;
        step = d[slide].clicks;
      }
    }
    notifyListeners();
  }

  /// Corrección manual cuando el contador se desfasa (no envía nada a la PC).
  void adjustSlide(int delta) {
    final d = deck;
    if (d == null || d.isEmpty) return;
    slide = (slide + delta).clamp(0, d.length - 1);
    step = 0;
    notifyListeners();
  }

  void _onBrowserChanged() {
    final page = browser.page;
    if (page != _lastBrowserPage && page > 0) {
      final i = _slideForPage(page);
      if (i != null) {
        slide = i;
        step = 0;
      }
    }
    _lastBrowserPage = page;
    notifyListeners();
  }

  /// Si el PDF incluye las diapositivas ocultas (tiene tantas páginas como el archivo),
  /// se busca por número; si no, la página N es la N-ésima diapositiva visible.
  int? _slideForPage(int page) {
    final d = deck;
    if (d == null || d.isEmpty) return null;
    if (browser.total == _deckTotal && _deckTotal != d.length) {
      final i = d.indexWhere((s) => s.number == page);
      return i >= 0 ? i : null; // diapositiva oculta: se queda la anterior
    }
    return (page - 1).clamp(0, d.length - 1);
  }

  Future<File> _notesStore() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/notas.pptx');
  }

  Future<void> _restoreNotes() async {
    final name = _prefs.getString('notes_name');
    if (name == null) return;
    final f = await _notesStore();
    if (!await f.exists()) return;
    try {
      final parsed = await PptxNotes.parse(await f.readAsBytes());
      _localDeck = parsed.slides;
      _localTotal = parsed.total;
      _localName = name;
      _localSlide = (_prefs.getInt('notes_slide') ?? 0).clamp(0, parsed.slides.isEmpty ? 0 : parsed.slides.length - 1);
    } catch (_) {
      _localDeck = null;
    }
  }

  /// Carga las notas de un .pptx ya leído. Lanza FormatException si no es válido.
  Future<void> _loadNotes(Uint8List bytes, String name, {required bool quiet}) async {
    final parsed = await PptxNotes.parse(bytes);
    if (parsed.slides.isEmpty) throw const FormatException('La presentación no tiene diapositivas.');
    await (await _notesStore()).writeAsBytes(bytes, flush: true);
    await _prefs.setString('notes_name', name);
    _localDeck = parsed.slides;
    _localTotal = parsed.total;
    _localName = name;
    _localSlide = 0;
    _localStep = 0;
    if (!quiet && parsed.slides.every((s) => s.notes.trim().isEmpty)) {
      _nudge('Esta presentación no tiene notas del presentador');
    }
  }

  /// Modos Bluetooth y WiFi: elegir el .pptx solo para ver las notas.
  Future<void> pickNotes() async {
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: _mobileNotesExtensions);
    if (picked == null) return;
    deckLoading = true;
    notifyListeners();
    try {
      await _loadNotes(await picked.readAsBytes(), picked.name, quiet: false);
    } on FormatException catch (e) {
      _nudge(e.message);
    } catch (_) {
      _nudge('No se pudo leer el archivo. ¿Es un .pptx u .odp?');
    } finally {
      deckLoading = false;
      notifyListeners();
    }
  }

  Future<void> clearNotes() async {
    _localDeck = null;
    _localName = null;
    _localTotal = 0;
    await _prefs.remove('notes_name');
    try {
      await (await _notesStore()).delete();
    } catch (_) {}
    notifyListeners();
  }

  /// Volver al inicio (p. ej. al empezar a presentar).
  void restartNotes() {
    slide = 0;
    step = 0;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_localDeck != null && _ready) _prefs.setInt('notes_slide', _localSlide);
    super.notifyListeners();
  }

  // ---------------------------------------------------------------- notas desde la PC

  /// La PC dice qué versión de notas tiene (llega con cada respuesta al ping, cada ~2 s).
  void _onPcNotes(int version, int port) {
    final host = wifi.targetAddress;
    if (host == null) return;
    if (_pcFor != null && _pcFor != host.address) _dropPcNotes();
    if (version == 0) {
      if (_pcDeck != null) {
        _dropPcNotes();
        notifyListeners();
      }
      return;
    }
    if (version == _pcVersion || _pcFetching) return;
    _fetchPcNotes(host, port, version);
  }

  Future<void> _fetchPcNotes(InternetAddress host, int port, int version) async {
    _pcFetching = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(Uri(scheme: 'http', host: host.address, port: port, path: '/notes'));
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));
      final j = Map<String, Object?>.from(jsonDecode(body) as Map);
      final v = (j['version'] as num?)?.toInt() ?? 0;
      // La PC cambió de opinión mientras se descargaba, o la dirección ya no es la elegida
      if (wifi.targetAddress?.address != host.address) return;
      if (v == 0) {
        _dropPcNotes();
        return;
      }
      final parsed = PptxDeck.fromJson(j);
      if (parsed.slides.isEmpty) return;
      final sameFile = _pcName == j['name'] && _pcDeck?.length == parsed.slides.length;
      _pcDeck = parsed.slides;
      _pcTotal = parsed.total;
      _pcName = (j['name'] as String?) ?? 'presentación';
      _pcVersion = v;
      _pcFor = host.address;
      if (sameFile) {
        // Solo se guardaron cambios en el archivo: conservar la posición
        _pcSlide = _pcSlide.clamp(0, parsed.slides.length - 1);
        _pcStep = 0;
      } else {
        _pcSlide = 0;
        _pcStep = 0;
        if (mode == Mode.wifi) _nudge('Notas de la PC: $_pcName');
      }
    } catch (e) {
      debugPrint('Notas de la PC: $e');
    } finally {
      client.close(force: true);
      _pcFetching = false;
      notifyListeners();
    }
  }

  void _dropPcNotes() {
    _pcDeck = null;
    _pcName = null;
    _pcTotal = 0;
    _pcSlide = 0;
    _pcStep = 0;
    _pcVersion = -1;
    _pcFor = null;
  }

  // ================================================================ estado visible

  ConnView get status {
    switch (mode) {
      case Mode.bluetooth:
        return switch (btState) {
          BtState.connected => ConnView(Conn.on, 'Conectado', isIOS ? 'App de escritorio' : btDeviceName),
          BtState.connecting => ConnView(Conn.busy, 'Conectando…', btDeviceName),
          BtState.waiting => const ConnView(Conn.busy, 'Esperando PC', 'Abre Slide Remote en la PC'),
          BtState.off => const ConnView(Conn.error, 'Bluetooth apagado', 'Actívalo en el teléfono'),
          BtState.noPermission => const ConnView(Conn.error, 'Sin permiso', 'Permite el acceso a Bluetooth'),
          BtState.unavailable => ConnView(Conn.error, 'No disponible', btMessage),
          BtState.idle => ConnView(Conn.off, 'Desconectado', btMessage ?? 'Elige tu PC y conecta'),
          BtState.unknown => const ConnView(Conn.off, 'Preparando…'),
        };
      case Mode.wifi:
        final pc = wifi.target;
        if (pc == null) return const ConnView(Conn.off, 'Sin PC', 'Elige tu PC en la lista');
        if (wifi.online) {
          return ConnView(Conn.on, 'Conectado', '${pc.name}${wifi.latencyMs != null ? ' · ${wifi.latencyMs} ms' : ''}');
        }
        return ConnView(Conn.busy, 'Buscando…', pc.name);
      case Mode.browser:
        if (browser.error != null) return ConnView(Conn.error, 'Error', browser.error);
        if (converting) return const ConnView(Conn.busy, 'Convirtiendo…', 'Se hace en el teléfono');
        if (!browser.hasPdf) return const ConnView(Conn.off, 'Sin presentación', 'Elige tu presentación');
        if (browser.viewers > 0) {
          return ConnView(Conn.on, 'Proyectando',
              browser.total > 0 ? 'Diapositiva ${browser.page} de ${browser.total}' : 'Cargando PDF…');
        }
        return const ConnView(Conn.busy, 'Esperando', 'Abre la dirección en la PC');
    }
  }

  bool get canSend => status.conn == Conn.on;
}
