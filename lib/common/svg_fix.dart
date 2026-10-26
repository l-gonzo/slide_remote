import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Repara el SVG con animaciones que exporta LibreOffice (`impress_svg_Export`) antes de
/// mandarlo al navegador. El PDF de la misma presentación sale bien; el SVG tiene dos fallas:
///
///  1. **Imágenes que no se ven.** Una imagen que aparece más de una vez (en la misma
///     presentación) se exporta como `<use xlink:href="#bitmap(N)">`, pero muchas veces la
///     definición `bitmap(N)` no se escribe. Pasa con presentaciones de PowerPoint, Google
///     Slides, OnlyOffice, WPS y LibreOffice. Se reponen con la imagen original del .pptx o
///     .odp: el recuadro de cada `<use>` roto coincide con la posición de la imagen en la
///     diapositiva.
///  2. **"Haga clic para modificar el estilo…"**: los marcadores de título y texto del patrón
///     se exportan como figuras del fondo y el reproductor los muestra en cada diapositiva.
///     En una presentación nunca se ven: se quitan.
///
/// Nunca falla: si algo no se entiende, el SVG se queda como estaba.
abstract final class DeckSvgFix {
  /// [source]: la presentación original (.pptx u .odp) para reponer las imágenes; con otro
  /// formato solo se quitan los marcadores.
  static Future<void> apply(File svg, {String? source}) async {
    try {
      await Isolate.run(() => _applySync(svg.path, source));
    } catch (_) {}
  }

  static void _applySync(String svgPath, String? source) {
    final file = File(svgPath);
    final original = file.readAsStringSync();
    var s = _dropMasterPlaceholders(original);
    // Con un .ppt o .key no se entienden las imágenes: solo se quitan los marcadores
    if (source != null) {
      try {
        s = _restoreBitmaps(s, File(source).readAsBytesSync());
      } catch (_) {}
    }
    if (!identical(s, original) && s != original) file.writeAsStringSync(s, flush: true);
  }

  // ------------------------------------------------------------------ marcadores del patrón

  static final _placeholder = RegExp(r'<g class="com\.sun\.star\.presentation\.(?:TitleText|Outliner|Subtitle)Shape">');

  /// Quita los marcadores de título, texto y subtítulo de los patrones (están todos juntos,
  /// antes de las diapositivas).
  static String _dropMasterPlaceholders(String s) {
    final from = s.indexOf('class="Master_Slide"');
    if (from < 0) return s;
    var to = s.indexOf('<g class="DummySlide"', from);
    if (to < 0) to = s.indexOf('<g class="SlideGroup"', from);
    if (to < 0) return s;
    final out = StringBuffer();
    var at = 0;
    for (final m in _placeholder.allMatches(s.substring(0, to), from)) {
      if (m.start < at) continue;
      final end = _groupEnd(s, m.start);
      if (end < 0 || end > to) continue;
      out
        ..write(s.substring(at, m.start))
        ..write('<g/>'); // en su lugar, para no cambiar el orden de lo demás
      at = end;
    }
    if (at == 0) return s;
    out.write(s.substring(at));
    return out.toString();
  }

