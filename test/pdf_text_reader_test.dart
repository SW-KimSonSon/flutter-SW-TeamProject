import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:study_assistant/services/pdf_text_reader.dart';
import 'package:study_assistant/services/material_terms_service.dart';
import 'package:study_assistant/services/windows_ocr.dart';
import 'fixtures/pdf_fixture.dart';
import 'material_terms_service_test.dart' show FakeLlm;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
  });

  test('bundled PDFium extracts Korean text in page order', () async {
    final text = await PdfTextReader.extract(textPdf(['CPU 스케줄링', '라운드 로빈']));
    expect(text, contains('CPU 스케줄링'));
    expect(text, contains('라운드 로빈'));
    expect(text.indexOf('CPU'), lessThan(text.indexOf('라운드')));
  });
  test('blank PDF is attempted with OCR before readable error', () async {
    await expectLater(
      PdfTextReader.extract(textPdf(['']), ocr: FakeOcr('')),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('자동 문자 인식'),
        ),
      ),
    );
  });
  test(
    'mixed text and image pages use OCR only where text is absent',
    () async {
      final ocr = FakeOcr('이미지 페이지의 강의 내용');
      final text = await PdfTextReader.extract(
        textPdf(['CPU 스케줄링', '', '마지막 페이지']),
        ocr: ocr,
      );
      expect(ocr.calls, 1);
      expect(text.indexOf('CPU'), lessThan(text.indexOf('이미지')));
      expect(text.indexOf('이미지'), lessThan(text.indexOf('마지막')));
    },
  );
  test('invalid PDF is rejected with a useful error', () async {
    await expectLater(
      PdfTextReader.extract(Uint8List.fromList([1, 2, 3])),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('PDF를 열 수 없습니다'),
        ),
      ),
    );
  });
  test('PDF file with Korean path feeds existing local terms flow', () async {
    final dir = await Directory.systemTemp.createTemp('pdf_test_');
    try {
      final file = File('${dir.path}/한글 강의자료.pdf');
      await file.writeAsBytes(textPdf(['CPU 스케줄링']));
      final client = FakeLlm();
      final service = MaterialTermsService(
        client: client,
        maxInputCharacters: 6000,
      );
      expect(await service.extract(file.path), 'CPU, 스케줄링');
      expect(client.input, contains('CPU 스케줄링'));
      // Document handles must have been released, allowing immediate removal.
      await file.delete();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}

class FakeOcr implements PageOcr {
  FakeOcr(this.text);
  final String text;
  int calls = 0;
  @override
  Future<String> recognize(Uint8List bgra, int width, int height) async {
    calls++;
    expect(bgra.length, width * height * 4);
    expect(width, lessThanOrEqualTo(2400));
    expect(height, lessThanOrEqualTo(2400));
    return text;
  }
}
