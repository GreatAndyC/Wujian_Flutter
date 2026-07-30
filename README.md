# 物见

一个面向家庭收纳、搬家整理和物品盘点的开源多模态应用。

你拍一张照片，物见会调用兼容 OpenAI `chat/completions` 的视觉模型，尽量自动识别：

- 物品名称
- 分类
- 数量
- 房间
- 箱号
- 品牌 / 型号 / 颜色 / 材质
- 简短描述和备注

识别结果不会直接“黑箱入库”，而是先进入待确认队列，适合真实家庭场景里逐步整理和修正。

## 为什么做这个

家庭物品管理的真正难点，不是做一个表格，而是把“记录”这件事变得足够轻。

物见的目标很简单：

- 拍照比手填更快
- AI 先给结构化草稿
- 人再做最后确认
- 数据留在本地，方便后续搜索、导出、搬家和盘点

## v1.0.4 更新

`v1.0.4+5` 是一次以“存储可控、数据不丢、连续拍照稳定”为目标的稳定性版本。本次更新重点重做了图片落盘、目录保存、识别队列和发布签名链路。

### 图片占用与性能

- 图片写入长期存储前会在后台压缩，最长边限制为 2048 像素，避免相机原始大图持续堆积。
- 使用压缩后内容的 SHA-256 摘要去重，相同图片即使被重复或并发导入，也只会保留一份永久文件。
- 图片成功保存后会清理相机临时源文件；相机缓存也已纳入存储统计，并支持自动和手动清理。
- 首次启动会在后台迁移旧版全尺寸图片，压缩旧文件、合并重复内容，并清理不再使用的文件。
- 缩略图按实际显示尺寸解码，Android 端也限制了预览和拍照分辨率，降低连续拍摄时的内存压力。

### 数据可靠性

- 物品目录与待处理队列现在统一原子保存，并带有可校验的备份；主文件损坏时会自动尝试恢复。
- 上次异常退出时尚未完成的识别任务会重新排队，不再永久停留在“处理中”。
- 新增、更新和删除操作统一串行执行；保存失败时会回滚内存状态，并清理无主图片。
- 设置、令牌或本地数据格式异常时会安全降级，避免应用启动白屏或直接崩溃。

### 相机与智能识别

- Android 相机增加重复回调去重、超时解锁和失败恢复，旧会话的迟到回调不会再污染当前拍摄。
- 识别请求采用受控并发，减少连拍后瞬间发出大量请求导致的超时、限流和内存峰值。
- 网络请求增加连接与响应超时、响应体大小限制，并要求远程服务使用 HTTPS。
- 模型访问令牌不再写入明文偏好设置，现有令牌会自动迁移到系统安全存储。

### 启动、发布与 QA

- 修复 iOS 安全存储配置和启动重试流程，启动失败时会显示可重试页面，不再停留在空白界面。
- Android 正式包不再回退使用 debug 签名；缺少生产签名时构建会直接失败，避免再次产生无法覆盖升级的安装包。
- CI 会检查格式、静态分析、自动化测试、Android 构建和 APK 签名；版本标签也必须与应用版本一致。
- 本版本已通过 `flutter analyze`、21 项自动化测试、Android debug/release 构建与签名验证，以及 iOS 模拟器构建和启动冒烟测试。真机相机压力测试仍应在正式发布前执行。

> **Android 升级提醒：** 早期 `v1.0.3` APK 曾使用不稳定的 debug 签名。如果设备上的旧 APK 与 `v1.0.4` 生产证书不同，Android 会拒绝覆盖安装。请勿为升级直接卸载旧版，否则设备内的目录和图片会一并删除；应先确认数据已得到可恢复的保全。

完整细节请参阅 [v1.0.4 发布说明](docs/releases/v1.0.4.md) 和 [稳定性 QA 记录](docs/ways-of-work/plan/stability-hardening/qa-plan.md)。

## 当前能力

- 单张拍摄识别
- 连续拍摄，后台逐条识别
- 待确认队列
- 首页待确认队列支持直接确认
- 已入库物品搜索、筛选、查看
- 视图页快速编辑物品状态
- 多配置管理
- 多模型 / 多服务商预设
- Token 统计
- 本地存储统计与清理
- 导出 PDF / Excel / Markdown

## 支持的模型接入方式

物见现在不是绑死某一家服务商，而是走一层通用的 OpenAI-compatible 适配。

