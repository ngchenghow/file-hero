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
  late bool shared, fail, cancelPicker, deleted, fileMode, deleteFails;
  late int shareErrors, queued;
  late bool ssdMissing, pickInternal;
  String? target;
  setUp(() {
    shareErrors = 0; queued = 0; ssdMissing = false; pickInternal = false; deleted = false; fileMode = false; deleteFails = false; calls = []; shared = false; fail = false; cancelPicker = false; target = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch(call.method) {
        case 'takeSharedFiles':
          if(!shared) return null;
          if(shareErrors > 0) { shareErrors--; throw PlatformException(code: 'SHARE', message: '无法读取源文件', details: true); }
          shared = false; return {'files': ['photo.jpg'], 'pending': queued};
        case 'discardShare': shared = false; return 0;
        case 'ssdStatus': return {'state': ssdMissing ? 'missing' : target == null ? 'unauthorized' : 'ready', 'name': target ?? '', 'other': false};
        case 'restoreTarget': return ssdMissing ? null : target;
        case 'connect': if(pickInternal) { pickInternal = false; throw PlatformException(code: 'STORAGE', message: '所选位置不在 USB SSD 上'); } return cancelPicker ? null : '旅行资料';
        case 'importSelected':
          if(fail) { fail = false; throw PlatformException(code: 'ERROR', message: '已有同名文件'); }
          return {'batch': '旅行资料', 'imported': 1, 'path': call.arguments['existing'] == true ? '' : '旅行资料', 'warning': ''};
        case 'delete':
          if(deleteFails) { return {'deleted': false, 'warning': '设备拒绝删除'}; }
          deleted = true; return {'deleted': true, 'warning': ''};
        case 'list': if(deleted) return <Object>[]; return [{'name': fileMode ? 'photo.jpg' : '旅行批次', 'directory': !fileMode, 'size': 2048, 'fileCount': 2, 'modified': '2026-09-23T10:00:00Z', 'metadata': {'Description': '京都照片和票据'}}];
        case 'search': return [{'name': '京都.jpg', 'path': '旅行批次/第一天/京都.jpg', 'directory': false, 'size': 1024, 'modified': '2026-09-23T10:00:00Z', 'metadata': {'Description': '清水寺'}}, {'name': '第一天', 'path': '旅行批次/第一天', 'directory': true, 'size': 1024, 'fileCount': 1, 'modified': '2026-09-23T10:00:00Z', 'metadata': {}}];
        case 'thumbnail': return null;
        case 'open': return true;
        case 'export': if(cancelPicker) return null; return call.arguments['directory'] == true ? {'name': '旅行批次 (2)', 'files': 5} : true;
        case 'send': return {'via': call.arguments['via'], 'files': call.arguments['directory'] == true ? 3 : 1};
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
  testWidgets('folders show a folder icon beside the title and files do not', (tester) async {
    target = 'SSD'; await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    expect(tester.getRect(find.byKey(const ValueKey('folder-icon'))).right, lessThanOrEqualTo(tester.getRect(find.text('旅行批次')).left));
    fileMode = true; await tester.tap(find.byTooltip('刷新')); await advance(tester);
    expect(find.byKey(const ValueKey('folder-icon')), findsNothing);
  });
  testWidgets('search looks through all subfolders and opens results by full path', (tester) async {
    target = 'SSD'; await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.enterText(find.byType(TextField).first, '京都'); await advance(tester);
    expect(calls.lastWhere((c) => c.method == 'search').arguments, {'path': '', 'query': '京都'});
    expect(find.text('京都.jpg'), findsOneWidget);
    expect(find.text('位于：旅行批次/第一天'), findsOneWidget);
    expect(find.text('旅行批次'), findsNothing);
    await tester.tap(find.text('第一天')); await advance(tester);
    expect(calls.lastWhere((c) => c.method == 'list').arguments['path'], '旅行批次/第一天');
    expect(find.text('旅行批次'), findsOneWidget);
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
    expect(find.text('选择存放位置'), findsNothing);
    await tester.tap(find.text('存入')); await advance(tester);
    expect(find.text('授权 SSD'), findsOneWidget);
    await tester.tap(find.text('开始授权')); await advance(tester);
    expect(calls.where((c) => c.method == 'connect').length, 1);
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
  testWidgets('cancel delete never sends destructive request', (tester) async {
    target = 'SSD'; await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.byTooltip('删除 旅行批次')); await advance(tester);
    expect(find.textContaining('所有文件和子文件夹'), findsOneWidget);
    expect(calls.where((c) => c.method == 'delete'), isEmpty);
    await tester.tap(find.text('取消')); await advance(tester);
    expect(calls.where((c) => c.method == 'delete'), isEmpty);
    expect(find.text('旅行批次'), findsOneWidget);
  });
  testWidgets('confirmed folder deletion sends exact path and refreshes', (tester) async {
    target = 'SSD'; await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.byTooltip('删除 旅行批次')); await advance(tester);
    await tester.tap(find.text('永久删除')); await advance(tester);
    final data = calls.singleWhere((c) => c.method == 'delete').arguments;
    expect(data['path'], '旅行批次'); expect(data['directory'], true);
    expect(find.text('旅行批次'), findsNothing);
    expect(find.textContaining('已删除「旅行批次」'), findsOneWidget);
  });
  testWidgets('file deletion uses file type and confirmation', (tester) async {
    target = 'SSD'; fileMode = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.byTooltip('删除 photo.jpg')); await advance(tester);
    expect(find.text('删除文件？'), findsOneWidget);
    await tester.tap(find.text('永久删除')); await advance(tester);
    final data = calls.singleWhere((c) => c.method == 'delete').arguments;
    expect(data['path'], 'photo.jpg'); expect(data['directory'], false);
    expect(find.text('photo.jpg'), findsNothing);
  });
  testWidgets('failed deletion retains item and reports failure', (tester) async {
    target = 'SSD'; deleteFails = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.byTooltip('删除 旅行批次')); await advance(tester);
    await tester.tap(find.text('永久删除')); await advance(tester);
    expect(find.text('旅行批次'), findsOneWidget);
    expect(find.text('删除未完成：设备拒绝删除'), findsOneWidget);
  });

  testWidgets('new mode restores root after choosing existing folder', (tester) async {
    target = 'SSD 根目录'; shared = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.text('已有文件夹')); await advance(tester);
    await tester.tap(find.text('选择已有文件夹')); await advance(tester);
    expect(calls.lastWhere((c) => c.method == 'connect').arguments['existing'], true);
    await tester.tap(find.text('新建文件夹')); await advance(tester);
    expect(find.text('选择存放位置'), findsNothing);
    await tester.tap(find.text('存入')); await advance(tester);
    final index = calls.indexWhere((c) => c.method == 'importSelected');
    expect(calls[index - 1].method, 'restoreTarget');
    expect(calls[index].arguments['path'], '');
    expect(calls[index].arguments['existing'], false);
  });

  testWidgets('unreadable share shows dialog and can be retried', (tester) async {
    target = 'SSD'; shared = true; shareErrors = 1;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    expect(find.text('无法接收这次分享'), findsOneWidget);
    expect(find.text('无法读取源文件'), findsOneWidget);
    await tester.tap(find.text('重试')); await advance(tester);
    expect(find.text('分享文件存入 SSD'), findsOneWidget);
    expect(calls.where((c) => c.method == 'discardShare'), isEmpty);
  });
  testWidgets('unreadable share can be discarded explicitly', (tester) async {
    target = 'SSD'; shared = true; shareErrors = 1;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.text('放弃这批')); await advance(tester);
    expect(calls.where((c) => c.method == 'discardShare').length, 1);
    expect(find.text('分享文件存入 SSD'), findsNothing);
    expect(find.text('已放弃无法读取的分享，未存入任何文件'), findsOneWidget);
  });
  testWidgets('share dialog tells user about queued shares', (tester) async {
    target = 'SSD'; shared = true; queued = 2;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    expect(find.text('另有 2 批分享在排队，处理完这批后会继续'), findsOneWidget);
  });
  testWidgets('missing SSD stops share before choosing a folder', (tester) async {
    target = 'SSD'; shared = true; ssdMissing = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    expect(find.text('未检测到 SSD'), findsOneWidget);
    expect(find.text('分享文件存入 SSD'), findsNothing);
    await tester.tap(find.text('放弃这批')); await advance(tester);
    expect(find.text('未检测到 SSD，已停止存入，未存入任何文件'), findsOneWidget);
    expect(calls.where((c) => c.method == 'connect' || c.method == 'importSelected'), isEmpty);
  });
  testWidgets('plugging SSD in and retrying continues the share', (tester) async {
    target = 'SSD'; shared = true; ssdMissing = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    ssdMissing = false;
    await tester.tap(find.text('重试')); await advance(tester);
    expect(find.text('分享文件存入 SSD'), findsOneWidget);
  });
  testWidgets('SSD unplugged while dialog is open stops before writing', (tester) async {
    target = 'SSD'; shared = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    ssdMissing = true;
    await tester.tap(find.text('存入')); await advance(tester);
    expect(find.text('未检测到 SSD'), findsOneWidget);
    await tester.tap(find.text('放弃这批')); await advance(tester);
    expect(calls.where((c) => c.method == 'importSelected'), isEmpty);
  });
  testWidgets('picking a folder outside the SSD is explained and retried', (tester) async {
    target = 'SSD'; shared = true; pickInternal = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.text('已有文件夹')); await advance(tester);
    await tester.tap(find.text('选择已有文件夹')); await advance(tester);
    expect(find.text('所选位置不在 USB SSD 上'), findsOneWidget);
    await tester.tap(find.text('重新选择')); await advance(tester);
    expect(find.text('分享文件存入 SSD'), findsOneWidget);
    expect(calls.where((c) => c.method == 'importSelected'), isEmpty);
  });
  testWidgets('first authorization explains root selection and file-hero folder', (tester) async {
    shared = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    expect(find.textContaining('file-hero 文件夹中'), findsOneWidget);
    await tester.tap(find.text('存入')); await advance(tester);
    expect(find.textContaining('停在 SSD 最上层（根目录）'), findsOneWidget);
    expect(find.textContaining('自动在 SSD 根目录建立 file-hero 文件夹'), findsOneWidget);
    expect(calls.where((c) => c.method == 'connect'), isEmpty);
    await tester.tap(find.text('开始授权')); await advance(tester);
    final data = calls.singleWhere((c) => c.method == 'connect').arguments;
    expect(data['existing'], false);
    expect(calls.where((c) => c.method == 'importSelected').length, 1);
  });
  testWidgets('cancelling the authorization explanation never opens the picker', (tester) async {
    shared = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.text('存入')); await advance(tester);
    await tester.tap(find.text('取消').last); await advance(tester);
    expect(calls.where((c) => c.method == 'connect'), isEmpty);
    expect(find.text('分享文件存入 SSD'), findsOneWidget);
  });
  testWidgets('folder can be sent over Bluetooth', (tester) async {
    target = 'SSD'; await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.byTooltip('导出 旅行批次')); await advance(tester);
    expect(find.textContaining('包括说明 file-readme.txt'), findsOneWidget);
    await tester.tap(find.text('蓝牙发送')); await advance(tester);
    final data = calls.singleWhere((c) => c.method == 'send').arguments;
    expect(data['path'], '旅行批次'); expect(data['directory'], true); expect(data['via'], 'bluetooth');
    expect(find.textContaining('已打开蓝牙发送（3 个文件）'), findsOneWidget);
  });
  testWidgets('folder export copies the whole folder to a picked location', (tester) async {
    target = 'SSD'; await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.byTooltip('导出 旅行批次')); await advance(tester);
    await tester.tap(find.text('导出文件夹副本')); await advance(tester);
    expect(calls.lastWhere((c) => c.method == 'export').arguments, {'path': '旅行批次', 'directory': true});
    expect(find.text('已导出文件夹「旅行批次 (2)」（5 个文件）'), findsOneWidget);
    cancelPicker = true;
    await tester.tap(find.byTooltip('导出 旅行批次')); await advance(tester);
    await tester.tap(find.text('导出文件夹副本')); await advance(tester);
    expect(find.text('已取消导出'), findsOneWidget);
  });
  testWidgets('file export sheet offers Bluetooth and other senders', (tester) async {
    target = 'SSD'; fileMode = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.text('photo.jpg')); await advance(tester);
    await tester.ensureVisible(find.text('蓝牙导出到其他设备'));
    await tester.tap(find.text('蓝牙导出到其他设备')); await advance(tester);
    await tester.tap(find.text('其他方式发送')); await advance(tester);
    final data = calls.singleWhere((c) => c.method == 'send').arguments;
    expect(data['path'], 'photo.jpg'); expect(data['directory'], false); expect(data['via'], 'chooser');
  });
  testWidgets('file detail opens the SSD file in a phone app', (tester) async {
    target = 'SSD'; fileMode = true;
    await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    await tester.tap(find.text('photo.jpg')); await advance(tester);
    await tester.tap(find.text('打开')); await advance(tester);
    expect(calls.singleWhere((c) => c.method == 'open').arguments['path'], 'photo.jpg');
    expect(find.text('已打开「photo.jpg」'), findsOneWidget);
  });
  testWidgets('sending stops when SSD is missing', (tester) async {
    target = 'SSD'; await tester.pumpWidget(const FileHeroApp()); await advance(tester);
    ssdMissing = true;
    await tester.tap(find.byTooltip('导出 旅行批次')); await advance(tester);
    await tester.tap(find.text('蓝牙发送')); await advance(tester);
    expect(calls.where((c) => c.method == 'send'), isEmpty);
    expect(find.text('未检测到 SSD，无法发送。请连接 SSD 后重试。'), findsOneWidget);
  });
}
