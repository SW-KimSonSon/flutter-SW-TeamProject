import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_assistant/services/local_llm_client.dart';
import 'package:study_assistant/services/material_terms_service.dart';

class FakeLlm implements LocalLlmClient {
  String? input;
  @override
  Future<LlmCompletion> complete({
    required String instructions,
    required String input,
  }) async {
    this.input = input;
    return const LlmCompletion(
      text: '1. CPU, CPU, 2. 스케줄링',
      model: 'qwen2.5:3b',
    );
  }
}

void main() {
  test('terms use the local client and deduplicate output', () async {
    final client = FakeLlm();
    final service = MaterialTermsService(
      client: client,
      maxInputCharacters: 6000,
    );
    expect(await service.extractText('CPU 스케줄링'), 'CPU, 스케줄링');
    expect(client.input, contains('CPU 스케줄링'));
  });
  test('empty input does not reach the model', () async {
    final client = FakeLlm();
    final service = MaterialTermsService(
      client: client,
      maxInputCharacters: 10,
    );
    await expectLater(service.extractText('  '), throwsException);
    expect(client.input, isNull);
  });
  test('long material is covered in order with bounded requests', () async {
    final client = StructuredStub();
    final service = MaterialTermsService(
      client: client,
      maxInputCharacters: 6000,
    );
    final original = List.generate(
      12,
      (i) => '페이지 ${i + 1} CPU 스케줄링 라운드 로빈 ${'본문 ' * 220}\n',
    ).join();
    await service.extractText(original);
    expect(client.inputs.length, greaterThan(1));
    expect(client.inputs.every((input) => input.length <= 6000), isTrue);
    expect(
      client.inputs.map((input) => input.replaceFirst('[강의자료]\n', '')).join(),
      original.trim(),
    );
    expect(service.usedLocalFallback, isFalse);
  });
  test(
    'output limit automatically splits and never uses partial output',
    () async {
      final client = StructuredStub(failAbove: 650);
      final service = MaterialTermsService(
        client: client,
        maxInputCharacters: 6000,
      );
      expect(await service.extractText('CPU 스케줄링 라운드 로빈 ' * 100), 'CPU, 스케줄링');
      expect(client.inputs.length, greaterThan(2));
      expect(service.usedLocalFallback, isFalse);
    },
  );
  test('persistent output failure has bounded source-word fallback', () async {
    final client = StructuredStub(failAbove: 0);
    final service = MaterialTermsService(
      client: client,
      maxInputCharacters: 6000,
    );
    final result = await service.extractText('CPU 스케줄링 ' * 120);
    expect(result, contains('CPU'));
    expect(result.length, lessThanOrEqualTo(120));
    expect(service.usedLocalFallback, isTrue);
    expect(client.inputs.length, lessThanOrEqualTo(7));
  });
  test(
    'malformed structured output is recovered without user settings',
    () async {
      final service = MaterialTermsService(
        client: StructuredStub(malformed: true),
        maxInputCharacters: 6000,
      );
      expect(await service.extractText('CPU 스케줄링'), contains('CPU'));
      expect(service.usedLocalFallback, isTrue);
    },
  );
  test(
    'connection errors propagate without retry or silent fallback',
    () async {
      final client = StructuredStub(unavailable: true);
      final service = MaterialTermsService(
        client: client,
        maxInputCharacters: 6000,
      );
      await expectLater(
        service.extractText('CPU 스케줄링 ' * 100),
        throwsA(isA<AiException>()),
      );
      expect(client.inputs.length, 1);
      expect(service.usedLocalFallback, isFalse);
    },
  );
  test('prompt terms are limited to 120 characters', () {
    expect(
      MaterialTermsService.cleanTerms('${'가' * 100}, ${'나' * 30}'),
      '가' * 100,
    );
  });
  test('DOCX text and PPTX numeric slide order are preserved', () async {
    final directory = await Directory.systemTemp.createTemp('material_test_');
    try {
      final client = FakeLlm();
      final service = MaterialTermsService(
        client: client,
        maxInputCharacters: 6000,
      );
      Future<void> archiveFile(String name, Map<String, String> entries) async {
        final archive = Archive();
        for (final entry in entries.entries) {
          final bytes = utf8.encode(entry.value);
          archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
        }
        await File(
          '${directory.path}/$name',
        ).writeAsBytes(ZipEncoder().encode(archive));
      }

      await archiveFile('test.docx', {
        'word/document.xml': '<w:p><w:t>CPU &amp; 메모리</w:t></w:p>',
      });
      await service.extract('${directory.path}/test.docx');
      expect(client.input, contains('CPU & 메모리'));
      await archiveFile('test.pptx', {
        'ppt/slides/slide10.xml': '<a:p><a:t>마지막</a:t></a:p>',
        'ppt/slides/slide2.xml': '<a:p><a:t>먼저</a:t></a:p>',
      });
      await service.extract('${directory.path}/test.pptx');
      expect(
        client.input!.indexOf('먼저'),
        lessThan(client.input!.indexOf('마지막')),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

class StructuredStub implements StructuredLlmClient {
  StructuredStub({
    this.failAbove,
    this.malformed = false,
    this.unavailable = false,
  });
  final int? failAbove;
  final bool malformed;
  final bool unavailable;
  final inputs = <String>[];
  @override
  Future<LlmCompletion> complete({
    required String instructions,
    required String input,
  }) => throw StateError('Expected schema');
  @override
  Future<LlmCompletion> completeStructured({
    required String instructions,
    required String input,
    required Map<String, dynamic> schema,
  }) async {
    inputs.add(input);
    expect(schema['type'], 'object');
    if (unavailable) throw const AiException(AiFailure.unavailable, 'offline');
    if (failAbove != null && input.length > failAbove!) {
      throw const AiOutputLimitException();
    }
    return LlmCompletion(
      text: malformed ? '{invalid' : '{"terms":["CPU","스케줄링"]}',
      model: 'qwen2.5:3b',
    );
  }
}
