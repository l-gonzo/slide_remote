import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'i18n.dart';

/// Idioma de los mensajes de error dentro del isolate (ahí no llega el estado de [I18n]).
bool _es = false;
String _t(String es, String en) => _es ? es : en;

/// Una diapositiva tal como se ve en la presentación (las ocultas se omiten).
class SlideInfo {
  const SlideInfo({required this.number, required this.title, required this.notes, required this.clicks});

  /// Número de diapositiva en el archivo (1 = primera, contando las ocultas).
  final int number;
  final String title;
  final String notes;

  /// Clics de animación antes de pasar a la siguiente diapositiva.
  final int clicks;

  Map<String, Object> toJson() => {'n': number, 't': title, 'notes': notes, 'c': clicks};

  static SlideInfo fromJson(Map<String, Object?> j) => SlideInfo(
        number: (j['n'] as num?)?.toInt() ?? 0,
        title: (j['t'] as String?) ?? '',
        notes: (j['notes'] as String?) ?? '',
        clicks: (j['c'] as num?)?.toInt() ?? 0,
      );
}

/// Resultado de leer un .pptx.
class PptxDeck {
  const PptxDeck({required this.slides, required this.total, this.aspect});

  /// Diapositivas visibles, en orden.
  final List<SlideInfo> slides;

  /// Total de diapositivas en el archivo, contando las ocultas.
  final int total;

  /// Ancho / alto de las diapositivas (p. ej. 1.777 para 16:9), si viene en el archivo.
  final double? aspect;

  Map<String, Object?> toJson() => {
        'total': total,
        'aspect': aspect,
        'slides': [for (final s in slides) s.toJson()],
      };

  static PptxDeck fromJson(Map<String, Object?> j) => PptxDeck(
        total: (j['total'] as num?)?.toInt() ?? 0,
        aspect: (j['aspect'] as num?)?.toDouble(),
        slides: [
          for (final s in (j['slides'] as List<Object?>? ?? const []))
            if (s is Map) SlideInfo.fromJson(Map<String, Object?>.from(s)),
        ],
      );
}

/// Extensiones cuyas notas se leen directamente (sin convertir):
/// formato de PowerPoint/OnlyOffice/WPS (OOXML) y de LibreOffice/OpenOffice (OpenDocument).
const kNotesExtensions = [
  'pptx', 'pptm', 'ppsx', 'ppsm', 'potx', 'potm', // OOXML
  'odp', 'otp', 'fodp', // OpenDocument
];

/// Lee títulos, notas del presentador y número de animaciones de una presentación.
/// No necesita convertir nada: .pptx y .odp son ZIP con archivos XML (.fodp es un XML).
/// El formato se detecta por el contenido, no por la extensión.
abstract final class PptxNotes {
  /// Se ejecuta en otro isolate para no trabar la interfaz con archivos grandes.
  static Future<PptxDeck> parse(Uint8List bytes) {
    final es = I18n.es;
    return Isolate.run(() {
      _es = es;
      return parseSync(bytes);
    });
  }

  static PptxDeck parseSync(Uint8List bytes) {
    // OpenDocument plano (.fodp): XML sin comprimir
    var i = 0;
    while (i < bytes.length && i < 8 && (bytes[i] == 0xEF || bytes[i] == 0xBB || bytes[i] == 0xBF ||
        bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09)) {
      i++;
    }
    if (i < bytes.length && bytes[i] == 0x3C /* < */) {
      return OdpNotes.parseDocs(XmlDocument.parse(_utf8(bytes)), null);
    }
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      throw FormatException(_t(
          'Este formato no se puede leer directo. Guárdala como .pptx u .odp (PowerPoint o LibreOffice).',
          'This format can’t be read directly. Save it as .pptx or .odp (PowerPoint or LibreOffice).'));
    }
    final zip = ZipDecoder().decodeBytes(bytes);
    if (zip.findFile('ppt/presentation.xml') == null && zip.findFile('content.xml') != null) {
      return OdpNotes.parseZip(zip);
    }

    XmlDocument? doc(String path) {
      final f = zip.findFile(path);
      if (f == null) return null;
      try {
        // `content` existe en archive 3 (List<int>) y 4 (Uint8List)
        final data = Uint8List.fromList(f.content as List<int>);
        return XmlDocument.parse(_utf8(data));
      } catch (_) {
        return null;
      }
    }

