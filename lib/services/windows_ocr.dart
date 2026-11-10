import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

abstract interface class PageOcr {
  Future<String> recognize(Uint8List bgra, int width, int height);
}

class WindowsOcr implements PageOcr {
  const WindowsOcr();

  String _workerPath() {
    final candidates = [
      '${File(Platform.resolvedExecutable).parent.path}/study_ocr.exe',
      '${Directory.current.path}/build/windows/x64/runner/Release/study_ocr.exe',
      '${Directory.current.path}/build/windows/x64/runner/Debug/study_ocr.exe',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    throw const FormatException(
      '자동 OCR 구성 파일을 찾을 수 없습니다. 최신 앱의 전체 배포 폴더를 사용해 주세요.',
    );
  }

  @override
  Future<String> recognize(Uint8List bgra, int width, int height) async {
    if (!Platform.isWindows) {
      throw const FormatException('이미지 PDF 자동 인식은 현재 Windows 앱에서 지원합니다.');
    }
    final process = await Process.start(_workerPath(), ['$width', '$height']);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      return await (() async {
        process.stdin.add(bgra);
        await process.stdin.close();
        final code = await process.exitCode;
        final text = await output;
        await errors;
        if (code == 3) {
          throw const FormatException(
            '이 Windows에 사용할 수 있는 OCR 언어가 없습니다. 이미지 PDF를 자동 인식할 수 없습니다.',
          );
        }
        if (code != 0) {
          throw const FormatException('페이지 이미지의 자동 문자 인식에 실패했습니다.');
        }
        return text.trim();
      })().timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw const FormatException('페이지 문자 인식 시간이 초과되었습니다. 더 선명한 PDF를 사용해 주세요.');
    } finally {
      process.kill();
      // Observe pipe completion even when the worker is interrupted.
      await output.catchError((_) => '');
      await errors.catchError((_) => '');
    }
  }
}
