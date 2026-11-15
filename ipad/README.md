# 阅读 iPad 版

阅读 Archive 的原生 iPad 客户端，最低支持 iPadOS 17。横屏和宽窗口显示侧栏，窄窗口可在书架、搜书和书源间切换。

## 在 Xcode 运行

用 Xcode 16 或更新版本打开 `LegadoPad.xcodeproj`，选择 `LegadoPad` scheme 和 iPad 模拟器，点 Run。安装到个人 iPad 时，在 Signing & Capabilities 选择自己的 Team。如需注册独立的 App ID，在 `LegadoPad.xcconfig` 修改 `PRODUCT_BUNDLE_IDENTIFIER`。

```sh
cd ipad
swift test
xcodebuild -project LegadoPad.xcodeproj -scheme LegadoPad \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' CODE_SIGNING_ALLOWED=NO build
```

命令里的机型可替换为本机已安装的 iPad 模拟器。仓库的 [iPad 构建记录](https://github.com/chaoQWQ/legado-ipad/actions/workflows/ipad.yml) 提供启动截图和模拟器应用压缩包。

## 导入与阅读

- 在「书架」点「导入」，从「文件」选择一个或多个 TXT、EPUB。TXT 支持多种常见中文编码并尝试识别章标题。EPUB 按原书顺序导入纯文本章节。
- 在「书源」导入 Android 阅读 3.0 导出的书源 JSON，启用后到「搜书」输入书名或作者。选择结果查看详情，再加入书架。打开过的在线章节可离线阅读。
- 在「书源」点书源名称或铅笔编辑，可分栏修改配置、直接编辑 JSON，也可在「＋」菜单新建书源或输入网络导入地址。对已有书源修改地址会另存为新书源。
- 在书源编辑的「基本」页打开「书名和目录转简体」，该书源的书名及章节标题就会显示为简体。已加入书架的书会立即生效。
- 在「订阅」打开「书源广场」搜索、预览并勾选可导入的书源和合集。广场使用安卓版内置的源仓库目录。 [书源](https://www.yckceo.com/yuedu/shuyuan/index.html) · [书源合集](https://www.yckceo.com/yuedu/shuyuans/index.html) · [地址发布页](https://yckceo.vip/)
- 「规则订阅」可保存一个书源 JSON 地址，手动预览导入，或在打开应用时定期检查。静默更新只应用到已从该订阅导入且没有被手动修改的书源。也可以添加标准 RSS 或 Atom 订阅浏览文章。
- 阅读页底部可搜索本地或已缓存的正文、调整阅读进度、自动滚动或定时翻页、管理文字替换、切换夜间主题和启动系统朗读。书架会记录每本书的阅读位置，也可以添加书签。
- 「界面」提供字号、字距、行距、段距、字重、字体、缩进、边距、翻页方式与速度，以及繁简转换和阅读信息。开启「共用布局」时，各主题使用同一套排版。
- 「设置」管理屏幕方向和超时、状态栏与底部系统提示、亮度控件、菜单不透明度、章内或整书进度条、文本选择、两端对齐、翻页手势和键盘。窗口方向由 iPadOS 调整，支持范围取决于当前的多任务窗口模式。
- 在线书籍可刷新当前章、选择章节范围下载，或从其他已启用的书源换源。换源按章名匹配阅读位置，并按书源保留已下载章节和书签。自动阅读和系统朗读默认为当前章节运行。

书源使用自身指定的 HTTP 或 HTTPS 地址。兼容范围包括常见 CSS、XPath、基础 JSONPath 和 Legado 选择器，可处理常规 GET／POST 和目录或正文分页。正文替换规则 `@js:java.t2s(result)` 由系统执行繁体转简体，也适用于已缓存的正文。通用 JavaScript、WebView、登录流程和部分复杂规则暂未移植。应用不内置书籍或书源。

本分支使用仓库的 [GPL-3.0 许可](../LICENSE)。iPad 应用使用仓库的 [阅读 Archive 图标](../docs/archive_icon.svg)。
