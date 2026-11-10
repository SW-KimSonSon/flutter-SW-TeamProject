import 'dart:math';
import 'dart:typed_data';

/// Team VAD: 48 kHz mono signed 16-bit PCM, utterance boundaries and pre-roll.
class SpeechSegmenter {
  SpeechSegmenter({
    required this.onUtterance,
    this.onDiagnostic,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final void Function(List<int>) onUtterance;
  final void Function(String)? onDiagnostic;
  final DateTime Function() _clock;
  final List<int> _audioBuffer = [];
  void add(List<int> pcm) {
    _audioBuffer.addAll(pcm);
    _processVadFrames();
  }

  void checkTimeout() => _checkVadTimeout();
  void reset() => _resetVad();
  static bool isHallucination(String text) => _isHallucination(text);
  static List<int> wavHeader(int length) => _createWavHeader(length);
  static const int _sampleRate = 48000;
  // 최대 길이를 넘겨 강제로 자를 때, 끝부분을 다음 구간 앞에 겹쳐 두는 길이
  static const int _overlapSeconds = 1;
  // 이 값보다 조용하면 무음으로 봄 (로그의 소음 기준선 보며 조절)
  static const double _silenceRmsThreshold = 300.0;

  int get _overlapBytes => _sampleRate * 2 * _overlapSeconds;

  // 발화 문장 단위 분할 설정
  static const int _vadFrameMs = 20; // 프레임 길이
  static const int _vadEndSilenceMs = 500; // 이 시간만큼 조용하면 발화가 끝났다고 판단
  static const int _vadMinSpeechMs = 300; // 이보다 짧은 소리는 잡음으로 보고 버림
  static const int _vadPreRollMs = 400; // 말 시작 직전 소리도 포함 (첫 음절 잘림 방지)
  static const int _vadMaxUtteranceSeconds = 20; // 안 쉬고 말해도 이 길이에서 강제로 자름
  static const double _vadNoiseRatio = 3.0; // 주변 소음의 몇 배 이상이면 말소리로 볼지

  int get _vadFrameBytes => _sampleRate * 2 * _vadFrameMs ~/ 1000;

  // 발화 상태
  final List<int> _utterance = []; // 지금 모으는 중인 발화
  final List<List<int>> _preRoll = []; // 말 시작 전 최근 프레임들

  bool _inSpeech = false;
  int _speechMs = 0;
  int _silenceMs = 0;
  double _noiseFloor = 0;
  late DateTime _lastAudioAt = _clock();

  // Whisper가 무음에서 자주 만들어내는 환각 문구
  static const List<String> _hallucinationPhrases = [
    "시청해주셔서 감사합니다",
    "시청해 주셔서 감사합니다",
    "구독과 좋아요",
    "자막 제공",
  ];

  // 음량 계산, 무음 판별에 사용
  double _calcRms(List<int> pcm) {
    final bytes = Uint8List.fromList(pcm);
    final bd = ByteData.sublistView(bytes);
    final sampleCount = bytes.length ~/ 2;
    if (sampleCount == 0) return 0;

    double sum = 0;
    for (int i = 0; i < sampleCount; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      sum += s * s;
    }
    return sqrt(sum / sampleCount);
  }

  // 환각 문구 여부
  static bool _isHallucination(String text) {
    final t = text.trim().replaceAll(RegExp(r'[.!?。\s]+$'), '');
    return _hallucinationPhrases.contains(t);
  }

  // 상태 초기화
  void _resetVad() {
    _audioBuffer.clear();
    _utterance.clear();
    _preRoll.clear();
    _inSpeech = false;
    _speechMs = 0;
    _silenceMs = 0;
    _noiseFloor = 0;
  }

  // 쌓인 소리를 프레임 단위로 잘라 하나씩 넣음
  void _processVadFrames() {
    _lastAudioAt = _clock();
    final frameBytes = _vadFrameBytes;
    while (_audioBuffer.length >= frameBytes) {
      final frame = _audioBuffer.sublist(0, frameBytes);
      _audioBuffer.removeRange(0, frameBytes);
      _handleVadFrame(frame);
    }
  }

  // 소음 기준선이 올라가도 말소리 판정 기준이 이 값을 넘지 않게 제한
  static const double _vadMaxThreshold = 1500.0;

  // 프레임 하나를 보고 말의 시작과 끝을 판단
  void _handleVadFrame(List<int> frame) {
    final rms = _calcRms(frame);
    final threshold = min(
      _vadMaxThreshold,
      max(_silenceRmsThreshold, _noiseFloor * _vadNoiseRatio),
    );
    final isSpeech = rms >= threshold;

    if (!_inSpeech) {
      // 말하는 중이 아닐 때만 주변 소음 크기를 갱신
      if (rms < _noiseFloor) {
        _noiseFloor = _noiseFloor * 0.7 + rms * 0.3;
      } else {
        _noiseFloor = _noiseFloor * 0.995 + rms * 0.005;
      }

      if (!isSpeech) {
        // 말 시작 직전 소리를 잠깐 보관
        _preRoll.add(frame);
        final maxFrames = _vadPreRollMs ~/ _vadFrameMs;
        while (_preRoll.length > maxFrames) {
          _preRoll.removeAt(0);
        }
        return;
      }

      // 말 시작: 보관해 둔 직전 소리를 앞에 붙임
      _inSpeech = true;
      _speechMs = 0;
      _silenceMs = 0;
      _utterance.clear();
      for (final f in _preRoll) {
        _utterance.addAll(f);
      }
      _preRoll.clear();
    }

    _utterance.addAll(frame);
    if (isSpeech) {
      _speechMs += _vadFrameMs;
      _silenceMs = 0;
    } else {
      _silenceMs += _vadFrameMs;
    }

    final utteranceMs = _utterance.length * 1000 ~/ (_sampleRate * 2);
    if (_silenceMs >= _vadEndSilenceMs) {
      _finishUtterance();
    } else if (utteranceMs >= _vadMaxUtteranceSeconds * 1000) {
      _finishUtterance(forced: true);
    }
  }

  // 소리 입력이 끊겨도 일정 시간이 지나면 발화를 마무리
  void _checkVadTimeout() {
    if (!_inSpeech) return;
    final idleMs = _clock().difference(_lastAudioAt).inMilliseconds;
    if (idleMs >= _vadEndSilenceMs) {
      _finishUtterance();
    }
  }

  // 발화 하나를 마무리해서 인식 대기열에 넣음
  void _finishUtterance({bool forced = false}) {
    final pcm = List<int>.from(_utterance);
    final speechMs = _speechMs;

    if (forced) {
      // 강제로 자른 경우 말은 계속 이어지므로 끝부분을 다음 구간 앞에 겹쳐 둠
      final tailStart = max(0, pcm.length - _overlapBytes);
      final tail = pcm.sublist(tailStart);
      _utterance
        ..clear()
        ..addAll(tail);
      _speechMs = 0;
      _silenceMs = 0;
    } else {
      _utterance.clear();
      _inSpeech = false;
      _speechMs = 0;
      _silenceMs = 0;
    }

    final seconds = pcm.length / (_sampleRate * 2);
    onDiagnostic?.call(
      "발화 종료: ${seconds.toStringAsFixed(1)}초 / 말소리 ${speechMs}ms / "
      "소음 기준선 ${_noiseFloor.toStringAsFixed(0)}",
    );

    // 너무 짧은 소리는 인식하지 않음
    if (speechMs < _vadMinSpeechMs) return;

    onUtterance(pcm);
  }

  static List<int> _createWavHeader(
    int pcmLength, {
    int sampleRate = 48000,
    int channels = 1,
  }) {
    final int byteRate = sampleRate * channels * 2;
    final int blockAlign = channels * 2;
    final int fileSize = 36 + pcmLength;

    final header = ByteData(44);
    header.setUint32(0, 0x52494646, Endian.big);
    header.setUint32(4, fileSize, Endian.little);
    header.setUint32(8, 0x57415645, Endian.big);
    header.setUint32(12, 0x666d7420, Endian.big);
    header.setUint16(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint32(36, 0x64617461, Endian.big);
    header.setUint32(40, pcmLength, Endian.little);

    return header.buffer.asUint8List();
  }
}
