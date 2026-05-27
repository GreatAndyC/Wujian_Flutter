# iCheck / 物见

物见是一款面向家庭物品整理的 Flutter 应用。它用手机拍照记录物品，通过火山方舟兼容的视觉模型自动识别名称、分类、房间、箱号和物品属性，再把确认后的记录沉淀成本地清单，方便搬家、收纳、找东西和导出盘点表。

## 当前状态

- 应用版本：`1.0.0+1`
- Android 包名：`com.wujian.app.icheck`
- 默认模型：`doubao-seed-2-0-mini-260428`
- 默认 Base URL：`https://ark.cn-beijing.volces.com/api/v3`
- 当前 release 包已经包含 `CAMERA` 和 `INTERNET` 权限。
- 当前 release 构建使用 debug 签名，仅适合个人安装、测试和 GitHub Release 分发；正式上架前需要配置独立 release keystore。

## 功能

- 单张拍摄：拍完后立即识别，并可进入确认页编辑后入库。
- 连续拍摄：连续拍多件物品，结果进入待确认队列，后台逐条识别。
- 待确认队列：识别成功或失败的记录都可以手动确认、编辑或移除。
- 物品视图：按名称、分类、房间、箱号搜索，按分类筛选。
- 物品详情：保存名称、分类、数量、状态、描述、房间、箱号、品牌、型号、颜色、材质、备注和图片。
- 多配置管理：可保存多个模型/API 配置，并切换当前配置。
- 连接测试：在设置页验证 Base URL、API Key 和模型 ID 是否可用。
- Token 统计：分别统计当前配置和全部配置的请求数、Prompt tokens、Completion tokens 与 Total tokens。
- 本地存储统计：查看图片和导出文件占用，并清理未引用的本地媒体。
- 导出：支持按分类或按箱号导出为 PDF、Excel、Markdown，并调用系统分享。

## 安装 Release 包

打开手机 USB 调试，连接电脑后执行：

```powershell
adb devices
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

如果连接了多台设备，先从 `adb devices` 找到设备号，再指定设备安装：

```powershell
adb -s edd87c69 install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

`-r` 表示覆盖安装，不清除应用数据。

## Release 包说明

执行 `flutter build apk --release --split-per-abi` 后会生成三个 release APK。GitHub Release 页面也应该上传这三个文件，用户按手机 CPU 架构下载对应版本即可。

| 文件 | 适用设备 | 说明 |
| --- | --- | --- |
| `app-arm64-v8a-release.apk` | 绝大多数现代 Android 手机 | 推荐优先下载。常见于近几年的小米、OPPO、vivo、荣耀、华为、三星、一加等设备。 |
| `app-armeabi-v7a-release.apk` | 较老的 32 位 Android 手机 | 仅在老设备无法安装 arm64 包时使用。 |
| `app-x86_64-release.apk` | x86_64 Android 模拟器或少量 x86 设备 | 主要用于电脑上的 Android 模拟器测试。 |

如果不确定手机架构，可以运行：

```powershell
adb shell getprop ro.product.cpu.abilist
```

返回结果里包含 `arm64-v8a` 就安装 `app-arm64-v8a-release.apk`。

## 从源码构建

环境要求：

- Flutter stable，Dart SDK 满足 `^3.9.2`
- Android SDK 和 platform-tools
- 已连接 Android 真机或模拟器

构建并安装推荐流程：

```powershell
cd E:\Project\iCheck
flutter pub get
flutter build apk --release --split-per-abi
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

如果在国内网络环境构建，可以指定镜像：

```powershell
$env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
flutter pub get
flutter build apk --release --split-per-abi
```

## 首次使用

1. 安装 APK 后打开应用，允许相机权限。
2. 进入“设置”页，填写 Base URL、API Key 和模型 ID。
3. 点击“测试连接”，确认接口可用。
4. 回到“主页”，选择单张拍摄或连续拍摄。
5. 在待确认队列中检查识别结果，编辑后确认入库。
6. 到“视图”页搜索、筛选或导出清单。

API Key 会通过 `flutter_secure_storage` 存储在设备安全存储中；普通配置和物品记录保存在本地。

## GitHub Release 发布

仓库内已经准备了：

- `.github/workflows/release.yml`：推送 `v*` tag 时自动构建 split APK，并上传到 GitHub Release。
- `docs/releases/v1.0.0.md`：`v1.0.0` Release 页面正文，可直接复制到 GitHub Release 描述。

发布步骤：

```powershell
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions 完成后，Release 页面会带上三个 APK 和 `SHA256SUMS.txt`。如果手动发布，也请上传这四个文件。

## 常见问题

### SocketFailed host lookup

如果提示类似：

```text
SocketFailed host lookup: 'ark.cn-beijing.volces.com'
```

优先检查：

- 当前 APK 是否是最新 release 包，旧 release 曾缺少 `android.permission.INTERNET` 权限。
- 手机是否能访问网络。
- Base URL 是否写成 `https://ark.cn-beijing.volces.com/api/v3`，不要在末尾重复追加 `/chat/completions`。

### 连接测试失败

- 确认 API Key 有效。
- 确认模型 ID 已开通并支持视觉输入。
- 确认手机网络可以访问火山方舟服务。
- 如果使用代理或公司网络，先切到普通 Wi-Fi 或移动网络重试。

### 覆盖安装失败

如果提示签名不一致，说明手机上已有不同签名的旧包。个人测试时可以先卸载再安装，但这会删除应用本地数据：

```powershell
adb uninstall com.wujian.app.icheck
adb install build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

## 项目结构

```text
lib/
  app/                  应用入口、主题和组合根
  data/repositories/    本地存储、设置、识别和 token 统计实现
  data/services/        PDF、Excel、Markdown 导出和媒体存储服务
  domain/entities/      物品、配置、导出格式、统计等领域对象
  domain/repositories/  仓储接口
  features/home/        首页、拍摄和待确认队列
  features/items/       物品详情和编辑表单
  features/settings/    API 配置、token 统计和存储管理
  features/shell/       AppController、作用域和主导航
  features/view/        物品视图、搜索、筛选和导出入口
```

## 开发命令

```powershell
flutter pub get
dart format lib
dart analyze lib
flutter test
flutter build apk --release --split-per-abi
```

## 发布前检查清单

- `android/app/src/main/AndroidManifest.xml` 包含 `CAMERA` 和 `INTERNET` 权限。
- `pubspec.yaml` 中的 `version` 已更新。
- `docs/releases/` 中的发布说明已更新。
- 已执行 `flutter build apk --release --split-per-abi`。
- 已在真机上安装 `app-arm64-v8a-release.apk` 并完成一次连接测试。
- GitHub Release 上传了三个 APK 和 `SHA256SUMS.txt`。
