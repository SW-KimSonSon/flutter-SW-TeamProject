/// Local AI settings. Changing these defaults requires restarting/rebuilding the app.
class OllamaConfig {
  const OllamaConfig({
    this.baseUrl = 'http://localhost:11434',
    this.model = 'qwen2.5:3b',
    this.requestTimeout = const Duration(minutes: 3),
    this.contextWindow = 8192,
    this.maxOutputTokens = 768,
    this.maxInputCharacters = 6000,
    this.keepAlive = '5m',
  });

  final String baseUrl;
  final String model;
  final Duration requestTimeout;
  final int contextWindow;
  final int maxOutputTokens;
  // A conservative character guard, not an exact token count. Never truncate.
  final int maxInputCharacters;
  final String keepAlive;
}
