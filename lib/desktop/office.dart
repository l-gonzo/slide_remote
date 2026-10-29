import 'dart:async';
import 'dart:io';

import '../common/i18n.dart';

/// Conversión de presentaciones con los programas que haya en la PC:
/// LibreOffice (Windows, macOS, Linux) y, en Windows, también PowerPoint.
abstract final class Office {
  static Future<String?> findSoffice() async {
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
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', ['soffice']);
      final p = '${r.stdout}'.trim().split('\n').first.trim();
      if (r.exitCode == 0 && p.isNotEmpty) return p;
    } catch (_) {}
    return null;
  }

  /// Convierte [input] a [format] ('pdf', 'odp'…) dentro de [outDir]. Devuelve el archivo.
  /// [filter]: filtro de exportación de LibreOffice, si el predeterminado no sirve.
  /// Lanza [FormatException] con un mensaje para el usuario si no se puede.
  static Future<File> convert(File input, String format, Directory outDir, {String? filter}) async {
    final soffice = await findSoffice();
    if (soffice != null) {
      // Perfil propio: así funciona aunque LibreOffice ya esté abierto
      final profile = Uri.directory('${outDir.path}/perfil').toString();
      final proc = await Process.start(soffice, [
        '-env:UserInstallation=$profile',
        '--headless',
        '--norestore',
        '--convert-to',
        filter == null ? format : '$format:$filter',
        '--outdir',
        outDir.path,
        input.path,
      ]);
      final stdout = proc.stdout.transform(const SystemEncoding().decoder).join();
      final stderr = proc.stderr.transform(const SystemEncoding().decoder).join();
      try {
        await proc.exitCode.timeout(const Duration(minutes: 3));
      } on TimeoutException {
        // Si no se termina, LibreOffice se quedaría abierto (y con el perfil bloqueado)
        proc.kill(ProcessSignal.sigkill);
        throw FormatException(t('LibreOffice tardó demasiado en convertir el archivo.',
            'LibreOffice took too long to convert the file.'));
      }
      final out = (await outDir.list().toList())
          .whereType<File>()
          .where((x) => x.path.toLowerCase().endsWith('.$format'))
          .firstOrNull;
      if (out != null) return out;
      final err = (await stderr).trim();
      final detail = err.isNotEmpty ? err : (await stdout).trim();
      throw FormatException('${t('LibreOffice no pudo convertir el archivo', 'LibreOffice could not convert the file')}'
          '${detail.isEmpty ? '.' : ' ($detail)'}');
    }
    if (Platform.isWindows && format == 'pdf' && filter == null) {
      final out = File('${outDir.path}\\presentacion.pdf');
      if (await _powerPointToPdf(input, out)) return out;
    }
    throw FormatException(t(
        'Para proyectar o leer este archivo instala LibreOffice en esta PC (gratis), o elige la presentación en PDF.',
        'To present or read this file install LibreOffice on this computer (free), or choose the presentation as PDF.'));
  }

  /// Nombre del programa con el que [openSlideshow] abriría [file] (para mostrarlo en la app).
  static Future<String?> slideshowApp(File file) async => (await _slideshowCommand(file))?.$1;

  /// Abre la presentación a pantalla completa en su programa (PowerPoint, Keynote o LibreOffice
  /// Impress). Ahí funcionan las animaciones, transiciones, videos y enlaces; el teléfono la
  /// controla con teclas como siempre. Lanza [FormatException] si no hay con qué abrirla.
  static Future<String> openSlideshow(File file) async {
    final cmd = await _slideshowCommand(file);
    if (cmd == null) {
      throw FormatException(t(
          'No se encontró PowerPoint, Keynote ni LibreOffice en esta PC para abrir la presentación.',
          'PowerPoint, Keynote or LibreOffice was not found on this computer to open the presentation.'));
    }
    final (app, exe, args) = cmd;
    await Process.start(exe, args, mode: ProcessStartMode.detached);
    return app;
  }

  /// (programa, ejecutable, argumentos) para presentar [file].
  static Future<(String, String, List<String>)?> _slideshowCommand(File file) async {
    final path = file.absolute.path;
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    String osa(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    if (Platform.isWindows && ext != 'odp' && ext != 'pdf' && await _windowsHasPowerPoint()) {
      // `start` busca POWERPNT.EXE en "App Paths"; /S abre directo la presentación
      return ('PowerPoint', 'cmd', ['/c', 'start', '', 'POWERPNT.EXE', '/S', path]);
    }
    if (Platform.isMacOS) {
      if (ext == 'key' && await Directory('/Applications/Keynote.app').exists()) {
        return ('Keynote', 'osascript', [
          '-e', 'tell application "Keynote"',
          '-e', 'activate',
          '-e', 'set d to open POSIX file "${osa(path)}"',
          '-e', 'start d from first slide of d',
          '-e', 'end tell',
        ]);
      }
      if (ext != 'odp' && ext != 'pdf' && await Directory('/Applications/Microsoft PowerPoint.app').exists()) {
        return ('PowerPoint', 'osascript', [
          '-e', 'tell application "Microsoft PowerPoint"',
          '-e', 'activate',
          '-e', 'open POSIX file "${osa(path)}"',
          '-e', 'run slide show slide show settings of active presentation',
          '-e', 'end tell',
        ]);
      }
    }
    if (ext != 'pdf') {
      final soffice = await findSoffice();
      if (soffice != null) return ('LibreOffice Impress', soffice, ['--norestore', '--show', path]);
    }
    // Un PDF (o nada más instalado): el programa predeterminado del sistema
    if (Platform.isWindows) return (t('el visor de PDF', 'the PDF viewer'), 'cmd', ['/c', 'start', '', path]);
    if (Platform.isMacOS) return (t('el visor de PDF', 'the PDF viewer'), 'open', [path]);
    if (ext == 'pdf') return (t('el visor de PDF', 'the PDF viewer'), 'xdg-open', [path]);
    return null;
  }

  static Future<bool> _windowsHasPowerPoint() async {
    try {
      for (final root in ['HKLM', 'HKCU']) {
        final r = await Process.run(
            'reg', ['query', '$root\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\powerpnt.exe', '/ve']);
        if (r.exitCode == 0) return true;
      }
    } catch (_) {}
    return false;
  }

  /// Windows con PowerPoint instalado: exportar a PDF por automatización (sin abrir ventanas).
  static Future<bool> _powerPointToPdf(File input, File out) async {
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    final script = r'$ErrorActionPreference = "Stop"; '
        r'$ppt = New-Object -ComObject PowerPoint.Application; '
        '\$p = \$ppt.Presentations.Open(${q(input.path)}, \$true, \$false, \$false); '
        '\$p.SaveAs(${q(out.path)}, 32); '
        r'$p.Close(); $ppt.Quit()';
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script])
          .timeout(const Duration(minutes: 3));
      return r.exitCode == 0 && await out.exists();
    } catch (_) {
      return false;
    }
  }
}