设置页内置这些预设：

- 火山方舟
- OpenRouter
- 小米 MiMo（按量）
- 小米 MiMo（Token Plan）
- Google Gemini
- Groq
- 自定义兼容接口

同时会根据当前预设给出常用模型下拉，不需要每次手动输入模型名。

### 推荐测试组合

如果你想一次性把国内主流多模态供应商测一轮，最省事的方式是直接用 `OpenRouter`。

建议优先测试这些模型：

- `xiaomi/mimo-v2.5`
- `xiaomi/mimo-v2-omni`
- `qwen/qwen3-vl-8b-instruct`
- `qwen/qwen3-vl-30b-a3b-instruct`
- `z-ai/glm-4.5v`
- `z-ai/glm-5v-turbo`
- `minimax/minimax-01`
- `google/gemini-2.5-flash-lite`
- `google/gemini-2.5-flash`
- `openai/gpt-4.1-mini`

如果你只想先找一个“便宜、快、还比较稳”的默认选项，可以先试：

- `xiaomi/mimo-v2.5`
- `qwen/qwen3-vl-8b-instruct`
- `z-ai/glm-4.5v`

## 截止目前的产品状态

- 版本：`1.0.4+5`
- Android 包名：`com.wujian.app.icheck`
- 默认预设：`火山方舟`
- 默认模型：`doubao-seed-2-0-mini-260428`
- iOS 最低版本：`13.0`

这还是一个偏早期、可用但持续演进中的开源版本。它更适合：

- 个人自用
- 家庭整理
- 搬家盘点
- 多模型效果对比
- 作为视觉结构化录入的二次开发基础

## 快速开始

### Android

如果你已经有 release APK，直接安装即可。

常见安装命令：

```bash
adb devices
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

如果你要自己构建：

```bash
flutter pub get
flutter build apk --debug
```

release 构建不会再回退使用 debug 证书。先通过以下环境变量提供固定 keystore，再生成 GitHub Release 对应的分架构 APK：

```bash
WUJIAN_RELEASE_STORE_FILE=/absolute/path/release.jks \
WUJIAN_RELEASE_STORE_PASSWORD='your-store-password' \
WUJIAN_RELEASE_KEY_ALIAS='your-key-alias' \
WUJIAN_RELEASE_KEY_PASSWORD='your-key-password' \
flutter build apk --release --split-per-abi
```

生成后通常会有三个 APK：

- `app-arm64-v8a-release.apk`
- `app-armeabi-v7a-release.apk`
- `app-x86_64-release.apk`

大多数真机优先安装 `app-arm64-v8a-release.apk`。如果只是本地自测，直接用默认产物 `app-release.apk` 即可。

### iOS

iOS 不能像 Android 一样直接随便分发安装包。开源版本如果想给别人试用，推荐走：

- 真机自测：`Xcode + Apple ID`
- 小范围分发：`TestFlight`

首次准备：

```bash
flutter pub get
cd ios
pod install
cd ..
open ios/Runner.xcworkspace
```

注意：

- 一定要打开 `ios/Runner.xcworkspace`
- 不要直接打开 `ios/Runner.xcodeproj`

在 Xcode 里需要做的事：

- 选择 `Runner`
- 打开 `Signing & Capabilities`
- 勾选 `Automatically manage signing`
- 选择你的 `Team`
- 确认 `Bundle Identifier` 唯一

本地验证：

```bash
flutter build ios --release
```

导出 TestFlight 构建：

```bash
flutter build ipa --release
```

## 如何配置并测试多模型

第一次打开 App 后：

1. 进入“设置”
2. 新建一个配置
3. 选择服务商预设
4. 填入 API Key
5. 从“常用模型”下拉选择模型
6. 点击“测试连接”
7. 回到首页拍一张相同的测试图片

当前推荐的实际使用流程：

1. 在“设置”里新建一个配置并测试连接
2. 回到首页拍照，图片会以原始比例完整展示
3. 新照片先进入待确认队列，可直接在列表里点“确认”
4. 进入“视图”后可继续快速修改物品状态，例如待确认、已装箱等

为了横向对比不同模型，建议你每次都用同一组图片，观察这些维度：

- 名称是否准确
- 分类是否稳定
- 中文表达是否自然
- OCR 能力如何
- 是否会乱猜房间 / 箱号
- 速度如何
- Token 消耗是否可接受

### 用 OpenRouter 测国内主流多模态

推荐这样配：

- 服务商预设：`OpenRouter`
- Base URL：自动填充
- API Key：你的 OpenRouter Key
- 模型：从下拉里依次切换

建议测试顺序：

1. `xiaomi/mimo-v2.5`
2. `qwen/qwen3-vl-8b-instruct`
3. `z-ai/glm-4.5v`
4. `minimax/minimax-01`
5. `xiaomi/mimo-v2-omni`
6. `qwen/qwen3-vl-30b-a3b-instruct`
7. `z-ai/glm-5v-turbo`

## 数据与隐私

- API Key 使用 `flutter_secure_storage` 存储
- 普通配置、物品记录、导出文件保存在本地
- 图片会保存在本地，并参与导出
- 图片会压缩并按内容去重；旧版原图会在启动后分批迁移
- 相机临时图会计入 App 内存储统计，并按保留策略自动清理
- 配置字段、物品数据和本地图片不会因为正常重新打开 App 而丢失
- 具体图片是否上传到第三方模型服务，取决于你当前选用的模型服务商

如果你对隐私比较敏感，建议：

- 使用你信任的供应商
- 使用单独 API Key
- 定期清理本地图片与导出文件

## 技术栈

- Flutter
- Dart
- `camera`
- `flutter_secure_storage`
- `shared_preferences`
- `pdf`
- `excel`
- `share_plus`

## 项目结构

```text
lib/
  app/                  应用入口
  data/repositories/    设置、本地存储、识别、统计
  data/services/        图片存储、导出服务
  domain/entities/      领域对象
  domain/repositories/  仓储接口
  features/home/        拍摄、待确认队列
  features/items/       物品详情与编辑
  features/settings/    配置、Token、存储管理
  features/view/        搜索、筛选、导出
