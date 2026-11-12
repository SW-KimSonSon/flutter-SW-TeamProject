# Study Assistant

## 프로젝트 소개

Study Assistant는 강의 음성을 실시간 자막으로 변환하고, 자막을 바탕으로 AI 요약과 질문응답을 제공하는 Windows용 Flutter 졸업작품입니다. PDF 강의자료를 보조자료로 활용하며, 음성 인식과 AI 분석은 로컬 Whisper 및 Ollama 서버에서 처리합니다.

## 주요 기능

- **음성 인식(STT)**: 마이크 또는 컴퓨터 소리를 선택해 한국어 자막을 생성합니다.
- **화면 공유와 자막 보기**: 공유할 화면이나 창을 선택하고, 실시간 자막과 누적된 전체 자막을 확인합니다.
- **AI 요약·질문응답**: 강의 자막의 핵심 내용을 요약하고 강의 내용에 대한 질문에 답합니다.
- **강의자료 참고**: PDF·DOCX·PPTX·TXT에서 읽은 내용을 AI의 보조자료로 사용하고, 추출한 핵심 용어를 STT 프롬프트에 반영합니다.
- **긴 PDF 분할 분석**: 긴 자료를 구간별로 분석한 뒤 결과를 종합합니다.
- **이미지 PDF OCR**: 텍스트가 없는 PDF 페이지를 Windows 내장 OCR로 읽습니다. Poppler 설치는 필요하지 않습니다.

## 사용 기술

| 구분 | 기술 |
|---|---|
| 앱 | Flutter, Dart, Windows 데스크톱 |
| 화면·음성 입력 | flutter_webrtc, desktop_audio_capture, record |
| 음성 인식 | whisper.cpp 서버, large-v3-turbo 양자화 모델 |
| AI 요약·질문응답 | Ollama, Qwen2.5 3B |
| PDF·문서 처리 | pdfrx(PDFium), archive |
| 이미지 문자 인식 | Windows OCR, C++ 도우미 프로그램 |

## 설치 및 실행 방법

### 1. 개발 환경 준비

- Windows PC와 Flutter SDK를 준비합니다. 프로젝트의 Dart SDK 요구 버전은 `^3.11.1`입니다.
- Visual Studio의 **C++를 사용한 데스크톱 개발** 워크로드와 Windows SDK가 필요합니다.
- 현재 STT 설정은 CUDA 12.4용 Whisper 실행 파일을 사용합니다. 호환되는 NVIDIA GPU·드라이버 환경을 준비하세요.
- 마이크 입력을 사용하려면 Windows에서 데스크톱 앱의 마이크 접근을 허용하세요.

프로젝트 루트에서 개발 환경을 확인합니다.

```powershell
flutter doctor -v
flutter pub get
```

### 2. Whisper 실행 파일과 모델 준비

다음 구조로 파일을 배치합니다. 코드의 실행 경로와 파일명이 일치해야 합니다.

```text
study_assistant/
└─ whisper.cpp/
   ├─ whisper-cublas-12.4.0-bin-x64/
   │  └─ Release/
   │     ├─ whisper-server.exe
   │     └─ 함께 제공된 DLL 파일들
   └─ models/
      └─ ggml-large-v3-turbo-q5_0.bin
```

whisper.cpp , whisper-cublas-12.4.0-bin-x64/ : https://github.com/ggml-org/whisper.cpp/releases

ggml-large-v3-turbo-q5_0.bin : https://huggingface.co/ggerganov/whisper.cpp/tree/main

`whisper-server.exe`만 복사하지 말고 같은 실행 패키지의 DLL도 함께 준비하세요. 앱이 로컬 서버를 시작하며 주소는 `127.0.0.1:8080`입니다. 해당 포트를 다른 프로그램이 사용 중이면 실행할 수 없습니다.

### 3. Ollama와 AI 모델 준비

Windows용 Ollama를 설치하고 다음 명령으로 모델을 받습니다.

```powershell
ollama pull qwen2.5:3b
ollama list
```

Ollama를 실행한 상태에서 앱을 사용하세요. 기본 주소는 `http://localhost:11434`이며, 모델과 요청 한도는 `lib/config/ollama_config.dart`에 정의되어 있습니다.

### 4. 앱 실행

프로젝트 루트에서 실행합니다.

```powershell
flutter run -d windows
```

한글 경로에서 Windows 빌드 문제가 발생하면 제공된 스크립트를 사용할 수 있습니다.

```powershell
.\scripts\windows.ps1 -Action run
```

Flutter가 PATH에 없다면 `-FlutterPath "C:\경로\flutter\bin\flutter.bat"`를 추가하세요. OCR 도우미 `study_ocr.exe`는 Windows 앱 빌드 시 함께 생성됩니다.

### 5. 사용 순서

1. **컴퓨터 소리** 또는 **마이크**를 선택하고 음성 인식을 시작합니다.
2. 자막을 확인하고 **전체 자막 보기**로 누적 내용을 살펴봅니다.
3. 필요하면 **강의자료 불러오기**로 PDF 등의 자료를 선택합니다.
4. **AI 요약하기** 또는 **AI 질문하기**를 사용합니다. 자막이 주요 분석 대상이며 자료는 보조 근거로 활용됩니다.

## 참고사항

- 자료만 불러오고 자막이 없는 상태에서는 요약·질문응답을 실행할 수 없습니다.
- 자막과 질문의 합산 입력 한도는 기본 6,000자입니다. 긴 PDF 분할과 달리 긴 자막의 자동 분할은 지원하지 않습니다. 입력 공간이 부족하면 PDF 보조 근거를 추가하지 않고 자막만 분석합니다.
- 이미지 PDF 인식에는 Windows OCR 언어 지원이 필요합니다. 한국어 엔진을 우선 사용하며, 없으면 사용자 언어 설정의 엔진을 시도합니다. 흐리거나 복잡한 문서는 인식 결과가 부정확할 수 있습니다.
- 패키지·실행 파일·모델은 실행 전에 준비해야 합니다. 앱은 누락된 Whisper나 Qwen 모델을 자동으로 다운로드하지 않습니다.
- STT, OCR, AI 응답의 속도와 정확도는 PC 사양 및 입력 품질에 따라 달라집니다. AI가 생성한 내용은 강의 자막과 자료를 대조해 확인하세요.
