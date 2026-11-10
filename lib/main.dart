import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show AppExitResponse;
import 'package:file_selector/file_selector.dart';
import 'services/speech_segmenter.dart';
import 'services/whisper_service.dart';
import 'services/material_terms_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:desktop_audio_capture/audio_capture.dart';
import 'config/ollama_config.dart';
import 'models/lecture_ai.dart';
import 'services/lecture_ai_service.dart';
import 'services/local_llm_client.dart';
import 'services/ollama_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LectureScreen(),
    );
  }
}

// 소리를 받아올 곳: 컴퓨터소리나 마이크소리
enum AudioInputMode { system, mic }

class LectureScreen extends StatefulWidget {
  const LectureScreen({super.key});

  @override
  State<LectureScreen> createState() => _LectureScreenState();
}

class _LectureScreenState extends State<LectureScreen> {
  // 화면 공유
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  MediaStream? _stream;
  bool _isSharing = false;
  bool _isProcessingSTT = false;

  final ValueNotifier<String> _subtitleNotifier = ValueNotifier<String>("");
  final ValueNotifier<String> _finalSubtitleNotifier = ValueNotifier<String>(
    "",
  );
  final ValueNotifier<Offset> _boxPositionNotifier = ValueNotifier<Offset>(
    const Offset(50, 200),
  );

  double _boxW = 300.0;
  double _boxH = 120.0;
  double _boxOpacity = 0.6;
  double _subtitleFontSize = 18.0;

  // whisper 프롬프트 실시간 제어용
  final TextEditingController _promptController = TextEditingController(
    text: "",
  );

  // AI 요약 / 질문 기능
  static const _aiConfig = OllamaConfig();
  final OllamaService _ollamaService = OllamaService(config: _aiConfig);
  late final LectureAiService _lectureAiService = LectureAiService(
    client: _ollamaService,
    maxInputCharacters: _aiConfig.maxInputCharacters,
  );

  String _summaryText = "";
  bool _showSummary = false;
  bool _isSummarizing = false;

  double _summaryBoxWidth = 330.0;
  double _summaryBoxHeight = 190.0;
  Offset _summaryBoxPosition = const Offset(600, 300);

  // 전체 자막 박스
  bool _showTranscript = false;
  double _transcriptBoxWidth = 380.0;
  double _transcriptBoxHeight = 260.0;
  Offset _transcriptBoxPosition = const Offset(600, 20);
  final ScrollController _transcriptScroll =
      ScrollController(); // 새 자막이 붙을 때 맨 아래를 따라감

  final TextEditingController _questionController = TextEditingController();

  // 오디오 캡쳐 설정
  SystemAudioCapture? _systemAudioCapture;

  // 마이크 모드용 설정
  AudioInputMode _inputMode = AudioInputMode.system;
  MicAudioCapture? _micAudioCapture;

  StreamSubscription? _audioSubscription;
  Timer? _sttTimer;
  final WhisperService _whisper = WhisperService();
  late final AppLifecycleListener _appLifecycle;
  late final SpeechSegmenter _segmenter = SpeechSegmenter(
    onUtterance: _enqueueUtterance,
    onDiagnostic: debugPrint,
  );
  final List<List<int>> _utteranceQueue = [];
  int _captureSession = 0;
  bool _isStarting = false;
  bool _isStopping = false;
  bool _isLoadingMaterial = false;
  String _materialStatus = '';
  String _materialText = '';
  String _materialName = '';
  String _captureStatus = '';