```

## 本地开发

环境要求：

- Flutter stable
- Dart SDK 满足 `^3.9.2`
- Android SDK
- iOS 开发时需要 Xcode 和 CocoaPods

常用命令：

```bash
flutter pub get
dart format lib
flutter analyze
flutter test
flutter build apk --debug
```

## 常见问题

### 1. `pod install` 之后 Xcode 打开很慢或者看起来卡死

先确认你打开的是 `Runner.xcworkspace`。

如果还是异常，优先检查：

- `~/Library/Developer/Xcode/DerivedData` 是否需要清理
- `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 下是否有损坏的描述文件
- Xcode 当前登录的 Apple ID / Team 是否正常

### 2. 连接测试失败

优先检查：

- API Key 是否有效
- 模型是否真的支持视觉输入
- Base URL 是否填写正确
- 当前网络是否能访问对应服务商

### 3. 安装 Android APK 提示签名不一致

说明手机里的旧版本与新 APK 签名不一致。不要直接卸载：卸载会删除本地目录和图片。正式发布从 v1.0.4 起必须始终使用同一个 release keystore，正常升级应直接覆盖安装。

如果旧测试包确实使用了不同签名，应先保全设备数据，再处理卸载；无法确认数据已备份时应停止操作。

## 发布

仓库里已经准备了 GitHub Release 工作流：

- `.github/workflows/release.yml`

推送 `v*` tag 后可自动构建 Android release 产物。

发布工作流需要配置以下 GitHub Actions Secrets：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

CI 会拒绝缺少固定签名的 release 构建，也会校验 tag 版本与 `pubspec.yaml` 一致，避免再次生成无法覆盖升级的随机 debug 签名包。

示例：

```bash
git tag v1.0.4
git push origin v1.0.4
```

如果手动发 Release，建议至少附带：

- 三个 Android APK
- `SHA256SUMS.txt`
- 对应版本说明

## 路线图

接下来值得继续做的方向：

- 一键生成多模型测试配置
- 同图多模型对比视图
- 更细的识别模板和结构化 schema
- 更强的 OCR / 文档类物品识别
- iOS TestFlight 发布流程打磨
- 更完整的开源产品介绍页和截图

## 许可证

本项目采用 [MIT License](LICENSE) 开源。

## 致谢

这个项目的核心价值，来自这些基础能力的组合：

- Flutter 的跨平台开发体验
- 多模态大模型的视觉理解能力
- 开源生态对个人产品和小工具的低门槛支持

如果你正在做家庭整理、搬家盘点、物品资产管理，欢迎直接拿这个项目继续改。
