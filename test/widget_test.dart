import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_assistant/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // Stub the renderer only; tests never start screen or audio capture.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('FlutterWebRTC'), (
          call,
        ) async {
          if (call.method == 'createVideoRenderer') return {'textureId': 1};
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('FlutterWebRTC'), null);
  });
  testWidgets('microphone selector and full transcript remain available', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('마이크'));
    await tester.pumpAndSettle();
    expect(find.text('마이크소리 인식 시작'), findsOneWidget);
    await tester.tap(find.text('전체 자막 보기'));
    await tester.pumpAndSettle();
    expect(find.text('전체 자막'), findsOneWidget);
    await tester.tap(find.text('전체 자막 닫기'));
    await tester.pumpAndSettle();
    expect(find.text('전체 자막'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('existing controls and empty summary feedback remain', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('컴퓨터소리 인식 시작'), findsOneWidget);
    expect(find.text('강의자료 불러오기'), findsOneWidget);
    expect(find.text('중지'), findsOneWidget);
    expect(find.text('실시간 자막 프롬프트'), findsOneWidget);
    expect(find.text('AI 질문하기'), findsOneWidget);
    await tester.tap(find.text('AI 요약하기'));
    await tester.pumpAndSettle();
    expect(find.text('요약할 자막 내용이 없습니다.'), findsOneWidget);
    expect(find.text('AI 요약 결과'), findsOneWidget);
    await tester.tap(find.text('요약 닫기'));
    await tester.pumpAndSettle();
    expect(find.text('AI 요약 결과'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('question dialog validates input and reopens', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 질문하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('질문하기'));
    await tester.pumpAndSettle();
    expect(find.text('질문을 입력해주세요.'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '강의 내용은?',
    );
    await tester.tap(find.text('질문하기'));
    await tester.pumpAndSettle();
    expect(find.text('질문에 사용할 자막 내용이 없습니다.'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 질문하기'));
    await tester.pumpAndSettle();
    expect(find.text('질문을 입력한 뒤 질문하기 버튼을 눌러주세요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