    final presentation = doc('ppt/presentation.xml');
    if (presentation == null) {
      throw FormatException(_t('El archivo no parece una presentación (.pptx u .odp).', 'The file doesn’t look like a presentation (.pptx or .odp).'));
    }
    final presRels = _rels(doc('ppt/_rels/presentation.xml.rels'));

    // Orden real de las diapositivas: <p:sldIdLst><p:sldId r:id="rId2"/>…
    final slidePaths = <String>[];
    for (final e in presentation.descendantElements) {
      if (e.name.local != 'sldId') continue;
      final rid = _relId(e);
      final target = rid == null ? null : presRels[rid]?.target;
      if (target != null) slidePaths.add(_resolve('ppt/', target));
    }

    // Tamaño de diapositiva: <p:sldSz cx="12192000" cy="6858000"/>
    double? aspect;
    for (final e in presentation.descendantElements) {
      if (e.name.local != 'sldSz') continue;
      final cx = double.tryParse(e.getAttribute('cx') ?? '');
      final cy = double.tryParse(e.getAttribute('cy') ?? '');
      if (cx != null && cy != null && cy > 0) aspect = cx / cy;
      break;
    }

    final out = <SlideInfo>[];
    for (var i = 0; i < slidePaths.length; i++) {
      final path = slidePaths[i];
      final slide = doc(path);
      if (slide == null) continue;
      // Diapositivas ocultas: no aparecen al presentar
      if (slide.rootElement.getAttribute('show') == '0') continue;

      final slideRels = _rels(doc(_relsPathFor(path)));
      String notes = '';
      for (final r in slideRels.values) {
        if (r.type.endsWith('/notesSlide')) {
          final notesDoc = doc(_resolve(_dirOf(path), r.target));
          if (notesDoc != null) notes = _notesText(notesDoc);
          break;
        }
      }
      out.add(SlideInfo(
        number: i + 1,
        title: _title(slide),
        notes: notes,
        clicks: _clickCount(slide),
      ));
    }
    return PptxDeck(slides: out, total: slidePaths.length, aspect: aspect);
  }

  // ------------------------------------------------------------------ texto

  /// Texto del marcador de notas (type="body") del notesSlide, por párrafos.
  static String _notesText(XmlDocument notes) {
    for (final sp in notes.descendantElements.where((e) => e.name.local == 'sp')) {
      final type = _placeholderType(sp);
      if (type == 'body') return _paragraphs(sp);
    }
    return '';
  }

  static String _title(XmlDocument slide) {
    for (final sp in slide.descendantElements.where((e) => e.name.local == 'sp')) {
      final type = _placeholderType(sp);
      if (type == 'title' || type == 'ctrTitle') {
        return _paragraphs(sp).replaceAll('\n', ' ').trim();
      }
    }
    return '';
  }

  static String? _placeholderType(XmlElement sp) {
    for (final e in sp.descendantElements) {
      if (e.name.local == 'ph') return e.getAttribute('type') ?? 'body';
      if (e.name.local == 'txBody') break; // el marcador va antes del texto
    }
    return null;
  }

  static String _paragraphs(XmlElement sp) {
    final lines = <String>[];
    for (final p in sp.descendantElements.where((e) => e.name.local == 'p')) {
      final buf = StringBuffer();
      for (final e in p.descendantElements) {
        if (e.name.local == 't') buf.write(e.innerText);
        if (e.name.local == 'br') buf.write('\n');
      }
      lines.add(buf.toString());
    }
    // Quitar líneas vacías al inicio y al final, conservar las intermedias
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  // ------------------------------------------------------------------ animaciones

  /// Cuenta los pasos "al hacer clic" de la secuencia principal de animaciones.
  /// Estructura: `<p:cTn nodeType="mainSeq"><p:childTnLst><p:par>…</p:par>…` — cada `<p:par>`
  /// hijo es un paso; es un clic si su primer efecto tiene nodeType="clickEffect".
  static int _clickCount(XmlDocument slide) {
    for (final ctn in slide.descendantElements) {
      if (ctn.name.local != 'cTn' || ctn.getAttribute('nodeType') != 'mainSeq') continue;
      final list = ctn.childElements.where((e) => e.name.local == 'childTnLst').firstOrNull;
      if (list == null) return 0;
      var clicks = 0;
      for (final step in list.childElements.where((e) => e.name.local == 'par')) {
        final first = step.descendantElements
            .where((e) => e.name.local == 'cTn' && e.getAttribute('nodeType') != null)
            .firstOrNull;
        if (first?.getAttribute('nodeType') == 'clickEffect') clicks++;
      }
      return clicks;
    }
    return 0;
  }

  // ------------------------------------------------------------------ relaciones

  static Map<String, _Rel> _rels(XmlDocument? d) {
    final out = <String, _Rel>{};
    if (d == null) return out;
    for (final e in d.descendantElements.where((e) => e.name.local == 'Relationship')) {
      final id = e.getAttribute('Id');
      final target = e.getAttribute('Target');
      if (id != null && target != null) out[id] = _Rel(e.getAttribute('Type') ?? '', target);
    }
    return out;
  }

  /// El atributo r:id (el prefijo puede variar; se busca "id" con prefijo).
  static String? _relId(XmlElement e) {
    for (final a in e.attributes) {
      if (a.name.local == 'id' && a.name.prefix != null && a.name.prefix!.isNotEmpty) return a.value;
    }
    return null;
  }

  static String _dirOf(String path) => path.substring(0, path.lastIndexOf('/') + 1);

  static String _relsPathFor(String path) {
    final dir = _dirOf(path);
    return '${dir}_rels/${path.substring(dir.length)}.rels';
  }

  /// Resuelve "slides/slide1.xml" o "../notesSlides/notesSlide1.xml" contra una carpeta.
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

  /// Texto UTF-8 de un XML del archivo (sin BOM).
  static String decodeUtf8(Uint8List data) => _utf8(data);

  static String _utf8(Uint8List data) {
    // Quitar BOM si lo hay
    final start = (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) ? 3 : 0;
    return const Utf8Decoder(allowMalformed: true).convert(data, start);
  }
}

