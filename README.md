# file-hero

Portable SSD 文件管理器：**C++17 文件引擎 + Electron 桌面端 + Flutter Android App**。

## v0.1 功能

- 选择 SSD / 文件夹、浏览子目录、搜索当前目录、显示文件大小和修改日期。
- 导入文件，自动生成说明；同名文件拒绝覆盖。
- 导出文件副本、新建文件夹、编辑文件描述。
- 为已有文件递归生成或更新 `file-readme.txt`；浏览本身不修改 SSD。
- 桌面显示 SSD 总容量和剩余容量；Android 通过系统 Storage Access Framework 访问 USB SSD，无需所有文件权限。
- 所有内容本地保存，无云端账号、无文件上传服务。

## 每个文件的说明

同一目录下多个文件不能都直接使用同一个 `file-readme.txt`，因此按文件名分开存放：

```text
SSD/
  photos/
    trip.jpg
    .file-hero/
      trip.jpg/
        file-readme.txt
```

UTF-8 文本，两端共享同一格式：

```text
Description: 日本旅行的原始照片
First-Indexed-UTC: 2026-09-23T10:20:30Z
Format: file-hero/v1
Last-Stored-UTC: 2026-09-23T10:20:30Z
Modified-UTC: 2026-09-22T09:00:00Z
Name: trip.jpg
Size-Bytes: 3145728
```

日期统一 UTC。`Modified-UTC` 来自文件系统；`First-Indexed-UTC` 是首次建档日期；`Last-Stored-UTC` 仅在通过 File Hero 导入时记录。已有文件的历史存入日期为 `unknown`，不会用扫描时间假冒。描述是单行文本，最多 8192 UTF-8 字节。

整个文件夹连同 `.file-hero` 一起移动到另一台设备即可共享说明。Android 保存前保留 `file-readme.backup.txt`，因为 SAF 不保证原子替换；桌面采用临时文件后替换。请在操作完成后安全弹出 SSD。

## Windows 桌面开发

需要 Node.js 22+、C++17 编译器（MinGW g++；或 CMake + Visual Studio），以及 npm。

```powershell
npm ci
npm test
npm start
npm run dist
```

默认检测 `C:/msys64/mingw64/bin/g++.exe`，也可通过 `CXX` 指定 g++ 路径。输出 `dist/File Hero 0.1.0.exe`（portable，无安装步骤）。C++ 引擎静态链接 MinGW runtime。Visual Studio 可用 `cmake -S . -B build/cmake` 和 `cmake --build build/cmake --config Release`，然后将生成的引擎复制到 `build/file-hero-core.exe` 并直接运行 `npx electron .`。

## Android 开发

需要 Flutter stable、JDK 17 和 Android SDK。首次生成与本机 Flutter 版本匹配的 Android runner：

```sh
node scripts/bootstrap-mobile.cjs
cd mobile
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk --debug
```

连接支持 OTG 的 Android 手机和 SSD，点击右上角 USB 图标，在系统选择器中授权 SSD 目录。手机必须支持 SSD 的文件系统及供电；只有系统 DocumentsProvider 暴露的设备才可访问。每次启动需重新选择目录。不能通过普通 `dart:io` 路径访问任意 USB 盘，因此使用 Kotlin SAF 桥接。

## 构建与验证

GitHub Actions 自动跑 C++ 测试、Windows portable 打包、Flutter analyze / widget test / debug APK 构建。安装包位于 Actions 成功运行的 Artifacts。Android debug APK 用于测试；正式分发需配置自己的签名。

`npm test` 覆盖中文文件名、说明保存、时间保留、递归建档、容量更新、禁止覆盖、路径越界和中断写入保护。

## 当前范围

第一版提供浏览、导入、导出、建目录、说明管理。尚不提供删除、重命名、移动、断点续传、跨设备联网同步、系统托盘或自动监听。外部工具重命名文件后需手动迁移对应的 `.file-hero/旧文件名` 目录。导出只复制文件，整批迁移请连同说明目录复制。暂不跟随符号链接。不要由多个 File Hero 实例同时写同一目录。大目录扫描在后台执行，但暂不支持取消；文件列表一次载入。未签名 Windows 程序可能显示系统发布者提示。

## 结构

```text
native/         C++ 文件引擎（JSON CLI）
desktop/        Electron 主进程、隔离 preload、中文界面
mobile/         Flutter UI 与 Kotlin SAF 桥接
scripts/        本地构建与 Flutter runner 初始化
tests/          引擎集成测试
.github/        Windows / Android CI
```

实现参考：[Electron 安全说明](https://www.electronjs.org/docs/latest/tutorial/security)、[Android SAF 文档](https://developer.android.com/training/data-storage/shared/documents-files)、[Flutter 平台通道](https://docs.flutter.dev/platform-integration/platform-channels)。
