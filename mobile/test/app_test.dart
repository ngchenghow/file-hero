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
  setUp(() { TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => null); });
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
      if(call.method == 'takeSharedFiles') return null;
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
    await advance(tester);
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async { if(call.method != 'takeSharedFiles') { calls.add(call.method); } return null; });
    await tester.pumpWidget(const FileHeroApp());
    await advance(tester);
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
    await advance(tester);
    await tester.tap(find.byTooltip('选择 SSD / 文件夹'));
    await advance(tester);
    expect(find.text('京都旅行的照片和票据'), findsOneWidget);
    expect(find.text('2 个文件 · 2.0 KB'), findsOneWidget);
    expect(thumbnails, ['旅行批次']);
    final cover = tester.getRect(find.byKey(const ValueKey('preview-旅行批次')));
    final description = tester.getRect(find.text('京都旅行的照片和票据'));
    expect(cover.right, lessThan(description.left));
  });
  testWidgets('cold share reuses SSD and saves without reopening file picker', (tester) async {
    var available = true;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if(call.method == 'takeSharedFiles') { if(!available) return null; available = false; return ['photo.jpg', 'ticket.pdf']; }
      if(call.method == 'restoreTarget') return 'My SSD';
      if(call.method == 'importSelected') { return {'batch': '分享照片', 'imported': 2}; }
      if(call.method == 'list') return <Object>[];
      return null;
    });
    await tester.pumpWidget(const FileHeroApp());
    await advance(tester);
    expect(find.text('分享文件存入 SSD'), findsOneWidget);
    expect(find.text('目标：My SSD'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('share-name')), '分享照片');
    await tester.enterText(find.byKey(const ValueKey('share-description')), '手机分享的照片');
    await tester.tap(find.text('存入'));
    await advance(tester);
    expect(calls.where((c) => c.method == 'pickFiles' || c.method == 'connect'), isEmpty);
    final imported = calls.singleWhere((c) => c.method == 'importSelected');
    expect(imported.arguments['name'], '分享照片');
    expect(imported.arguments['description'], '手机分享的照片');
    expect(find.textContaining('已存入分享批次'), findsOneWidget);
  });
  testWidgets('warm share requests missing SSD authorization and can be cancelled', (tester) async {
    var available = false;
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if(call.method == 'takeSharedFiles') { if(!available) return null; available = false; return ['shared.pdf']; }
      if(call.method == 'connect') return 'New SSD';
      if(call.method == 'list') return <Object>[];
      return null;
    });
    await tester.pumpWidget(const FileHeroApp());
    await advance(tester);
    available = true;
    tester.binding.channelBuffers.push(channel.name, const StandardMethodCodec().encodeMethodCall(const MethodCall('shareAvailable')), (_) {});
    await advance(tester);
    expect(find.text('分享文件存入 SSD'), findsOneWidget);
    expect(methods, contains('connect'));
    expect(methods, isNot(contains('pickFiles')));
    await tester.tap(find.text('取消'));
    await advance(tester);
    expect(methods, isNot(contains('importSelected')));
    expect(find.textContaining('已取消分享存入'), findsOneWidget);
  });
}

