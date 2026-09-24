import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const FileHeroApp());

class FileHeroApp extends StatelessWidget {
  const FileHeroApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'File Hero', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff237859)), useMaterial3: true, scaffoldBackgroundColor: const Color(0xfff5f7fa)),
    home: const FilesPage(),
  );
}

class FilesPage extends StatefulWidget {
  const FilesPage({super.key});
  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  static const channel = MethodChannel('com.filehero/storage');
  bool connected = false, busy = false;
  String folder = '', driveName = '', query = '', message = idleMessage;
  static const idleMessage = '从相册或文件管理器分享文件到 File Hero。';
  List<Map<String, dynamic>> entries = [], results = [];
  final searchText = TextEditingController();
  Timer? searchTimer;
  final Map<String, Future<Uint8List?>> thumbnails = {};
  bool checkingShares = false, sharePending = false;
  final queuedShares = ValueNotifier<int>(0);
  @override
  void initState() {
    super.initState();
    channel.setMethodCallHandler((event) async {
      if(event.method == 'shareAvailable') {
        queuedShares.value = event.arguments as int? ?? queuedShares.value + 1;
        if(busy && mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('收到新的分享，完成当前操作后会继续'))); }
        sharePending = true; await checkShares();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) { if(mounted) { sharePending = true; checkShares(); } });
  }
  @override
  void dispose() { channel.setMethodCallHandler(null); searchTimer?.cancel(); searchText.dispose(); queuedShares.dispose(); super.dispose(); }
  Future<void> checkShares() async {
    if(!mounted || busy || checkingShares) return;
    checkingShares = true; sharePending = false;
    final previousMessage = message;
    await work(() async {
      Map? taken;
      try { taken = await call('takeSharedFiles') as Map?; }
      on PlatformException catch(e) { await shareFailed(e); return; }
      if(!mounted) return;
      if(taken == null) {
        queuedShares.value = 0;
        if(!connected) {
          final status = await call('ssdStatus') as Map?;
          if(!mounted) return;
          if(status?['state'] == 'missing') { setState(() => message = previousMessage == idleMessage ? '未检测到 SSD。请用 USB 连接 SSD 后再分享文件。' : previousMessage); return; }
          final target = await call('restoreTarget') as String?;
          if(!mounted) return;
          if(target != null) { setState(() { connected = true; driveName = target; }); await load(''); }
        }
        if(mounted) { setState(() => message = previousMessage); }
        return;
      }
      queuedShares.value = taken['pending'] as int? ?? 0;
      sharePending = true;
      await saveShared((taken['files'] as List).cast<String>());
    });
    checkingShares = false;
    if(mounted && sharePending) { Future<void>.microtask(checkShares); }
  }
  // The failed batch stays queued natively until the user retries or discards it.
  Future<void> shareFailed(PlatformException e) async {
    if(!mounted) return;
    final retryable = e.details == true || e.code == 'BUSY';
    final retry = await showDialog<bool>(context: context, barrierDismissible: false, builder: (context) => AlertDialog(
      title: const Text('无法接收这次分享'),
      content: Text(e.message ?? '分享的文件无法读取'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('放弃这批')), if(retryable) FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('重试'))],
    ));
    if(!mounted) return;
    if(retry != true) {
      queuedShares.value = await call('discardShare') as int? ?? 0;
      if(mounted) { setState(() => message = '已放弃无法读取的分享，未存入任何文件'); }
    }
    sharePending = true;
  }
  // Stops the share flow while the SSD is not plugged in; returns null when the user gives up.
  Future<Map<String,dynamic>?> ensureSsd() async {
    while(true) {
      final status = Map<String,dynamic>.from(await call('ssdStatus') as Map);
      if(!mounted) return null;
      if(status['state'] != 'missing') return status;
      setState(() { connected = false; driveName = ''; folder = ''; clearSearch(); entries = []; thumbnails.clear(); message = '未检测到 SSD，已暂停存入'; });
      final choice = await showDialog<String>(context: context, barrierDismissible: false, builder: (context) => AlertDialog(
        title: const Text('未检测到 SSD'),
        content: const Text('没有找到已授权的 USB SSD，存入已暂停，不会把文件存到手机里。\n\n1. 用 USB 线或转接头连接 SSD\n2. 等通知栏出现 USB 存储，或文件管理器能看到 SSD\n3. 点「重试」\n\n在你放弃之前，分享的文件会一直保留。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('放弃这批')),
          if(status['other'] == true) TextButton(onPressed: () => Navigator.pop(context, 'other'), child: const Text('改用其他 SSD')),
          FilledButton(onPressed: () => Navigator.pop(context, 'retry'), child: const Text('重试')),
        ],
      ));
      if(!mounted || choice == null || choice == 'cancel') return null;
      if(choice == 'other') return {...status, 'state': 'unauthorized'};
    }
  }
  Future<String?> authorize(bool existing) async {
    if(!existing) {
      // SSD authorization goes through the system picker; explain exactly what to tap before opening it.
      final start = await showDialog<bool>(context: context, barrierDismissible: false, builder: (context) => AlertDialog(
        title: const Text('授权 SSD'),
        content: const Text('第一次使用需要授权 File Hero 访问 SSD。接下来会打开系统的文件夹选择界面：\n\n1. 确认界面显示的是你的 SSD；如果不是，点左上角 ☰ 菜单选择 SSD\n2. 停在 SSD 最上层（根目录），不要进入任何文件夹\n3. 点底部「使用此文件夹」，再点「允许」\n\nFile Hero 会自动在 SSD 根目录建立 file-hero 文件夹，所有文件都存放在里面。'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('开始授权'))],
      ));
      if(!mounted || start != true) return null;
    }
    try { return await call('connect', {'existing': existing}) as String?; }
    on PlatformException catch(e) {
      if(mounted) { await showDialog<void>(context: context, builder: (context) => AlertDialog(title: const Text('无法使用所选位置'), content: Text(e.message ?? '请选择 USB SSD 上的文件夹'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('重新选择'))])); }
      return null;
    }
  }
  Future<void> saveShared(List<String> picked) async {
    if(await ensureSsd() == null) { if(mounted) { setState(() => message = '未检测到 SSD，已停止存入，未存入任何文件'); } return; }
    final target = await call('restoreTarget') as String?;
    if(!mounted) return;
    setState(() { connected = target != null; driveName = target ?? ''; folder = ''; clearSearch(); entries = []; thumbnails.clear(); });
    var name = '分享-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-').split('.').first}';
    var description = '', mode = 'new';
    var existingReady = false;
    while(true) {
      if(!mounted) return;
      final form = await showDialog<Map<String,String>>(context: context, builder: (context) => _ShareSaveDialog(target: driveName, initialName: name, initialDescription: description, initialMode: mode, existingReady: existingReady, count: picked.length, queued: queuedShares));
      if(!mounted) return;
      if(form == null) {
        if(connected) { await load(''); }
        if(mounted) { setState(() => message = '已取消分享存入，未存入任何文件'); }
        return;
      }
      name = form['name']!; description = form['description']!; mode = form['mode']!;
      existingReady = form['existingReady'] == 'true';
      if(await ensureSsd() == null) { if(mounted) { setState(() => message = '未检测到 SSD，已停止存入，未存入任何文件'); } return; }
      if(form['action'] == 'target') {
        final changed = await authorize(mode == 'existing');
        if(!mounted) return;
        if(changed != null) {
          existingReady = mode == 'existing';
          setState(() { connected = true; driveName = changed; folder = ''; clearSearch(); entries = []; });
        }
        continue;
      }
      if(mode == 'new') {
        final rootTarget = await call('restoreTarget') as String?;
        if(!mounted) return;
        if(rootTarget == null) {
          final authorized = await authorize(false);
          if(!mounted) return;
          if(authorized == null) { continue; }
          setState(() { connected = true; driveName = authorized; });
        } else { setState(() { connected = true; driveName = rootTarget; }); }
      }
      setState(() => message = '正在存入 ${picked.length} 个文件，请勿拔盘…');
      dynamic result;
      try {
        result = await call('importSelected', {'path': '', 'existing': mode == 'existing', 'name': name.trim(), 'description': mode == 'existing' ? '' : description.replaceAll(RegExp(r'[\r\n]+'), ' ')});
      } on PlatformException catch(e) {
        if(!mounted) return;
        await showDialog<void>(context: context, builder: (context) => AlertDialog(title: const Text('未能存入'), content: Text(e.message ?? '请重新选择目标文件夹'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('重新选择'))]));
        continue;
      }
      await load(result['path'] as String);
      if(mounted) { setState(() => message = '已存入「${result['batch']}」：${result['imported']} 个文件；说明已更新。${result['warning'] ?? ''}'); }
      return;
    }
  }
  String child(String name) => folder.isEmpty ? name : '$folder/$name';
  // Search results carry their full path; entries of the current folder only have a name.
  String pathOf(Map<String,dynamic> file) => file['path'] as String? ?? child(file['name'] as String);
  void clearSearch() { searchTimer?.cancel(); searchText.clear(); query = ''; results = []; }
  void search(String value) {
    setState(() { query = value; if(value.trim().isEmpty) results = []; });
    searchTimer?.cancel();
    if(value.trim().isNotEmpty) searchTimer = Timer(const Duration(milliseconds: 350), () => work(runSearch));
  }
  Future<void> runSearch() async {
    final text = query.trim();
    if(text.isEmpty) return;
    final data = await call('search', {'query': text}) as List;
    if(mounted && text == query.trim()) { setState(() { results = data.map((e) => Map<String,dynamic>.from(e as Map)).toList(); message = '在「${folder.isEmpty ? '我的 SSD' : folder}」及所有子文件夹找到 ${results.length} 个项目${results.length >= 500 ? '（仅显示前 500 个）' : ''}'; }); }
  }
  String size(int n) { if(n < 1024) return '$n B'; if(n < 1048576) return '${(n/1024).toStringAsFixed(1)} KB'; if(n < 1073741824) return '${(n/1048576).toStringAsFixed(1)} MB'; return '${(n/1073741824).toStringAsFixed(1)} GB'; }
  Future<dynamic> call(String method, [Map<String, dynamic> values = const {}]) => channel.invokeMethod(method, {'path': folder, ...values});
  Future<void> work(Future<void> Function() action) async {
    if(busy) return;
    setState(() { busy = true; message = '正在处理，请勿拔出 SSD…'; });
    try { await action(); } on PlatformException catch(e) { if(mounted) setState(() => message = '操作未完成：${e.message}'); }
    catch(e) { if(mounted) setState(() => message = '操作未完成：$e'); }
    finally {
      if(mounted) { setState(() => busy = false); }
      if(mounted && sharePending && !checkingShares) { Future<void>.microtask(checkShares); }
    }
  }
  Future<void> load([String? target]) async {
    final path = target ?? folder;
    final data = await call('list', {'path': path}) as List;
    if(!mounted) return;
    final moved = path != folder;
    setState(() { if(moved) clearSearch(); folder = path; thumbnails.clear(); entries = data.map((e) => Map<String,dynamic>.from(e as Map)).toList(); message = '${entries.length} 个项目'; });
    if(!moved && query.trim().isNotEmpty) await runSearch();
  }
  Future<String?> textPrompt(String title, {String initial = ''}) async {
    return showDialog<String>(context: context, builder: (context) => _TextPromptDialog(title: title, initial: initial));
  }
  Future<void> deleteEntry(Map<String,dynamic> file) async {
    final name = file['name'] as String;
    final path = pathOf(file);
    final directory = file['directory'] == true;
    await work(() async {
      final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: Text(directory ? '删除文件夹？' : '删除文件？'),
        content: Text('「$name」\n\n${directory ? '此文件夹及其中所有文件和子文件夹都会永久删除。' : '此文件将永久删除。'}此操作无法撤销。${name.toLowerCase() == 'file-readme.txt' ? '\n删除说明文件会丢失本批描述和历史记录。' : ''}'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error), onPressed: () => Navigator.pop(context, true), child: const Text('永久删除'))],
      ));
      if(!mounted) return;
      if(confirmed != true) { setState(() => message = '已取消删除'); return; }
      final result = await call('delete', {'path': path, 'directory': directory});
      await load();
      if(mounted) { setState(() => message = result['deleted'] == true ? '已删除「$name」。${result['warning'] ?? ''}' : '删除未完成：${result['warning']}'); }
    });
  }
  Future<void> detail(Map<String,dynamic> file) async {
    final meta = Map<String,dynamic>.from(file['metadata'] as Map? ?? {});
    final action = await showModalBottomSheet<String>(context: context, isScrollControlled: true, builder: (context) => SafeArea(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.insert_drive_file_outlined, size: 36), const SizedBox(height: 12), Text(file['name'] as String, style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 20),
      Text('容量：${size((file['size'] as num).toInt())}\n修改日期：${file['modified']}\n首次建档：${meta['First-Indexed-UTC'] ?? '尚未建档'}\n上一次存入：${meta['Last-Stored-UTC'] == 'unknown' ? '未知' : meta['Last-Stored-UTC'] ?? '未知'}'), const SizedBox(height: 20), Text((meta['Description'] as String?)?.isNotEmpty == true ? meta['Description'] as String : '尚未填写文件描述'), const SizedBox(height: 20),
      FilledButton.icon(onPressed: () => Navigator.pop(context, 'open'), icon: const Icon(Icons.open_in_new), label: const Text('打开')),
      OutlinedButton.icon(onPressed: () => Navigator.pop(context, 'describe'), icon: const Icon(Icons.edit_outlined), label: const Text('编辑说明')),
      TextButton.icon(onPressed: () => Navigator.pop(context, 'export'), icon: const Icon(Icons.download_outlined), label: const Text('导出文件副本')),
      TextButton.icon(onPressed: () => Navigator.pop(context, 'send'), icon: const Icon(Icons.bluetooth), label: const Text('蓝牙导出到其他设备')),
      const Text('本批所有文件的描述统一保存在当前文件夹的 file-readme.txt。', style: TextStyle(fontSize: 11, color: Colors.grey)),
    ])))));
    if(!mounted || action == null) return;
    if(action == 'open') {
      await work(() async { await call('open', {'path': pathOf(file)}); if(mounted) { setState(() => message = '已打开「${file['name']}」'); } });
    } else if(action == 'send') {
      await sendMenu(file);
    } else if(action == 'describe') {
      final description = await textPrompt('文件描述', initial: meta['Description'] as String? ?? '');
      if(description != null) { await work(() async { await call('describe', {'path': pathOf(file), 'description': description.replaceAll(RegExp(r'[\r\n]+'), ' ')}); await load(); }); }
    } else { await exportCopy(file); }
  }
  // Files are saved through the system "save as" picker; folders are copied (with subfolders) into a picked folder.
  Future<void> exportCopy(Map<String,dynamic> file) async {
    final directory = file['directory'] == true;
    await work(() async {
      final result = await call('export', {'path': pathOf(file), 'directory': directory});
      if(!mounted) return;
      setState(() => message = result == null ? '已取消导出'
        : directory ? '已导出文件夹「${(result as Map)['name']}」（${result['files']} 个文件）' : '已导出文件副本');
    });
  }
  Future<void> sendMenu(Map<String,dynamic> file) async {
    final name = file['name'] as String;
    final directory = file['directory'] == true;
    final via = await showModalBottomSheet<String>(context: context, builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(title: Text('导出「$name」'), subtitle: const Text('导出的是副本，SSD 上的原件保持不变')),
      ListTile(leading: const Icon(Icons.download_outlined), title: Text(directory ? '导出文件夹副本' : '导出文件副本'), subtitle: Text(directory ? '选择手机或其他存储上的位置，复制整个文件夹（包括子文件夹）' : '选择手机或其他存储上的保存位置'), onTap: () => Navigator.pop(context, 'copy')),
      ListTile(leading: const Icon(Icons.bluetooth), title: const Text('蓝牙发送'), subtitle: Text('选择已配对或附近的设备；对方需开启蓝牙并接受文件${directory ? '。只发送此文件夹内的文件和 file-readme.txt，不含子文件夹' : ''}'), onTap: () => Navigator.pop(context, 'bluetooth')),
      ListTile(leading: const Icon(Icons.share_outlined), title: const Text('其他方式发送'), subtitle: const Text('附近分享、聊天软件等'), onTap: () => Navigator.pop(context, 'chooser')),
    ])));
    if(!mounted || via == null) return;
    if(via == 'copy') { await exportCopy(file); return; }
    await work(() async {
      final status = await call('ssdStatus') as Map?;
      if(!mounted) return;
      if(status?['state'] == 'missing') { setState(() => message = '未检测到 SSD，无法发送。请连接 SSD 后重试。'); return; }
      final result = Map<String,dynamic>.from(await call('send', {'path': pathOf(file), 'directory': directory, 'via': via}) as Map);
      if(!mounted) return;
      final count = result['files'];
      setState(() => message = result['via'] == 'bluetooth'
        ? '已打开蓝牙发送（$count 个文件）。请选择接收设备，传输完成前请勿拔出 SSD。'
        : via == 'bluetooth' ? '此手机没有可直接调用的蓝牙发送，请在列表中选择「蓝牙」（$count 个文件）。传输完成前请勿拔出 SSD。' : '请在列表中选择发送方式（$count 个文件）。传输完成前请勿拔出 SSD。');
    });
  }
  Widget preview(Map<String,dynamic> file) {
    final name = file['name'] as String;
    final directory = file['directory'] == true;
    final path = pathOf(file);
    final icon = directory ? Icons.folder_outlined : name.toLowerCase().endsWith('.pdf') ? Icons.picture_as_pdf_outlined : Icons.description_outlined;
    final fallback = Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 34, color: const Color(0xff528a67)), const SizedBox(height: 5), Text(directory ? '文件夹' : name.split('.').last.toUpperCase().characters.take(8).toString(), maxLines: 1, style: const TextStyle(fontSize: 10, color: Color(0xff6b8577)))]);
    return Container(key: ValueKey('preview-$path'), width: 96, height: 96, clipBehavior: Clip.antiAlias, decoration: BoxDecoration(color: const Color(0xffeaf1ec), borderRadius: BorderRadius.circular(10)), child: FutureBuilder<Uint8List?>(
      future: thumbnails.putIfAbsent(path, () async { try { return await channel.invokeMethod<Uint8List>('thumbnail', {'path': path}); } catch(_) { return null; } }),
      builder: (context, snapshot) => snapshot.data == null ? fallback : Image.memory(snapshot.data!, fit: BoxFit.contain, gaplessPlayback: true, errorBuilder: (context, error, stackTrace) => fallback),
    ));
  }
  Widget fileRow(Map<String,dynamic> file) {
    final directory = file['directory'] == true;
    final metadata = Map<String,dynamic>.from(file['metadata'] as Map? ?? {});
    final description = (metadata['Description'] as String? ?? '').trim();
    final location = file['path'] == null ? null : (file['path'] as String).split('/').reversed.skip(1).toList().reversed.join('/');
    return Card(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5), elevation: 0, color: Colors.white, child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: busy ? null : () { if(directory) { work(() => load(pathOf(file))); } else { detail(file); } },
      child: Padding(padding: const EdgeInsets.all(12), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        preview(file), const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if(directory) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.folder, key: ValueKey('folder-icon'), size: 20, color: Color(0xffd9a441))),
            Expanded(child: Text(file['name'] as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
          if(location != null) Padding(padding: const EdgeInsets.only(top: 3), child: Text('位于：${location.isEmpty ? '我的 SSD' : location}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Color(0xff528a67)))),
          const SizedBox(height: 7),
          Text(description.isEmpty ? directory ? '暂无批次描述' : '暂无描述，点击添加' : description, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: description.isEmpty ? Colors.grey : const Color(0xff395345))),
          const SizedBox(height: 9),
          Text(directory ? '${file['fileCount'] ?? '—'} 个文件 · ${size((file['size'] as num).toInt())}' : size((file['size'] as num).toInt()), style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text('日期：${(file['modified'] as String? ?? 'unknown').split('T').first}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ])),
        IconButton(tooltip: '导出 ${file['name']}', onPressed: busy ? null : () => sendMenu(file), icon: const Icon(Icons.ios_share)),
        IconButton(tooltip: '删除 ${file['name']}', onPressed: busy ? null : () => deleteEntry(file), icon: const Icon(Icons.delete_outline), color: Theme.of(context).colorScheme.error),
      ])),
    ));
  }
  @override
  Widget build(BuildContext context) {
    final visible = query.trim().isEmpty ? entries : results;
    return Scaffold(
      appBar: AppBar(title: const Text('file-hero', style: TextStyle(fontWeight: FontWeight.w700))),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('每份文件，都有故事。', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 8), Text(connected ? driveName : '你的 SSD 随身文件库', style: const TextStyle(color: Color(0xff528a67))), const SizedBox(height: 16), TextField(controller: searchText, decoration: InputDecoration(hintText: '搜索当前文件夹及子文件夹', prefixIcon: const Icon(Icons.search), suffixIcon: query.isEmpty ? null : IconButton(tooltip: '清除搜索', onPressed: () => setState(clearSearch), icon: const Icon(Icons.close)), filled: true, border: const OutlineInputBorder(borderSide: BorderSide.none)), onChanged: search),
          if(connected) SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [IconButton(tooltip: '返回上层', onPressed: busy || folder.isEmpty ? null : () => work(() => load(folder.split('/').take(folder.split('/').length - 1).join('/'))), icon: const Icon(Icons.arrow_upward)), Text(folder.isEmpty ? '我的 SSD' : folder), IconButton(tooltip: '刷新', onPressed: busy ? null : () => work(() => load()), icon: const Icon(Icons.refresh))])),
        ])),
        if(busy) const LinearProgressIndicator(),
        Expanded(child: !connected ? const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('在相册或文件管理器选择文件\n点击分享 → File Hero\n\n选择新建文件夹或已有文件夹存入 SSD。', textAlign: TextAlign.center))) : visible.isEmpty ? Center(child: Text(query.trim().isEmpty ? '没有文件。请从其他应用分享文件到 File Hero。' : busy ? '正在搜索…' : '没有匹配的文件或文件夹')) : ListView.builder(itemCount: visible.length, itemBuilder: (context,index) => fileRow(visible[index]))),
        Padding(padding: const EdgeInsets.all(16), child: Text(message, style: const TextStyle(fontSize: 12), maxLines: 4)),

      ]),
    );
  }
}

