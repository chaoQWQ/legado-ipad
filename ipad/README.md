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
- 在阅读页打开目录跳转章节，或通过阅读设置调整字体、字号、行距和主题。书架会记录每本书的阅读位置，也可以手动添加书签。

书源使用自身指定的 HTTP 或 HTTPS 地址。兼容范围包括常见 CSS、XPath、基础 JSONPath 和 Legado 选择器，可处理常规 GET／POST 和目录或正文分页。JavaScript、WebView、登录流程和部分复杂规则暂未移植。应用不内置书籍或书源。

本分支使用仓库的 [GPL-3.0 许可](../LICENSE)。图标源于 Android 版的原有资源。