class _Rel {
  const _Rel(this.type, this.target);
  final String type;
  final String target;
}


/// Presentaciones OpenDocument (.odp de LibreOffice/OpenOffice, también las que exporta OnlyOffice).
///
///     content.xml
///       office:automatic-styles / style:style[family=drawing-page]
///           style:drawing-page-properties presentation:visibility="hidden"   ← oculta
///       office:body / office:presentation / draw:page
///           draw:frame presentation:class="title" / draw:text-box / text:p   ← título
///           anim:par[node-type=timing-root] / anim:seq[node-type=main-sequence] / anim:par…
///           presentation:notes / draw:frame[class=notes] / draw:text-box / text:p   ← notas
abstract final class OdpNotes {
  static XmlDocument? _doc(Archive zip, String path) {
    final f = zip.findFile(path);
    if (f == null) return null;
    try {
      return XmlDocument.parse(PptxNotes._utf8(Uint8List.fromList(f.content as List<int>)));
    } catch (_) {
      return null;
    }
  }

  static PptxDeck parseZip(Archive zip) {
    final content = _doc(zip, 'content.xml');
    if (content == null) throw FormatException(_t('El archivo .odp está dañado (falta content.xml).', 'The .odp file is damaged (content.xml is missing).'));
    return parseDocs(content, _doc(zip, 'styles.xml'));
  }

