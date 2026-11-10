/// Transport-independent contract, usable by UI, background jobs and PKM flows.
abstract interface class LocalLlmClient {
  Future<LlmCompletion> complete({
    required String instructions,
    required String input,
  });
}

/// Optional structured output, used only for extracting material keywords.
abstract interface class StructuredLlmClient implements LocalLlmClient {
  Future<LlmCompletion> completeStructured({
    required String instructions,
    required String input,
    required Map<String, dynamic> schema,
  });
}

class LlmCompletion {
  const LlmCompletion({required this.text, required this.model});

  final String text;
  final String model;
}

enum AiFailure {
  invalidInput,
  inputTooLong,
  configuration,
  unavailable,
  modelMissing,
  timeout,
  busy,
  invalidResponse,
  server,
  disposed,
}

/// Errors remain separate from successful content so they cannot become notes.
class AiException implements Exception {
  const AiException(this.kind, this.message);

  final AiFailure kind;
  final String message;

  @override
  String toString() => message;
}

class AiOutputLimitException extends AiException {
  const AiOutputLimitException()
    : super(
        AiFailure.invalidResponse,
        'AI 응답이 출력 길이 제한에 도달했습니다. 질문을 좁히거나 설정의 출력 제한을 조정해주세요.',
      );
}
