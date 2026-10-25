import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'pptx_notes.dart';

/// Un video o audio insertado en una diapositiva. El PDF solo trae su imagen (el primer cuadro);
/// la página web pone el archivo real encima, en el mismo lugar, para reproducirlo.
class DeckMedia {
  const DeckMedia({
    required this.slide,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.file,
    required this.kind,
    required this.mime,
  });

  /// Número de diapositiva en el archivo (1 = primera, contando las ocultas).
  final int slide;

  /// Posición y tamaño como fracción de la diapositiva (0..1).
  final double x, y, w, h;

  /// Archivo ya extraído en disco.
  final String file;

  /// 'video' o 'audio'.
  final String kind;
  final String mime;
}

/// Videos y audios de una presentación, extraídos a una carpeta para servirlos a la página web.
class DeckMediaSet {
  const DeckMediaSet({required this.items, required this.visible, required this.total});
  static const empty = DeckMediaSet(items: [], visible: [], total: 0);

  final List<DeckMedia> items;

  /// Números de las diapositivas visibles (las ocultas no salen en el PDF).
  final List<int> visible;

  /// Diapositivas en el archivo, contando las ocultas.
  final int total;

  bool get isEmpty => items.isEmpty;

  /// Página del PDF de la diapositiva [slide], o null si no aparece. Igual que en las notas:
  /// si el PDF tiene tantas páginas como el archivo, incluye las ocultas.
  int? pageOf(int slide, int pdfPages) {
    if (pdfPages == total) return slide;
    final i = visible.indexOf(slide);
    return i < 0 ? null : i + 1;
  }

