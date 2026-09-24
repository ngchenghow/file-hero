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
  String folder = '', driveName = '', query = '', message = '从相册或文件管理器分享文件到 File Hero。';
  List<Map<String, dynamic>> entries = [];
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
  void dispose() { channel.setMethodCallHandler(null); queuedShares.dispose(); super.dispose(); }
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
  Future<void> saveShared(List<String> picked) async {
    final target = await call('restoreTarget') as String?;
    if(!mounted) return;
    setState(() { connected = target != null; driveName = target ?? ''; folder = ''; entries = []; thumbnails.clear(); });
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
      if(form['action'] == 'target') {
        final changed = await call('connect', {'existing': mode == 'existing'}) as String?;
        if(!mounted) return;
        if(changed != null) {
          existingReady = mode == 'existing';
          setState(() { connected = true; driveName = changed; folder = ''; entries = []; });
        }
        continue;
      }
      if(mode == 'new') {
        final rootTarget = await call('restoreTarget') as String?;
        if(!mounted) return;
        if(rootTarget == null) {
          final authorized = await call('connect', {'existing': false}) as String?;
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
  Future<void> deleteEntry(Map<String,dynamic> file) async {
    final name = file['name'] as String;
    final path = child(name);
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
        IconButton(tooltip: '删除 ${file['name']}', onPressed: busy ? null : () => deleteEntry(file), icon: const Icon(Icons.delete_outline), color: Theme.of(context).colorScheme.error),
      ])),
    ));
  }
  @override
  Widget build(BuildContext context) {
    final visible = entries.where((e) => (e['name'] as String).toLowerCase().contains(query.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('file-hero', style: TextStyle(fontWeight: FontWeight.w700))),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('每份文件，都有故事。', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 8), Text(connected ? driveName : '你的 SSD 随身文件库', style: const TextStyle(color: Color(0xff528a67))), const SizedBox(height: 16), TextField(decoration: const InputDecoration(hintText: '搜索当前文件夹', prefixIcon: Icon(Icons.search), filled: true, border: OutlineInputBorder(borderSide: BorderSide.none)), onChanged: (value) => setState(() => query = value)),
          if(connected) SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [IconButton(tooltip: '返回上层', onPressed: busy || folder.isEmpty ? null : () => work(() => load(folder.split('/').take(folder.split('/').length - 1).join('/'))), icon: const Icon(Icons.arrow_upward)), Text(folder.isEmpty ? '我的 SSD' : folder), IconButton(tooltip: '刷新', onPressed: busy ? null : () => work(() => load()), icon: const Icon(Icons.refresh))])),
        ])),
        if(busy) const LinearProgressIndicator(),
        Expanded(child: !connected ? const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('在相册或文件管理器选择文件\n点击分享 → File Hero\n\n选择新建文件夹或已有文件夹存入 SSD。', textAlign: TextAlign.center))) : visible.isEmpty ? const Center(child: Text('没有文件。请从其他应用分享文件到 File Hero。')) : ListView.builder(itemCount: visible.length, itemBuilder: (context,index) => fileRow(visible[index]))),
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
      Text(mode == 'new' ? '新文件夹将直接建立在 SSD 根目录。首次存入时需授权根目录。' : !existingReady ? '请选择要存入的已有文件夹' : '目标：${widget.target}'),
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

