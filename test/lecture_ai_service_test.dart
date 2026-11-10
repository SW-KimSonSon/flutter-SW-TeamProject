import 'package:flutter_test/flutter_test.dart';
import 'package:study_assistant/models/lecture_ai.dart';
import 'package:study_assistant/services/lecture_ai_service.dart';
import 'package:study_assistant/services/local_llm_client.dart';

void main() {
  late FakeLlm client;
  late LectureAiService service;
  final instant = DateTime.utc(2026, 10, 8);
  const source = LectureContext(
    transcript: 'CPU 스케줄링은 실행 순서를 결정한다.',
    lectureId: 'lecture-1',
  );
  setUp(() {
    client = FakeLlm();
    service = LectureAiService(
      client: client,
      maxInputCharacters: 100,
      clock: () => instant,
    );
  });
  test('summary carries provenance for future database and PKM use', () async {
    final result = await service.summarize(source);
    expect(result.kind, LectureAiKind.summary);
    expect(result.content, '답변');
    expect(result.source, same(source));
    expect(result.source.lectureId, 'lecture-1');
    expect(result.model, 'test-model');
    expect(result.createdAt, instant);
    expect(result.question, isNull);
    expect(client.instructions, contains('3~5줄'));
    expect(client.instructions, contains('키워드'));
    expect(client.input, contains(source.transcript));
  });
  test(
    'question preserves full input and separate grounding instructions',
    () async {
      final result = await service.answerQuestion(source, '무엇을 결정해?');
      expect(result.kind, LectureAiKind.answer);
      expect(result.question, '무엇을 결정해?');
      expect(client.input, contains(source.transcript));
      expect(client.input, contains('무엇을 결정해?'));
      expect(client.instructions, contains('자막에 없는 내용'));
      expect(client.instructions, contains('한국어'));
    },
  );
  test('empty transcript or question never invokes model', () async {
    const empty = LectureContext(transcript: '  ');
    await expectLater(service.summarize(empty), throwsA(isA<AiException>()));
    await expectLater(
      service.answerQuestion(empty, '질문'),
      throwsA(isA<AiException>()),
    );
    await expectLater(
      service.answerQuestion(source, ' '),
      throwsA(isA<AiException>()),
    );
    expect(client.calls, 0);
  });
  test(
    'oversized transcript or combined question is not silently truncated',
    () async {
      await expectLater(
        service.summarize(LectureContext(transcript: '가' * 101)),
        throwsA(
          isA<AiException>().having(
            (e) => e.kind,
            'kind',
            AiFailure.inputTooLong,
          ),
        ),
      );
      await expectLater(
        service.answerQuestion(source, '나' * 100),
        throwsA(isA<AiException>()),
      );
      expect(client.calls, 0);
    },
  );
  test(
    'failure stays an exception instead of becoming a saved answer',
    () async {
      client.error = const AiException(AiFailure.unavailable, '연결 실패');
      await expectLater(service.summarize(source), throwsA(same(client.error)));
    },
  );
}

class FakeLlm implements LocalLlmClient {
  int calls = 0;
  String? instructions;
  String? input;
  AiException? error;
  @override
  Future<LlmCompletion> complete({
    required String instructions,
    required String input,
  }) async {
    calls++;
    this.instructions = instructions;
    this.input = input;
    if (error != null) throw error!;
    return const LlmCompletion(text: '답변', model: 'test-model');
  }
}
