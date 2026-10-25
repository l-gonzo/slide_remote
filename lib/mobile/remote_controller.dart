import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../common/deck_media.dart';
import '../common/i18n.dart';
import '../common/pptx_notes.dart';
import '../common/protocol.dart';
import '../common/theme.dart';
import 'browser_server.dart';
import 'ink.dart';
import 'native_bridge.dart';
import 'slide_thumbs.dart';
import 'talk_timer.dart';
import 'wifi_client.dart';

enum Mode { bluetooth, wifi, browser }

/// Mano con la que se sostiene el teléfono: los controles se acomodan de ese lado.
enum Hand { right, left }

/// "No molestar" al presentar: activo, falta el permiso, o el sistema no lo permite (iOS).
enum DndState { off, on, needsAccess, unsupported }

/// Estado del modo Bluetooth (Android = teclado HID, iOS = BLE hacia la app de escritorio).
enum BtState { unknown, unavailable, off, noPermission, idle, connecting, connected, waiting }

/// Toda la lógica del control remoto. La UI solo escucha y llama métodos.
class RemoteController extends ChangeNotifier {
  RemoteController() {
    wifi.addListener(notifyListeners);
    wifi.onNotes = _onPcNotes;
    wifi.onPage = _onPcPage;
    browser.addListener(_onBrowserChanged);
  }

  final wifi = WifiClient();
  final browser = BrowserServer();

  /// Cronómetro de la presentación (solo en el teléfono).
  final timer = TalkTimer();

  /// Miniatura de la siguiente diapositiva al transmitir.
  final thumbs = SlideThumbs();

  /// Dibujos del modo WiFi (se mandan a la app de escritorio mientras la vista de dibujo está abierta).
  late final InkBoard wifiInk = InkBoard((m) => wifiInkSink?.call(m));
  void Function(Map<String, Object?>)? wifiInkSink;

  /// Puerto de la app de escritorio para notas y dibujo (lo anuncia por WiFi).
  int? _pcPort;

  /// Dirección del WebSocket de dibujo de la PC, si la app de escritorio la anunció.
  Uri? get pcDrawUri {
    final host = wifi.targetAddress;
    final port = _pcPort;
    if (host == null || port == null || !wifi.online) return null;
    return Uri(scheme: 'ws', host: host.address, port: port, path: '/phone');
  }

  final bool isAndroid = Platform.isAndroid;
  final bool isIOS = Platform.isIOS;

  late SharedPreferences _prefs;
  StreamSubscription<Map<String, Object?>>? _nativeSub;
  bool _ready = false;
  bool _foreground = false;

  Mode mode = Mode.bluetooth;
  bool invert = false;
  bool arrows = false;

  // ---- al presentar
  /// Mano dominante: los botones y acciones se acomodan de ese lado.
  Hand hand = Hand.right;

  /// Modo una mano: todo lo que se toca queda en la parte de abajo, al alcance del pulgar.
  bool oneHand = false;

  /// Ignorar un segundo toque muy seguido en los botones de la pantalla (toques accidentales).
  bool tapGuard = true;

  /// Activar "No molestar" del teléfono mientras se presenta.
  bool dnd = true;
  DndState dndState = DndState.off;

  /// Tamaño del texto de las notas.
  double notesFont = 22;

  /// Pantalla bloqueada: los toques no hacen nada (solo los botones de volumen). Evita cambios
  /// de diapositiva o gestos del sistema accidentales con el teléfono en la mano o el bolsillo.
  bool locked = false;

  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

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
  // Notas elegidas en el teléfono: separadas por modo (las de "Transmitir desde móvil" no se
  // mezclan con las de "Control Bluetooth", etc.).
  final Map<Mode, _NotesSlot> _slots = {for (final m in Mode.values) m: _NotesSlot(m)};
  _NotesSlot get _slot => _slots[mode]!;

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

  List<SlideInfo>? get deck => notesFromPc ? _pcDeck : _slot.deck;
  String? get deckName => notesFromPc ? _pcName : _slot.name;
  int get _deckTotal => notesFromPc ? _pcTotal : _slot.total;

  /// Índice en [deck] (solo diapositivas visibles).
  int get slide => notesFromPc ? _pcSlide : _slot.slide;
  set slide(int v) {
    if (notesFromPc) {
      _pcSlide = v;
    } else {
      _slot.slide = v;
    }
  }

