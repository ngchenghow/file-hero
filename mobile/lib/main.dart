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
  String folder = '', driveName = '', query = '', message = '先选择文件，再选择 SSD 并新建文件夹存入。';
  List<Map<String, dynamic>> entries = [];
  final Map<String, Future<Uint8List?>> thumbnails = {};
  bool checkingShares = false, sharePending = false;
  @override
  void initState() {
    super.initState();
    channel.setMethodCallHandler((event) async {
      if(event.method == 'shareAvailable') { sharePending = true; await checkShares(); }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) { if(mounted) { sharePending = true; checkShares(); } });
  }
  @override
  void dispose() { channel.setMethodCallHandler(null); super.dispose(); }
  Future<void> checkShares() async {
    if(!mounted || busy || checkingShares) return;
    checkingShares = true; sharePending = false;
    final previousMessage = message;
    await work(() async {
      final picked = await call('takeSharedFiles') as List?;
      if(!mounted) return;
      if(picked == null) { setState(() => message = previousMessage); return; }
      sharePending = true;
      await saveShared(picked.cast<String>());
    });
    checkingShares = false;
    if(mounted && sharePending) { Future<void>.microtask(checkShares); }
  }
  Future<void> saveShared(List<String> picked) async {
    var target = await call('restoreTarget') as String?;
    if(!mounted) return;
    target ??= await call('connect') as String?;
    if(!mounted) return;
    if(target == null) { setState(() => message = '已取消分享存入，未创建文件夹'); return; }
    final selectedTarget = target;
    setState(() { connected = true; driveName = selectedTarget; folder = ''; entries = []; thumbnails.clear(); });
    var name = '分享-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-').replaceAll('.', '-')}';
    var description = '';
    while(true) {
      if(!mounted) return;
      final form = await showDialog<Map<String,String>>(context: context, builder: (context) => _ShareSaveDialog(target: driveName, files: picked, initialName: name, initialDescription: description));
      if(!mounted) return;
      if(form == null) { await load(''); if(mounted) { setState(() => message = '已取消分享存入，未创建文件夹'); } return; }
      name = form['name']!; description = form['description']!;
      if(form['action'] == 'target') {
        final changed = await call('connect') as String?;
        if(!mounted) return;
        if(changed != null) { setState(() { driveName = changed; folder = ''; entries = []; }); }
        continue;
      }
      setState(() => message = '正在将分享的 ${picked.length} 个文件存入 SSD，请勿拔盘…');
      final result = await call('importSelected', {'path': '', 'name': name.trim(), 'description': description.replaceAll(RegExp(r'[\r\n]+'), ' ')});
      await load(result['batch'] as String);
      if(mounted) { setState(() => message = '已存入分享批次「${result['batch']}」：${result['imported']} 个文件和一份 file-readme.txt'); }
      return;
    }
  }
  String child(String name) => folder.isEmpty ? name : '$folder/$name';
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
    if(mounted) { setState(() { folder = path; thumbnails.clear(); entries = data.map((e) => Map<String,dynamic>.from(e as Map)).toList(); message = '${entries.length} 个项目'; }); }
  }
  Future<String?> textPrompt(String title, {String initial = ''}) async {
    return showDialog<String>(context: context, builder: (context) => _TextPromptDialog(title: title, initial: initial));
  }
  Future<void> importBatch() async {
    await work(() async {
      final picked = await call('pickFiles') as List?;
      if(!mounted) return;
      if(picked == null || picked.isEmpty) { setState(() => message = '已取消选择文件'); return; }
      setState(() => message = '已选 ${picked.length} 个文件，请选择 SSD 中的目标目录。');
      final target = await call('connect');
      if(!mounted) return;
      if(target == null) { setState(() => message = '已取消选择 SSD，未存入任何文件'); return; }
      setState(() { connected = true; driveName = target as String; folder = ''; entries = []; query = ''; });
      final name = await textPrompt('在 SSD 新建文件夹', initial: '批次-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-').split('.').first}');
      if(!mounted) return;
      if(name == null) { await load(''); setState(() => message = '已取消，未创建文件夹'); return; }
      final description = await textPrompt('本批文件的描述');
      if(!mounted) return;
      if(description == null) { await load(''); setState(() => message = '已取消，未创建文件夹'); return; }
      final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('准备存入 SSD'),
        content: SingleChildScrollView(child: Text('新文件夹：$driveName / ${name.trim()}\n\n已选 ${picked.length} 个文件：\n${picked.take(12).join('\n')}${picked.length > 12 ? '\n…' : ''}\n\n描述：$description\n\n本批文件共用一个 file-readme.txt。')),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('新建文件夹并存入'))],
      ));
      if(!mounted) return;
      if(confirmed != true) { await load(''); setState(() => message = '已取消，未存入任何文件'); return; }
      setState(() => message = '正在 SSD 新建文件夹并复制 ${picked.length} 个文件，请勿拔盘…');
      final result = await call('importSelected', {'path': '', 'name': name.trim(), 'description': description.replaceAll(RegExp(r'[\r\n]+'), ' ')});
      await load(result['batch'] as String);
      if(mounted) { setState(() => message = '已存入「${result['batch']}」：${result['imported']} 个文件和一份 file-readme.txt'); }
    });
  }
  Future<void> detail(Map<String,dynamic> file) async {
    final meta = Map<String,dynamic>.from(file['metadata'] as Map? ?? {});
    final action = await showModalBottomSheet<String>(context: context, isScrollControlled: true, builder: (context) => SafeArea(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.insert_drive_file_outlined, size: 36), const SizedBox(height: 12), Text(file['name'] as String, style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 20),
      Text('容量：${size((file['size'] as num).toInt())}\n修改日期：${file['modified']}\n首次建档：${meta['First-Indexed-UTC'] ?? '尚未建档'}\n上一次存入：${meta['Last-Stored-UTC'] == 'unknown' ? '未知' : meta['Last-Stored-UTC'] ?? '未知'}'), const SizedBox(height: 20), Text((meta['Description'] as String?)?.isNotEmpty == true ? meta['Description'] as String : '尚未填写文件描述'), const SizedBox(height: 20),
      FilledButton.icon(onPressed: () => Navigator.pop(context, 'describe'), icon: const Icon(Icons.edit_outlined), label: const Text('编辑说明')),
      TextButton.icon(onPressed: () => Navigator.pop(context, 'export'), icon: const Icon(Icons.download_outlined), label: const Text('导出文件副本')),
      const Text('本批所有文件的描述统一保存在当前文件夹的 file-readme.txt。', style: TextStyle(fontSize: 11, color: Colors.grey)),
    ])))));
    if(!mounted || action == null) return;
    if(action == 'describe') {
      final description = await textPrompt('文件描述', initial: meta['Description'] as String? ?? '');
      if(description != null) { await work(() async { await call('describe', {'path': child(file['name'] as String), 'description': description.replaceAll(RegExp(r'[\r\n]+'), ' ')}); await load(); }); }
    } else { await work(() async { final result = await call('export', {'path': child(file['name'] as String)}); if(mounted) { setState(() => message = result == true ? '已导出文件副本' : '已取消导出'); } }); }
  }
  Widget preview(Map<String,dynamic> file) {
    final name = file['name'] as String;
    final directory = file['directory'] == true;
    final icon = directory ? Icons.folder_outlined : name.toLowerCase().endsWith('.pdf') ? Icons.picture_as_pdf_outlined : Icons.description_outlined;
    final fallback = Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 34, color: const Color(0xff528a67)), const SizedBox(height: 5), Text(directory ? '文件夹' : name.split('.').last.toUpperCase().characters.take(8).toString(), maxLines: 1, style: const TextStyle(fontSize: 10, color: Color(0xff6b8577)))]);
    return Container(key: ValueKey('preview-$name'), width: 96, height: 96, clipBehavior: Clip.antiAlias, decoration: BoxDecoration(color: const Color(0xffeaf1ec), borderRadius: BorderRadius.circular(10)), child: FutureBuilder<Uint8List?>(
      future: thumbnails.putIfAbsent(child(name), () async { try { return await channel.invokeMethod<Uint8List>('thumbnail', {'path': child(name)}); } catch(_) { return null; } }),
      builder: (context, snapshot) => snapshot.data == null ? fallback : Image.memory(snapshot.data!, fit: BoxFit.contain, gaplessPlayback: true, errorBuilder: (context, error, stackTrace) => fallback),
    ));
  }
  Widget fileRow(Map<String,dynamic> file) {
    final directory = file['directory'] == true;
    final metadata = Map<String,dynamic>.from(file['metadata'] as Map? ?? {});
    final description = (metadata['Description'] as String? ?? '').trim();
    return Card(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5), elevation: 0, color: Colors.white, child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: busy ? null : () { if(directory) { work(() => load(child(file['name'] as String))); } else { detail(file); } },
      child: Padding(padding: const EdgeInsets.all(12), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        preview(file), const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(file['name'] as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 7),
          Text(description.isEmpty ? directory ? '暂无批次描述' : '暂无描述，点击添加' : description, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: description.isEmpty ? Colors.grey : const Color(0xff395345))),
          const SizedBox(height: 9),
          Text(directory ? '${file['fileCount'] ?? '—'} 个文件 · ${size((file['size'] as num).toInt())}' : size((file['size'] as num).toInt()), style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text('日期：${(file['modified'] as String? ?? 'unknown').split('T').first}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ])),
      ])),
    ));
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
        Expanded(child: !connected ? const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('1. 选择要存入的文件（可多选）\n2. 选择 SSD 目标目录\n3. 新建批次文件夹并存入\n\n也可点击右上角 USB 图标浏览 SSD。', textAlign: TextAlign.center))) : visible.isEmpty ? const Center(child: Text('没有文件。选择文件并存入 SSD。')) : ListView.builder(itemCount: visible.length, itemBuilder: (context,index) => fileRow(visible[index]))),
        Padding(padding: const EdgeInsets.all(16), child: Text(message, style: const TextStyle(fontSize: 12), maxLines: 4)),
        SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(12,0,12,12), child: Wrap(spacing: 8, children: [
          FilledButton.icon(onPressed: busy ? null : importBatch, icon: const Icon(Icons.upload), label: const Text('选择文件并存入 SSD')),
          if(connected) OutlinedButton(onPressed: busy ? null : () => work(() async { final n = await call('index'); await load(); setState(() => message = '已将 $n 个文件的信息更新到各文件夹的 file-readme.txt'); }), child: const Text('更新说明')),
          if(connected) TextButton(onPressed: busy ? null : () async { final name = await textPrompt('新建文件夹'); if(name != null) { await work(() async { await call('mkdir', {'name': name.trim()}); await load(); }); } }, child: const Text('＋ 文件夹')),
        ]))),
      ]),
    );
  }
}

