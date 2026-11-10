import 'dart:typed_data';
import 'dart:math';

import 'package:pdfrx/pdfrx.dart';
import 'windows_ocr.dart';

/// Uses bundled PDFium and, for image pages, the bundled Windows OCR worker.
/// No PATH lookup, document upload, or runtime engine download is needed.
class PdfTextReader {
  static Future<String> extract(
    Uint8List bytes, {
    PageOcr ocr = const WindowsOcr(),
    void Function(String)? onProgress,
  }) async {
    await pdfrxFlutterInitialize();
    PdfDocument document;
    try {
      // Memory input also avoids native-library problems with Korean file paths.
      document = await PdfDocument.openData(bytes);
    } catch (_) {
      throw const FormatException(
        'PDF를 열 수 없습니다. 파일이 손상되었거나 암호로 보호되어 있는지 확인해 주세요.',
      );
    }
    try {
      final pages = <String>[];
      for (final page in document.pages) {
        var text = ((await page.loadText())?.fullText ?? '').trim();
        onProgress?.call(
          'PDF ${page.pageNumber}/${document.pages.length}페이지 읽는 중',
        );
        if (text.isEmpty) {
          onProgress?.call(
            'PDF ${page.pageNumber}/${document.pages.length}페이지 자동 문자 인식 중',
          );
          final scale = min(200 / 72, 2400 / max(page.width, page.height));
          final rendered = await page.render(
            width: (page.width * scale).ceil(),
            height: (page.height * scale).ceil(),
          );
          if (rendered == null) {
            throw const FormatException('PDF 페이지 이미지를 읽지 못했습니다.');
          }
          try {
            text = await ocr.recognize(
              rendered.pixels,
              rendered.width,
              rendered.height,
            );
          } finally {
            rendered.dispose();
          }
        }
        pages.add(text);
      }
      final text = pages.join('\n\n').trim();
      if (text.isEmpty) {
        throw const FormatException(
          '자동 문자 인식 후에도 PDF에서 글자를 찾지 못했습니다. 빈 페이지이거나 이미지가 흐린지 확인해 주세요.',
        );
      }
      return text;
    } finally {
      await document.dispose();
    }
  }
}
