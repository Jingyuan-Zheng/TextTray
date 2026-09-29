# Text Tray

**Text Tray** 是一个极简 macOS 临时文本托盘。它适合那些不想打开完整文本编辑器、不想开便签、不想打开外部 AI 或翻译工具来回复制粘贴，只想快速查看、编辑、处理、统计、复制或保存一段临时文本的场景。

![Text Tray 总览](docs/images/overview.jpg)

## 解决什么问题

使用电脑时经常会遇到这种很小但烦人的文本任务：

- 刚复制了一段文字，但原 App 里看起来太小
- 只是临时看一下，不想打开文本编辑器
- 不想把临时内容放进便签
- 想知道这段文本有多少字符、多少词、多少行
- 想简单清理 PDF 复制出来的断行
- 想轻量编辑一下再复制或保存
- 偶尔想调用轻量 AI 文本动作、Apple Intelligence 写作工具或系统翻译，但不想开一整套工具流程

Text Tray 的定位就是快速打开、快速处理、快速离开。

## 功能

### 临时文本托盘

- 为复制或传入的文本打开一个清爽、专注的临时窗口
- 不用打开完整文本编辑器，也不用把临时内容放进便签
- 需要时可以让窗口保持在其他窗口之上
- 可以重新读取当前剪贴板，替换窗口中的临时文本

### 阅读、编辑和统计

- 编辑、选择、滚动、撤销、重做和查找文本
- 显示行号和自动换行
- 调整字号
- 查看字符数、词数、行数、选中文字数量、字号和光标位置

### 快速文本清理

- 去除首尾空白
- 删除多余空行
- 统一换行符
- 去除每行末尾空格
- 修复常见 PDF 复制断行
- 撤销上一次文本处理

### 复制、保存和打印

- 一键复制全部文本
- 保存为 `.txt`、`.md`、`.json`、`.csv`、`.html`、`.swift`、`.py`、`.js`，或自定义后缀
- 默认文件名使用 `Text_YYYYMMDDHHMMSS.txt`
- 打印当前文本

### 智能辅助

- 提取待办、日期、金额和联系人
- 总结要求、解释文本、检查风险、草拟回复、整理成清单或表格
- 在系统支持时调用 Apple Intelligence 辅助写作
- 支持中文、英文、西班牙语、德语、法语、意大利语和葡萄牙语的系统多语言翻译，并可设置双语语言对

### 偏好设置

- 记住语言、置顶、字号、行号、自动换行和统计信息显示
- 文本保持临时：只保存偏好，不保存正文内容

Text Tray 不会自动保存正文，不记录剪贴板历史，不后台监听剪贴板，不上传内容，也不会在关闭时清空系统剪贴板。

## 截图

### PDF 断行处理

![PDF 断行处理](docs/images/pdf-line-breaks.jpg)

### AI 文本动作

Text Tray 的 AI 文本动作适合对临时文本做快速结构化处理，例如从邮件中提取任务和日期。

处理前示例：

![处理前邮件示例](docs/images/email-example.jpg)

提取任务：

![AI 提取任务](docs/images/ai-tasks.jpg)

提取日期：

![AI 提取日期](docs/images/ai-dates.jpg)

### Apple Intelligence 辅助写作

在系统支持时，可以直接在编辑器中调用系统 Apple Intelligence 辅助写作。

![Apple Intelligence 写作工具](docs/images/writing-tools.jpg)

### 翻译

![翻译](docs/images/translation.jpg)

### 保存和导出

![导出](docs/images/export.jpg)

### 快捷指令启动

![快捷指令设置](docs/images/shortcut-setup.jpg)

## 安装

从 Release 下载 `TextTray-1.1.0.dmg`，打开后将 `Text Tray.app` 拖到“应用程序”文件夹。

如果 macOS 提示安全确认，可以在 Finder 中 Control-click 后选择打开，或在系统设置里允许。

## 通过快捷指令启动

在快捷指令中使用“运行 Shell 脚本”：

```bash
open -n "/Applications/Text Tray.app"
```

也可以直接传入文本：

```bash
APP="/Applications/Text Tray.app"
printf '%s' "$SHORTCUT_INPUT" | "$APP/Contents/MacOS/TemporaryClipboardViewer" --stdin
```

## 从源码构建

要求：

- macOS 13 或更新
- Xcode Command Line Tools
- Swift 编译器

构建：

```bash
./scripts/build.sh
```

输出：

- `build/Text Tray.app`
- `releases/TextTray.zip`

构建脚本会生成普通 `.app`，并打包为 `TextTray.zip`。

## 隐私

Text Tray 只做本地临时处理。

- 不使用数据库
- 不记录剪贴板历史
- 不自动保存文本
- 不后台监听剪贴板
- 不在关闭时清空剪贴板
- 只有用户主动复制时才会写入剪贴板

语言、字号、行号、自动换行、统计信息显示和置顶等偏好会用 `UserDefaults` 保存。正文内容不会保存。

## License

MIT
