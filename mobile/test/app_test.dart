import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_hero/main.dart';

void main() {
  const channel = MethodChannel('com.filehero/storage');
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() { TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null); });
  testWidgets('starts disconnected and explains USB access', (tester) async {
    await tester.pumpWidget(const FileHeroApp());
    expect(find.text('file-hero'), findsOneWidget);
    expect(find.textContaining('选择要存入的文件'), findsOneWidget);
    expect(find.text('选择文件并存入 SSD'), findsOneWidget);
  });
  testWidgets('selects source files before destination and creates folder only after confirmation', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch(call.method) {
        case 'pickFiles': return ['photo.jpg', 'tickets.pdf'];
        case 'connect': return 'Portable SSD';
        case 'importSelected': return {'batch': '旅行资料', 'imported': 2};
        case 'list': return <Object>[];
        default: throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });
    await tester.pumpWidget(const FileHeroApp());
    await tester.tap(find.text('选择文件并存入 SSD'));
    await tester.pumpAndSettle();
    expect(calls.map((c) => c.method).toList(), ['pickFiles', 'connect']);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '旅行资料');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '照片与机票');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('准备存入 SSD'), findsOneWidget);
    expect(calls.where((c) => c.method == 'importSelected'), isEmpty);
    await tester.tap(find.text('新建文件夹并存入'));
    await tester.pumpAndSettle();
    final imported = calls.singleWhere((c) => c.method == 'importSelected');
    expect(imported.arguments['name'], '旅行资料');
    expect(imported.arguments['description'], '照片与机票');
    expect(imported.arguments['path'], '');
    expect(calls.last.arguments['path'], '旅行资料');
    expect(find.textContaining('已存入「旅行资料」'), findsOneWidget);
  });
  testWidgets('cancelling source picker does not open destination or write files', (tester) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async { calls.add(call.method); return null; });
    await tester.pumpWidget(const FileHeroApp());
    await tester.tap(find.text('选择文件并存入 SSD'));
    await tester.pumpAndSettle();
    expect(calls, ['pickFiles']);
    expect(find.text('已取消选择文件'), findsOneWidget);
  });
}
