import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:study_assistant/services/whisper_service.dart';

void main() {
  test(
    'repeated app sessions reuse a healthy existing Whisper server',
    () async {
      var probes = 0;
      for (var i = 0; i < 3; i++) {
        final service = WhisperService(
          clientFactory: () => MockClient((request) async {
            expect(request.url.path, '/health');
            expect(request.followRedirects, isFalse);
            probes++;
            return http.Response(
              '{"status":"ok"}',
              200,
              headers: {'server': 'whisper.cpp'},
            );
          }),
        );
        await service.start();
        await service.close();
        await service.close();
        await expectLater(service.start(), throwsStateError);
      }
      expect(probes, 3);
    },
  );
  test(
    'an existing loading Whisper server is awaited, not duplicated',
    () async {
      var probes = 0;
      final service = WhisperService(
        clientFactory: () => MockClient((_) async {
          probes++;
          return probes == 1
              ? http.Response(
                  '{"status":"loading model"}',
                  503,
                  headers: {'server': 'whisper.cpp'},
                )
              : http.Response(
                  '{"status":"ok"}',
                  200,
                  headers: {'server': 'whisper.cpp'},
                );
        }),
      );
      await service.start();
      expect(probes, 2);
      await service.close();
    },
  );
  test('unrelated or invalid healthy HTTP servers are never reused', () async {
    for (final response in [
      http.Response('{"status":"ok"}', 200),
      http.Response(
        '{"status":"wrong"}',
        200,
        headers: {'server': 'whisper.cpp'},
      ),
      http.Response(
        '',
        302,
        headers: {'server': 'whisper.cpp', 'location': 'http://example.com'},
      ),
    ]) {
      final service = WhisperService(
        clientFactory: () => MockClient((_) async => response),
      );
      await expectLater(service.start(), throwsStateError);
      await service.close();
    }
  });
  test('close during startup blocks late attachment to a server', () async {
    final response = Completer<http.Response>();
    final service = WhisperService(
      clientFactory: () => MockClient((_) => response.future),
    );
    final startup = service.start();
    final assertion = expectLater(startup, throwsStateError);
    final closing = service.close();
    response.complete(
      http.Response('{"status":"ok"}', 200, headers: {'server': 'whisper.cpp'}),
    );
    await assertion;
    await closing;
  });
  test(
    'local multipart request carries Korean prompt, WAV and cleared prompt',
    () async {
      final prompts = <String>[];
      final service = WhisperService(
        clientFactory: () => MockClient((request) async {
          expect(request.url.toString(), 'http://127.0.0.1:8080/inference');
          final body = utf8.decode(request.bodyBytes, allowMalformed: true);
          expect(body, contains('utterance.wav'));
          expect(body, contains('RIFF'));
          expect(body, contains('name="prompt"'));
          prompts.add(body);
          return http.Response.bytes(utf8.encode('{"text":"한국어 자막"}'), 200);
        }),
      );
      expect(await service.transcribe([0, 0], '스케줄링'), '한국어 자막');
      await service.transcribe([0, 0], '');
      expect(prompts.first, contains('스케줄링'));
      expect(prompts.last, isNot(contains('스케줄링')));
      service.dispose();
    },
  );
  test('HTTP failures and malformed responses are reported', () async {
    for (final response in [
      http.Response('error', 500),
      http.Response('{}', 200),
    ]) {
      final service = WhisperService(
        clientFactory: () => MockClient((_) async => response),
      );
      await expectLater(service.transcribe([0, 0], ''), throwsException);
      service.dispose();
    }
  });
  test('timeout covers the response body, not just HTTP headers', () async {
    final stream = StreamController<List<int>>();
    final service = WhisperService(
      requestTimeout: const Duration(milliseconds: 20),
      clientFactory: () => MockClient.streaming(
        (_, _) async => http.StreamedResponse(stream.stream, 200),
      ),
    );
    await expectLater(
      service.transcribe([0, 0], ''),
      throwsA(isA<TimeoutException>()),
    );
    await stream.close();
    service.dispose();
  });
  test('cancelled request ignores late successful response', () async {
    final response = Completer<http.Response>();
    final service = WhisperService(
      clientFactory: () => MockClient((_) => response.future),
    );
    final pending = service.transcribe([0, 0], '');
    service.cancelRequest();
    final assertion = expectLater(pending, throwsStateError);
    response.complete(http.Response('{"text":"stale"}', 200));
    await assertion;
    service.dispose();
  });
}
