import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_assistant/services/speech_segmenter.dart';

List<int> pcm(int milliseconds, int amplitude) {
  final data = ByteData(milliseconds * 48 * 2);
  for (var i = 0; i < data.lengthInBytes; i += 2) {
    data.setInt16(i, amplitude, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  test('silence and sub-300ms noise are discarded', () {
    final results = <List<int>>[];
    final vad = SpeechSegmenter(onUtterance: results.add);
    vad.add(pcm(1000, 0));
    vad.add(pcm(280, 2000));
    vad.add(pcm(500, 0));
    expect(results, isEmpty);
  });
  test('speech ends at 500ms silence and retains 400ms pre-roll', () {
    final results = <List<int>>[];
    final vad = SpeechSegmenter(onUtterance: results.add);
    vad.add(pcm(1000, 0));
    vad.add(pcm(300, 2000));
    vad.add(pcm(480, 0));
    expect(results, isEmpty);
    vad.add(pcm(20, 0));
    expect(results.single.length, 1200 * 96);
  });
  test('partial audio callbacks and input interruption preserve speech', () {
    var now = DateTime.utc(2026);
    final results = <List<int>>[];
    final vad = SpeechSegmenter(onUtterance: results.add, clock: () => now);
    final audio = pcm(320, 2000);
    vad.add(audio.sublist(0, 51));
    vad.add(audio.sublist(51));
    now = now.add(const Duration(milliseconds: 499));
    vad.checkTimeout();
    expect(results, isEmpty);
    now = now.add(const Duration(milliseconds: 1));
    vad.checkTimeout();
    vad.checkTimeout();
    expect(results.single, audio);
  });
  test('continuous speech splits at 20 seconds with 1 second overlap', () {
    final results = <List<int>>[];
    final vad = SpeechSegmenter(onUtterance: results.add);
    for (var i = 0; i < 1000; i++) {
      vad.add(pcm(20, 2000));
    }
    expect(results.single.length, 20000 * 96);
    vad.add(pcm(300, 2500));
    vad.add(pcm(500, 0));
    expect(results.length, 2);
    expect(results[1].length, 1800 * 96);
    expect(results[1].sublist(0, 1000 * 96), results[0].sublist(19000 * 96));
  });
  test('reset removes unfinished speech and noise state', () {
    final results = <List<int>>[];
    final vad = SpeechSegmenter(onUtterance: results.add);
    vad.add(pcm(400, 2000));
    vad.reset();
    vad.add(pcm(1000, 0));
    expect(results, isEmpty);
  });
  test('hallucination filter preserves sentences containing the phrase', () {
    expect(SpeechSegmenter.isHallucination('시청해주셔서 감사합니다. '), isTrue);
    expect(SpeechSegmenter.isHallucination('구독과 좋아요를 분석합니다.'), isFalse);
  });
  test('WAV header declares mono 48kHz signed PCM16', () {
    final header = ByteData.sublistView(
      Uint8List.fromList(SpeechSegmenter.wavHeader(96000)),
    );
    expect(header.getUint32(4, Endian.little), 96036);
    expect(header.getUint32(16, Endian.little), 16);
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 48000);
    expect(header.getUint16(34, Endian.little), 16);
    expect(header.getUint32(40, Endian.little), 96000);
  });
}
