package com.filehero.file_hero

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
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

class MainActivity : FlutterActivity() {
    private var root: DocumentFile? = null
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var pendingPath = ""
    private var pendingKind = ""
    private var active = false
    private fun utc(millis: Long = System.currentTimeMillis()): String = if (millis <= 0) "unknown" else SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(millis))
    private fun valid(name: String) { require(name.isNotEmpty() && name !in listOf(".", "..", ".file-hero") && name.none { it in "/\\\r\n\t" }) { "Invalid or reserved name" } }
    private fun resolve(path: String): DocumentFile {
        var file = root ?: error("请先连接 SSD")
        if (path.isNotEmpty()) for (part in path.split('/')) { valid(part); file = file.findFile(part) ?: error("文件不存在") }
        return file
    }
    private fun metadata(file: DocumentFile): DocumentFile? = file.parentFile?.findFile(".file-hero")?.findFile(file.name ?: error("Missing filename"))?.findFile("file-readme.txt")
    private fun readMeta(file: DocumentFile): MutableMap<String, String> {
        val doc = metadata(file) ?: return mutableMapOf()
        val text = contentResolver.openInputStream(doc.uri)?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: error("无法读取说明")
        return text.lineSequence().mapNotNull { val at = it.indexOf(": "); if(at < 0) null else it.substring(0, at) to it.substring(at + 2).trimEnd('\r') }.toMap().toMutableMap()
    }
    private fun writeMeta(file: DocumentFile, description: String? = null, stored: Boolean = false): Map<String, String> {
        val meta = readMeta(file)
        if(description != null) { require(description.toByteArray(Charsets.UTF_8).size <= 8192 && !description.contains('\n') && !description.contains('\r')) { "描述最多 8192 UTF-8 字节，且必须为单行" }; meta["Description"] = description }
        meta.putIfAbsent("Description", ""); meta["Format"] = "file-hero/v1"; meta["Name"] = file.name!!
        meta["Size-Bytes"] = file.length().toString(); meta["Modified-UTC"] = utc(file.lastModified())
        meta.putIfAbsent("First-Indexed-UTC", utc()); meta.putIfAbsent("Last-Stored-UTC", "unknown")
        if(stored) meta["Last-Stored-UTC"] = utc()
        val parent = file.parentFile ?: error("Missing parent")
        val base = parent.findFile(".file-hero") ?: parent.createDirectory(".file-hero") ?: error("无法创建说明目录")
        val dir = base.findFile(file.name!!) ?: base.createDirectory(file.name!!) ?: error("无法创建文件说明目录")
        val doc = dir.findFile("file-readme.txt") ?: dir.createFile("text/plain", "file-readme.txt") ?: error("无法创建说明文件")
        // SAF providers do not guarantee atomic rename/replace. Keep the previous text as a backup.
        val previous = contentResolver.openInputStream(doc.uri)?.use { it.readBytes() } ?: byteArrayOf()
        if(previous.isNotEmpty()) {
            val backup = dir.findFile("file-readme.backup.txt") ?: dir.createFile("text/plain", "file-readme.backup.txt") ?: error("无法备份说明")
            contentResolver.openOutputStream(backup.uri, "wt")?.use { it.write(previous) } ?: error("无法写入说明备份")
        }
        contentResolver.openOutputStream(doc.uri, "wt")?.bufferedWriter(Charsets.UTF_8)?.use { out -> meta.toSortedMap().forEach { (key, value) -> out.write("$key: $value\n") } } ?: error("无法写入说明")
        return meta
    }
    private fun index(dir: DocumentFile): Int {
        var n = 0
        for(file in dir.listFiles()) if(file.name != ".file-hero") { if(file.isDirectory) n += index(file) else if(file.isFile) { writeMeta(file); n++ } }
        return n
    }
    private fun background(result: MethodChannel.Result, fn: () -> Any?) {
        worker.execute { try { val value = fn(); runOnUiThread { active = false; result.success(value) } } catch(e: Exception) { runOnUiThread { active = false; result.error("STORAGE", e.message, null) } } }
    }
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.filehero/storage").setMethodCallHandler { call, result -> handle(call, result) }
    }
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if(active) { result.error("BUSY", "文件操作仍在进行", null); return }
        active = true
        val path = call.argument<String>("path") ?: ""
        if(call.method in listOf("connect", "import", "export")) {
            try {
                pending = result; pendingKind = call.method; pendingPath = path
                val intent = when(call.method) {
                    "connect" -> Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    "import" -> { require(root != null) { "请先连接 SSD" }; Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*") }
                    else -> { require(root != null) { "请先连接 SSD" }; Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, path.substringAfterLast('/')) }
                }
                startActivityForResult(intent, 100)
            } catch(e: Exception) { pending = null; active = false; result.error("STORAGE", e.message, null) }
            return
        }
        background(result) {
            val file = resolve(path)
            when(call.method) {
                "list" -> { require(file.isDirectory && file.canRead()) { "无法读取文件夹" }; file.listFiles().filter { it.name != ".file-hero" }.sortedWith(compareBy<DocumentFile> { !it.isDirectory }.thenBy { it.name }).map { f -> mapOf("name" to (f.name ?: ""), "directory" to f.isDirectory, "size" to f.length(), "modified" to utc(f.lastModified()), "metadata" to if(f.isFile) readMeta(f) else emptyMap<String,String>()) } }
                "index" -> { require(file.isDirectory); index(file) }
                "describe" -> { require(file.isFile); writeMeta(file, call.argument<String>("description") ?: "") }
                "mkdir" -> { val name = call.argument<String>("name") ?: ""; valid(name); require(file.findFile(name) == null) { "文件夹已存在" }; require(file.createDirectory(name) != null) { "无法创建文件夹" }; true }
                else -> error("Unknown method")
            }
        }
    }
    @Deprecated("Used for Flutter activity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if(requestCode != 100) return
        val result = pending ?: return; pending = null
        val uri = data?.data
        if(resultCode != Activity.RESULT_OK || uri == null) { active = false; result.success(null); return }
        val kind = pendingKind; val path = pendingPath
        background(result) {
            when(kind) {
                "connect" -> {
                    val flags = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    contentResolver.takePersistableUriPermission(uri, flags)
                    val selected = DocumentFile.fromTreeUri(this, uri) ?: error("无法连接文件夹")
                    require(selected.canRead()) { "无法读取文件夹" }; root = selected; selected.name ?: "USB SSD"
                }
                "import" -> {
                    val dest = resolve(path); require(dest.isDirectory)
                    val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if(it.moveToFirst()) it.getString(0) else null } ?: error("无法读取文件名")
                    valid(name); require(dest.findFile(name) == null) { "文件已存在；导入不会覆盖" }
                    val created = dest.createFile(contentResolver.getType(uri) ?: "application/octet-stream", name) ?: error("无法创建文件")
                    try { copy(uri, created.uri); writeMeta(created, stored = true) } catch(e: Exception) { created.delete(); throw e }; true
                }
                "export" -> { val src = resolve(path); require(src.isFile); require(src.uri != uri) { "不能覆盖源文件" }; copy(src.uri, uri); true }
                else -> error("Unknown result")
            }
        }
    }
    private fun copy(source: Uri, target: Uri) {
        contentResolver.openInputStream(source)?.use { input -> contentResolver.openOutputStream(target, "wt")?.use { output -> input.copyTo(output, 1024 * 1024) } ?: error("无法写入目标") } ?: error("无法读取源文件")
    }
}
