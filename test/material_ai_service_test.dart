import 'package:flutter_test/flutter_test.dart';
import 'package:study_assistant/services/local_llm_client.dart';
import 'package:study_assistant/services/material_ai_service.dart';

class Stub implements LocalLlmClient {
  final inputs = <String>[];
  bool oversized = false;
  @override
  Future<LlmCompletion> complete({
    required String instructions,
    required String input,
  }) async {
    inputs.add(input);
    return LlmCompletion(
      text: oversized ? '내용' * 900 : 'CPU와 마지막 페이지 근거',
      model: 'test',
    );
  }
}

void main() {
  test('long material covers every character and merges every chunk', () async {
    final client = Stub();
    final text = '${'자료 내용 CPU 😀 ' * 700}마지막페이지 비밀숫자 42';
    final result = await MaterialAiService(
      client: client,
      maxInputCharacters: 6000,
    ).analyze(text: text, name: 'lecture.pdf');
    final maps = client.inputs.where((i) => i.startsWith('[자료 구간')).toList();
    expect(maps.length, greaterThan(1));
    expect(maps.map((i) => i.substring(i.indexOf('\n') + 1)).join(), text);
    expect(client.inputs.every((i) => i.length <= 6000), isTrue);
    expect(client.inputs.last, contains('전체 자료의 구간별 분석'));
    expect(result.source.transcript, text);
    expect(result.source.lectureId, 'lecture.pdf');
  });
  test('question is included for every chunk and final answer', () async {
    final client = Stub();
    await MaterialAiService(
      client: client,
      maxInputCharacters: 6000,
    ).analyze(text: '본문 ' * 1400, name: 'scan.pdf', question: '메모리는?');
    expect(client.inputs.length, greaterThan(2));
    expect(client.inputs.every((i) => i.contains('메모리는?')), isTrue);
  });
  test('empty text and excessive question fail without model calls', () async {
    final client = Stub();
    final service = MaterialAiService(client: client, maxInputCharacters: 6000);
    await expectLater(
      service.analyze(text: '', name: ''),
      throwsA(isA<AiException>()),
    );
    await expectLater(
      service.analyze(text: '본문', name: '', question: '질문' * 4000),
      throwsA(isA<AiException>()),
    );
    expect(client.inputs, isEmpty);
  });
  test(
    'non shrinking reductions stop instead of looping or truncating',
    () async {
      final client = Stub()..oversized = true;
      await expectLater(
        MaterialAiService(
          client: client,
          maxInputCharacters: 6000,
        ).analyze(text: '본문 ' * 1200, name: 'long.pdf'),
        throwsA(isA<AiException>()),
      );
      expect(client.inputs.length, lessThan(15));
    },
  );
}