class _ShareSaveDialog extends StatefulWidget {
  const _ShareSaveDialog({required this.target, required this.files, required this.initialName, required this.initialDescription});
  final String target, initialName, initialDescription;
  final List<String> files;
  @override
  State<_ShareSaveDialog> createState() => _ShareSaveDialogState();
}

class _ShareSaveDialogState extends State<_ShareSaveDialog> {
  late final TextEditingController name, description;
  final formKey = GlobalKey<FormState>();
  @override
  void initState() { super.initState(); name = TextEditingController(text: widget.initialName); description = TextEditingController(text: widget.initialDescription); }
  @override
  void dispose() { name.dispose(); description.dispose(); super.dispose(); }
  void finish(String action) {
    if(action == 'save' && !formKey.currentState!.validate()) return;
    Navigator.pop(context, {'action': action, 'name': name.text, 'description': description.text});
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('分享文件存入 SSD'),
    content: SingleChildScrollView(child: Form(key: formKey, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('目标：${widget.target}'), const SizedBox(height: 10),
      Text('已接收 ${widget.files.length} 个文件\n${widget.files.take(5).join('\n')}${widget.files.length > 5 ? '\n…' : ''}', style: const TextStyle(fontSize: 12)), const SizedBox(height: 16),
      TextFormField(key: const ValueKey('share-name'), controller: name, decoration: const InputDecoration(labelText: '新批次文件夹名称'), validator: (value) => value == null || value.trim().isEmpty ? '请输入文件夹名称' : null), const SizedBox(height: 12),
      TextFormField(key: const ValueKey('share-description'), controller: description, maxLines: 3, decoration: const InputDecoration(labelText: '这批文件的描述（可选）')),
    ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')), TextButton(onPressed: () => finish('target'), child: const Text('更换 SSD')), FilledButton(onPressed: () => finish('save'), child: const Text('存入'))],
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

