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
  late List<MethodCall> calls;
  late bool shared, fail, cancelPicker;
  String? target;
  setUp(() {
    calls = []; shared = false; fail = false; cancelPicker = false; target = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch(call.method) {
        case 'takeSharedFiles': if(!shared) return null; shared = false; return ['photo.jpg'];
        case 'restoreTarget': return target;
        case 'connect': return cancelPicker ? null : '旅行资料';
        case 'importSelected':
          if(fail) { fail = false; throw PlatformException(code: 'ERROR', message: '已有同名文件'); }
          return {'batch': '旅行资料', 'imported': 1, 'path': call.arguments['existing'] == true ? '' : '旅行资料', 'warning': ''};
        case 'list': return [{'name': '旅行批次', 'directory': true, 'size': 2048, 'fileCount': 2, 'modified': '2026-09-23T10:00:00Z', 'metadata': {'Description': '京都照片和票据'}}];
        case 'thumbnail': return null;
        default: throw PlatformException(code: 'UNEXPECTED', message: call.method);
      }
    });
  });
  tearDown(() { TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null); });
  testWidgets('home only explains sharing and removes old actions', (tester) async {
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    expect(find.byIcon(Icons.usb), findsNothing);
    expect(find.text('选择文件并存入 SSD'), findsNothing);
    expect(find.textContaining('点击分享 → File Hero'), findsOneWidget);
    expect(calls.where((c) => c.method == 'connect'), isEmpty);
  });
  testWidgets('restores folders with cover left and description right', (tester) async {
    target = 'SSD'; await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    expect(find.text('2 个文件 · 2.0 KB'), findsOneWidget);
    expect(tester.getRect(find.byKey(const ValueKey('preview-旅行批次'))).right, lessThan(tester.getRect(find.text('京都照片和票据')).left));
  });
  testWidgets('new folder sends name description and explicit new mode', (tester) async {
    target = 'SSD'; shared = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.enterText(find.byKey(const ValueKey('share-name')), '旅行资料');
    await tester.enterText(find.byKey(const ValueKey('share-description')), '照片票据');
    await tester.tap(find.text('存入')); await advance(tester);
    final data = calls.singleWhere((c) => c.method == 'importSelected').arguments;
    expect(data['existing'], false); expect(data['name'], '旅行资料'); expect(data['description'], '照片票据');
    expect(calls.where((c) => c.method == 'connect' || c.method == 'pickFiles'), isEmpty);
  });
  testWidgets('existing mode requires selected folder and imports directly', (tester) async {
    target = 'SSD'; shared = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.text('已有文件夹')); await advance(tester);
    expect(find.byKey(const ValueKey('share-name')), findsNothing);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '存入')).onPressed, isNull);
    await tester.tap(find.text('选择已有文件夹')); await advance(tester);
    expect(find.text('目标：旅行资料'), findsOneWidget);
    await tester.tap(find.text('存入')); await advance(tester);
    final data = calls.singleWhere((c) => c.method == 'importSelected').arguments;
    expect(data['existing'], true); expect(data['path'], ''); expect(data['description'], '');
    expect(calls.lastWhere((c) => c.method == 'list').arguments['path'], '');
  });
  testWidgets('warm share allows destination cancellation without writes', (tester) async {
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    shared = true; cancelPicker = true;
    tester.binding.channelBuffers.push(channel.name, const StandardMethodCodec().encodeMethodCall(const MethodCall('shareAvailable')), (_) {});
    await advance(tester);
    await tester.tap(find.text('选择存放位置')); await advance(tester);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '存入')).onPressed, isNull);
    await tester.tap(find.text('取消')); await advance(tester);
    expect(calls.where((c) => c.method == 'importSelected'), isEmpty);
  });
  testWidgets('conflict keeps shared files available for retry', (tester) async {
    shared = true; target = 'SSD'; fail = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.text('存入')); await advance(tester);
    expect(find.text('已有同名文件'), findsOneWidget);
    await tester.tap(find.text('重新选择')); await advance(tester);
    await tester.enterText(find.byKey(const ValueKey('share-name')), '不同名称');
    await tester.tap(find.text('存入')); await advance(tester);
    expect(calls.where((c) => c.method == 'importSelected').length, 2);
    expect(find.textContaining('已存入「旅行资料」'), findsOneWidget);
  });
}
