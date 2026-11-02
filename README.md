# GhostHide — 极简 App 隐藏器（TrollStore 专用）

**只有一个功能：开关一拨，App 从 桌面 / App 资源库 / 设置 / Spotlight 同时消失。数据完好，随时恢复。**

界面：打开 → 面容 ID → 一列 App，每个 App 一个开关。
- 开（绿）= 隐藏，图标当场消失
- 关 = 恢复显示
- 右上角 Respring = 刷新桌面（如个别图标没即时消失）

## 使用前提
- iOS 15.3 + TrollStore（你的环境完美支持）
- 安装后在 TrollStore 设置里装好「持久化助手」

## 安装方法（无需 Mac）
1. 把本文件夹上传到你的 GitHub（新建仓库，全部文件传上去，包括 `.github` 文件夹）
2. 仓库页面 → Actions → "Build GhostHide.tipa" → Run workflow
3. 跑完后在本次运行页面底部下载 `GhostHide-tipa` 产物，得到 `GhostHide.tipa`
4. iPhone 上用 Safari 下载这个 .tipa → 用「其他应用打开」→ 选 TrollStore → 安装

## 工作原理（为什么藏得比其他开源 hider 干净）
桌面、资源库、设置、搜索的数据源都是系统 **LaunchServices**。
GhostHide 自带 root helper（巨魔的 persona-mgmt 机制提权），直接调系统私有 API
`LSApplicationWorkspace unregisterApplication:` 把 App 从 LaunchServices **注销**——
源头消失，四个地方同时消失。其他 hider 只藏桌面图标，所以设置里一翻一个准。

- 被藏 App 的**沙盒数据完全不动**，恢复后原样回来
- 隐藏记录存在 GhostHide 自己的沙盒里（`Documents/hidden.plist`），按 bundleID 对应原路径，绝不失联
- **不修改系统、不注入进程**，最坏情况只是某 App 暂时不显示，开关关掉必恢复

## 注意事项
1. **通知会暴露**：被藏 App 的通知仍会出现在锁屏。藏之前建议顺手关掉该 App 的通知
2. **iOS 升级前先全部恢复**（开关全关），升级后想藏再重新藏
3. 系统重建图标缓存后，被注销的 App 不会自己回来（因为 LaunchServices 里没有它）——这是隐藏可靠的另一面保障
4. GhostHide 自己请放在不容易被注意的位置，或改伪装：改 `resources/Info.plist` 里的 `CFBundleDisplayName`（比如改成"计算器"），重新构建即可

## 文件结构
```
GhostHide/
├── Makefile                     # 一键构建（Mac / GitHub Actions）
├── src/
│   ├── main.m / AppDelegate.*   # App 入口
│   ├── RootViewController.*     # 界面：列表 + 开关 + 面容ID
│   ├── AppScanner.*             # 扫描 /var/containers/Bundle/Application
│   ├── HideManager.*            # 隐藏记录管理
│   ├── SpawnRoot.*              # root 提权拉起 helper（TrollStore 官方机制）
│   └── helper/helper_main.m     # root helper：hide/show/respring
├── resources/
│   ├── Info.plist               # TSRootBinaries 声明（改伪装名在这里）
│   ├── app-entitlements.plist   # 巨魔权限（已避开 15.x+A12 封禁区）
│   └── helper-entitlements.plist
└── .github/workflows/build.yml  # 云端构建
```
