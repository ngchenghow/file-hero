import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_hero/main.dart';

Future<void> advance(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) { await tester.pump(const Duration(milliseconds: 500)); }
}

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
    await advance(tester);
    expect(calls.map((c) => c.method).toList(), ['pickFiles', 'connect']);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '旅行资料');
    await tester.tap(find.text('保存'));
    await advance(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await advance(tester);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '照片与机票');
    await tester.tap(find.text('保存'));
    await advance(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await advance(tester);
    expect(find.text('准备存入 SSD'), findsOneWidget);
    expect(calls.where((c) => c.method == 'importSelected'), isEmpty);
    await tester.tap(find.text('新建文件夹并存入'));
    await advance(tester);
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
    await advance(tester);
    expect(calls, ['pickFiles']);
    expect(find.text('已取消选择文件'), findsOneWidget);
  });
  testWidgets('batch folder has a cover on the left and description on the right', (tester) async {
    final thumbnails = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if(call.method == 'connect') return 'SSD';
      if(call.method == 'thumbnail') { thumbnails.add(call.arguments['path'] as String); return null; }
      if(call.method == 'list') { return [{'name': '旅行批次', 'directory': true, 'size': 2048, 'fileCount': 2, 'modified': '2026-09-23T10:00:00Z', 'metadata': {'Description': '京都旅行的照片和票据'}}]; }
      return null;
    });
    await tester.pumpWidget(const FileHeroApp());
    await tester.tap(find.byTooltip('选择 SSD / 文件夹'));
    await advance(tester);
    expect(find.text('京都旅行的照片和票据'), findsOneWidget);
    expect(find.text('2 个文件 · 2.0 KB'), findsOneWidget);
    expect(thumbnails, ['旅行批次']);
    final cover = tester.getRect(find.byKey(const ValueKey('preview-旅行批次')));
    final description = tester.getRect(find.text('京都旅行的照片和票据'));
    expect(cover.right, lessThan(description.left));
  });
}

