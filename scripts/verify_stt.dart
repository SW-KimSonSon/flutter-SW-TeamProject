import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:study_assistant/services/whisper_service.dart';

Future<void> main(List<String> args) async {
  final wav = await File(args.single).readAsBytes();
  final data = wav.buffer.asByteData();
  List<int>? pcm;
  for (var offset = 12; offset + 8 <= wav.length;) {
    final size = data.getUint32(offset + 4, Endian.little);
    if (ascii.decode(wav.sublist(offset, offset + 4)) == 'data') {
      pcm = wav.sublist(offset + 8, offset + 8 + size);
    }
    offset += 8 + size + size % 2;
  }
  if (pcm == null) throw StateError('Missing PCM data');
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  for (var run = 0; run < 2; run++) {
    final service = WhisperService(port: port);
    try {
      await service.start();
      final result = await service.transcribe(pcm, '인공지능, 컴퓨터');
      stdout.writeln(result);
      if (!result.contains('인공지능') || !result.contains('컴퓨터')) {
        throw StateError('Korean STT regression');
      }
    } finally {
      await service.close();
    }
    final freed = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await freed.close();
    stdout.writeln('Run ${run + 1}: STT passed, port released');
  }
}