  /// Clics de animación ya dados en la diapositiva actual.
  int get step => notesFromPc ? _pcStep : _slot.step;
  set step(int v) {
    if (notesFromPc) {
      _pcStep = v;
    } else {
      _slot.step = v;
    }
  }

  // ---- conversión a PDF (modo Navegador)
  bool converting = false;
  String? convertingName;

  SlideInfo? get currentSlide => (deck == null || deck!.isEmpty) ? null : deck![slide];
  SlideInfo? get nextSlide => (deck == null || slide + 1 >= deck!.length) ? null : deck![slide + 1];

  /// Contador de animaciones de la diapositiva ("animación 2/5"), o null si no aplica.
  /// Transmitiendo, lo informa el reproductor que proyecta (sin animaciones, como un PDF, no se
  /// muestra); con teclas se cuentan los clics según el archivo.
  ({int step, int total})? get animProgress {
    if (slideIsExact) {
      final (step, steps) = switch (mode) {
        Mode.browser when browser.hasAnim && browser.fxPage == browser.page => (browser.fxStep, browser.fxSteps),
        Mode.wifi when pcPresenting => (_shownStep, _shownSteps),
        _ => (0, -1),
      };
      return steps > 0 ? (step: step, total: steps) : null;
    }
    final s = currentSlide;
    return s != null && s.clicks > 0 ? (step: step, total: s.clicks) : null;
  }

  /// En el modo Navegador la página la reporta el navegador; en los demás se cuenta.
  bool get slideIsExact => (mode == Mode.browser && browser.hasPdf) || pcPresenting;

  // ---- "Proyectar en esta PC" (modo WiFi): la PC dice en qué página va
  int _shownPage = 0;
  int _shownTotal = 0;
  int _shownStep = 0, _shownSteps = -1; // animación en la que va (la informa la PC)
  DateTime _shownPageAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// La app de escritorio está proyectando (avisa con cada respuesta, cada ~2 s).
  bool get pcPresenting =>
      mode == Mode.wifi && _shownPage > 0 && DateTime.now().difference(_shownPageAt) < const Duration(seconds: 6);

  /// Página y total que proyecta la PC (0 si no proyecta).
  int get shownPage => pcPresenting ? _shownPage : 0;
  int get shownTotal => pcPresenting ? _shownTotal : 0;

  void _onPcPage(int page, int total, int version, int step, int steps) {
    final was = pcPresenting;
    if (step != _shownStep || steps != _shownSteps) {
      _shownStep = step;
      _shownSteps = steps;
      notifyListeners();
    }
    _shownPage = page;
    _shownTotal = total;
    _shownPageAt = DateTime.now();
    if (page > 0 && version != 0 && version != _pcPdfVer) _fetchPcPdf(version);
    if (page > 0 && deck != null) {
      final i = _slideForPage(page, total);
      if (i != null && (i != slide || step != 0)) {
        slide = i;
        step = 0;
        notifyListeners();
        return;
      }
    }
    if (was != pcPresenting) notifyListeners();
  }

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
    hand = _prefs.getString('hand') == 'left' ? Hand.left : Hand.right;
    oneHand = _prefs.getBool('one_hand') ?? false;
    tapGuard = _prefs.getBool('tap_guard') ?? true;
    dnd = _prefs.getBool('dnd') ?? true;
    notesFont = (_prefs.getDouble('notes_font') ?? 22).clamp(15, 34);
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
    await timer.load();
    await _restorePdf();
    await _restoreNotes();
    _restoreMedia(); // en segundo plano: puede tardar con videos grandes
    // Si la app se cerró de golpe presentando, devolver el "No molestar" como estaba
    await NativeBridge.setDnd(false);

