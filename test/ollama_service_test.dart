import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:study_assistant/config/ollama_config.dart';
import 'package:study_assistant/services/local_llm_client.dart';
import 'package:study_assistant/services/ollama_service.dart';

http.Response success() => http.Response.bytes(
  utf8.encode(
    jsonEncode({
      'model': 'qwen2.5:3b',
      'message': {'content': '한국어 요약'},
      'done': true,
    }),
  ),
  200,
);
Matcher failure(AiFailure kind) =>
    throwsA(isA<AiException>().having((e) => e.kind, 'kind', kind));
Future<LlmCompletion> ask(OllamaService service) =>
    service.complete(instructions: '한국어', input: '자막');

void main() {
  test('structured material requests retain existing token settings', () async {
    const schema = {'type': 'object'};
    final service = OllamaService(
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body);
        expect(body['format'], schema);
        expect(body['options']['num_predict'], 768);
        expect(body['options']['num_ctx'], 8192);
        return success();
      }),
    );
    addTearDown(service.dispose);
    await service.completeStructured(
      instructions: '용어',
      input: '자료',
      schema: schema,
    );
  });
  test('local non-streaming Qwen request and Korean UTF-8 response', () async {
    final service = OllamaService(
      clientFactory: () => MockClient((request) async {
        expect(request.url.toString(), 'http://localhost:11434/api/chat');
        expect(request.method, 'POST');
        expect(request.followRedirects, isFalse);
        expect(request.headers.containsKey('authorization'), isFalse);
        final body = jsonDecode(request.body);
        expect(body['model'], 'qwen2.5:3b');
        expect(body.containsKey('format'), isFalse);
        expect(body['stream'], isFalse);
        expect(body.containsKey('think'), isFalse);
        expect(body['messages'], [
          {'role': 'system', 'content': '한국어'},
          {'role': 'user', 'content': '자막'},
        ]);
        return success();
      }),
    );
    addTearDown(service.dispose);
    expect((await ask(service)).text, '한국어 요약');
  });

  test('model can be changed through configuration', () async {
    final service = OllamaService(
      config: const OllamaConfig(model: 'qwen2.5:7b'),
      clientFactory: () => MockClient((request) async {
        expect(jsonDecode(request.body)['model'], 'qwen2.5:7b');
        return success();
      }),
    );
    addTearDown(service.dispose);
    await ask(service);
  });

  for (final config in [
    const OllamaConfig(baseUrl: 'https://example.com'),
    const OllamaConfig(baseUrl: 'http://192.168.1.2:11434'),
    const OllamaConfig(baseUrl: 'http://localhost:11434?redirect=remote'),
    const OllamaConfig(model: 'qwen:cloud'),
  ]) {
    test(
      'rejects non-local configuration ${config.baseUrl} ${config.model}',
      () async {
        final service = OllamaService(
          config: config,
          clientFactory: () => throw StateError('Must not connect'),
        );
        addTearDown(service.dispose);
        await expectLater(ask(service), failure(AiFailure.configuration));
      },
    );
  }

  for (final entry in {
    404: AiFailure.modelMissing,
    500: AiFailure.server,
    302: AiFailure.server,
  }.entries) {
    test('HTTP ${entry.key} maps to actionable failure', () async {
      final service = OllamaService(
        clientFactory: () => MockClient(
          (_) async => http.Response('internal details', entry.key),
        ),
      );
      addTearDown(service.dispose);
      await expectLater(ask(service), failure(entry.value));
    });
  }

  for (final body in [
    'not json',
    '{}',
    '[]',
    '{"done":true,"message":{"content":""}}',
    '{"done":false,"message":{"content":"partial"}}',
    '{"done":true,"message":{"content":"partial"},"done_reason":"length"}',
  ]) {
    test('rejects invalid or incomplete output $body', () async {
      final service = OllamaService(
        clientFactory: () => MockClient((_) async => http.Response(body, 200)),
      );
      addTearDown(service.dispose);
      await expectLater(ask(service), failure(AiFailure.invalidResponse));
    });
  }

  test('connection failure is reported', () async {
    final service = OllamaService(
      clientFactory: () =>
          MockClient((_) async => throw const SocketException('refused')),
    );
    addTearDown(service.dispose);
    await expectLater(ask(service), failure(AiFailure.unavailable));
  });

  test('concurrent requests are rejected and busy state is released', () async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final service = OllamaService(
      clientFactory: () => MockClient((_) {
        calls++;
        return pending.future;
      }),
    );
    addTearDown(service.dispose);
    final first = ask(service);
    await expectLater(ask(service), failure(AiFailure.busy));
    pending.complete(success());
    await first;
    await ask(service);
    expect(calls, 2);
  });

  test('timeout closes client and a subsequent request succeeds', () async {
    final pending = Completer<http.Response>();
    final clients = <TrackingClient>[];
    final service = OllamaService(
      config: const OllamaConfig(requestTimeout: Duration(milliseconds: 20)),
      clientFactory: () {
        final isFirst = clients.isEmpty;
        final client = TrackingClient(
          MockClient((_) => isFirst ? pending.future : Future.value(success())),
        );
        clients.add(client);
        return client;
      },
    );
    addTearDown(service.dispose);
    await expectLater(ask(service), failure(AiFailure.timeout));
    expect(clients.first.closed, isTrue);
    expect((await ask(service)).text, '한국어 요약');
    pending.complete(success());
  });

  test('dispose closes connection and rejects late or new results', () async {
    final pending = Completer<http.Response>();
    final client = TrackingClient(MockClient((_) => pending.future));
    final service = OllamaService(clientFactory: () => client);
    final expectation = expectLater(ask(service), failure(AiFailure.disposed));
    service.dispose();
    expect(client.closed, isTrue);
    pending.complete(success());
    await expectation;
    await expectLater(ask(service), failure(AiFailure.disposed));
  });
}

class TrackingClient extends http.BaseClient {
  TrackingClient(this.inner);
  final http.Client inner;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
  @override
  void close() {
    closed = true;
    inner.close();
  }
}