  /// [content] es content.xml (o el .fodp completo); [styles] es styles.xml si existe.
  static PptxDeck parseDocs(XmlDocument content, XmlDocument? styles) {
    final pres = content.descendantElements.where((e) => e.name.local == 'presentation' &&
        e.parentElement?.name.local == 'body').firstOrNull;
    if (pres == null) throw FormatException(_t('El archivo no parece una presentación (.odp).', 'The file doesn’t look like a presentation (.odp).'));

    // Estilos de página ocultos (pueden estar en content.xml o en styles.xml)
    final hiddenStyles = <String>{};
    for (final d in [content, if (styles != null) styles]) {
      for (final st in d.descendantElements.where((e) => e.name.local == 'style')) {
        if (_attr(st, 'family') != 'drawing-page') continue;
        final props = st.childElements.where((e) => e.name.local == 'drawing-page-properties').firstOrNull;
        if (props != null && _attr(props, 'visibility') == 'hidden') {
          final n = _attr(st, 'name');
          if (n != null) hiddenStyles.add(n);
        }
      }
    }

    final pages = pres.childElements.where((e) => e.name.local == 'page').toList();
    final out = <SlideInfo>[];
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      if (hiddenStyles.contains(_attr(page, 'style-name'))) continue;
      String title = '';
      String notes = '';
      for (final child in page.childElements) {
        final local = child.name.local;
        if (local == 'frame' && title.isEmpty && _attr(child, 'class') == 'title') {
          title = _paragraphs(child).replaceAll('\n', ' ').trim();
        } else if (local == 'notes') {
          for (final f in child.descendantElements.where((e) => e.name.local == 'frame')) {
            if (_attr(f, 'class') == 'notes') {
              notes = _paragraphs(f);
              break;
            }
          }
        }
      }
      out.add(SlideInfo(number: i + 1, title: title, notes: notes, clicks: _clickCount(page)));
    }
    return PptxDeck(slides: out, total: pages.length, aspect: _aspect(content, styles));
  }

  /// Igual que en .pptx: cada paso de la secuencia principal cuyo primer efecto es "al hacer clic".
  static int _clickCount(XmlElement page) {
    for (final seq in page.descendantElements) {
      if (seq.name.local != 'seq' || _attr(seq, 'node-type') != 'main-sequence') continue;
      var clicks = 0;
      for (final step in seq.childElements.where((e) => e.name.local == 'par')) {
        final first = step.descendantElements
            .where((e) => e.name.local == 'par' && _attr(e, 'node-type') != null)
            .firstOrNull;
        if (_attr(first, 'node-type') == 'on-click') clicks++;
      }
      return clicks;
    }
    return 0;
  }

  /// Proporción de la diapositiva: page-layout de la primera página maestra.
  static double? _aspect(XmlDocument content, XmlDocument? styles) {
    final docs = [if (styles != null) styles, content];
    String? layoutName;
    for (final d in docs) {
      final mp = d.descendantElements.where((e) => e.name.local == 'master-page').firstOrNull;
      layoutName = _attr(mp, 'page-layout-name');
      if (layoutName != null) break;
    }
    for (final d in docs) {
      for (final pl in d.descendantElements.where((e) => e.name.local == 'page-layout')) {
        if (layoutName != null && _attr(pl, 'name') != layoutName) continue;
        final props = pl.childElements.where((e) => e.name.local == 'page-layout-properties').firstOrNull;
        final w = _length(_attr(props, 'page-width'));
        final h = _length(_attr(props, 'page-height'));
        if (w != null && h != null && h > 0) return w / h;
      }
    }
    return null;
  }

  static double? _length(String? v) => v == null ? null : double.tryParse(v.replaceAll(RegExp(r'[a-z%]+$'), ''));

  /// Texto de un marco: cada text:p / text:h es una línea (las listas también usan text:p).
  static String _paragraphs(XmlElement frame) {
    final lines = <String>[];
    for (final p in frame.descendantElements.where((e) => e.name.local == 'p' || e.name.local == 'h')) {
      final buf = StringBuffer();
      _inline(p, buf);
      lines.add(buf.toString());
    }
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  static void _inline(XmlNode node, StringBuffer buf) {
    for (final n in node.children) {
      if (n is XmlText || n is XmlCDATA) {
        buf.write(n.value);
      } else if (n is XmlElement) {
        switch (n.name.local) {
          case 's':
            buf.write(' ' * (int.tryParse(_attr(n, 'c') ?? '') ?? 1));
          case 'tab':
            buf.write('\t');
          case 'line-break':
            buf.write('\n');
          case 'note' || 'annotation':
            break; // notas al pie / comentarios: no son parte del texto
          default:
            _inline(n, buf);
        }
      }
    }
  }

  /// Atributo por nombre local, sin importar el prefijo (presentation:, draw:, style:…).
  static String? _attr(XmlElement? e, String local) {
    if (e == null) return null;
    for (final a in e.attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }
}