    _nativeSub = NativeBridge.events.listen(_onNative);
    languageChanged();
    _ready = true;
    notifyListeners();
    await onForeground();
  }

  @override
  void dispose() {
    _nativeSub?.cancel();
    if (dndState == DndState.on) NativeBridge.setDnd(false);
    if (locked) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    wifi.dispose();
    browser.dispose();
    _nudges.close();
    timer.dispose();
    thumbs.dispose();
    super.dispose();
  }

  /// La app volvió al frente: capturar volumen y reconectar el modo actual.
  Future<void> onForeground() async {
    // Diálogos del sistema (permisos, "hacer visible") también disparan onResume: ignorar
    if (!_ready || _foreground) return;
    _foreground = true;
    await NativeBridge.setVolumeCapture(true);
    await WakelockPlus.enable();
    if (locked) await _immersive(true);
    await _startMode(mode, resumed: true);
    await _syncDnd(); // pudo dar el acceso a "No molestar" en los ajustes del sistema
  }

  /// La app pasó a segundo plano: soltar el volumen y la PC.
  Future<void> onBackground() async {
    if (!_ready || !_foreground) return;
    _foreground = false;
    await NativeBridge.setVolumeCapture(false);
    await WakelockPlus.disable();
    await _stopTransports(keepBrowser: true);
    await _syncDnd();
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

  /// Botones de la pantalla: con [tapGuard], un segundo toque muy seguido se ignora
  /// (un roce o un doble toque sin querer no salta dos diapositivas).
  void tap({required bool forward}) {
    if (locked) return;
    final now = DateTime.now();
    if (tapGuard && now.difference(_lastTap) < const Duration(milliseconds: 380)) return;
    _lastTap = now;
    send(forward: forward);
  }

  Future<void> send({required bool forward}) async {
    (forward ? pulseNext : pulsePrev).value++;
    final cmd = Cmd.of(forward: forward, arrows: arrows);
    switch (mode) {
      case Mode.bluetooth:
        if (isAndroid) {
          if (await NativeBridge.hidSend(hidUsageFor(cmd))) return _advance(forward);
          if (await NativeBridge.hidReconnect()) {
            _nudge(t('Reconectando con la PC…', 'Reconnecting to the computer…'));
          } else {
            _nudge(t('Conecta tu PC primero', 'Connect your computer first'));
          }
        } else {
          if (await NativeBridge.bleSend(cmd)) return _advance(forward);
          _nudge(t('Abre Zlide en la PC para conectar', 'Open Zlide on the computer to connect'));
        }
      case Mode.wifi:
        if (wifi.target == null) return _nudge(t('Elige tu PC', 'Choose your computer'));
        if (wifi.busy) {
          return _nudge(t('Otro teléfono está presentando en esta PC', 'Another phone is presenting on this computer'));
        }
        final sent = wifi.send(cmd);
        // Si la PC proyecta, ella dice la página exacta; si no, se cuentan las pulsaciones
        if (sent && !pcPresenting) _advance(forward);
        if (!sent) {
          _nudge(t('No se pudo enviar', 'Could not send'));
        } else if (!wifi.online) {
          _nudge(t('La PC no responde. ¿Está abierta Zlide?', 'The computer is not responding. Is Zlide open?'));
        }
      case Mode.browser:
        if (!browser.hasPdf) return _nudge(t('Primero elige tu presentación', 'Choose your presentation first'));
        if (!browser.go(forward ? 1 : -1)) _nudge(t('Abre la dirección en el navegador de la PC', 'Open the address in the computer’s browser'));
    }
  }

  void _nudge(String msg) {
    if (!_nudges.isClosed) _nudges.add(msg);
  }

  // ================================================================ ir a una diapositiva

  /// Total de páginas cuando se transmite (la página la sabe quien proyecta), o 0.
  int get exactTotal => switch (mode) {
        Mode.browser when browser.hasPdf => browser.total,
        Mode.wifi when pcPresenting => _shownTotal,
        _ => 0,
      };

  /// Página del PDF que corresponde a la diapositiva [i] de [deck] (al revés que [_slideForPage]).
  int _pageForSlide(int i, int pdfPages) {
    final d = deck!;
    if (pdfPages == _deckTotal && _deckTotal != d.length) return d[i].number;
    return i + 1;
  }

  /// Ir a la diapositiva [i] de [deck] (la lista que sale al tocar el número).
  Future<void> goToSlide(int i) async {
    final d = deck;
    if (d == null || i < 0 || i >= d.length) return;
    if (slideIsExact) return goToPage(_pageForSlide(i, exactTotal));
    // Sin transmitir: la PC escribe el número (contando las ocultas) y Enter
    if (await _typeSlideNumber(d[i].number)) {
      slide = i;
      step = 0;
      notifyListeners();
    }
  }

  /// Transmitiendo: ir a la página [page] del PDF. La posición se sincroniza sola al cambiar.
  Future<void> goToPage(int page) async {
    HapticFeedback.selectionClick();
    switch (mode) {
      case Mode.browser:
        browser.goTo(page);
      case Mode.wifi:
        if (!wifi.sendGoTo(page)) _nudge(t('No se pudo enviar', 'Could not send'));
      case Mode.bluetooth:
        await _typeSlideNumber(page);
    }
  }

  /// Control Bluetooth y WiFi sin proyectar: el número y Enter. true si se envió.
  Future<bool> _typeSlideNumber(int n) async {
    HapticFeedback.selectionClick();
    switch (mode) {
      case Mode.bluetooth:
        if (isAndroid) {
          for (final usage in hidUsagesForNumber(n)) {
            if (!await NativeBridge.hidSend(usage)) {
              _nudge(t('Conecta tu PC primero', 'Connect your computer first'));
              return false;
            }
          }
          return true;
        }
        if (await NativeBridge.bleSend(Cmd.goTo, arg: n)) return true;
        _nudge(t('Abre Zlide en la PC para conectar', 'Open Zlide on the computer to connect'));
        return false;
      case Mode.wifi:
        if (wifi.target == null) {
          _nudge(t('Elige tu PC', 'Choose your computer'));
          return false;
        }
        if (wifi.sendGoTo(n)) return true;
        _nudge(t('No se pudo enviar', 'Could not send'));
        return false;
      case Mode.browser:
        return false; // con PDF siempre es exacto
    }
  }

  // ================================================================ miniatura de la siguiente

  /// PDF del que salen las miniaturas: el del teléfono, o el que proyecta la PC.
  String? get thumbPdf => switch (mode) {
        Mode.browser => browser.pdfFile?.path,
        Mode.wifi when pcPresenting => _pcPdfPath,
        _ => null,
      };

  /// Página de la siguiente diapositiva, solo al transmitir.
  int? get nextPage {
    if (!slideIsExact || nextSlide == null) return null;
    return _pageForSlide(slide + 1, exactTotal);
  }

  // PDF que proyecta la PC, descargado para las miniaturas (también lo usa la vista de dibujo)
  int _pcPdfVer = 0;
  String? _pcPdfPath;
  bool _pcPdfLoading = false;
  DateTime _pcPdfFailedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// (versión, ruta) del PDF de la PC ya descargado.
  (int, String)? get pcPdf => _pcPdfPath == null ? null : (_pcPdfVer, _pcPdfPath!);

  Future<void> _fetchPcPdf(int version) async {
    final host = wifi.targetAddress;
    final port = _pcPort;
    if (_pcPdfLoading || host == null || port == null) return;
    if (DateTime.now().difference(_pcPdfFailedAt) < const Duration(seconds: 30)) return;
    _pcPdfLoading = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final file = File('${Directory.systemTemp.path}/slideremote_thumb_$version.pdf');
    try {
      final res = await (await client.getUrl(Uri(scheme: 'http', host: host.address, port: port, path: '/deck.pdf')))
          .close()
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      await res.pipe(file.openWrite()).timeout(const Duration(seconds: 60));
      final old = _pcPdfPath;
      _pcPdfVer = version;
      _pcPdfPath = file.path;
      if (old != null && old != file.path) File(old).delete().ignore();
      notifyListeners();
    } catch (e) {
      debugPrint('PDF de la PC: $e');
      _pcPdfFailedAt = DateTime.now();
    } finally {
      client.close(force: true);
      _pcPdfLoading = false;
    }
  }

  // ================================================================ ajustes

  /// Avisar del idioma a la parte nativa (mensajes de Bluetooth/conversión) y a la página
  /// del modo Navegador. La interfaz se redibuja sola al cambiar [I18n.current].
  void languageChanged() {
    NativeBridge.setLanguage(I18n.current.value);
    browser.setLanguage(I18n.current.value);
    notifyListeners();
  }

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

  Future<void> setHand(Hand h) async {
    hand = h;
    await _prefs.setString('hand', h.name);
    notifyListeners();
  }

  Future<void> setOneHand(bool v) async {
    oneHand = v;
    await _prefs.setBool('one_hand', v);
    notifyListeners();
  }

  Future<void> setTapGuard(bool v) async {
    tapGuard = v;
    await _prefs.setBool('tap_guard', v);
    notifyListeners();
  }

  Future<void> setNotesFont(double v) async {
    notesFont = v.clamp(15, 34);
    notifyListeners();
    await _prefs.setDouble('notes_font', notesFont);
  }

  // ================================================================ al presentar

  /// Bloquear la pantalla: solo los botones de volumen cambian de diapositiva; se ocultan las
  /// barras del sistema para que un roce en los bordes no saque de la app.
  Future<void> setLocked(bool v) async {
    if (v == locked) return;
    locked = v;
    HapticFeedback.mediumImpact();
    notifyListeners();
    await _immersive(v);
  }

  static Future<void> _immersive(bool on) =>
      SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);

  Future<void> setDnd(bool v) async {
    dnd = v;
    await _prefs.setBool('dnd', v);
    if (v && (await NativeBridge.dndStatus()) == 'denied') {
      dndState = DndState.needsAccess;
      notifyListeners();
      await NativeBridge.openDndSettings();
      return;
    }
    await _syncDnd();
  }

  Future<void> openDndSettings() => NativeBridge.openDndSettings();

  /// "No molestar" activo mientras la app está al frente y se puede presentar (conectado).
  bool _dndBusy = false;
  Future<void> _syncDnd() async {
    if (!_ready || _dndBusy) return;
    _dndBusy = true;
    try {
      // Una vez activo se queda mientras la app esté al frente: un corte de la conexión no debe
      // dejar pasar avisos ni cambiar el modo del sistema a cada rato
      final want = dnd && _foreground && (canSend || dndState == DndState.on);
      final st = await NativeBridge.dndStatus();
      final DndState next;
      if (st == 'unsupported') {
        next = DndState.unsupported;
      } else if (st != 'granted') {
        next = dnd ? DndState.needsAccess : DndState.off;
      } else if (want) {
        next = await NativeBridge.setDnd(true) == 'on' ? DndState.on : DndState.needsAccess;
      } else {
        if (dndState == DndState.on) await NativeBridge.setDnd(false);
        next = DndState.off;
      }
      if (next != dndState) {
        dndState = next;
        super.notifyListeners();
      }
    } finally {
      _dndBusy = false;
    }
  }

  // ================================================================ empezar a presentar en la PC

  /// La PC tiene una presentación elegida (y no la controla otro teléfono).
  bool get pcCanStart => mode == Mode.wifi && wifi.online && !wifi.busy && wifi.pcHasDeck;

  /// La PC está presentando con el programa original (PowerPoint, Keynote, Impress).
  bool get pcNative => mode == Mode.wifi && wifi.online && wifi.pcDeckMode == DeckMode.native;

  /// La presentación tiene animaciones o videos: conviene el programa original.
  bool get deckHasAnimations => deck?.any((s) => s.clicks > 0) ?? false;

  void startOnPc({required bool native}) {
    if (!wifi.sendStart(native: native)) return _nudge(t('No se pudo enviar', 'Could not send'));
    HapticFeedback.selectionClick();
    _nudge(native
        ? t('Abriendo la presentación en la PC…', 'Opening the presentation on the computer…')
        : t('Preparando la presentación en la PC…', 'Preparing the presentation on the computer…'));
  }

  void stopOnPc() {
    if (wifi.sendStop()) HapticFeedback.selectionClick();
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
      btMessage = t('Este teléfono no soporta el modo teclado Bluetooth', 'This phone does not support Bluetooth keyboard mode');
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
    if (addr == null) return _nudge(t('Primero empareja tu PC', 'Pair your computer first'));
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
        if (e['ok'] == true) {
          _nudge(t('Visible por 2 min: empareja desde la configuración Bluetooth de la PC',
              'Visible for 2 min: pair from the computer’s Bluetooth settings'));
        }
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

  /// La misma presentación en SVG, con animaciones (solo si la conversión pudo hacerlo).
  Future<File> _svgStore() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/presentacion.svg');
  }

  Future<Directory> _mediaDir() async => Directory('${(await getApplicationSupportDirectory()).path}/media');

  /// Videos del archivo que se transmite desde el móvil (si el .pptx/.odp sigue guardado).
  Future<void> _restoreMedia() async {
    final name = _prefs.getString('pdf_name');
    if (name == null || name != _slots[Mode.browser]!.name) return;
    try {
      final f = await _notesStore(Mode.browser);
      if (!await f.exists()) return;
      final dir = await _mediaDir();
      final media = await DeckMediaSet.extract(await f.readAsBytes(), dir.path);
      if (browser.pdfName == name) browser.setMedia(media);
    } catch (_) {}
  }

  Future<void> _restorePdf() async {
    final name = _prefs.getString('pdf_name');
    if (name == null) return;
    final f = await _pdfStore();
    final svg = await _svgStore();
    if (await f.exists()) await browser.setPdf(f, name, svg: await svg.exists() ? svg : null);
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
    final svgDest = await _svgStore();

    if (ext == 'pdf') {
      await clearNotes(of: Mode.browser); // un PDF no trae notas: no dejar las de otra presentación
      if (await svgDest.exists()) await svgDest.delete(); // el de la presentación anterior
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
    final svgOutput = File('${dir.path}/convertido.svg');
    try {
      await input.writeAsBytes(bytes, flush: true);

      // Notas del mismo archivo (.pptx, .odp y afines; .ppt y .key no se pueden leer directo)
      PptxDeck? info;
      if (kNotesExtensions.contains(ext)) {
        try {
          info = await PptxNotes.parse(bytes);
          await _loadNotes(bytes, name, quiet: true, into: Mode.browser);
        } catch (_) {
          info = null; // sin notas, pero se intenta convertir igual
          await clearNotes(of: Mode.browser);
        }
      } else {
        await clearNotes(of: Mode.browser);
      }

      final (available, reason) = await NativeBridge.converterStatus();
      if (!available) {
        _nudge(reason == null
            ? t('Esta versión no incluye el convertidor. Elige la presentación exportada a PDF.',
                'This version does not include the converter. Choose the presentation exported as PDF.')
            : '${t('Convertidor no disponible', 'Converter not available')}: $reason');
        return;
      }
      if (await output.exists()) await output.delete();
      if (await svgOutput.exists()) await svgOutput.delete();
      await NativeBridge.convertToPdf(
        input: input.path,
        output: output.path,
        svgOutput: svgOutput.path,
        aspect: info?.aspect,
        expected: info?.total,
      );
      await output.copy(dest.path);
      // Con SVG se ven las animaciones y transiciones en el navegador
      final hasSvg = await svgOutput.exists() && await svgOutput.length() > 0;
      if (hasSvg) {
        await svgOutput.copy(svgDest.path);
      } else if (await svgDest.exists()) {
        await svgDest.delete();
      }
      await _prefs.setString('pdf_name', name);
      await browser.setPdf(dest, name, svg: hasSvg ? svgDest : null);
      // Videos y audios del archivo: se ponen encima del PDF en el navegador
      final mediaDir = await _mediaDir();
      try {
        if (await mediaDir.exists()) await mediaDir.delete(recursive: true);
      } catch (_) {}
      if (kNotesExtensions.contains(ext)) browser.setMedia(await DeckMediaSet.extract(bytes, mediaDir.path));
      if (deck != null && kNotesExtensions.contains(ext)) _nudge(t('Listo: presentación convertida y notas cargadas', 'Done: presentation converted and notes loaded'));
    } on PlatformException catch (e) {
      _nudge('${t('No se pudo convertir', 'Could not convert')}: ${e.message ?? e.code}');
    } catch (e) {
      _nudge('${t('No se pudo convertir', 'Could not convert')}: $e');
    } finally {
      converting = false;
      convertingName = null;
      try {
        if (await input.exists()) await input.delete();
        if (await output.exists()) await output.delete();
        if (await svgOutput.exists()) await svgOutput.delete();
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
      final i = _slideForPage(page, browser.total);
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
  int? _slideForPage(int page, int pdfPages) {
    final d = deck;
    if (d == null || d.isEmpty) return null;
    if (pdfPages == _deckTotal && _deckTotal != d.length) {
      final i = d.indexWhere((s) => s.number == page);
      return i >= 0 ? i : null; // diapositiva oculta: se queda la anterior
    }
    return (page - 1).clamp(0, d.length - 1);
  }

  Future<File> _notesStore(Mode m) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/notas_${m.name}.bin');
  }

  Future<void> _restoreNotes() async {
    // Versión anterior: un solo archivo de notas para todos los modos → pasa a "Control Bluetooth"
    final oldName = _prefs.getString('notes_name');
    if (oldName != null) {
      final dir = await getApplicationSupportDirectory();
      final old = File('${dir.path}/notas.pptx');
      try {
        if (await old.exists()) await old.rename((await _notesStore(Mode.bluetooth)).path);
        await _prefs.setString('notes_name_${Mode.bluetooth.name}', oldName);
        await _prefs.setInt('notes_slide_${Mode.bluetooth.name}', _prefs.getInt('notes_slide') ?? 0);
      } catch (_) {}
      await _prefs.remove('notes_name');
      await _prefs.remove('notes_slide');
    }
    for (final s in _slots.values) {
      final name = _prefs.getString('notes_name_${s.mode.name}');
      if (name == null) continue;
      final f = await _notesStore(s.mode);
      if (!await f.exists()) continue;
      try {
        final parsed = await PptxNotes.parse(await f.readAsBytes());
        s.deck = parsed.slides;
        s.total = parsed.total;
        s.name = name;
        s.slide = (_prefs.getInt('notes_slide_${s.mode.name}') ?? 0)
            .clamp(0, parsed.slides.isEmpty ? 0 : parsed.slides.length - 1);
      } catch (_) {
        s.deck = null;
      }
    }
  }

  /// Carga las notas de un .pptx/.odp ya leído en el modo [into] (por defecto, el actual).
  /// Lanza FormatException si no es válido.
  Future<void> _loadNotes(Uint8List bytes, String name, {required bool quiet, Mode? into}) async {
    final s = _slots[into ?? mode]!;
    final parsed = await PptxNotes.parse(bytes);
    if (parsed.slides.isEmpty) throw FormatException(t('La presentación no tiene diapositivas.', 'The presentation has no slides.'));
    await (await _notesStore(s.mode)).writeAsBytes(bytes, flush: true);
    await _prefs.setString('notes_name_${s.mode.name}', name);
    s.deck = parsed.slides;
    s.total = parsed.total;
    s.name = name;
    s.slide = 0;
    s.step = 0;
    if (!quiet && parsed.slides.every((s) => s.notes.trim().isEmpty)) {
      _nudge(t('Esta presentación no tiene notas del presentador', 'This presentation has no speaker notes'));
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
      _nudge(t('No se pudo leer el archivo. ¿Es un .pptx u .odp?', 'Could not read the file. Is it a .pptx or .odp?'));
    } finally {
      deckLoading = false;
      notifyListeners();
    }
  }

  /// Quita las notas del modo [of] (por defecto, el actual).
  Future<void> clearNotes({Mode? of}) async {
    final s = _slots[of ?? mode]!;
    s.deck = null;
    s.name = null;
    s.total = 0;
    s.slide = 0;
    s.step = 0;
    await _prefs.remove('notes_name_${s.mode.name}');
    try {
      await (await _notesStore(s.mode)).delete();
    } catch (_) {}
    notifyListeners();
  }

  /// Volver al inicio (p. ej. al empezar a presentar).
  void restartNotes() {
    slide = 0;
    step = 0;
    notifyListeners();
  }

  bool _couldSend = false;

  @override
  void notifyListeners() {
    if (_ready) {
      final s = _slot;
      if (s.deck != null) _prefs.setInt('notes_slide_${s.mode.name}', s.slide);
      final can = canSend;
      if (can != _couldSend) {
        _couldSend = can;
        _syncDnd();
      }
    }
    super.notifyListeners();
  }

  // ---------------------------------------------------------------- notas desde la PC

  /// La PC dice qué versión de notas tiene (llega con cada respuesta al ping, cada ~2 s).
  void _onPcNotes(int version, int port) {
    final host = wifi.targetAddress;
    if (host == null) return;
    if (_pcPort != port) {
      _pcPort = port;
      notifyListeners();
    }
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
      _pcName = (j['name'] as String?) ?? t('presentación', 'presentation');
      _pcVersion = v;
      _pcFor = host.address;
      if (sameFile) {
        // Solo se guardaron cambios en el archivo: conservar la posición
        _pcSlide = _pcSlide.clamp(0, parsed.slides.length - 1);
        _pcStep = 0;
      } else {
        _pcSlide = 0;
        _pcStep = 0;
        if (mode == Mode.wifi) _nudge('${t('Notas de la PC', 'Notes from the computer')}: $_pcName');
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
          BtState.connected => ConnView(Conn.on, t('Conectado', 'Connected'), isIOS ? t('App de escritorio', 'Desktop app') : btDeviceName),
          BtState.connecting => ConnView(Conn.busy, t('Conectando…', 'Connecting…'), btDeviceName),
          BtState.waiting => ConnView(Conn.busy, t('Esperando PC', 'Waiting for computer'), t('Abre Zlide en la PC', 'Open Zlide on the computer')),
          BtState.off => ConnView(Conn.error, t('Bluetooth apagado', 'Bluetooth off'), t('Actívalo en el teléfono', 'Turn it on on the phone')),
          BtState.noPermission => ConnView(Conn.error, t('Sin permiso', 'No permission'), t('Permite el acceso a Bluetooth', 'Allow Bluetooth access')),
          BtState.unavailable => ConnView(Conn.error, t('No disponible', 'Not available'), btMessage),
          BtState.idle => ConnView(Conn.off, t('Desconectado', 'Disconnected'), btMessage ?? t('Elige tu PC y conecta', 'Choose your computer and connect')),
          BtState.unknown => ConnView(Conn.off, t('Preparando…', 'Getting ready…')),
        };
      case Mode.wifi:
        final pc = wifi.target;
        if (pc == null) return ConnView(Conn.off, t('Sin PC', 'No computer'), t('Elige tu PC en la lista', 'Choose your computer in the list'));
        if (wifi.online && wifi.busy) {
          return ConnView(Conn.error, t('PC ocupada', 'Computer busy'), t('Otro teléfono está presentando', 'Another phone is presenting'));
        }
        if (wifi.online && pcNative) {
          return ConnView(Conn.on, t('Presentando en la PC', 'Presenting on the computer'), t('Con el programa original', 'With the original app'));
        }
        if (wifi.online && pcPresenting) {
          return ConnView(Conn.on, t('Proyectando en la PC', 'Presenting on the computer'),
              _shownTotal > 0 ? t('Diapositiva $_shownPage de $_shownTotal', 'Slide $_shownPage of $_shownTotal') : pc.name);
        }
        if (wifi.online) {
          return ConnView(Conn.on, t('Conectado', 'Connected'), '${pc.name}${wifi.latencyMs != null ? ' · ${wifi.latencyMs} ms' : ''}');
        }
        return ConnView(Conn.busy, t('Buscando…', 'Searching…'), pc.name);
      case Mode.browser:
        if (browser.error != null) return ConnView(Conn.error, 'Error', browser.error);
        if (converting) return ConnView(Conn.busy, t('Convirtiendo…', 'Converting…'), t('Se hace en el teléfono', 'Done on the phone'));
        if (!browser.hasPdf) return ConnView(Conn.off, t('Sin presentación', 'No presentation'), t('Elige tu presentación', 'Choose your presentation'));
        if (browser.viewers > 0) {
          return ConnView(Conn.on, t('Proyectando', 'Presenting'),
              browser.total > 0
                  ? t('Diapositiva ${browser.page} de ${browser.total}', 'Slide ${browser.page} of ${browser.total}')
                  : t('Cargando PDF…', 'Loading PDF…'));
        }
        return ConnView(Conn.busy, t('Esperando', 'Waiting'), t('Abre la dirección en la PC', 'Open the address on the computer'));
    }
  }

  bool get canSend => status.conn == Conn.on;
}

/// Notas elegidas en el teléfono para un modo.
class _NotesSlot {
  _NotesSlot(this.mode);
  final Mode mode;
  List<SlideInfo>? deck;
  String? name;
  int total = 0; // diapositivas del archivo contando las ocultas
  int slide = 0;
  int step = 0;
}
