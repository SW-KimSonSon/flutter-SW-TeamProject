import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:study_assistant/services/pdf_text_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real Windows OCR reads a Korean and English image-only PDF',
    () async {
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
      await pdfrxFlutterInitialize();
      final document = await PdfDocument.createFromJpegData(
        await File('test/fixtures/scanned_lecture.jpg').readAsBytes(),
        width: 800,
        height: 260,
        sourceName: 'scanned-test',
      );
      try {
        expect(
          (await document.pages.single.loadText())?.fullText.trim() ?? '',
          isEmpty,
        );
        final text = await PdfTextReader.extract(await document.encodePdf());
        expect(text, contains('CPU'));
        expect(text, contains('스케줄링'));
        expect(text, contains('메모리'));
      } finally {
        await document.dispose();
      }
    },
    skip:
        !Platform.isWindows ||
            !File(
                  'build/windows/x64/runner/Release/study_ocr.exe',
                ).existsSync() &&
                !File(
                  'build/windows/x64/runner/Debug/study_ocr.exe',
                ).existsSync()
        ? 'Build the Windows app first to test the bundled OCR worker.'
        : false,
  );
}