  /// Fin (exclusivo) del `<g>` que empieza en [start], contando los anidados.
  static int _groupEnd(String s, int start) {
    var depth = 0;
    var i = start;
    while (i < s.length) {
      final open = s.indexOf('<g', i);
      final close = s.indexOf('</g>', i);
      if (close < 0) return -1;
      if (open >= 0 && open < close) {
        final after = open + 2 < s.length ? s[open + 2] : '';
        final tagEnd = s.indexOf('>', open);
        if (tagEnd < 0) return -1;
        // `<g ...>` o `<g>`; no `<glyph` ni otros que empiecen con g
        if (after == ' ' || after == '>' || after == '/' || after == '\n') {
          if (s[tagEnd - 1] != '/') depth++;
          if (depth == 0) return tagEnd + 1; // `<g/>` suelto al inicio
        }
        i = tagEnd + 1;
      } else {
        depth--;
        i = close + 4;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  // ------------------------------------------------------------------ imágenes repetidas

  static final _brokenUse = RegExp(r'<use transform="[^"]*" xlink:href="#(bitmap\([^)"]*\))"\s*/>');
  static final _box = RegExp(r'<rect class="BoundingBox"[^>]*? x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"');
  static final _container = RegExp(r'<g id="container-id\d+">');

  static String _restoreBitmaps(String s, Uint8List pptx) {
    final defined = {for (final m in RegExp(r'id="(bitmap\([^)"]*\))"').allMatches(s)) m.group(1)};
    final broken = [for (final m in _brokenUse.allMatches(s)) if (!defined.contains(m.group(1))) m];
    if (broken.isEmpty) return s;

    final deck = _DeckPictures.read(pptx);
    if (deck == null) return s;
    final containers = [for (final m in _container.allMatches(s)) m.start];

    final out = StringBuffer();
    final ids = <String, String>{}; // imagen del .pptx → id en el SVG
    var at = 0;
    for (final m in broken) {
      final boxes = _box.allMatches(s.substring(0, m.start)).toList();
      if (boxes.isEmpty) continue;
      final b = boxes.last;
      final box = math.Rectangle<double>(
        double.parse(b.group(1)!),
        double.parse(b.group(2)!),
        double.parse(b.group(3)!),
        double.parse(b.group(4)!),
      );
      // Diapositiva visible en la que está (o -1: en un patrón)
      var slide = -1;
      for (var i = 0; i < containers.length && containers[i] < m.start; i++) {
        slide = i;
      }
      if (slide >= 0 && s.lastIndexOf('class="Master_Slide"', m.start) > containers[slide]) slide = -1;
      final pic = deck.match(slide, box);
      if (pic == null || deck.data(pic.media) == null) continue;
      final id = ids[pic.media] ??= 'zlide-bitmap-${ids.length}';
      out
        ..write(s.substring(at, m.start))
        ..write(pic.svg(id));
      at = m.end;
    }
    if (ids.isEmpty) return s;
    out.write(s.substring(at));
    final fixed = out.toString();

    // Las imágenes, una sola vez, de 1×1: cada uso las estira a su recuadro
    final defs = StringBuffer('<defs class="ZlideBitmaps">');
    for (final e in ids.entries) {
      final data = deck.data(e.key);
      if (data == null) continue;
      defs.write('<image id="${e.value}" x="0" y="0" width="1" height="1" preserveAspectRatio="none" '
          'xlink:href="data:${data.$1};base64,${base64.encode(data.$2)}"/>');
    }
    defs.write('</defs>');
    var where = fixed.indexOf('<g class="DummySlide"');
    if (where < 0) where = fixed.indexOf('<g class="SlideGroup"');
    if (where < 0) return s;
    return fixed.substring(0, where) + defs.toString() + fixed.substring(where);
  }
}

/// Una imagen en una diapositiva, en las unidades del SVG (centésimas de milímetro).
class _Picture {
  _Picture(this.media, this.rect, {this.rot = 0, this.flipH = false, this.flipV = false, this.crop = const [0, 0, 0, 0]});

  /// Ruta de la imagen dentro del .pptx.
  final String media;
  final math.Rectangle<double> rect;

  /// Grados, en el sentido de las manecillas.
  final double rot;
  final bool flipH, flipV;

  /// Recorte izquierda, arriba, derecha, abajo (fracciones de la imagen).
  final List<double> crop;

  /// Recuadro que ocupa ya girada (el que pone LibreOffice en `BoundingBox`).
  math.Rectangle<double> get bounds {
    if (rot % 180 == 0) return rect;
    final a = rot * math.pi / 180;
    final c = math.cos(a).abs(), s = math.sin(a).abs();
    final w = rect.width * c + rect.height * s, h = rect.width * s + rect.height * c;
    final cx = rect.left + rect.width / 2, cy = rect.top + rect.height / 2;
    return math.Rectangle(cx - w / 2, cy - h / 2, w, h);
  }

  String svg(String id) {
    String n(double v) => v.toStringAsFixed(v == v.roundToDouble() ? 0 : 4);
    final l = crop[0], t = crop[1], vw = 1 - crop[0] - crop[2], vh = 1 - crop[1] - crop[3];
    final img = '<svg x="${n(rect.left)}" y="${n(rect.top)}" width="${n(rect.width)}" height="${n(rect.height)}" '
        'viewBox="${n(l)} ${n(t)} ${n(vw)} ${n(vh)}" preserveAspectRatio="none" overflow="hidden">'
        '<use xlink:href="#$id"/></svg>';
    if (rot == 0 && !flipH && !flipV) return img;
    final cx = n(rect.left + rect.width / 2), cy = n(rect.top + rect.height / 2);
    return '<g transform="rotate(${n(rot)} $cx $cy) translate($cx $cy) '
        'scale(${flipH ? -1 : 1} ${flipV ? -1 : 1}) translate(-$cx -$cy)">$img</g>';
  }
}

/// Las imágenes de un .pptx u .odp: por diapositiva visible y las de los patrones y diseños.
class _DeckPictures {
  _DeckPictures(this._zip, this.slides, this.shared);

  final Archive _zip;
  final List<List<_Picture>> slides;
  final List<_Picture> shared;

  /// 1 unidad del SVG (centésima de milímetro) = 360 EMU.
  static const _emu = 360.0;

  static _DeckPictures? read(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);
    final pres = _xml(zip, 'ppt/presentation.xml');
    if (pres == null) return _odp(zip);
    final rels = _rels(zip, 'ppt/presentation.xml');
    final slides = <List<_Picture>>[];
    for (final e in pres.descendantElements.where((e) => e.name.local == 'sldId')) {
      final target = rels[_rid(e)];
      if (target == null) continue;
      final doc = _xml(zip, target);
      if (doc == null) continue;
      if (doc.rootElement.getAttribute('show') == '0') continue; // oculta: no está en el SVG
      slides.add(_pictures(zip, target, doc));
    }
    final shared = <_Picture>[];
    for (final f in zip.files) {
      final name = f.name;
      if (!RegExp(r'^ppt/(slideLayouts|slideMasters)/[^/]+\.xml$').hasMatch(name)) continue;
      final doc = _xml(zip, name);
      if (doc != null) shared.addAll(_pictures(zip, name, doc));
    }
    return _DeckPictures(zip, slides, shared);
  }

  // ------------------------------------------------------------------ .odp

  /// Las imágenes de un .odp. Sus medidas van en cm: 1 unidad del SVG = 1/1000 cm.
  static _DeckPictures? _odp(Archive zip) {
    final content = _xml(zip, 'content.xml');
    if (content == null) return null;
    final styles = _xml(zip, 'styles.xml');
    final docs = [if (styles != null) styles, content];
    final hidden = <String>{};
    for (final d in docs) {
      for (final st in d.descendantElements.where((e) => e.name.local == 'style')) {
        final props = st.childElements.where((e) => e.name.local == 'drawing-page-properties').firstOrNull;
        if (props?.getAttribute('presentation:visibility') == 'hidden') hidden.add(st.getAttribute('style:name') ?? '');
      }
    }
    final pres = content.descendantElements
        .where((e) => e.name.local == 'presentation' && e.parentElement?.name.local == 'body')
        .firstOrNull;
    if (pres == null) return null;
    final slides = [
      for (final page in pres.childElements.where((e) => e.name.local == 'page'))
        if (!hidden.contains(page.getAttribute('draw:style-name'))) _odpPictures(page),
    ];
    final shared = [
      for (final m in styles?.descendantElements.where((e) => e.name.local == 'master-page') ?? const <XmlElement>[])
        ..._odpPictures(m),
    ];
    return _DeckPictures(zip, slides, shared);
  }

  /// Imágenes de una página: `draw:frame` con `draw:image` (las posiciones son absolutas,
  /// también dentro de grupos).
  static List<_Picture> _odpPictures(XmlElement page) {
    final out = <_Picture>[];
    for (final img in page.descendantElements.where((e) => e.name.local == 'image')) {
      final frame = img.parentElement;
      var href = img.getAttribute('xlink:href');
      if (frame == null || frame.name.local != 'frame' || href == null || href.contains('://')) continue;
      if (href.startsWith('./')) href = href.substring(2);
      final w = _cm(frame.getAttribute('svg:width')), h = _cm(frame.getAttribute('svg:height'));
      if (w == null || h == null) continue;
      var x = _cm(frame.getAttribute('svg:x')) ?? 0, y = _cm(frame.getAttribute('svg:y')) ?? 0;
      var rot = 0.0;
      // "rotate (a) translate (x y)": a en radianes, en contra de las manecillas
      final tr = RegExp(r'rotate\s*\(\s*(-?[\d.e-]+)\s*\)\s*translate\s*\(\s*(\S+)\s+([^)\s]+)\s*\)')
          .firstMatch(frame.getAttribute('draw:transform') ?? '');
      if (tr != null) {
        final a = double.tryParse(tr.group(1)!) ?? 0;
        final tx = _cm(tr.group(2)) ?? 0, ty = _cm(tr.group(3)) ?? 0;
        // Centro de la figura ya girada; el recuadro sin girar va alrededor de él
        final cx = tx + w / 2 * math.cos(a) + h / 2 * math.sin(a);
        final cy = ty - w / 2 * math.sin(a) + h / 2 * math.cos(a);
        x = cx - w / 2;
        y = cy - h / 2;
        rot = -a * 180 / math.pi;
      }
      out.add(_Picture(href, math.Rectangle(x * 1000, y * 1000, w * 1000, h * 1000), rot: rot));
    }
    return out;
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

  // ------------------------------------------------------------------ búsqueda

  /// La imagen cuyo recuadro coincide con [box]: primero en la diapositiva [slide], luego en
  /// los patrones (ahí van los logotipos y fondos que se repiten).
  _Picture? match(int slide, math.Rectangle<double> box) {
    _Picture? best;
    var bestErr = double.infinity;
    for (final list in [if (slide >= 0 && slide < slides.length) slides[slide], shared]) {
      for (final p in list) {
        final r = p.bounds;
        final err = (r.left - box.left).abs() +
            (r.top - box.top).abs() +
            (r.width - box.width).abs() +
            (r.height - box.height).abs();
        if (err < bestErr) {
          bestErr = err;
          best = p;
        }
      }
      // Margen: redondeos y el grosor de un borde alrededor de la imagen. Más no: el recuadro
      // de una sombra difuminada (otro bitmap que LibreOffice tampoco define) es más grande
      // que la figura y no debe tomarse por ella.
      if (best != null && bestErr <= 40 + 0.01 * (box.width + box.height)) return best;
      best = null;
      bestErr = double.infinity;
    }
    return null;
  }

  /// (tipo, bytes) de la imagen [media], si el navegador la puede mostrar.
  (String, List<int>)? data(String media) {
    final f = _zip.findFile(media);
    if (f == null) return null;
    final ext = media.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' || 'jfif' => 'image/jpeg',
      'gif' => 'image/gif',
      'svg' => 'image/svg+xml',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      _ => null, // emf, wmf, tiff: el navegador no las muestra
    };
    return mime == null ? null : (mime, f.content as List<int>);
  }

  static List<_Picture> _pictures(Archive zip, String part, XmlDocument doc) {
    final rels = _rels(zip, part);
    final out = <_Picture>[];
    final tree = doc.descendantElements.where((e) => e.name.local == 'spTree').firstOrNull;
    if (tree != null) _walk(tree, rels, (x, y) => (x, y), (w, h) => (w, h), out);
    return out;
  }

  /// Recorre las figuras; [pos] y [size] pasan de las coordenadas del grupo a las de la página.
  static void _walk(
    XmlElement parent,
    Map<String, String> rels,
    (double, double) Function(double, double) pos,
    (double, double) Function(double, double) size,
    List<_Picture> out,
  ) {
    for (final e in parent.childElements) {
      switch (e.name.local) {
        case 'AlternateContent':
          // La primera opción (Choice) es la que lee LibreOffice
          final choice = e.childElements.firstOrNull;
          if (choice != null) _walk(choice, rels, pos, size, out);
        case 'grpSp':
          final x = _xfrm(e, 'grpSpPr');
          if (x == null) {
            _walk(e, rels, pos, size, out);
            continue;
          }
          final (off, ext, chOff, chExt) = (x.off, x.ext, x.chOff ?? x.off, x.chExt ?? x.ext);
          final kx = chExt.$1 == 0 ? 1.0 : ext.$1 / chExt.$1;
          final ky = chExt.$2 == 0 ? 1.0 : ext.$2 / chExt.$2;
          _walk(
            e,
            rels,
            (cx, cy) => pos(off.$1 + (cx - chOff.$1) * kx, off.$2 + (cy - chOff.$2) * ky),
            (w, h) => size(w * kx, h * ky),
            out,
          );
        // Una imagen, o una figura rellena con una imagen
        case 'pic' || 'sp':
          final fill = e.name.local == 'pic'
              ? e
              : e.childElements
                  .where((c) => c.name.local == 'spPr')
                  .expand((c) => c.childElements)
                  .where((c) => c.name.local == 'blipFill')
                  .firstOrNull;
          if (fill == null) continue;
          final blip = fill.descendantElements.where((b) => b.name.local == 'blip').firstOrNull;
          final media = blip == null ? null : rels[_attr(blip, 'embed')];
          final x = _xfrm(e, 'spPr');
          if (media == null || x == null) continue;
          final (px, py) = pos(x.off.$1, x.off.$2);
          final (pw, ph) = size(x.ext.$1, x.ext.$2);
          final src = fill.descendantElements.where((c) => c.name.local == 'srcRect').firstOrNull;
          double c(String k) => (double.tryParse(src?.getAttribute(k) ?? '') ?? 0) / 100000;
          out.add(_Picture(
            media,
            math.Rectangle(px / _emu, py / _emu, pw / _emu, ph / _emu),
            rot: x.rot,
            flipH: x.flipH,
            flipV: x.flipV,
            crop: [c('l'), c('t'), c('r'), c('b')],
          ));
      }
    }
  }

  static ({
    (double, double) off,
    (double, double) ext,
    (double, double)? chOff,
    (double, double)? chExt,
    double rot,
    bool flipH,
    bool flipV,
  })? _xfrm(XmlElement shape, String propsName) {
    final props = shape.childElements.where((c) => c.name.local == propsName).firstOrNull;
    final x = props?.childElements.where((c) => c.name.local == 'xfrm').firstOrNull;
    if (x == null) return null;
    (double, double)? pair(String name, String a, String b) {
      final c = x.childElements.where((c) => c.name.local == name).firstOrNull;
      if (c == null) return null;
      return (double.tryParse(c.getAttribute(a) ?? '') ?? 0, double.tryParse(c.getAttribute(b) ?? '') ?? 0);
    }

    final off = pair('off', 'x', 'y'), ext = pair('ext', 'cx', 'cy');
    if (off == null || ext == null) return null;
    return (
      off: off,
      ext: ext,
      chOff: pair('chOff', 'x', 'y'),
      chExt: pair('chExt', 'cx', 'cy'),
      rot: (double.tryParse(x.getAttribute('rot') ?? '') ?? 0) / 60000,
      flipH: x.getAttribute('flipH') == '1',
      flipV: x.getAttribute('flipV') == '1',
    );
  }

  static XmlDocument? _xml(Archive zip, String path) {
    final f = zip.findFile(path);
    if (f == null) return null;
    try {
      final data = f.content as List<int>;
      // Sin BOM
      final start = (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) ? 3 : 0;
      return XmlDocument.parse(const Utf8Decoder(allowMalformed: true).convert(data, start));
    } catch (_) {
      return null;
    }
  }

  /// Id → ruta dentro del .pptx de las relaciones de [part] (solo las internas).
  static Map<String, String> _rels(Archive zip, String part) {
    final slash = part.lastIndexOf('/');
    final dir = part.substring(0, slash);
    final doc = _xml(zip, '$dir/_rels/${part.substring(slash + 1)}.rels');
    if (doc == null) return const {};
    return {
      for (final e in doc.descendantElements.where((e) => e.name.local == 'Relationship'))
        if (e.getAttribute('TargetMode') != 'External')
          if (e.getAttribute('Id') case final id?)
            if (e.getAttribute('Target') case final target?) id: _resolve(dir, target),
    };
  }

  static String? _rid(XmlElement e) => _attr(e, 'id', prefixed: true);

  /// Atributo [local] con prefijo (`r:embed`, `r:id`).
  static String? _attr(XmlElement e, String local, {bool prefixed = true}) {
    for (final a in e.attributes) {
      if (a.name.local == local && (!prefixed || (a.name.prefix?.isNotEmpty ?? false))) return a.value;
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
}
