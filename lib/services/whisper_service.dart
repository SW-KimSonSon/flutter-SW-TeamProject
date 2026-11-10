import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'speech_segmenter.dart';

enum _WhisperHealth { absent, loading, ready }

/// One resident local model process; audio is uploaded in memory, never to a cloud.
class WhisperService {
  WhisperService({
    this.port = 8080,
    this.requestTimeout = const Duration(seconds: 30),
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? _localClient;

  final int port;
  final Duration requestTimeout;
  final http.Client Function() _clientFactory;
  Process? _server;
  Future<void>? _starting;
  Future<void>? _closing;
  http.Client? _requestClient;
  bool _disposed = false;
  int _requestGeneration = 0;

  static http.Client _localClient() =>
      IOClient(HttpClient()..findProxy = (_) => 'DIRECT');

  Future<void> start() async {
    if (_disposed) throw StateError('Whisper 서비스가 종료되었습니다.');
    if (_starting != null) return _starting!;
    final future = _startServer();
    _starting = future;
    try {
      await future;
    } finally {
      _starting = null;
    }
  }

  Future<void> _startServer() async {
    // Reuse a surviving server, but never confuse an unrelated HTTP service
    // with Whisper. Loading servers are also shared instead of duplicated.
    final _WhisperHealth health;
    try {
      health = await _probeHealth();
    } on TimeoutException {
      await _waitUntilReady();
      return;
    }
    if (_disposed) throw StateError('Whisper 서비스가 종료되었습니다.');
    if (health == _WhisperHealth.ready) return;
    if (health == _WhisperHealth.loading || _server != null) {
      await _waitUntilReady();
      return;
    }
    final sep = Platform.pathSeparator;
    final root = _findProjectRoot();
    final exe =
        //'$root${sep}whisper.cpp${sep}whisper-blas-bin-x64${sep}Release${sep}whisper-server.exe';
        '$root${sep}whisper.cpp${sep}whisper-cublas-12.4.0-bin-x64${sep}Release${sep}whisper-server.exe';
    //final model = '$root${sep}whisper.cpp${sep}models${sep}ggml-small.bin';
    final model = '$root${sep}whisper.cpp${sep}models${sep}ggml-large-v3-turbo-q5_0.bin';
    if (!await File(exe).exists() || !await File(model).exists()) {
      throw Exception(
        //'whisper-server.exe 또는 ggml-small.bin이 없습니다. ',
        'whisper-server.exe 또는 ggml-large-v3-turbo-q5_0.bin이 없습니다. ',
      );
    }
    if (_disposed) throw StateError('Whisper 서비스가 종료되었습니다.');
    final process = await Process.start(exe, [
      '-m',
      //'..$sep..${sep}models${sep}ggml-small.bin',
      '..$sep..${sep}models${sep}ggml-large-v3-turbo-q5_0.bin',
      '-l',
      'ko',
      '-t',
      '8',
      '--host',
      '127.0.0.1',
      '--port',
      '$port',
    ], workingDirectory: File(exe).parent.path);
    if (_disposed) {
      process.kill();
      throw StateError('Whisper 서비스가 종료되었습니다.');
    }
    _server = process;
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    int? exitCode;
    unawaited(
      process.exitCode.then((code) {
        exitCode = code;
        if (identical(_server, process)) _server = null;
      }),
    );
    try {
      // Two app instances may launch at the same time. If one process loses
      // the bind race, accept the healthy server started by the other instance.
      await _waitUntilReady(exitCode: () => exitCode);
    } catch (_) {
      process.kill();
      if (identical(_server, process)) _server = null;
      rethrow;
    }
  }

  Future<_WhisperHealth> _probeHealth() async {
    final client = _clientFactory();
    try {
      final request = http.Request(
        'GET',
        Uri.parse('http://127.0.0.1:$port/health'),
      )..followRedirects = false;
      final response = await (() async => http.Response.fromStream(
        await client.send(request),
      ))().timeout(const Duration(seconds: 1));
      final server = response.headers['server']?.toLowerCase();
      if (server != 'whisper.cpp') {
        throw StateError(
          '포트 $port를 다른 프로그램이 사용 중입니다. Whisper 서버가 아니므로 재사용하지 않았습니다.',
        );
      }
      if (response.statusCode != 200 && response.statusCode != 503) {
        throw StateError('포트 $port의 Whisper 서버 상태가 올바르지 않습니다.');
      }
      final dynamic body;
      try {
        body = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        throw StateError('포트 $port의 Whisper 서버 응답을 읽을 수 없습니다.');
      }
      if (body is Map && response.statusCode == 200 && body['status'] == 'ok') {
        return _WhisperHealth.ready;
      }
      if (body is Map &&
          response.statusCode == 503 &&
          body['status'] == 'loading model') {
        return _WhisperHealth.loading;
      }
      throw StateError('포트 $port의 Whisper 서버 상태가 올바르지 않습니다.');
    } on http.ClientException {
      // A listener that cannot speak HTTP is still an occupied port.
      if (!await _isPortOpen()) return _WhisperHealth.absent;
      throw StateError('포트 $port의 프로그램에서 Whisper 상태를 확인할 수 없습니다.');
    } on TimeoutException {
      // Windows can take longer to report connection refusal than the HTTP
      // timeout. Distinguish an unused port from a busy/loading server.
      if (!await _isPortOpen()) return _WhisperHealth.absent;
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<bool> _isPortOpen() async {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 500),
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  Future<void> _waitUntilReady({int? Function()? exitCode}) async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (!_disposed && DateTime.now().isBefore(deadline)) {
      try {
        final health = await _probeHealth();
        if (_disposed) throw StateError('Whisper 서비스가 종료되었습니다.');
        if (health == _WhisperHealth.ready) return;
      } on TimeoutException {
        // An existing Whisper server may still be loading its model.
      }
      if (exitCode?.call() != null) {
        throw Exception('Whisper 서버가 종료되었습니다 (코드 ${exitCode!()}).');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw Exception('Whisper 모델 준비가 취소되었거나 2분을 초과했습니다.');
  }

  String _findProjectRoot() {
    // Works both from flutter run and from the built executable's directory.
    for (final start in [
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ]) {
      var directory = start;
      for (var depth = 0; depth < 9; depth++) {
        if (File(
              //'${directory.path}/whisper.cpp/whisper-blas-bin-x64/Release/whisper-server.exe',
              '${directory.path}/whisper.cpp/whisper-cublas-12.4.0-bin-x64/Release/whisper-server.exe',
            ).existsSync() &&
            File(
              //'${directory.path}/whisper.cpp/models/ggml-small.bin',
              '${directory.path}/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin',
            ).existsSync()) {
          return directory.path;
        }
        final parent = directory.parent;
        if (parent.path == directory.path) break;
        directory = parent;
      }
    }
    throw Exception(
      //'Whisper 실행 파일과 ggml-small.bin을 찾을 수 없습니다. 프로젝트 루트 또는 실행 파일 옆에 whisper.cpp 폴더를 준비해 주세요.',
      'Whisper 실행 파일과 ggml-mlarge-v3-turbo-q5_0.bin을 찾을 수 없습니다. 프로젝트 루트 또는 실행 파일 옆에 whisper.cpp 폴더를 준비해 주세요.',
    );
  }

  Future<String> transcribe(List<int> pcm, String prompt) async {
    if (_disposed) throw StateError('Whisper 서비스가 종료되었습니다.');
    if (_requestClient != null) throw StateError('이미 음성을 인식하고 있습니다.');
    final client = _clientFactory();
    _requestClient = client;
    final generation = _requestGeneration;
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('http://127.0.0.1:$port/inference'),
          )
          ..followRedirects = false
          ..fields['response_format'] = 'json'
          ..fields['temperature'] = '0.0'
          ..fields['language'] = 'ko'
          // Always send even an empty prompt: the server may retain request settings.
          ..fields['prompt'] = prompt
          ..files.add(
            http.MultipartFile.fromBytes('file', [
              ...SpeechSegmenter.wavHeader(pcm.length),
              ...pcm,
            ], filename: 'utterance.wav'),
          );
    try {
      final response = await (() async {
        final streamed = await client.send(request);
        return http.Response.fromStream(streamed);
      })().timeout(requestTimeout);
      if (_disposed || generation != _requestGeneration) {
        throw StateError('취소된 음성 인식입니다.');
      }
      if (response.statusCode != 200) {
        throw Exception('Whisper 서버 오류 ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map || decoded['text'] is! String) {
        throw const FormatException('Whisper 응답에 자막이 없습니다.');
      }
      return decoded['text'] as String;
    } finally {
      client.close();
      if (identical(_requestClient, client)) _requestClient = null;
    }
  }

  void cancelRequest() {
    _requestGeneration++;
    _requestClient?.close();
    _requestClient = null;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _disposed = true;
    cancelRequest();
    // Only this instance's child is owned. Reused servers belong to another
    // app instance and must not be terminated here.
    final process = _server;
    process?.kill();
    _server = null;
    if (process != null) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        process.kill();
      }
    }
    try {
      await _starting?.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Startup observes _disposed and kills a child created during shutdown.
    }
  }

  void dispose() => unawaited(close());
}
