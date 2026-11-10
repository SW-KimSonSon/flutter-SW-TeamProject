import 'package:flutter_test/flutter_test.dart';
import 'package:study_assistant/models/lecture_ai.dart';
import 'package:study_assistant/services/lecture_ai_service.dart';
import 'package:study_assistant/services/local_llm_client.dart';

class Recorder implements LocalLlmClient {
  final inputs = <String>[];
  final instructions = <String>[];
  @override
  Future<LlmCompletion> complete({
    required String instructions,
    required String input,
  }) async {
    inputs.add(input);
    this.instructions.add(instructions);
    return const LlmCompletion(text: '보조자료 근거', model: 'test');
  }
}

void main() {
  const caption = LectureContext(transcript: '강의 주제는 CPU 스케줄링이며 할당량은 10ms입니다.');
  test(
    'absent PDF leaves prompts, input and request count exactly unchanged',
    () async {
      final a = Recorder();
      final b = Recorder();
      final original = LectureAiService(client: a, maxInputCharacters: 6000);
      final explicit = LectureAiService(client: b, maxInputCharacters: 6000);
      await original.summarize(caption);
      await explicit.summarize(caption, materialText: '  ');
      await original.answerQuestion(caption, '할당량은?');
      await explicit.answerQuestion(caption, '할당량은?', materialText: '');
      expect(a.inputs, b.inputs);
      expect(a.instructions, b.instructions);
      expect(a.inputs.length, 2);
      expect(a.inputs.first, '[강의 자막]\n${caption.transcript}');
    },
  );
  test('PDF alone never replaces empty captions', () async {
    final client = Recorder();
    final ai = LectureAiService(client: client, maxInputCharacters: 6000);
    await expectLater(
      ai.summarize(
        const LectureContext(transcript: ''),
        materialText: 'PDF 본문',
      ),
      throwsA(isA<AiException>()),
    );
    await expectLater(
      ai.answerQuestion(
        const LectureContext(transcript: ''),
        '질문',
        materialText: 'PDF 본문',
      ),
      throwsA(isA<AiException>()),
    );
    expect(client.inputs, isEmpty);
  });
  test(
    'long PDF is read but final source and conflict priority remain captions',
    () async {
      final client = Recorder();
      final ai = LectureAiService(client: client, maxInputCharacters: 6000);
      final pdf = '${'할당량 99ms, 자료 설명. ' * 600}마지막페이지';
      final result = await ai.answerQuestion(
        caption,
        '할당량은?',
        materialText: pdf,
      );
      expect(
        client.inputs.where((i) => i.contains('[자료 구간')).length,
        greaterThan(1),
      );
      expect(client.inputs.any((i) => i.contains('마지막페이지')), isTrue);
      expect(client.inputs.last, startsWith('[강의 자막]\n${caption.transcript}'));
      expect(client.inputs.last, contains('[학생 질문]\n할당량은?'));
      expect(client.inputs.last, contains('[PDF 보조 참고자료'));
      expect(client.instructions.last, contains('충돌하면 자막을 우선'));
      expect(client.instructions.last, contains('보조자료에 따르면'));
      expect(client.inputs.every((i) => i.length <= 6000), isTrue);
      expect(result.source, same(caption));
    },
  );
  test(
    'reference never displaces captions at the existing input limit',
    () async {
      final client = Recorder();
      final ai = LectureAiService(client: client, maxInputCharacters: 6000);
      final text = '가' * 5900;
      await ai.summarize(
        LectureContext(transcript: text),
        materialText: '보조자료',
      );
      expect(client.inputs, ['[강의 자막]\n$text']);
    },
  );
}
