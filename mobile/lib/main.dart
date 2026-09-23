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
  String folder = '', driveName = '', query = '', message = '连接 USB SSD，选择系统文件选择器中的目录。';
  List<Map<String, dynamic>> entries = [];
  String child(String name) => folder.isEmpty ? name : '$folder/$name';
  String size(int n) { if(n < 1024) return '$n B'; if(n < 1048576) return '${(n/1024).toStringAsFixed(1)} KB'; if(n < 1073741824) return '${(n/1048576).toStringAsFixed(1)} MB'; return '${(n/1073741824).toStringAsFixed(1)} GB'; }
  Future<dynamic> call(String method, [Map<String, dynamic> values = const {}]) => channel.invokeMethod(method, {'path': folder, ...values});
  Future<void> work(Future<void> Function() action) async {
    if(busy) return;
    setState(() { busy = true; message = '正在处理，请勿拔出 SSD…'; });
    try { await action(); } on PlatformException catch(e) { if(mounted) setState(() => message = '操作未完成：${e.message}'); }
    catch(e) { if(mounted) setState(() => message = '操作未完成：$e'); }
    finally { if(mounted) setState(() => busy = false); }
  }
  Future<void> load([String? target]) async {
    final path = target ?? folder;
    final data = await call('list', {'path': path}) as List;
    if(mounted) setState(() { folder = path; entries = data.map((e) => Map<String,dynamic>.from(e as Map)).toList(); message = '${entries.length} 个项目'; });
  }
  Future<String?> textPrompt(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(context: context, builder: (context) => AlertDialog(title: Text(title), content: TextField(controller: controller, autofocus: true, maxLines: title == '文件描述' ? 4 : 1), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('保存'))]));
    // Keep controller alive until the dialog exit animation completes.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose(); return value;
  }
  Future<void> detail(Map<String,dynamic> file) async {
    final meta = Map<String,dynamic>.from(file['metadata'] as Map? ?? {});
    final action = await showModalBottomSheet<String>(context: context, isScrollControlled: true, builder: (context) => SafeArea(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.insert_drive_file_outlined, size: 36), const SizedBox(height: 12), Text(file['name'] as String, style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 20),
      Text('容量：${size((file['size'] as num).toInt())}\n修改日期：${file['modified']}\n首次建档：${meta['First-Indexed-UTC'] ?? '尚未建档'}\n上一次存入：${meta['Last-Stored-UTC'] == 'unknown' ? '未知' : meta['Last-Stored-UTC'] ?? '未知'}'), const SizedBox(height: 20), Text((meta['Description'] as String?)?.isNotEmpty == true ? meta['Description'] as String : '尚未填写文件描述'), const SizedBox(height: 20),
      FilledButton.icon(onPressed: () => Navigator.pop(context, 'describe'), icon: const Icon(Icons.edit_outlined), label: const Text('编辑说明')),
      TextButton.icon(onPressed: () => Navigator.pop(context, 'export'), icon: const Icon(Icons.download_outlined), label: const Text('导出文件副本')),
      const Text('说明位置：.file-hero / 文件名 / file-readme.txt', style: TextStyle(fontSize: 11, color: Colors.grey)),
    ])))));
    if(!mounted || action == null) return;
    if(action == 'describe') {
      final description = await textPrompt('文件描述', initial: meta['Description'] as String? ?? '');
      if(description != null) await work(() async { await call('describe', {'path': child(file['name'] as String), 'description': description.replaceAll(RegExp(r'[\r\n]+'), ' ')}); await load(); });
    } else { await work(() async { final result = await call('export', {'path': child(file['name'] as String)}); if(mounted) setState(() => message = result == true ? '已导出文件副本' : '已取消导出'); }); }
  }
  @override
  Widget build(BuildContext context) {
    final visible = entries.where((e) => (e['name'] as String).toLowerCase().contains(query.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('file-hero', style: TextStyle(fontWeight: FontWeight.w700)), actions: [IconButton(tooltip: '选择 SSD / 文件夹', onPressed: busy ? null : () => work(() async { final result = await call('connect'); if(result != null) { setState(() { connected = true; driveName = result as String; }); await load(''); } else { setState(() => message = '已取消连接'); } }), icon: const Icon(Icons.usb))]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('每份文件，都有故事。', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 8), Text(connected ? driveName : '你的 SSD 随身文件库', style: const TextStyle(color: Color(0xff528a67))), const SizedBox(height: 16), TextField(decoration: const InputDecoration(hintText: '搜索当前文件夹', prefixIcon: Icon(Icons.search), filled: true, border: OutlineInputBorder(borderSide: BorderSide.none)), onChanged: (value) => setState(() => query = value)),
          if(connected) SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [IconButton(tooltip: '返回上层', onPressed: busy || folder.isEmpty ? null : () => work(() => load(folder.split('/').take(folder.split('/').length - 1).join('/'))), icon: const Icon(Icons.arrow_upward)), Text(folder.isEmpty ? '我的 SSD' : folder), IconButton(tooltip: '刷新', onPressed: busy ? null : () => work(() => load()), icon: const Icon(Icons.refresh))])),
        ])),
        if(busy) const LinearProgressIndicator(),
        Expanded(child: !connected ? const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('点击右上角 USB 图标连接设备。\n支持系统文件选择器可访问的 USB SSD。', textAlign: TextAlign.center))) : visible.isEmpty ? const Center(child: Text('没有文件。导入一份，开始整理。')) : ListView.builder(itemCount: visible.length, itemBuilder: (context,index) { final f = visible[index]; final dir = f['directory'] == true; return ListTile(leading: Icon(dir ? Icons.folder_outlined : Icons.description_outlined, color: const Color(0xff528a67)), title: Text(f['name'] as String), subtitle: Text(dir ? '文件夹' : '${size((f['size'] as num).toInt())} · ${(f['metadata'] as Map).containsKey('Format') ? '已建档' : '待建档'}'), trailing: const Icon(Icons.chevron_right), onTap: busy ? null : () { if(dir) {work(() => load(child(f['name'] as String)));} else {detail(f);} }); })),
        Padding(padding: const EdgeInsets.all(16), child: Text(message, style: const TextStyle(fontSize: 12), maxLines: 4)),
        if(connected) SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(12,0,12,12), child: Wrap(spacing: 8, children: [
          FilledButton.icon(onPressed: busy ? null : () => work(() async { await call('import'); await load(); }), icon: const Icon(Icons.upload), label: const Text('导入')),
          OutlinedButton(onPressed: busy ? null : () => work(() async { final n = await call('index'); await load(); setState(() => message = '已更新 $n 份说明'); }), child: const Text('生成说明')),
          TextButton(onPressed: busy ? null : () async { final name = await textPrompt('新建文件夹'); if(name != null) await work(() async { await call('mkdir', {'name': name.trim()}); await load(); }); }, child: const Text('＋ 文件夹')),
        ]))),
      ]),
    );
  }
}
