import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Una diapositiva tal como se ve en la presentación (las ocultas se omiten).
class SlideInfo {
  const SlideInfo({required this.number, required this.title, required this.notes, required this.clicks});

  /// Número de diapositiva en el archivo (1 = primera, contando las ocultas).
  final int number;
  final String title;
  final String notes;

  /// Clics de animación antes de pasar a la siguiente diapositiva.
  final int clicks;
}

/// Lee títulos, notas del presentador y número de animaciones de un .pptx.
/// No necesita convertir nada: un .pptx es un ZIP con archivos XML.
abstract final class PptxNotes {
  /// Se ejecuta en otro isolate para no trabar la interfaz con archivos grandes.
  static Future<List<SlideInfo>> parse(Uint8List bytes) => Isolate.run(() => parseSync(bytes));

  static List<SlideInfo> parseSync(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);

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
      throw const FormatException('El archivo no parece una presentación de PowerPoint (.pptx).');
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
    return out;
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
  /// Estructura: <p:cTn nodeType="mainSeq"><p:childTnLst><p:par>…</p:par>… — cada <p:par>
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
