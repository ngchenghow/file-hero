# file-hero

Portable SSD 文件管理器，Android 使用 **Flutter + Kotlin SAF**，桌面使用 **Electron + C++17**。手机和电脑读写同一个 SSD 上的 `file-hero` 文件夹和同一种 `file-readme.txt` 格式，双方存入的文件都可以在另一方浏览、打开和编辑说明。

## 按批次存入，一个说明文件

Android 从系统分享接收文件，选择「新建文件夹」并填写名称、描述，在 SSD 创建独立批次文件夹；也可选「已有文件夹」直接追加：

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

Android 文件夹列表采用左侧封面预览、右侧批次描述的卡片布局，同时显示文件数量、总容量和日期。封面从文件夹内可预览的图片、视频或 PDF 自动读取；没有可预览内容时显示文件夹图标。点击文件夹进入查看文件。

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

## Windows 桌面版 v0.2

安装 `File-Hero-Setup-0.2.0.exe`（当前用户安装，不需要管理员权限）。首次启动后：

- **插入 SSD 自动打开**：登录 Windows 时启动一个很小的后台程序 `file-hero-agent.exe`（C++，无窗口）。插入根目录有 `file-hero` 文件夹的 SSD（手机版授权过、或桌面版启用过的 SSD）时，自动打开 File Hero 并连接该 SSD。其他 U 盘不会触发。
- **拖拽存入**：把文件或文件夹从资源管理器拖到 File Hero 窗口任意位置。界面中间的圆角「待存入 SSD」区显示拖入的项目（图片有缩略图，可逐个 ✕ 移出或「清空」），可以多次拖入累加。右下角选择存入位置：
  - 「新建文件夹」：填写名称和描述，建在 SSD 的 `file-hero` 下；
  - 「已有文件夹」：从列表选择，可填写这些文件的描述，保留文件夹原有描述；
  - 「当前文件夹」：存入下方正在浏览的文件夹（在某个文件夹内拖入时默认选中）。
  然后点「复制到 SSD」，显示复制进度，完成后打开目标文件夹。「从电脑存入」按钮选择的文件也会进入这个区域。
- **右键「Share to SSD」**：在资源管理器选中一个或多个文件或文件夹 → 右键 →「Share to SSD」（Windows 11 在「显示更多选项」中，或按住 Shift 再右键直接显示）。选中的项目一次性进入同一个待存入区。未插 SSD 时会等待，插入后可继续，不会存到电脑上。
- 文件夹连同子文件夹一起复制，每一层都有自己的 `file-readme.txt`；只存入一个文件夹并新建时，名称默认为原文件夹名，它本身就是新建的文件夹。原文件夹里已有 File Hero 说明时保留其中的描述。
- **浏览方式与手机相同**：`file-hero` 下的批次文件夹以卡片显示，左侧封面（图片、视频、PDF 缩略图），右侧批次描述、文件数量、总容量和日期。点击文件夹进入；点击文件编辑描述，「打开」用电脑默认程序打开，另可在资源管理器中显示、导出副本、删除（需确认）。
- 左侧「电脑整合」可关闭自动打开或右键菜单；卸载时一并移除。

文件名按与 Android 相同的规则整理为手机和电脑都能用的名称；同一批重名文件改为 `name (2).ext`；已有文件夹中存在同名文件时整批拒绝，不会覆盖。大文件复制显示进度。SSD 为 NTFS 时会提示：多数手机无法写入 NTFS，建议使用 **exFAT**。手机拍摄的 HEIC 照片或 HEVC 视频在 Windows 上可能需要从 Microsoft Store 安装 HEIF / HEVC 扩展才能打开。

## 视频截图与 AI 描述

电脑版存入视频时，会在视频所在的文件夹里建立 `thumbs` 文件夹，为每个视频截 3 张 250×250 的 JPEG（在视频 25%、50%、75% 处，整个画面等比缩放，空白处为黑色），并在 `file-readme.txt` 里该视频的记录中写上截图位置：

```text
[File: 京都.mp4]
Description:
Thumbnails: thumbs/京都.mp4-1.jpg | thumbs/京都.mp4-2.jpg | thumbs/京都.mp4-3.jpg
```

- 已在 SSD 上但还没有截图的视频（包括手机存入的），在电脑版点「更新说明」即可补齐；缺了某张截图的视频也会重新截图。
- 支持 MP4、MOV、M4V、WebM 等常见格式（H.264、HEVC、VP9）；无法解码的视频（如旧 AVI）会跳过并在状态栏提示。
- `thumbs` 是 File Hero 专用文件夹：电脑和手机都不显示、不搜索，也不会在里面建立说明文件。重命名或删除视频时截图跟着改名或删除。

**让 Claude 写描述**：在 Claude 的工作模式中选择 SSD 上的批次文件夹（或整个 `file-hero` 文件夹），然后说：