  /// Lo que se manda a la página web: `{t:'media', items:[{page, id, x, y, w, h, src, kind}]}`.
  /// [src] arma la dirección de cada archivo a partir de su índice en [items].
  Map<String, Object?> message(int pdfPages, String Function(int i) src) {
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < items.length && pdfPages > 0; i++) {
      final m = items[i];
      final page = pageOf(m.slide, pdfPages);
      if (page == null) continue;
      out.add({'id': i, 'page': page, 'x': m.x, 'y': m.y, 'w': m.w, 'h': m.h, 'src': src(i), 'kind': m.kind, 'mime': m.mime});
    }
    return {'t': 'media', 'items': out};
  }

  /// Lee la presentación [bytes] (.pptx u .odp) y extrae sus videos y audios a [dir].
  /// Nunca falla: si el formato no se entiende, no hay videos.
  static Future<DeckMediaSet> extract(Uint8List bytes, String dir) => Isolate.run(() {
        try {
          return _extractSync(bytes, dir);
        } catch (_) {
          return DeckMediaSet.empty;
        }
      });

  static DeckMediaSet _extractSync(Uint8List bytes, String dir) {
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) return DeckMediaSet.empty;
    final zip = ZipDecoder().decodeBytes(bytes);
    final found = zip.findFile('ppt/presentation.xml') != null ? _pptx(zip) : _odp(zip);
    if (found == null) return DeckMediaSet.empty;
    final (raw, visible, total) = found;
    if (raw.isEmpty) return DeckMediaSet(items: const [], visible: visible, total: total);
    Directory(dir).createSync(recursive: true);
    final out = <DeckMedia>[];
    final written = <String, String>{};
    for (final m in raw) {
      final f = zip.findFile(m.zipPath);
      if (f == null) continue;
      final ext = m.zipPath.contains('.') ? m.zipPath.split('.').last.toLowerCase() : '';
      final mime = _mime(ext, m.kind);
      if (mime == null) continue; // formato que el navegador no reproduce (wmv, avi…)
      final file = written[m.zipPath] ??= () {
        final path = '$dir/media${written.length}.$ext';
        File(path).writeAsBytesSync(f.content as List<int>, flush: true);
        return path;
      }();
      out.add(DeckMedia(
        slide: m.slide,
        x: m.x.clamp(0.0, 1.0),
        y: m.y.clamp(0.0, 1.0),
        w: m.w.clamp(0.0, 1.0),
        h: m.h.clamp(0.0, 1.0),
        file: file,
        kind: mime.startsWith('audio') ? 'audio' : 'video',
        mime: mime,
      ));
    }
    return DeckMediaSet(items: out, visible: visible, total: total);
  }

  static String? _mime(String ext, String kind) => switch (ext) {
        'mp4' || 'm4v' => kind == 'audio' ? 'audio/mp4' : 'video/mp4',
        'mov' => 'video/quicktime',
        'webm' => 'video/webm',
        'ogv' => 'video/ogg',
        'mp3' => 'audio/mpeg',
        'm4a' => 'audio/mp4',
        'wav' => 'audio/wav',
        'ogg' || 'oga' => 'audio/ogg',
        'aac' => 'audio/aac',
        _ => null,
      };

  // ------------------------------------------------------------------ .pptx

  static (List<_Raw>, List<int>, int)? _pptx(Archive zip) {
    final pres = _xml(zip, 'ppt/presentation.xml');
    if (pres == null) return null;
    final presRels = _rels(_xml(zip, 'ppt/_rels/presentation.xml.rels'));
    double cx = 0, cy = 0;
    for (final e in pres.descendantElements) {
      if (e.name.local != 'sldSz') continue;
      cx = double.tryParse(e.getAttribute('cx') ?? '') ?? 0;
      cy = double.tryParse(e.getAttribute('cy') ?? '') ?? 0;
      break;
    }
    if (cx <= 0 || cy <= 0) return null;
    final paths = <String>[];
    for (final e in pres.descendantElements) {
      if (e.name.local != 'sldId') continue;
      final id = _prefixedId(e);
      final target = id == null ? null : presRels[id]?.$2;
      if (target != null) paths.add(_resolve('ppt/', target));
    }
    final raw = <_Raw>[];
    final visible = <int>[];
    for (var i = 0; i < paths.length; i++) {
      final slide = _xml(zip, paths[i]);
      if (slide == null) continue;
      if (slide.rootElement.getAttribute('show') != '0') visible.add(i + 1);
      final dir = paths[i].substring(0, paths[i].lastIndexOf('/') + 1);
      final rels = _rels(_xml(zip, '${dir}_rels/${paths[i].substring(dir.length)}.rels'));
      for (final pic in slide.descendantElements.where((e) => e.name.local == 'pic')) {
        String? target;
        var kind = 'video';
        for (final e in pic.descendantElements) {
          final l = e.name.local;
          if (l == 'audioFile') kind = 'audio';
          // <p14:media r:embed> es el archivo dentro del .pptx; <a:videoFile r:link> puede ser externo
          if (l == 'media' || l == 'videoFile' || l == 'audioFile') {
            for (final a in e.attributes) {
              if ((a.name.local == 'embed' || a.name.local == 'link') && a.name.prefix != null) {
                final r = rels[a.value];
                if (r != null && !r.$3) target ??= _resolve(dir, r.$2);
              }
            }
          }
        }
        if (target == null) continue;
        final box = _pptxBox(pic);
        if (box == null) continue;
        raw.add(_Raw(i + 1, box.$1 / cx, box.$2 / cy, box.$3 / cx, box.$4 / cy, target, kind));
      }
    }
    return (raw, visible, paths.length);
  }

  /// Posición del elemento en la diapositiva (EMU), aplicando los grupos que lo contienen.
  static (double, double, double, double)? _pptxBox(XmlElement pic) {
    (double, double, double, double)? xfrm(XmlElement owner, String prPrefix) {
      final pr = owner.childElements.where((e) => e.name.local == prPrefix).firstOrNull;
      final x = pr?.childElements.where((e) => e.name.local == 'xfrm').firstOrNull;
      final off = x?.childElements.where((e) => e.name.local == 'off').firstOrNull;
      final ext = x?.childElements.where((e) => e.name.local == 'ext').firstOrNull;
      double n(XmlElement? e, String a) => double.tryParse(e?.getAttribute(a) ?? '') ?? 0;
      if (off == null || ext == null) return null;
      return (n(off, 'x'), n(off, 'y'), n(ext, 'cx'), n(ext, 'cy'));
    }

    var box = xfrm(pic, 'spPr');
    if (box == null) return null;
    for (var g = pic.parentElement; g != null; g = g.parentElement) {
      if (g.name.local != 'grpSp') continue;
      final pr = g.childElements.where((e) => e.name.local == 'grpSpPr').firstOrNull;
      final x = pr?.childElements.where((e) => e.name.local == 'xfrm').firstOrNull;
      double n(String el, String a) =>
          double.tryParse(x?.childElements.where((e) => e.name.local == el).firstOrNull?.getAttribute(a) ?? '') ?? 0;
      final chCx = n('chExt', 'cx'), chCy = n('chExt', 'cy');
      if (x == null || chCx <= 0 || chCy <= 0) continue;
      final sx = n('ext', 'cx') / chCx, sy = n('ext', 'cy') / chCy;
      final b = box!;
      box = (
        n('off', 'x') + (b.$1 - n('chOff', 'x')) * sx,
        n('off', 'y') + (b.$2 - n('chOff', 'y')) * sy,
        b.$3 * sx,
        b.$4 * sy,
      );
    }
    return box;
  }

  // ------------------------------------------------------------------ .odp

  static (List<_Raw>, List<int>, int)? _odp(Archive zip) {
    final content = _xml(zip, 'content.xml');
    if (content == null) return null;
    final styles = _xml(zip, 'styles.xml');
    final docs = [if (styles != null) styles, content];
    // Tamaño de la página: page-layout de la primera página maestra
    double? pw, ph;
    String? layout;
    for (final d in docs) {
      layout ??= _attr(d.descendantElements.where((e) => e.name.local == 'master-page').firstOrNull, 'page-layout-name');
    }
    for (final d in docs) {
      for (final pl in d.descendantElements.where((e) => e.name.local == 'page-layout')) {
        if (layout != null && _attr(pl, 'name') != layout) continue;
        final props = pl.childElements.where((e) => e.name.local == 'page-layout-properties').firstOrNull;
        pw ??= _cm(_attr(props, 'page-width'));
        ph ??= _cm(_attr(props, 'page-height'));
      }
    }
    if (pw == null || ph == null || pw <= 0 || ph <= 0) return null;
    final pres = content.descendantElements
        .where((e) => e.name.local == 'presentation' && e.parentElement?.name.local == 'body')
        .firstOrNull;
    if (pres == null) return null;
    final hidden = <String>{};
    for (final d in docs) {
      for (final st in d.descendantElements.where((e) => e.name.local == 'style')) {
        final props = st.childElements.where((e) => e.name.local == 'drawing-page-properties').firstOrNull;
        if (_attr(props, 'visibility') == 'hidden') hidden.add(_attr(st, 'name') ?? '');
      }
    }
    final pages = pres.childElements.where((e) => e.name.local == 'page').toList();
    final raw = <_Raw>[];
    final visible = <int>[];
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      if (!hidden.contains(_attr(page, 'style-name'))) visible.add(i + 1);
      for (final plugin in page.descendantElements.where((e) => e.name.local == 'plugin')) {
        final frame = plugin.parentElement;
        var href = _attr(plugin, 'href');
        if (frame == null || href == null || href.contains('://')) continue;
        if (href.startsWith('./')) href = href.substring(2);
        final x = _cm(_attr(frame, 'x')) ?? 0, y = _cm(_attr(frame, 'y')) ?? 0;
        final w = _cm(_attr(frame, 'width')), h = _cm(_attr(frame, 'height'));
        if (w == null || h == null) continue;
        final mime = _attr(plugin, 'mime-type') ?? '';
        raw.add(_Raw(i + 1, x / pw, y / ph, w / pw, h / ph, href, mime.startsWith('audio') ? 'audio' : 'video'));
      }
    }
    return (raw, visible, pages.length);
  }

  /// Longitud de OpenDocument ("12.5cm", "4in", "300pt"…) en centímetros.
  static double? _cm(String? v) {
    if (v == null) return null;
    final m = RegExp(r'^\s*(-?[\d.]+)\s*([a-z]*)').firstMatch(v);
    final n = double.tryParse(m?.group(1) ?? '');
    if (n == null) return null;
    return switch (m!.group(2)) {
      'mm' => n / 10,
      'in' => n * 2.54,
      'pt' => n * 2.54 / 72,
      'pc' => n * 2.54 / 6,
      'px' => n * 2.54 / 96,
      _ => n,
    };
  }

  // ------------------------------------------------------------------ comunes

  static XmlDocument? _xml(Archive zip, String path) {
    final f = zip.findFile(path);
    if (f == null) return null;
    try {
      return XmlDocument.parse(PptxNotes.decodeUtf8(Uint8List.fromList(f.content as List<int>)));
    } catch (_) {
      return null;
    }
  }

  /// Id → (tipo, destino, externo).
  static Map<String, (String, String, bool)> _rels(XmlDocument? d) => {
        if (d != null)
          for (final e in d.descendantElements.where((e) => e.name.local == 'Relationship'))
            if (e.getAttribute('Id') case final id?)
              if (e.getAttribute('Target') case final target?)
                id: (e.getAttribute('Type') ?? '', target, e.getAttribute('TargetMode') == 'External'),
      };

  static String? _prefixedId(XmlElement e) {
    for (final a in e.attributes) {
      if (a.name.local == 'id' && (a.name.prefix?.isNotEmpty ?? false)) return a.value;
    }
    return null;
  }

  static String _resolve(String baseDir, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final parts = [...baseDir.split('/').where((s) => s.isNotEmpty)];
    for (final seg in target.split('/')) {
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (seg.isNotEmpty && seg != '.') {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }

  static String? _attr(XmlElement? e, String local) {
    if (e == null) return null;
    for (final a in e.attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }
}

class _Raw {
  const _Raw(this.slide, this.x, this.y, this.w, this.h, this.zipPath, this.kind);
  final int slide;
  final double x, y, w, h;
  final String zipPath;
  final String kind;
}

/// Sirve un archivo con soporte de rangos (los navegadores los piden para adelantar un video).
Future<void> serveFileWithRange(HttpRequest req, File f, String mime) async {
  final res = req.response;
  final len = await f.length();
  res.headers
    ..set(HttpHeaders.contentTypeHeader, mime)
    ..set(HttpHeaders.acceptRangesHeader, 'bytes')
    ..set(HttpHeaders.cacheControlHeader, 'no-store');
  final range = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
  if (range != null && len > 0) {
    final a = int.tryParse(range.group(1)!);
    final b = int.tryParse(range.group(2)!);
    final start = a ?? (b == null ? 0 : (len - b).clamp(0, len - 1));
    final end = (a != null && b != null ? b : len - 1).clamp(start, len - 1);
    res.statusCode = HttpStatus.partialContent;
    res.headers
      ..set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$len')
      ..contentLength = end - start + 1;
    await res.addStream(f.openRead(start, end + 1));
  } else {
    res.headers.contentLength = len;
    await res.addStream(f.openRead());
  }
  await res.close();
}
