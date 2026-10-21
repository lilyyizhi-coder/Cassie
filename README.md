# Cassie · iPhone 语音助手开发预览版

面向中文日常场景的原生 SwiftUI App。最低部署版本为 iOS 17。已在 GitHub macOS runner 上通过模拟器编译和 iPhone 真机版本归档，生成待签名 IPA；尚未完成手机上的运行验证。

最新通过构建的源码提交：`2efbef1259348b727a7b608d1019098737dc2a39`。

- [通过的构建与日志](https://github.com/lilyyizhi-coder/Cassie/actions/runs/39536360015)
- [下载构建产物](https://github.com/lilyyizhi-coder/Cassie/actions/runs/39536360015/artifacts/12317109887)
- [Windows 安装说明](INSTALL-WINDOWS.md)

## 已接入代码的功能

| 功能 | 当前行为 | 使用条件 |
| --- | --- | --- |
| 中文语音输入与播报 | 点按录音，实时显示文字，再点按提交；最长录音 50 秒 | 麦克风、语音识别授权；设备提供中文本地识别能力 |
| 截图与照片文字搜索 | Vision OCR、本地增量索引、关键词匹配、来源图片与完整识别文字 | 相册授权；首次扫描需保持前台 |
| Celechron 课表查询 | 读取用户选择的系统日历，显示未来两周的课和下一节倒计时 | 先在 Celechron 开启系统日历同步，再选择“Celechron课表” |
| 语音备忘 | “记一下…”保存到本机；查看、查询、滑动删除 | 无外部账号 |
| 消息草稿 | 编写草稿、分享，或预填系统短信编辑器，由用户发送 | 短信编辑器需真机和可用消息配置 |
| 打开豆包 | 调用用户配置的“打开 App”快捷指令 | 在系统快捷指令中创建，并填入准确名称 |
| 台铃指令入口 | 确认后启动配置好的车辆解锁快捷指令 | 台铃智能与具体车型提供相应官方动作 |
| Siri / Action 按钮入口 | App Shortcut“和 Cassie 说话”，进入 App 并开始语音请求 | 安装后由用户在系统入口中配置 |

天气、路线、翻译、学习整理、截图语义问答、自动生成消息回复、日程写入与提醒、任意多步任务仍待实现。当前命令路由是本机规则，不是完整大模型助手。没有模拟接口成功或伪造课表数据。

## 没有 Mac 的构建方式

项目自带 `.github/workflows/ios-build.yml`，可在 GitHub 的 macOS runner 上生成 Xcode 项目、编译模拟器版本、归档设备版本并打包 `Cassie-unsigned.ipa`。该流程已成功运行。构建产物保留七天，过期后可重新运行工作流生成。

1. 将 **本目录的内容**放在一个 GitHub 仓库根目录。`project.yml`、`Sources/` 与 `.github/` 应在仓库根层。
2. 在该仓库的 Actions 页面运行 **Build Cassie for iOS**。普通网页上传可能遗漏点号开头的 `.github/` 目录；通过 Git 提交可避免这个问题。
3. 先查看编译结果；若失败，需根据日志修复。通过后下载 `Cassie-unsigned-build` artifact，解压得到待签名 IPA。
4. 在自己的 Windows 电脑中使用支持免费 Apple ID 的签名工具签名和安装。待签名 IPA 本身不能直接安装到 iPhone。

参考 [Sideloadly 官方说明](https://sideloadly.io/)：支持 Windows 与免费 Apple ID，免费签名有效期通常为七天，提供自动刷新；具体依赖与安装步骤以官方当前说明为准。Apple ID 登录在你自己的签名工具中完成，构建流程不需要 Apple ID 密码或签名证书。

免费签名、App Intents、中文离线语音和权限弹窗均需要在实际设备上验证。若设备没有当前可用的中文本地识别能力，App 会显示原因并保留文字输入，不会自动把录音上传。

## 有 Mac 时的本机构建

安装 Xcode 15 或更新版本及 XcodeGen：

```sh
brew install xcodegen
cd Cassie
xcodegen generate
open Cassie.xcodeproj
```

在 Xcode 中选择签名团队和独立的 Bundle ID，然后选择设备构建。`SWIFT_VERSION: 5.0` 表示 Swift 5 语言模式；本项目使用 Xcode 15+ 的工具链。

## Celechron 接入依据

已阅读 Celechron 的官方开源日历同步实现；它创建的系统日历名为 **Celechron课表**。Cassie 通过 EventKit 读取用户选中的这份日历，无需学校账号或教务密码，也没有复制 Celechron 的实现代码。源项目还提供 iCal 导出。

- [Celechron 系统日历同步实现](https://github.com/Celechron/Celechron/blob/main/lib/model/calendar_to_system.dart)
- [Celechron App Store 更新说明](https://apps.apple.com/ro/app/celechron/id6477194529)

台铃智能的 App Store 更新记录列有 Siri 控车功能，但这不代表所有车型都能解锁。先在你手机中的台铃智能和快捷指令动作列表里核对可用动作，再填入指令名称。启动快捷指令不代表车辆执行成功。

- [台铃智能 App Store](https://apps.apple.com/hk/app/id1597230423)
- [Apple：从 App 通过 URL 运行快捷指令](https://support.apple.com/en-au/guide/shortcuts/apd624386f42/ios)

## 数据处理

- OCR 文字和备忘保存在 App 的 Application Support 目录，采用 iOS 完整文件保护并排除系统备份。
- 当前没有云端模型、分析统计或内容上传代码。授权 App 访问相册也不等于授权上传相册。
- 扫描默认只处理截图，可关闭该选项扫描全部照片。已索引内容均可搜索。
- iCloud 图片下载默认关闭；需要时由用户开启。索引不保存原图副本。
- 回到 App 时重新检查相册权限；已删除或移出授权范围的图片文字会从索引中移除。
- 扫描可暂停，下次跳过已处理且未修改的图片。暂停会等待当前图片读取或 OCR 返回。
- 清除索引只清除 Cassie 的本机索引，不删除照片。

## 接下来需要的真机检查

1. 麦克风与语音权限：允许、拒绝、撤销；录音中切后台、结束、再次录音。
2. 相册：有限和完整授权，新增/编辑/删除截图，撤销访问后的索引清理。
3. OCR：真实中英文截图、表格、小字和长截图；确认检索结果能对应原图。
4. 日历：选择“Celechron课表”、当前正在上的课、下一节课、跨天和无课情况。
5. 备忘：保存、重启 App 后恢复、删除。
6. 豆包：准确和错误的快捷指令名；台铃：用户取消确认、系统拒绝、车辆无连接。
7. 消息：取消、发送失败和系统报告已发送。送达状态仍以消息 App 为准。

源文件检查、云端 Xcode 模拟器编译、设备归档和 IPA 打包已通过；上述权限交互与真实功能仍需安装后检查。编译成功不代表已完成所有计划功能。