> 查看每个文件夹 file-readme.txt 里 Thumbnails 列出的视频截图，给 Description 为空的视频写一句中文描述，写进该视频记录的 Description 行（一行，不换行）。不要改动其他行，也不要改已有的描述。

File Hero 下次打开或刷新文件夹时就会显示这些描述，手机上同样可见。

## Android 测试

v0.1.3 支持相册/文件管理器的系统分享：选中一个或多个文件 → 分享 → File Hero。新建模式选择 SSD 存放位置，填写名称、描述后点「存入」；已有模式选择具体文件夹直接追加，保留原描述。新建模式可复用上次授权位置。App 未启动或已经打开时都支持接收文件分享；普通文字/网址分享不会当作文件写入。App 使用专用 File Hero 图标。

1. 下载测试 APK 并安装；必要时允许浏览器/文件管理器安装此来源的应用。
2. 手机连接 USB SSD（需 OTG、支持的文件系统及足够供电）。也可先用系统允许选择的手机文件夹测试。
3. 在相册或文件管理器选中文件，点击分享 → File Hero。
4. 选择「新建文件夹」填写名称和描述，或「已有文件夹」选具体目录，点击「存入」。主页自动浏览上次授权位置。
5. 打开新批次，应看到所选文件和唯一的 `file-readme.txt`。
6. 点击任意文件 → 编辑说明；点击 `file-readme.txt` → 编辑批次说明。修改全部写回同一份文本。

只支持系统 DocumentsProvider 可见的 USB 设备。每次启动需重新选择目录，不需要「所有文件访问」权限。支持导出文件副本、当前目录搜索、新建目录、递归更新说明。同名批次不会覆盖。分享或选择的文件名会自动整理为可移植名称：非法字符替换为 `_`，同一批内重名文件自动改为 `name (2).ext`，读不到文件名时使用 `shared-时间-序号`，`file-readme.txt` 等保留名会加 `shared-` 前缀。无法读取的分享会弹窗提示，可重试或放弃。未检测到 USB SSD 时会暂停存入并提示连接方法，连接后可重试，不会存到手机内部存储；选择器中选了不在 SSD 上的位置会被拒绝。每个文件或文件夹可「蓝牙发送」到其他设备（调用系统蓝牙，对方无需安装 File Hero；文件夹发送其中全部文件及 file-readme.txt，不含子文件夹），也可用系统分享列表的附近分享等方式发送；传输完成前请勿拔出 SSD。

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
npm test        # C++ 引擎测试
npm run smoke   # 驱动真实 Electron 界面：分享 → 连接 → 新建/已有文件夹存入 → 编辑 → 导出 → 删除
npm start
npm run dist    # 生成 dist/File-Hero-Setup-<版本>.exe
```

右键菜单和自动启动只由安装版注册（`npm start` 开发模式不会修改注册表）。

Windows CI 可手动运行「Build and test」，选择 `all`。桌面和 Android 共用相同的批次文本格式。跨设备移动时复制整个批次文件夹即可。

## 当前范围

提供浏览、按批次存入、导出副本、新建目录、删除、统一说明编辑。尚不提供移动、重命名、跨设备联网同步和断点续传。外部更名后使用「更新说明」刷新清单；旧文件名对应的描述不会自动匹配到新文件名。请勿多个程序同时写同一批次。所有内容本地保存。

结构：`native/` C++ 引擎（`main.cpp`）与 Windows 后台程序（`agent.cpp`）；`installer/` NSIS 卸载清理；`desktop/` Electron；`mobile/` Flutter 与 Kotlin；`scripts/` 构建；`tests/` 引擎测试。

实现参考：[Android SAF](https://developer.android.com/training/data-storage/shared/documents-files)、[Flutter 平台通道](https://docs.flutter.dev/platform-integration/platform-channels)、[Electron 安全说明](https://www.electronjs.org/docs/latest/tutorial/security)。

Android v0.1.3：入口改为系统分享 → File Hero。分享窗口可新建文件夹并填写名称、描述，或通过系统目录选择器选择已有文件夹直接追加。已有文件夹保留原描述，统一更新 file-readme.txt；同名文件整批拒绝并可重新选择目标。主页自动恢复上次授权位置，不再提供 USB 和手动选文件按钮。

Android v0.1.4：文件／文件夹卡片右侧点击删除图标，再确认永久删除。文件夹连同全部内容删除；单个文件删除后更新统一说明中的清单、数量与总容量，保留批次描述及存入日期。授权根目录不可删除。

首次存入时先显示授权说明，再打开系统选择器（直接定位到 SSD 根目录）；用户停在 SSD 最上层点「使用此文件夹」→「允许」即可。File Hero 自动在 SSD 根目录建立 `file-hero` 文件夹，所有批次都存放在里面；选到子文件夹会提示重新选择（系统不允许选根目录时，可先手动建立 `file-hero` 文件夹再选它）。已有文件夹选择不会改变记住的授权。
