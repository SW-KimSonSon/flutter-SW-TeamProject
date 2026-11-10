import 'dart:convert';
import 'dart:typed_data';

/// Small PDF with a ToUnicode map so Korean extraction is tested without
/// relying on installed fonts or external PDF generation tools.
Uint8List textPdf(List<String> pages) {
  final chars = pages.join().runes.toSet().toList();
  final codes = {for (var i = 0; i < chars.length; i++) chars[i]: i + 1};
  String hex(int value) => value.toRadixString(16).padLeft(4, '0');
  final map =
      '''/CIDInit /ProcSet findresource begin
12 dict begin begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Test-UCS def /CMapType 2 def
1 begincodespacerange <0000> <FFFF> endcodespacerange
${chars.length} beginbfchar
${chars.map((c) => '<${hex(codes[c]!)}> <${hex(c)}>').join('\n')}
endbfchar endcmap CMapName currentdict /CMap defineresource pop end end''';
  String stream(String data) =>
      '<< /Length ${ascii.encode(data).length} >>\nstream\n$data\nendstream';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count ${pages.length} /Kids [${List.generate(pages.length, (i) => '${7 + i * 2} 0 R').join(' ')}] >>',
    '<< /Type /Font /Subtype /Type0 /BaseFont /TestFont /Encoding /Identity-H /DescendantFonts [4 0 R] /ToUnicode 6 0 R >>',
    '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestFont /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 5 0 R /DW 1000 >>',
    '<< /Type /FontDescriptor /FontName /TestFont /Flags 4 /FontBBox [0 -200 1000 1000] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>',
    stream(map),
    for (var i = 0; i < pages.length; i++) ...[
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 3 0 R >> >> /Contents ${8 + i * 2} 0 R >>',
      stream(
        pages[i].isEmpty
            ? ''
            : 'BT /F1 12 Tf 30 700 Td <${pages[i].runes.map((r) => hex(codes[r]!)).join()}> Tj ET',
      ),
    ],
  ];
  var pdf = '%PDF-1.4\n';
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(ascii.encode(pdf).length);
    pdf += '${i + 1} 0 obj\n${objects[i]}\nendobj\n';
  }
  final startXref = ascii.encode(pdf).length;
  pdf += 'xref\n0 ${objects.length + 1}\n0000000000 65535 f \n';
  for (final offset in offsets.skip(1)) {
    pdf += '${offset.toString().padLeft(10, '0')} 00000 n \n';
  }
  pdf +=
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$startXref\n%%EOF\n';
  return Uint8List.fromList(ascii.encode(pdf));
}
