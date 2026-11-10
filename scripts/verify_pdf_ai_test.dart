import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:study_assistant/services/material_terms_service.dart';
import 'package:study_assistant/services/material_ai_service.dart';
import 'package:study_assistant/services/ollama_service.dart';
import 'package:study_assistant/services/lecture_ai_service.dart';
import 'package:study_assistant/models/lecture_ai.dart';
import '../test/fixtures/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'PDF extraction, long-document summary and grounded Q&A with real Qwen',
    () async {
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
      await pdfrxFlutterInitialize();
      final folder = await Directory(
        '.verification/pdf',
      ).create(recursive: true);
      const lecture =
          '운영체제는 CPU 스케줄링으로 프로세스 실행 순서를 정합니다. 라운드 로빈은 각 프로세스에 같은 시간 할당량을 줍니다. 메모리 관리는 주소 공간을 관리합니다.';
      final files = [
        File('${folder.path}/일반.pdf'),
        File('${folder.path}/긴자료.pdf'),
        File('${folder.path}/이미지.pdf'),
      ];
      await files[0].writeAsBytes(textPdf([lecture]));
      final pages = List.generate(12, (i) => '제${i + 1}장 $lecture ' * 7);
      pages[11] += ' 이 강의의 프로젝트 이름은 은하수이고 제출 마감은 12월 24일입니다.';
      await files[1].writeAsBytes(textPdf(pages));
      final scan = await PdfDocument.createFromJpegData(
        await File('test/fixtures/scanned_lecture.jpg').readAsBytes(),
        width: 800,
        height: 260,
        sourceName: 'scan',
      );
      try {
        expect(
          (await scan.pages.single.loadText())?.fullText.trim() ?? '',
          isEmpty,
        );
        await files[2].writeAsBytes(await scan.encodePdf());
      } finally {
        await scan.dispose();
      }
      final client = OllamaService();
      final log = StringBuffer();
      try {
        final reader = MaterialTermsService(
          client: client,
          maxInputCharacters: 6000,
        );
        final ai = MaterialAiService(client: client, maxInputCharacters: 6000);
        for (var i = 0; i < files.length; i++) {
          final text = await reader.readText(files[i].path);
          if (i == 1) expect(text.length, greaterThan(6000));
          if (i == 2) expect(text, contains('메모리'));
          final terms = await reader.extractText(text);
          expect(terms, isNotEmpty);
          final summary = await ai.analyze(
            text: text,
            name: files[i].path,
            onProgress: stdout.writeln,
          );
          final question = i == 1
              ? '프로젝트 이름과 제출 마감은 무엇인가요?'
              : '자료에서 설명하는 CPU 스케줄링과 관련된 용어는 무엇인가요?';
          final answer = await ai.analyze(
            text: text,
            name: files[i].path,
            question: question,
            onProgress: stdout.writeln,
          );
          expect(summary.content, contains(RegExp('[가-힣]')));
          expect(answer.content, isNotEmpty);
          if (i == 1) {
            expect(answer.content, contains('은하수'));
            expect(answer.content, contains('24'));
          }
          final result =
              '${files[i].path}: ${text.length} chars\nTERMS: $terms\nSUMMARY: ${summary.content}\nANSWER: ${answer.content}';
          stdout.writeln(result);
          log.writeln(result);
        }
        final captions = LectureAiService(
          client: client,
          maxInputCharacters: 6000,
        );
        final summary = await captions.summarize(
          const LectureContext(transcript: lecture),
        );
        final answer = await captions.answerQuestion(
          const LectureContext(transcript: lecture),
          '라운드 로빈의 시간 배분은?',
        );
        expect(summary.content, isNotEmpty);
        expect(answer.content, contains('시간'));
        log.writeln(
          'CAPTION SUMMARY: ${summary.content}\nCAPTION ANSWER: ${answer.content}',
        );
      } finally {
        client.dispose();
        await File('${folder.path}/results.txt').writeAsString(log.toString());
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
