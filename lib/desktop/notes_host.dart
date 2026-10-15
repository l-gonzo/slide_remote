import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../common/pptx_notes.dart';
import '../common/protocol.dart';

/// Lo que se puede elegir en la app de escritorio. Los que no están en [kNotesExtensions]
/// necesitan LibreOffice instalado en la PC.
const kDesktopNotesExtensions = [...kNotesExtensions, 'ppt', 'pps', 'pot', 'key', 'dps'];

/// App de escritorio: lee las notas del .pptx que está en la PC y se las sirve al teléfono
/// por WiFi (GET http://<pc>:<puerto>/notes). Así el archivo no tiene que estar en el teléfono.
class NotesHost extends ChangeNotifier {
  NotesHost({required this.isAllowed});

  /// Solo se contesta a teléfonos que ya hablaron con esta PC por UDP (no a cualquiera en la red).
  final bool Function(InternetAddress) isAllowed;

  String? path;
  String? name;
  PptxDeck? deck;
  bool loading = false;
  String? error;

  /// Cambia cada vez que se carga una presentación (o el archivo se modifica). 0 = sin notas.
  int version = 0;
  int port = 0;

  HttpServer? _server;
  DateTime? _mtime;
  String _json = '{"version":0}';
  SharedPreferences? _prefs;

  int get slideCount => deck?.slides.length ?? 0;
  int get withNotes => deck?.slides.where((s) => s.notes.trim().isNotEmpty).length ?? 0;

  Future<void> start() async {
    _prefs = await SharedPreferences.getInstance();
    await _startServer();
    final saved = _prefs!.getString('desktop_notes_path');
    if (saved != null && await File(saved).exists()) await load(saved, quiet: true);
  }

  @override
  void dispose() {
    _server?.close(force: true);
    _server = null;
    super.dispose();
  }

  Future<void> _startServer() async {
    HttpServer? s;
    try {
      s = await HttpServer.bind(InternetAddress.anyIPv4, kNotesPort);
    } on SocketException {
      // Puerto ocupado: cualquiera libre (se anuncia en el mensaje NOTES)
      try {
        s = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      } catch (e) {
        error = 'No se pudo abrir el servidor de notas: $e';
        notifyListeners();
        return;
      }
    }
    _server = s;
    port = s.port;
    s.listen(_handle, onError: (_) {});
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final from = req.connectionInfo?.remoteAddress;
      if (from == null || !isAllowed(from)) {
        res.statusCode = HttpStatus.forbidden;
      } else if (req.method == 'GET' && req.uri.path == '/notes') {
        res.headers.contentType = ContentType.json;
        res.headers.set('Cache-Control', 'no-store');
        res.add(utf8.encode(_json));
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      res.statusCode = HttpStatus.internalServerError;
    }
    await res.close();
  }

  Future<void> pick() async {
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: kDesktopNotesExtensions);
    final p = picked?.path;
    if (p == null) return;
    await load(p, quiet: false);
  }

  Future<void> load(String filePath, {required bool quiet}) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final f = File(filePath);
      final base = _baseName(filePath);
      final ext = base.contains('.') ? base.split('.').last.toLowerCase() : '';
      final parsed = kNotesExtensions.contains(ext)
          ? await PptxNotes.parse(await f.readAsBytes())
          : await _parseWithLibreOffice(f, ext);
      if (parsed.slides.isEmpty) throw const FormatException('La presentación no tiene diapositivas.');
      path = filePath;
      name = base;
      deck = parsed;
      _mtime = await f.lastModified();
      _publish();
      await _prefs?.setString('desktop_notes_path', filePath);
    } on FormatException catch (e) {
      if (!quiet) error = e.message;
    } catch (e) {
      if (!quiet) error = 'No se pudo leer el archivo. ¿Es una presentación? ($e)';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  static String _baseName(String p) {
    final parts = p.split(RegExp(r'[/\\]'));
    return parts.lastWhere((x) => x.isNotEmpty, orElse: () => p);
  }

  /// Formatos que no se leen directo (.ppt viejo, Keynote…): si LibreOffice está instalado en
  /// la PC, se convierten a .odp en segundo plano y se leen las notas de ahí.
  static Future<PptxDeck> _parseWithLibreOffice(File f, String ext) async {
    final soffice = await _findSoffice();
    if (soffice == null) {
      throw FormatException('Para leer .$ext instala LibreOffice en esta PC, '
          'o guarda la presentación como .pptx u .odp.');
    }
    final tmp = await Directory.systemTemp.createTemp('slideremote');
    try {
      // Perfil propio: así funciona aunque LibreOffice ya esté abierto
      final profile = Uri.directory('${tmp.path}/perfil').toString();
      final r = await Process.run(soffice, [
        '-env:UserInstallation=$profile',
        '--headless',
        '--norestore',
        '--convert-to',
        'odp',
        '--outdir',
        tmp.path,
        f.path,
      ]).timeout(const Duration(minutes: 2));
      final out = tmp
          .listSync()
          .whereType<File>()
          .where((x) => x.path.toLowerCase().endsWith('.odp'))
          .firstOrNull;
      if (out == null) {
        throw FormatException('LibreOffice no pudo abrir el archivo .$ext (${'${r.stderr}'.trim()})');
      }
      return await PptxNotes.parse(await out.readAsBytes());
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<String?> _findSoffice() async {
    final candidates = <String>[
      if (Platform.isMacOS) '/Applications/LibreOffice.app/Contents/MacOS/soffice',
      if (Platform.isWindows) ...[
        r'C:\Program Files\LibreOffice\program\soffice.exe',
        r'C:\Program Files (x86)\LibreOffice\program\soffice.exe',
      ],
      if (Platform.isLinux) ...['/usr/bin/soffice', '/usr/bin/libreoffice', '/snap/bin/libreoffice',
        '/var/lib/flatpak/exports/bin/org.libreoffice.LibreOffice'],
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }
    // En el PATH
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', ['soffice']);
      final p = '${r.stdout}'.trim().split('\n').first.trim();
      if (r.exitCode == 0 && p.isNotEmpty) return p;
    } catch (_) {}
    return null;
  }

  void clear() {
    path = null;
    name = null;
    deck = null;
    _mtime = null;
    error = null;
    version = 0;
    _json = '{"version":0}';
    _prefs?.remove('desktop_notes_path');
    notifyListeners();
  }

  /// Si guardaste cambios en la presentación, se vuelven a leer las notas.
  Future<void> checkModified() async {
    final p = path;
    if (p == null || loading) return;
    try {
      final m = await File(p).lastModified();
      if (_mtime != null && m != _mtime) await load(p, quiet: true);
    } catch (_) {
      // El archivo se movió o borró: se conservan las notas ya leídas
    }
  }

  void _publish() {
    // Siempre distinto (y nunca 0): así el teléfono sabe que debe volver a descargar
    final v = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
    version = v == version ? v + 1 : (v == 0 ? 1 : v);
    _json = jsonEncode({'version': version, 'name': name, ...deck!.toJson()});
  }
}