  @override
  void initState() {
    super.initState();
    _appLifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _whisper.close();
        return AppExitResponse.exit;
      },
      onDetach: _whisper.dispose,
    );
    _renderer.initialize();
  }

  @override
  void dispose() {
    _captureSession++;
    _appLifecycle.dispose();
    _whisper.dispose();
    _renderer.dispose();
    _stream?.dispose();
    _sttTimer?.cancel();
    _audioSubscription?.cancel();
    _systemAudioCapture?.stopCapture();
    _micAudioCapture?.stopCapture();

    _subtitleNotifier.dispose();
    _finalSubtitleNotifier.dispose();
    _boxPositionNotifier.dispose();

    _promptController.dispose();
    _questionController.dispose();
    _transcriptScroll.dispose();
    _ollamaService.dispose();

    super.dispose();
  }

  // 강의자료 파일을 골라 핵심 용어를 뽑고 프롬프트 입력창에 채움
  Future<void> _loadMaterial() async {
    if (_isLoadingMaterial) return;

    final typeGroup = XTypeGroup(
      label: '강의자료',
      extensions: ['pdf', 'docx', 'pptx', 'txt'],
    );
    final picked = await openFile(acceptedTypeGroups: [typeGroup]);
    if (!mounted || picked == null || _isLoadingMaterial) return;

    setState(() {
      _isLoadingMaterial = true;
      _materialStatus = "'${picked.name}' 분석 중입니다...";
    });

    try {
      final service = MaterialTermsService(
        client: _ollamaService,
        maxInputCharacters: _aiConfig.maxInputCharacters,
        onProgress: (status) {
          if (mounted) setState(() => _materialStatus = status);
        },
      );
      final text = await service.readText(picked.path);
      if (!mounted) return;
      setState(() {
        _materialText = text;
        _materialName = picked.name;
      });
      try {
        final terms = await service.extractText(text);
        if (!mounted) return;
        setState(() {
          _promptController.text = terms;
          _materialStatus =
              '${picked.name}: 자료 준비 완료. AI는 자막을 기준으로 분석하고 자료를 보조 참고합니다.'
              '${service.usedLocalFallback ? " 일부 용어는 빈출 단어로 보완했습니다." : ""}';
        });
      } catch (error) {
        if (mounted) {
          setState(
            () => _materialStatus =
                '자료 본문을 읽었습니다. 용어 추출은 실패했지만 자막 분석의 보조자료로 사용할 수 있습니다: $error',
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final message = e is FormatException ? e.message : e.toString();
        _materialStatus =
            '강의자료 읽기 실패: $message'
            '${_materialText.isNotEmpty ? " (기존 자료 $_materialName 유지)" : ""}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingMaterial = false;
        });
      }
    }
  }

  // 자막 설정창
  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('자막 설정'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('가로 길이: ${_boxW.toInt()}'),
                    Slider(
                      value: _boxW,
                      min: 150,
                      max: 600,
                      onChanged: (v) {
                        setDialogState(() => _boxW = v);
                        setState(() {});
                      },
                    ),
                    Text('세로 길이: ${_boxH.toInt()}'),
                    Slider(
                      value: _boxH,
                      min: 50,
                      max: 400,
                      onChanged: (v) {
                        setDialogState(() => _boxH = v);
                        setState(() {});
                      },
                    ),
                    Text('투명도: ${(_boxOpacity * 100).toInt()}%'),
                    Slider(
                      value: _boxOpacity,
                      min: 0.1,
                      max: 1.0,
                      onChanged: (v) {
                        setDialogState(() => _boxOpacity = v);
                        setState(() {});
                      },
                    ),
                    Text('글씨 크기: ${_subtitleFontSize.toInt()}'),
                    Slider(
                      value: _subtitleFontSize,
                      min: 10,
                      max: 40,
                      onChanged: (v) {
                        setDialogState(() => _subtitleFontSize = v);
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('확인'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // 자막을 주요 분석 대상으로 유지하고, 자료가 있을 때만 보조로 전달합니다.
  Future<LectureAiResult> _requestAi({String? question}) {
    final source = LectureContext(transcript: _getCurrentTranscript());
    return question == null
        ? _lectureAiService.summarize(source, materialText: _materialText)
        : _lectureAiService.answerQuestion(
            source,
            question,
            materialText: _materialText,
          );
  }

  // 현재까지 누적된 자막 가져오기
  String _getCurrentTranscript() {
    final finalText = _finalSubtitleNotifier.value.trim();
    final currentText = _subtitleNotifier.value.trim();

    if (finalText.isNotEmpty) {
      return finalText;
    }

    if (currentText.isNotEmpty) {
      return currentText;
    }

    return "";
  }

  Future<String> _displayAiResult(
    Future<LectureAiResult> Function() request,
  ) async {
    try {
      return (await request()).content;
    } on AiException catch (error) {
      return error.message;
    } catch (_) {
      return "로컬 AI 처리 중 오류가 발생했습니다. 다시 시도해주세요.";
    }
  }

  // 질문 입력 팝업
  void _showQuestionDialog() {
    _questionController.clear();

    String answerText = "질문을 입력한 뒤 질문하기 버튼을 눌러주세요.";
    bool isAnswering = false;

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("AI에게 질문하기"),
              content: SizedBox(
                width: 520,
                height: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '강의 자막 내용을 기준으로 질문합니다.',
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _questionController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: "예: CPU 스케줄링이 뭐야?",
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton.icon(
                        onPressed: isAnswering
                            ? null
                            : () async {
                                final question = _questionController.text
                                    .trim();

                                if (question.isEmpty) {
                                  setDialogState(() {
                                    answerText = "질문을 입력해주세요.";
                                  });
                                  return;
                                }

                                setDialogState(() {
                                  isAnswering = true;
                                  answerText = "AI 답변 생성 중입니다...";
                                });

                                final result = await _displayAiResult(
                                  () => _requestAi(question: question),
                                );

                                if (!mounted || !context.mounted) return;

                                setDialogState(() {
                                  answerText = result;
                                  isAnswering = false;
                                });
                              },
                        icon: const Icon(Icons.question_answer),
                        label: Text(isAnswering ? "답변 중..." : "질문하기"),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            answerText,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text("닫기"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // 화면 공유 시작
  Future<void> _startShare() async {
    if (_isStarting || _isStopping || _isSharing) return;
    final session = ++_captureSession;
    setState(() {
      _isStarting = true;
      _captureStatus = '';
    });
    try {
      String? selectedSourceId;

      if (Platform.isWindows) {
        List<DesktopCapturerSource> sources = await desktopCapturer.getSources(
          types: [SourceType.Screen, SourceType.Window],
        );

        if (mounted) {
          selectedSourceId = await _showSelectionDialog(context, sources);
        }

        if (selectedSourceId == null) return;
      }

      final Map<String, dynamic> mediaConstraints = {
        'audio': false,
        'video': selectedSourceId != null
            ? {
                'deviceId': {'exact': selectedSourceId},
                'mandatory': {
                  'frameRate': 30,
                  'minWidth': 1280,
                  'minHeight': 720,
                },
              }
            : true,
      };

      final stream = await navigator.mediaDevices.getDisplayMedia(
        mediaConstraints,
      );

      if (!mounted || session != _captureSession) {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
        return;
      }
      setState(() {
        _stream = stream;
        _renderer.srcObject = stream;
        _isSharing = true;
        _finalSubtitleNotifier.value = "";
        _subtitleNotifier.value = "";
      });

      setState(() => _captureStatus = 'Whisper 모델을 준비하는 중입니다...');
      await _whisper.start();
      if (!mounted || session != _captureSession) return;

      if (_inputMode == AudioInputMode.mic) {
        await _startMicLoop(session);
      } else {
        await _startRecordingLoop(session);
      }
      if (mounted && session == _captureSession) {
        setState(() {
          _captureStatus = _inputMode == AudioInputMode.mic
              ? '마이크 음성 인식 중'
              : '음성 인식 중';
        });
      }
    } catch (e) {
      if (mounted && session == _captureSession) {
        await _stopShare();
        if (mounted) setState(() => _captureStatus = '화면 공유/STT 시작 실패: $e');
      }
    } finally {
      if (mounted) setState(() => _isStarting = false);
    }
  }

  // 공유할 화면 선택
  Future<String?> _showSelectionDialog(
    BuildContext context,
    List<DesktopCapturerSource> sources,
  ) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("공유할 화면 선택"),
          content: SizedBox(
            width: 500,
            height: 400,
            child: ListView.builder(
              itemCount: sources.length,
              itemBuilder: (context, index) {
                final source = sources[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListTile(
                    title: Text(
                      source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(context).pop(source.id);
                    },
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text("취소"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _stopShare() async {
    if (_isStopping) return;
    _captureSession++;
    setState(() {
      _isStopping = true;
      _isSharing = false;
    });
    _sttTimer?.cancel();
    _segmenter.reset();
    _utteranceQueue.clear();
    _whisper.cancelRequest();
    final stream = _stream;
    _stream = null;
    _renderer.srcObject = null;
    _subtitleNotifier.value = '';
    try {
      await _audioSubscription?.cancel();
      _audioSubscription = null;
      await _systemAudioCapture?.stopCapture();
      _systemAudioCapture = null;
      await _micAudioCapture?.stopCapture();
      _micAudioCapture = null;
    } catch (e) {
      debugPrint('오디오 종료 오류: $e');
    } finally {
      if (stream != null) {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
      }
      if (mounted) {
        setState(() {
          _isStopping = false;
          _captureStatus = '';
        });
      }
    }
  }

  Future<void> _startRecordingLoop(int session) async {
    _segmenter.reset();
    _utteranceQueue.clear();
    final capture = SystemAudioCapture(
      config: SystemAudioConfig(sampleRate: 48000, channels: 1),
    );
    _systemAudioCapture = capture;
    await capture.startCapture();
    if (!mounted || session != _captureSession) {
      await capture.stopCapture();
      return;
    }
    _audioSubscription = capture.audioStream?.listen(
      (data) {
        if (mounted && session == _captureSession) _segmenter.add(data);
      },
      onError: (Object error) {
        if (mounted && session == _captureSession) {
          setState(() => _captureStatus = '오디오 입력 오류: $error');
        }
      },
    );
    _sttTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && session == _captureSession) _segmenter.checkTimeout();
    });
  }

  // 마이크 입력을 받아 VAD로 넘김.
  Future<void> _startMicLoop(int session) async {
    _segmenter.reset();
    _utteranceQueue.clear();
    final capture = MicAudioCapture(
      config: MicAudioConfig(
        sampleRate: 48000,
        channels: 1,
        bitDepth: 16,
        gainBoost: 1.0,
        inputVolume: 1.0,
      ),
    );
    _micAudioCapture = capture;

    // 권한 요청이 지원되지 않아도 마이크 시작은 계속 시도
    try {
      await capture.requestPermissions();
    } catch (e) {
      debugPrint('마이크 권한 요청 오류: $e');
    }
    if (!await capture.hasInputDevice()) {
      throw Exception('마이크를 찾을 수 없습니다. 마이크 연결과 Windows 마이크 권한을 확인해 주세요.');
    }

    await capture.startCapture();
    if (!mounted || session != _captureSession) {
      await capture.stopCapture();
      return;
    }
    _audioSubscription = capture.audioStream?.listen(
      (data) {
        if (mounted && session == _captureSession) _segmenter.add(data);
      },
      onError: (Object error) {
        if (mounted && session == _captureSession) {
          setState(() => _captureStatus = '마이크 입력 오류: $error');
        }
      },
    );
    _sttTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && session == _captureSession) _segmenter.checkTimeout();
    });
  }

  void _enqueueUtterance(List<int> pcm) {
    if (!_isSharing) return;
    _utteranceQueue.add(pcm);
    while (_utteranceQueue.length > 6) {
      _utteranceQueue.removeAt(0);
      setState(() => _captureStatus = '인식 지연으로 오래된 발화를 건너뛰었습니다.');
    }
    unawaited(_processWhisperFromBuffer());
  }

  Future<void> _processWhisperFromBuffer() async {
    if (_isProcessingSTT) return;
    _isProcessingSTT = true;
    final session = _captureSession;
    try {
      while (mounted &&
          _isSharing &&
          session == _captureSession &&
          _utteranceQueue.isNotEmpty) {
        final pcm = _utteranceQueue.removeAt(0);
        try {
          final raw = await _whisper.transcribe(
            pcm,
            _promptController.text.trim(),
          );
          if (!mounted || session != _captureSession) return;
          final text = raw
              .replaceAll('\n', ' ')
              .replaceAll(RegExp(r'\[.*?\]|\(.*?\)|<.*?>'), '')
              .trim();
          if (text.isNotEmpty && !SpeechSegmenter.isHallucination(text)) {
            _subtitleNotifier.value = text;
            // 문장이 끝날 때마다 줄바꿈
            final lined = text
                .replaceAllMapped(RegExp(r'([.!?。])\s+'), (m) => '${m[1]}\n')
                .trimRight();
            _finalSubtitleNotifier.value += '$lined\n';
          } else {
            _subtitleNotifier.value = '';
          }
        } catch (e) {
          if (!mounted || session != _captureSession) return;
          setState(() => _captureStatus = '음성 인식 실패: $e');
        }
      }
    } finally {
      _isProcessingSTT = false;
      if (mounted && _isSharing && _utteranceQueue.isNotEmpty) {
        unawaited(_processWhisperFromBuffer());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      //appBar: AppBar(backgroundColor: Colors.blue),
      body: Column(
        children: [
          const SizedBox(height: 10),

          // 입력 선택 (녹음 중에는 바꿀 수 없음)
          Center(
            child: SegmentedButton<AudioInputMode>(
              segments: const [
                ButtonSegment(
                  value: AudioInputMode.system,
                  label: Text('컴퓨터 소리'),
                  icon: Icon(Icons.desktop_windows),
                ),
                ButtonSegment(
                  value: AudioInputMode.mic,
                  label: Text('마이크'),
                  icon: Icon(Icons.mic),
                ),
              ],
              selected: {_inputMode},
              onSelectionChanged: (_isSharing || _isStarting || _isStopping)
                  ? null
                  : (selection) => setState(() => _inputMode = selection.first),
            ),
          ),
          const SizedBox(height: 10),

          // 버튼
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: (_isSharing || _isStarting || _isStopping)
                    ? null
                    : _startShare,
                child: Text(
                  _inputMode == AudioInputMode.mic
                      ? "마이크소리 인식 시작"
                      : "컴퓨터소리 인식 시작",
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _isSharing && !_isStopping ? _stopShare : null,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text("중지"),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed: _isLoadingMaterial ? null : _loadMaterial,
                icon: const Icon(Icons.upload_file),
                label: Text(_isLoadingMaterial ? "분석 중..." : "강의자료 불러오기"),
              ),
            ],
          ),

          if (_captureStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(6),
              child: Text(_captureStatus),
            ),
          // 강의자료 처리 결과 안내
          if (_materialStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _materialStatus,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),

          const SizedBox(height: 10),

          // 실시간 프롬프트 가이드 입력창
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            child: TextField(
              controller: _promptController,
              decoration: const InputDecoration(
                labelText: "실시간 자막 프롬프트",
                hintText: "자주 틀리는 고유 명사, 상황 등을 적어두면 오인식이 줄어듭니다.",
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              maxLines: 1,
              style: const TextStyle(fontSize: 13),
            ),
          ),

          const SizedBox(height: 10),

          // 화면 + 자막 Stack
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    // 화면
                    Container(
                      margin: const EdgeInsets.all(10),
                      color: Colors.black,
                      child: RTCVideoView(
                        _renderer,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      ),
                    ),

                    // 자막 박스
                    if (_isSharing)
                      ValueListenableBuilder<Offset>(
                        valueListenable: _boxPositionNotifier,
                        builder: (context, boxPosition, child) {
                          return Positioned(
                            left: boxPosition.dx,
                            top: boxPosition.dy,
                            child: GestureDetector(
                              onPanUpdate: (d) {
                                final maxX = max(
                                  0.0,
                                  constraints.maxWidth - _boxW,
                                );
                                final maxY = max(
                                  0.0,
                                  constraints.maxHeight - _boxH,
                                );

                                double x =
                                    _boxPositionNotifier.value.dx + d.delta.dx;
                                double y =
                                    _boxPositionNotifier.value.dy + d.delta.dy;

                                x = x.clamp(0, maxX).toDouble();
                                y = y.clamp(0, maxY).toDouble();

                                _boxPositionNotifier.value = Offset(x, y);
                              },
                              child: Container(
                                width: _boxW,
                                height: _boxH,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(
                                    alpha: _boxOpacity,
                                  ),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          top: 10,
                                          right: 30,
                                          left: 10,
                                          bottom: 10,
                                        ),
                                        child: ValueListenableBuilder<String>(
                                          valueListenable: _subtitleNotifier,
                                          builder: (context, subtitle, child) {
                                            return SingleChildScrollView(
                                              child: Text(
                                                subtitle,
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: _subtitleFontSize,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      top: 2,
                                      right: 2,
                                      child: IconButton(
                                        icon: const Icon(
                                          Icons.settings,
                                          color: Colors.white70,
                                          size: 20,
                                        ),
                                        onPressed: _showSettingsDialog,
                                        tooltip: "자막 설정",
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),

                    // 요약 상자 출력
                    if (_showSummary)
                      Positioned(
                        left: _summaryBoxPosition.dx,
                        top: _summaryBoxPosition.dy,
                        child: SizedBox(
                          width: _summaryBoxWidth,
                          height: _summaryBoxHeight,
                          child: Stack(
                            children: [
                              Container(
                                width: _summaryBoxWidth,
                                height: _summaryBoxHeight,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  border: Border.all(color: Colors.grey),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  children: [
                                    GestureDetector(
                                      onPanUpdate: (details) {
                                        setState(() {
                                          double x =
                                              _summaryBoxPosition.dx +
                                              details.delta.dx;
                                          double y =
                                              _summaryBoxPosition.dy +
                                              details.delta.dy;

                                          final maxX =
                                              constraints.maxWidth -
                                              _summaryBoxWidth;
                                          final maxY =
                                              constraints.maxHeight -
                                              _summaryBoxHeight;

                                          if (maxX > 0) {
                                            x = x.clamp(0, maxX).toDouble();
                                          } else {
                                            x = 0;
                                          }

                                          if (maxY > 0) {
                                            y = y.clamp(0, maxY).toDouble();
                                          } else {
                                            y = 0;
                                          }

                                          _summaryBoxPosition = Offset(x, y);
                                        });
                                      },
                                      child: Container(
                                        height: 32,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.grey[200],
                                          borderRadius: const BorderRadius.only(
                                            topLeft: Radius.circular(8),
                                            topRight: Radius.circular(8),
                                          ),
                                        ),
                                        child: const Row(
                                          children: [
                                            Icon(Icons.open_with, size: 16),
                                            SizedBox(width: 6),
                                            Text(
                                              "AI 요약 결과",
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: SingleChildScrollView(
                                        padding: const EdgeInsets.all(12),
                                        child: Text(
                                          _summaryText,
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onPanUpdate: (details) {
                                    setState(() {
                                      _summaryBoxWidth =
                                          (_summaryBoxWidth + details.delta.dx)
                                              .clamp(220.0, 700.0)
                                              .toDouble();

                                      _summaryBoxHeight =
                                          (_summaryBoxHeight + details.delta.dy)
                                              .clamp(120.0, 500.0)
                                              .toDouble();
                                    });
                                  },
                                  child: Container(
                                    width: 28,
                                    height: 28,
                                    alignment: Alignment.bottomRight,
                                    padding: const EdgeInsets.all(4),
                                    child: const Icon(
                                      Icons.drag_handle,
                                      size: 20,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // 전체 자막 상자
                    if (_showTranscript)
                      Positioned(
                        left: _transcriptBoxPosition.dx,
                        top: _transcriptBoxPosition.dy,
                        child: SizedBox(
                          width: _transcriptBoxWidth,
                          height: _transcriptBoxHeight,
                          child: Stack(
                            children: [
                              Container(
                                width: _transcriptBoxWidth,
                                height: _transcriptBoxHeight,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  border: Border.all(color: Colors.grey),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  children: [
                                    GestureDetector(
                                      onPanUpdate: (details) {
                                        setState(() {
                                          double x =
                                              _transcriptBoxPosition.dx +
                                              details.delta.dx;
                                          double y =
                                              _transcriptBoxPosition.dy +
                                              details.delta.dy;

                                          final maxX =
                                              constraints.maxWidth -
                                              _transcriptBoxWidth;
                                          final maxY =
                                              constraints.maxHeight -
                                              _transcriptBoxHeight;

                                          if (maxX > 0) {
                                            x = x.clamp(0, maxX).toDouble();
                                          } else {
                                            x = 0;
                                          }

                                          if (maxY > 0) {
                                            y = y.clamp(0, maxY).toDouble();
                                          } else {
                                            y = 0;
                                          }

                                          _transcriptBoxPosition = Offset(x, y);
                                        });
                                      },
                                      child: Container(
                                        height: 32,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.grey[200],
                                          borderRadius: const BorderRadius.only(
                                            topLeft: Radius.circular(8),
                                            topRight: Radius.circular(8),
                                          ),
                                        ),
                                        child: const Row(
                                          children: [
                                            Icon(Icons.open_with, size: 16),
                                            SizedBox(width: 6),
                                            Text(
                                              "전체 자막",
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: ValueListenableBuilder<String>(
                                        valueListenable: _finalSubtitleNotifier,
                                        builder: (context, transcript, child) {
                                          final text = transcript.trim();

                                          // 이미 맨 아래를 보고 있었다면 새 자막이 붙을 때 따라 내려감
                                          final follow =
                                              !_transcriptScroll.hasClients ||
                                              _transcriptScroll
                                                      .position
                                                      .pixels >=
                                                  _transcriptScroll
                                                          .position
                                                          .maxScrollExtent -
                                                      40;
                                          if (follow) {
                                            WidgetsBinding.instance
                                                .addPostFrameCallback((_) {
                                                  if (_transcriptScroll
                                                      .hasClients) {
                                                    _transcriptScroll.jumpTo(
                                                      _transcriptScroll
                                                          .position
                                                          .maxScrollExtent,
                                                    );
                                                  }
                                                });
                                          }

                                          return SingleChildScrollView(
                                            controller: _transcriptScroll,
                                            padding: const EdgeInsets.all(12),
                                            child: SelectableText(
                                              text.isEmpty
                                                  ? "아직 인식된 자막이 없습니다."
                                                  : text,
                                              style: const TextStyle(
                                                fontSize: 14,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onPanUpdate: (details) {
                                    setState(() {
                                      _transcriptBoxWidth =
                                          (_transcriptBoxWidth +
                                                  details.delta.dx)
                                              .clamp(220.0, 700.0)
                                              .toDouble();

                                      _transcriptBoxHeight =
                                          (_transcriptBoxHeight +
                                                  details.delta.dy)
                                              .clamp(120.0, 500.0)
                                              .toDouble();
                                    });
                                  },
                                  child: Container(
                                    width: 28,
                                    height: 28,
                                    alignment: Alignment.bottomRight,
                                    padding: const EdgeInsets.all(4),
                                    child: const Icon(
                                      Icons.drag_handle,
                                      size: 20,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // 질문 버튼
                    Positioned(
                      right: 340,
                      bottom: 20,
                      child: ElevatedButton.icon(
                        onPressed: _showQuestionDialog,
                        icon: const Icon(Icons.question_answer),
                        label: const Text("AI 질문하기"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),

                    // 요약 버튼
                    Positioned(
                      right: 190,
                      bottom: 20,
                      child: ElevatedButton.icon(
                        onPressed: _isSummarizing
                            ? null
                            : () async {
                                if (_showSummary) {
                                  setState(() {
                                    _showSummary = false;
                                  });
                                  return;
                                }

                                double startX =
                                    constraints.maxWidth -
                                    _summaryBoxWidth -
                                    20;
                                double startY =
                                    constraints.maxHeight -
                                    _summaryBoxHeight -
                                    80;

                                if (startX < 0) startX = 0;
                                if (startY < 0) startY = 0;

                                setState(() {
                                  _summaryBoxPosition = Offset(startX, startY);
                                  _showSummary = true;
                                  _isSummarizing = true;
                                  _summaryText = "AI 요약 중입니다...";
                                });

                                final result = await _displayAiResult(
                                  () => _requestAi(),
                                );

                                if (!mounted) return;

                                setState(() {
                                  _summaryText = result;
                                  _isSummarizing = false;
                                });
                              },
                        icon: const Icon(Icons.summarize),
                        label: Text(
                          _isSummarizing
                              ? "요약 중..."
                              : (_showSummary ? "요약 닫기" : "AI 요약하기"),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),

                    // 전체 자막 버튼
                    Positioned(
                      right: 20,
                      bottom: 20,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          if (_showTranscript) {
                            setState(() {
                              _showTranscript = false;
                            });
                            return;
                          }

                          double startX =
                              constraints.maxWidth - _transcriptBoxWidth - 20;
                          if (startX < 0) startX = 0;

                          setState(() {
                            _transcriptBoxPosition = Offset(startX, 20);
                            _showTranscript = true;
                          });
                        },
                        icon: const Icon(Icons.subject),
                        label: Text(_showTranscript ? "전체 자막 닫기" : "전체 자막 보기"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.cyan,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
