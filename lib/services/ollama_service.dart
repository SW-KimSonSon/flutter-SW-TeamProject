import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../config/ollama_config.dart';
import 'local_llm_client.dart';

class OllamaService implements StructuredLlmClient {
  OllamaService({
    this.config = const OllamaConfig(),
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? _createLocalClient;

  final OllamaConfig config;
  final http.Client Function() _clientFactory;
  http.Client? _activeClient;
  bool _disposed = false;

  static http.Client _createLocalClient() =>
      IOClient(HttpClient()..findProxy = (_) => 'DIRECT');

  Uri _endpoint() {
    final uri = Uri.tryParse(config.baseUrl);
    if (uri == null ||
        uri.scheme != 'http' ||
        !{'localhost', '127.0.0.1', '[::1]', '::1'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        config.model.trim().isEmpty ||
        config.model.toLowerCase().contains('cloud') ||
        config.requestTimeout <= Duration.zero ||
        config.contextWindow <= config.maxOutputTokens ||
        config.maxOutputTokens <= 0 ||
        config.maxInputCharacters <= 0) {
      throw const AiException(
        AiFailure.configuration,
        '로컬 AI 설정을 확인해주세요. 로컬 주소와 로컬 모델만 사용할 수 있습니다.',
      );
    }
    return uri.resolve('/api/chat');
  }

  @override
  Future<LlmCompletion> complete({
    required String instructions,
    required String input,
  }) => _complete(instructions: instructions, input: input);

  @override
  Future<LlmCompletion> completeStructured({
    required String instructions,
    required String input,
    required Map<String, dynamic> schema,
  }) => _complete(instructions: instructions, input: input, schema: schema);

  Future<LlmCompletion> _complete({
    required String instructions,
    required String input,
    Map<String, dynamic>? schema,
  }) async {
    if (_disposed) {
      throw const AiException(AiFailure.disposed, 'AI 서비스가 종료되었습니다.');
    }
    if (_activeClient != null) {
      throw const AiException(
        AiFailure.busy,
        '다른 AI 요청을 처리 중입니다. 완료된 뒤 다시 시도해주세요.',
      );
    }
    final endpoint = _endpoint();
    final client = _clientFactory();
    _activeClient = client;
    try {
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/json; charset=utf-8'
        ..body = jsonEncode({
          'model': config.model,
          'stream': false,
          'format': ?schema,
          'messages': [
            {'role': 'system', 'content': instructions},
            {'role': 'user', 'content': input},
          ],
          'options': {
            'num_ctx': config.contextWindow,
            'num_predict': config.maxOutputTokens,
            'temperature': 0.2,
          },
          'keep_alive': config.keepAlive,
        });
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(config.requestTimeout);
      if (_disposed) {
        throw const AiException(AiFailure.disposed, 'AI 서비스가 종료되었습니다.');
      }
      if (response.statusCode == 404) {
        throw AiException(
          AiFailure.modelMissing,
          '모델 ${config.model} 또는 Ollama API를 찾을 수 없습니다. '
          'Ollama 주소와 설치된 모델을 확인해주세요.',
        );
      }
      if (response.statusCode != 200) {
        throw AiException(
          AiFailure.server,
          '로컬 AI 요청에 실패했습니다(상태 코드: ${response.statusCode}). '
          'Ollama 상태와 사용 가능한 메모리를 확인해주세요.',
        );
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic> || data['done'] != true) {
        throw const FormatException('Incomplete response');
      }
      final message = data['message'];
      final content = message is Map ? message['content'] : null;
      if (data['error'] != null ||
          content is! String ||
          content.trim().isEmpty) {
        throw const FormatException('Missing content');
      }
      if (data['done_reason'] == 'length') {
        throw const AiOutputLimitException();
      }
      return LlmCompletion(
        text: content.trim(),
        model: data['model'] is String ? data['model'] as String : config.model,
      );
    } on TimeoutException {
      throw const AiException(
        AiFailure.timeout,
        '로컬 AI 응답 대기 시간이 초과되었습니다. '
        '모델 로딩과 PC 성능을 확인한 뒤 다시 시도해주세요.',
      );
    } on SocketException {
      throw const AiException(
        AiFailure.unavailable,
        'Ollama에 연결할 수 없습니다. Windows에서 Ollama를 실행해주세요.',
      );
    } on http.ClientException {
      throw const AiException(
        AiFailure.unavailable,
        'Ollama 연결이 끊겼습니다. 로컬 서버 실행 상태를 확인해주세요.',
      );
    } on FormatException {
      throw const AiException(
        AiFailure.invalidResponse,
        'Ollama 응답이 비어 있거나 올바르지 않습니다. 모델과 서버 상태를 확인해주세요.',
      );
    } finally {
      // Closing also releases a timed-out request's connection. Server-side
      // inference cancellation depends on Ollama; never retry automatically.
      client.close();
      _activeClient = null;
    }
  }

  void dispose() {
    _disposed = true;
    _activeClient?.close();
  }
}
