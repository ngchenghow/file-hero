package com.filehero.file_hero

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Bundle
import android.util.Size
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executors
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private var root: DocumentFile? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val thumbnailWorker = Executors.newFixedThreadPool(2)
    private var pending: MethodChannel.Result? = null
    private var pendingPath = ""
    private var pendingKind = ""
    private var selectedSources: List<Pair<Uri,String>> = emptyList()
    private var storageChannel: MethodChannel? = null
    private val sharedBatches = java.util.ArrayDeque<List<Uri>>()
    private var active = false
    private fun utc(millis: Long = System.currentTimeMillis()): String = if (millis <= 0) "unknown" else SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(millis))
    private fun valid(name: String) {
        val base = name.substringBefore('.').uppercase(Locale.ROOT)
        require(name.isNotEmpty() && name !in listOf(".", "..") && !name.equals(".file-hero", true) && name.none { it in "/\\\r\n\t:<>\"|?*" } && !name.endsWith('.') && !name.endsWith(' ') && base !in listOf("CON", "PRN", "AUX", "NUL") && !base.matches(Regex("(COM|LPT)[1-9]"))) { "Invalid or reserved portable filename" }
    }
    private fun resolve(path: String, tree: DocumentFile? = root): DocumentFile {
        var file = tree ?: error("请先连接 SSD")
        if (path.isNotEmpty()) for (part in path.split('/')) { valid(part); file = file.findFile(part) ?: error("文件不存在") }
        return file
    }
    private data class Batch(val header: MutableMap<String,String> = mutableMapOf(), val files: MutableMap<String,MutableMap<String,String>> = mutableMapOf())
    private fun readBatch(dir: DocumentFile, strict: Boolean = true): Batch {
        val doc = dir.findFile("file-readme.txt") ?: return Batch()
        val text = contentResolver.openInputStream(doc.uri)?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: error("无法读取批次说明")
        val batch = Batch(); var current = batch.header
        for(raw in text.lineSequence()) {
            val line = raw.trimEnd('\r')
            if(line.startsWith("[File: ") && line.endsWith(']')) { val name = line.substring(7, line.length - 1); valid(name); current = batch.files.getOrPut(name) { mutableMapOf() } }
            else { val at = line.indexOf(": "); if(at >= 0) current[line.substring(0, at)] = line.substring(at + 2) }
        }
        if(batch.header["Format"] != "file-hero/batch-v1") { require(!strict) { "已有 file-readme.txt 不是 File Hero 批次说明，不会覆盖" }; return Batch() }
        return batch
    }
    private fun record(file: DocumentFile, meta: MutableMap<String,String> = mutableMapOf(), stored: Boolean = false): MutableMap<String,String> {
        meta.putIfAbsent("Description", ""); meta["Name"] = file.name!!; meta["Size-Bytes"] = file.length().toString(); meta["Modified-UTC"] = utc(file.lastModified())
        meta.putIfAbsent("First-Indexed-UTC", utc()); meta.putIfAbsent("Last-Stored-UTC", "unknown"); if(stored) meta["Last-Stored-UTC"] = utc()
        return meta
    }
    private fun writeBatch(dir: DocumentFile, batch: Batch) {
        val h = batch.header; h["Format"] = "file-hero/batch-v1"; h["Batch"] = dir.name ?: "SSD"
        h.putIfAbsent("Description", ""); h.putIfAbsent("Created-UTC", utc()); h.putIfAbsent("Last-Stored-UTC", "unknown")
        h["File-Count"] = batch.files.size.toString(); h["Size-Bytes"] = batch.files.values.sumOf { it["Size-Bytes"]?.toLongOrNull() ?: 0L }.toString()
        val text = buildString {
            h.toSortedMap().forEach { (key,value) -> append("$key: $value\n") }
            batch.files.toSortedMap().forEach { (name, fields) -> append("\n[File: $name]\n"); fields.toSortedMap().forEach { (key,value) -> append("$key: $value\n") } }
        }
        require(dir.findFile("file-readme.txt.tmp") == null && dir.findFile("file-readme.txt.backup") == null) { "存在未完成写入的说明文件，请先恢复" }
        val temp = dir.createFile("application/octet-stream", "file-readme.txt.tmp") ?: error("无法创建临时说明")
        val old = dir.findFile("file-readme.txt")
        var renamed = false
        try {
            contentResolver.openOutputStream(temp.uri, "wt")?.bufferedWriter(Charsets.UTF_8)?.use { it.write(text) } ?: error("无法写入批次说明")
            if(old != null) { require(old.renameTo("file-readme.txt.backup")) { "此存储设备不支持安全替换说明" }; renamed = true }
            require(temp.renameTo("file-readme.txt")) { "无法提交批次说明" }
        } catch(e: Exception) { temp.delete(); if(renamed) old?.renameTo("file-readme.txt"); throw e }
        if(old != null) require(old.delete()) { "说明已保存，但临时备份未能删除" }
    }
    private fun readMeta(file: DocumentFile): Map<String,String> {
        val batch = readBatch(file.parentFile ?: error("Missing parent"), false)
        val meta = if(file.name.equals("file-readme.txt", true)) batch.header else batch.files[file.name] ?: mutableMapOf()
        return if(meta.isEmpty()) meta else meta + ("Format" to "file-hero/batch-v1")
    }
    private fun writeMeta(file: DocumentFile, description: String): Map<String,String> {
        require(description.toByteArray(Charsets.UTF_8).size <= 8192 && !description.contains('\n') && !description.contains('\r')) { "描述最多 8192 UTF-8 字节，且必须为单行" }
        val parent = file.parentFile ?: error("Missing parent"); val batch = readBatch(parent)
        val meta = if(file.name.equals("file-readme.txt", true)) batch.header else record(file, batch.files.getOrPut(file.name!!) { mutableMapOf() })
        meta["Description"] = description; writeBatch(parent, batch); return meta
    }
    private fun index(dir: DocumentFile): Int {
        var n = 0; val batch = readBatch(dir); val previous = batch.files.toMap(); batch.files.clear()
        for(file in dir.listFiles()) if(file.name != ".file-hero") {
            if(file.isDirectory) n += index(file)
            else if(file.isFile && !file.name.equals("file-readme.txt", true) && file.name !in listOf("file-readme.txt.tmp", "file-readme.txt.backup")) { batch.files[file.name!!] = record(file, previous[file.name] ?: mutableMapOf()); n++ }
        }
        if(batch.files.isNotEmpty() || batch.header.isNotEmpty()) writeBatch(dir, batch)
        return n
    }
    private fun background(result: MethodChannel.Result, fn: () -> Any?) {
        worker.execute { try { val value = fn(); runOnUiThread { active = false; result.success(value) } } catch(e: Exception) { runOnUiThread { active = false; result.error("STORAGE", e.message, null) } } }
    }
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        storageChannel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.filehero/storage").also { channel -> channel.setMethodCallHandler { call, result -> handle(call, result) } }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if(savedInstanceState == null) receiveShare(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receiveShare(intent)
    }
    @Suppress("DEPRECATION")
    private fun receiveShare(incoming: Intent?) {
        if(incoming == null || incoming.action !in listOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return
        val uris = mutableListOf<Uri>()
        if(incoming.action == Intent.ACTION_SEND_MULTIPLE) {
            incoming.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else { incoming.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) } }
        incoming.clipData?.let { clip -> for(i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) } }
        // Only use delegated content URIs, never sender-supplied filesystem paths.
        sharedBatches.addLast(uris.distinct().filter { it.scheme == "content" })
        storageChannel?.invokeMethod("shareAvailable", null)
    }
    private fun sourceFiles(uris: List<Uri>): List<Pair<Uri,String>> {
        require(uris.isNotEmpty()) { "分享中没有可读取的文件，请从相册或文件管理器分享文件" }
        val names = mutableSetOf<String>()
        return uris.distinct().map { source ->
            val name = contentResolver.query(source, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if(it.moveToFirst()) it.getString(0) else null } ?: error("无法读取分享文件名，请重新分享")
            valid(name)
            require(name.lowercase(Locale.ROOT) !in listOf("file-readme.txt", "file-readme.txt.tmp", "file-readme.txt.backup")) { "file-readme.txt 保留给批次说明" }
            require(names.add(name.lowercase(Locale.ROOT))) { "文件有重名，请分批存入" }
            source to name
        }
    }
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if(call.method == "thumbnail") {
            val tree = root; val path = call.argument<String>("path") ?: ""
            thumbnailWorker.execute {
                val bytes = try { thumbnail(resolve(path, tree)) } catch(_: Exception) { null }
                runOnUiThread { result.success(bytes) }
            }
            return
        }
        if(active) { result.error("BUSY", "文件操作仍在进行", null); return }
        active = true
        if(call.method == "takeSharedFiles") {
            val uris = sharedBatches.pollFirst()
            if(uris == null) { active = false; result.success(null); return }
            background(result) { val sources = sourceFiles(uris); selectedSources = sources; sources.map { it.second } }
            return
        }
        if(call.method == "restoreTarget") {
            background(result) {
                try {
                    val saved = getPreferences(MODE_PRIVATE).getString("ssdTarget", null)
                    val candidate = root ?: saved?.let { DocumentFile.fromTreeUri(this, Uri.parse(it)) }
                    if(candidate != null && candidate.canRead() && candidate.canWrite()) { root = candidate; candidate.name ?: "SSD" } else null
                } catch(_: Exception) { root = null; null }
            }
            return
        }
        val path = call.argument<String>("path") ?: ""
        if(call.method in listOf("connect", "pickFiles", "export")) {
            try {
                pending = result; pendingKind = call.method; pendingPath = path
                val intent = when(call.method) {
                    "connect" -> Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    "pickFiles" -> { selectedSources = emptyList(); Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*").putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true) }
                    else -> { require(root != null) { "请先连接 SSD" }; Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, path.substringAfterLast('/')) }
                }
                startActivityForResult(intent, 100)
            } catch(e: Exception) { pending = null; active = false; result.error("STORAGE", e.message, null) }
            return
        }
        background(result) {
            val file = resolve(path)
            when(call.method) {
                "list" -> {
                    require(file.isDirectory && file.canRead()) { "无法读取文件夹" }
                    file.listFiles().filter { it.name != ".file-hero" }.sortedWith(compareBy<DocumentFile> { !it.isDirectory }.thenBy { it.name }).map { f ->
                        val meta = if(f.isDirectory) readBatch(f, false).header else if(f.isFile) readMeta(f) else emptyMap<String,String>()
                        mapOf("name" to (f.name ?: ""), "directory" to f.isDirectory, "size" to if(f.isDirectory) (meta["Size-Bytes"]?.toLongOrNull() ?: 0L) else f.length(), "fileCount" to (meta["File-Count"]?.toLongOrNull()), "modified" to ((if(f.isDirectory) meta["Last-Stored-UTC"] else null) ?: utc(f.lastModified())), "metadata" to meta)
                    }
                }
                "index" -> { require(file.isDirectory); index(file) }
                "describe" -> { require(file.isFile); writeMeta(file, call.argument<String>("description") ?: "") }
                "mkdir" -> { val name = call.argument<String>("name") ?: ""; valid(name); require(file.findFile(name) == null) { "文件夹已存在" }; require(file.createDirectory(name) != null) { "无法创建文件夹" }; true }
                "importSelected" -> importSelected(file, call.argument<String>("name") ?: "", call.argument<String>("description") ?: "")
                else -> error("Unknown method")
            }
        }
    }
    @Deprecated("Used for Flutter activity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if(requestCode != 100) return
        val result = pending ?: return; pending = null
        val picked = mutableListOf<Uri>()
        data?.clipData?.let { clip -> for(i in 0 until clip.itemCount) picked.add(clip.getItemAt(i).uri) }
        if(picked.isEmpty()) data?.data?.let { picked.add(it) }
        val uri = picked.firstOrNull()
        if(resultCode != Activity.RESULT_OK || uri == null) { active = false; result.success(null); return }
        val kind = pendingKind; val path = pendingPath
        background(result) {
            when(kind) {
                "connect" -> {
                    val flags = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    contentResolver.takePersistableUriPermission(uri, flags)
                    val selected = DocumentFile.fromTreeUri(this, uri) ?: error("无法连接文件夹")
                    require(selected.canRead() && selected.canWrite()) { "请选择可读写的 SSD 文件夹" }; root = selected
                    getPreferences(MODE_PRIVATE).edit().putString("ssdTarget", uri.toString()).apply()
                    selected.name ?: "USB SSD"
                }
                "pickFiles" -> {
                    val sources = sourceFiles(picked)
                    selectedSources = sources
                    sources.map { it.second }
                }
                "export" -> { val src = resolve(path); require(src.isFile); require(src.uri != uri) { "不能覆盖源文件" }; copy(src.uri, uri); true }
                else -> error("Unknown result")
            }
        }
    }
    private fun importSelected(parent: DocumentFile, batchName: String, description: String): Map<String,Any> {
        require(parent.isDirectory && parent.canWrite()) { "SSD 目标目录不可写" }; valid(batchName)
        require(description.toByteArray(Charsets.UTF_8).size <= 8192 && !description.contains('\n') && !description.contains('\r')) { "描述最多 8192 UTF-8 字节" }
        require(selectedSources.isNotEmpty()) { "请先选择文件" }
        require(parent.findFile(batchName) == null) { "此文件夹已存在，请更换批次名称" }
        val sources = selectedSources.toList()
        val dest = parent.createDirectory(batchName) ?: error("无法在 SSD 创建文件夹")
        try {
            val batch = Batch(); batch.header["Description"] = description; batch.header["Last-Stored-UTC"] = utc()
            for((source, name) in sources) {
                val created = dest.createFile(contentResolver.getType(source) ?: "application/octet-stream", name) ?: error("无法创建文件")
                copy(source, created.uri); batch.files[created.name!!] = record(created, stored = true)
            }
            writeBatch(dest, batch)
        } catch(e: Exception) { dest.delete(); throw e }
        selectedSources = emptyList()
        return mapOf("batch" to (dest.name ?: batchName), "imported" to sources.size)
    }
    private fun copy(source: Uri, target: Uri) {
        contentResolver.openInputStream(source)?.use { input -> contentResolver.openOutputStream(target, "wt")?.use { output -> input.copyTo(output, 1024 * 1024) } ?: error("无法写入目标") } ?: error("无法读取源文件")
    }
    private fun thumbnail(file: DocumentFile): ByteArray? {
        if(file.isDirectory) {
            // Batch cover: use the first available visual preview inside the folder.
            val candidates = file.listFiles().filter { child -> child.isFile && child.name?.substringAfterLast('.', "")?.lowercase(Locale.ROOT) in listOf("jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "pdf", "mp4", "mkv", "mov", "webm", "avi", "3gp") }.sortedBy { it.name }.take(8)
            for(candidate in candidates) { val cover = try { thumbnail(candidate) } catch(_: Exception) { null }; if(cover != null) return cover }
            return null
        }
        if(!file.isFile) return null
        val uri = file.uri
        var bitmap: Bitmap? = if(Build.VERSION.SDK_INT >= 29) {
            try { contentResolver.loadThumbnail(uri, Size(256, 256), null) } catch(_: Exception) { null }
        } else null
        if(bitmap == null) {
            val mime = contentResolver.getType(uri) ?: ""
            val extension = file.name?.substringAfterLast('.', "")?.lowercase(Locale.ROOT) ?: ""
            bitmap = when {
                mime.startsWith("image/") || extension in listOf("jpg", "jpeg", "png", "webp", "gif", "bmp", "heic") -> {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                    var sample = 1
                    while(bounds.outWidth / sample > 512 || bounds.outHeight / sample > 512) sample *= 2
                    val options = BitmapFactory.Options().apply { inSampleSize = sample }
                    contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
                }
                mime == "application/pdf" || extension == "pdf" -> {
                    contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                        PdfRenderer(descriptor).use { renderer ->
                            if(renderer.pageCount == 0) null else renderer.openPage(0).use { page ->
                                val scale = 256.0 / maxOf(page.width, page.height)
                                Bitmap.createBitmap(maxOf(1, (page.width * scale).toInt()), maxOf(1, (page.height * scale).toInt()), Bitmap.Config.ARGB_8888).also { preview ->
                                    preview.eraseColor(android.graphics.Color.WHITE)
                                    page.render(preview, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                }
                            }
                        }
                    }
                }
                mime.startsWith("video/") || extension in listOf("mp4", "mkv", "mov", "webm", "avi", "3gp") -> {
                    val retriever = MediaMetadataRetriever()
                    try { retriever.setDataSource(this, uri); if(Build.VERSION.SDK_INT >= 27) retriever.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 256, 256) else retriever.getFrameAtTime(0) } finally { retriever.release() }
                }
                else -> null
            }
        }
        val source = bitmap ?: return null
        val ratio = 256.0 / maxOf(source.width, source.height)
        val scaled = if(ratio < 1) Bitmap.createScaledBitmap(source, maxOf(1, (source.width * ratio).toInt()), maxOf(1, (source.height * ratio).toInt()), true) else source
        return try { ByteArrayOutputStream().use { output -> scaled.compress(Bitmap.CompressFormat.JPEG, 82, output); output.toByteArray() } }
        finally { if(scaled !== source) scaled.recycle(); source.recycle() }
    }
}