class _ShareSaveDialog extends StatefulWidget {
  const _ShareSaveDialog({required this.target, required this.initialName, required this.initialDescription, required this.initialMode, required this.existingReady, required this.count, required this.queued});
  final String target, initialName, initialDescription, initialMode;
  final bool existingReady;
  final int count;
  final ValueNotifier<int> queued;
  @override
  State<_ShareSaveDialog> createState() => _ShareSaveDialogState();
}
class _ShareSaveDialogState extends State<_ShareSaveDialog> {
  late final TextEditingController name, description;
  late String mode;
  late bool existingReady;
  final formKey = GlobalKey<FormState>();
  @override
  void initState() { super.initState(); name = TextEditingController(text: widget.initialName); description = TextEditingController(text: widget.initialDescription); mode = widget.initialMode; existingReady = widget.existingReady; }
  @override
  void dispose() { name.dispose(); description.dispose(); super.dispose(); }
  void finish(String action) {
    if(action == 'save' && !formKey.currentState!.validate()) return;
    Navigator.pop(context, {'action': action, 'name': name.text, 'description': description.text, 'mode': mode, 'existingReady': existingReady.toString()});
  }
  void selectMode(String value) { setState(() { if(mode != value) { existingReady = false; } mode = value; }); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('分享文件存入 SSD'),
    content: SingleChildScrollView(child: Form(key: formKey, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('已接收 ${widget.count} 个文件'),
      ValueListenableBuilder<int>(valueListenable: widget.queued, builder: (context, queued, _) => queued > 0 ? Padding(padding: const EdgeInsets.only(top: 6), child: Text('另有 $queued 批分享在排队，处理完这批后会继续', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary))) : const SizedBox.shrink()),
      const SizedBox(height: 12),
      Wrap(spacing: 8, children: [ChoiceChip(label: const Text('新建文件夹'), selected: mode == 'new', onSelected: (_) => selectMode('new')), ChoiceChip(label: const Text('已有文件夹'), selected: mode == 'existing', onSelected: (_) => selectMode('existing'))]),
      const SizedBox(height: 12),
      Text(mode == 'new' ? '新文件夹将建立在 SSD 的 file-hero 文件夹中。首次存入时需授权 SSD 根目录，file-hero 文件夹会自动建立。' : !existingReady ? '请选择要存入的已有文件夹' : '目标：${widget.target}'),
      if(mode == 'existing') TextButton.icon(onPressed: () => finish('target'), icon: const Icon(Icons.folder_open), label: const Text('选择已有文件夹')),
      if(mode == 'new') ...[
        TextFormField(key: const ValueKey('share-name'), controller: name, decoration: const InputDecoration(labelText: '文件夹名称'), validator: (value) => value == null || value.trim().isEmpty ? '请输入文件夹名称' : null), const SizedBox(height: 12),
        TextFormField(key: const ValueKey('share-description'), controller: description, maxLines: 3, decoration: const InputDecoration(labelText: '描述（可选）')),
      ] else const Text('文件将直接存入所选文件夹，保留原有描述。同名文件不会覆盖。', style: TextStyle(fontSize: 12)),
    ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')), FilledButton(onPressed: (mode == 'existing' ? existingReady : true) ? () => finish('save') : null, child: const Text('存入'))],
  );
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({required this.title, required this.initial});
  final String title;
  final String initial;
  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController controller;
  @override
  void initState() { super.initState(); controller = TextEditingController(text: widget.initial); }
  @override
  void dispose() { controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(controller: controller, autofocus: true, maxLines: widget.title.contains('描述') ? 4 : 1),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('保存'))],
  );
}

