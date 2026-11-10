import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:study_assistant/models/lecture_ai.dart';
import 'package:study_assistant/services/lecture_ai_service.dart';
import 'package:study_assistant/services/material_terms_service.dart';
import 'package:study_assistant/services/ollama_service.dart';
import '../test/fixtures/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'real caption AI with and without normal, long and OCR PDF references',
    () async {
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
      await pdfrxFlutterInitialize();
      await Directory('.verification/pdf').create(recursive: true);
      const body =
          'CPU 스케줄링에서 라운드 로빈은 각 프로세스에 같은 시간 할당량을 주며 메모리 관리는 주소 공간을 관리합니다.';
      await File('.verification/pdf/일반.pdf').writeAsBytes(textPdf([body]));
      await File('.verification/pdf/긴자료.pdf').writeAsBytes(
        textPdf(List.generate(12, (i) => '제${i + 1}장 $body ' * 12)),
      );
      final scan = await PdfDocument.createFromJpegData(
        await File('test/fixtures/scanned_lecture.jpg').readAsBytes(),
        width: 800,
        height: 260,
        sourceName: 'reference-test',
      );
      try {
        await File(
          '.verification/pdf/이미지.pdf',
        ).writeAsBytes(await scan.encodePdf());
      } finally {
        await scan.dispose();
      }
      final client = OllamaService();
      final ai = LectureAiService(client: client, maxInputCharacters: 6000);
      final reader = MaterialTermsService(
        client: client,
        maxInputCharacters: 6000,
      );
      const source = LectureContext(
        transcript: '오늘 강의의 주제는 CPU 스케줄링입니다. 라운드 로빈에서 이번 강의의 시간 할당량은 10밀리초입니다.',
      );
      final log = StringBuffer();
      try {
        for (final name in ['', '일반', '긴자료', '이미지']) {
          final pdf = name.isEmpty
              ? ''
              : await reader.readText('.verification/pdf/$name.pdf');
          if (name.isNotEmpty) expect(pdf.trim(), isNotEmpty);
          final summary = await ai.summarize(source, materialText: pdf);
          final answer = await ai.answerQuestion(
            source,
            '이번 강의의 시간 할당량은 몇 밀리초인가요?',
            materialText: pdf,
          );
          expect(summary.content, contains('CPU'));
          expect(answer.content, contains('10'));
          expect(answer.source, same(source));
          log.writeln(
            '$name SUMMARY: ${summary.content}\nANSWER: ${answer.content}',
          );
          stdout.writeln('${name.isEmpty ? "자막 단독" : name}: 요약·질문 검증 통과');
        }
        final conflict = await ai.answerQuestion(
          source,
          '이번 강의의 시간 할당량은?',
          materialText: 'PDF 예제의 시간 할당량은 99밀리초입니다.',
        );
        expect(conflict.content, contains('10'));
        log.writeln('CONFLICT: ${conflict.content}');
        final supplement = await ai.answerQuestion(
          source,
          '이번 강의의 시간 할당량은 얼마이며 보조자료의 CPU 스케줄링 실습 이름은 무엇인가요?',
          materialText: 'CPU 스케줄링 실습 이름은 은하수 실습입니다. 이 실습에서 프로세스의 실행 순서를 관찰합니다.',
        );
        expect(supplement.content, contains('10'));
        expect(supplement.content, contains('은하수'));
        expect(supplement.content, contains('보조자료'));
        log.writeln('SUPPLEMENT: ${supplement.content}');
        stdout.writeln(log.toString());
      } finally {
        client.dispose();
        await File(
          '.verification/pdf/caption-reference-results.txt',
        ).writeAsString(log.toString());
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
