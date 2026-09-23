# file-hero

Portable SSD 文件管理器，Android 使用 **Flutter + Kotlin SAF**，桌面使用 **Electron + C++17**。目前优先提供 Android 测试 APK。

## 按批次存入，一个说明文件

每次点击「选择文件并存入 SSD」，先多选文件，再选择 SSD 目标目录，填写新文件夹名称和描述。程序在 SSD 创建独立批次文件夹并复制所选文件：

```text
SSD/
  日本旅行-2026/
    photo-01.jpg
    photo-02.jpg
    tickets.pdf
    file-readme.txt
  工作资料-2026-09/
    proposal.pdf
    budget.xlsx
    file-readme.txt
```

**一个批次只有一个 `file-readme.txt`，没有逐文件说明目录或逐文件说明文件。** 批次描述、文件清单、每个文件的描述、字节大小、日期全部集中在这一份 UTF-8 文本中。应用内点击文件可以编辑该文件在统一说明中的描述；点击 `file-readme.txt` 可以编辑批次描述。

```text
Batch: 日本旅行-2026
Created-UTC: 2026-09-23T10:20:30Z
Description: 日本旅行原始照片与票据
File-Count: 1
Format: file-hero/batch-v1
Last-Stored-UTC: 2026-09-23T10:20:30Z
Size-Bytes: 3145728

[File: photo-01.jpg]
Description: 京都第一天
First-Indexed-UTC: 2026-09-23T10:20:30Z
Last-Stored-UTC: 2026-09-23T10:20:30Z
Modified-UTC: 2026-09-22T09:00:00Z
Name: photo-01.jpg
Size-Bytes: 3145728
```

日期统一 UTC。历史文件无法推断上次存入日期，会记录 `unknown`；通过应用存入的文件记录实际存入时间。文件大小是字节容量，不是磁盘实际占用空间。批次总容量不包含说明文件本身。

## Android 测试

1. 下载测试 APK 并安装；必要时允许浏览器/文件管理器安装此来源的应用。
2. 手机连接 USB SSD（需 OTG、支持的文件系统及足够供电）。也可先用系统允许选择的手机文件夹测试。
3. 点击「选择文件并存入 SSD」，在系统文件选择器中多选源文件。
4. 选择 SSD 目标目录，输入新文件夹名称和描述，点击「新建文件夹并存入」。右上角 USB 图标也可以独立浏览 SSD。
5. 打开新批次，应看到所选文件和唯一的 `file-readme.txt`。
6. 点击任意文件 → 编辑说明；点击 `file-readme.txt` → 编辑批次说明。修改全部写回同一份文本。

只支持系统 DocumentsProvider 可见的 USB 设备。每次启动需重新选择目录，不需要「所有文件访问」权限。支持导出文件副本、当前目录搜索、新建目录、递归更新说明。同名批次不会覆盖；一个批次中的重名文件会被拒绝。`file-readme.txt` 是保留名，不可作为待导入文件。

说明保存期间可能短暂产生临时文件；成功后只保留一个说明文件。SAF 不保证原子替换，异常断电时可能留下 `.tmp` 或 `.backup` 恢复文件，应恢复后再操作。大文件复制时不要拔盘；目前暂不提供取消和断点续传。

## 开发与构建

Android 需要 Flutter stable、JDK 17、Android SDK。首次生成与 Flutter 版本匹配的 runner：

```sh
node scripts/bootstrap-mobile.cjs
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

GitHub Actions 默认优先构建 Android，包含 analyze、widget test 和 debug APK。测试包用 debug key 签名，正式发布需配置发行签名。

Windows 需要 Node.js 22+ 和 MinGW g++（默认 `C:/msys64/mingw64/bin/g++.exe`，或通过 `CXX` 指定）：

```sh
npm ci
npm test
npm start
npm run dist
```

Windows CI 可手动运行「Build and test」，选择 `all`。桌面和 Android 共用相同的批次文本格式。跨设备移动时复制整个批次文件夹即可。

## 当前范围

第一版提供浏览、按批次导入、导出副本、新建目录、统一说明编辑。尚不提供删除、移动、重命名、跨设备联网同步、自动监听和断点续传。外部更名后使用「更新说明」刷新清单；旧文件名对应的描述不会自动匹配到新文件名。请勿多个程序同时写同一批次。所有内容本地保存。

结构：`native/` C++ 引擎；`desktop/` Electron；`mobile/` Flutter 与 Kotlin；`scripts/` 构建；`tests/` 引擎测试。

实现参考：[Android SAF](https://developer.android.com/training/data-storage/shared/documents-files)、[Flutter 平台通道](https://docs.flutter.dev/platform-integration/platform-channels)、[Electron 安全说明](https://www.electronjs.org/docs/latest/tutorial/security)。
