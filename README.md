# 墨守music (MoshouMusic)

> 墨韵守音 · 巨魔音乐
>
> iOS 巨魔版多源聚合音乐播放器，基于 TrollStore 安装，参考 LXMusic Mobile 架构独立开发。

## 技术栈

- **语言**: Swift 5
- **UI**: UIKit (iOS 14+ 兼容)
- **设计**: Material Design 3 鲜艳活泼风格
- **JS引擎**: JavaScriptCore (系统内置，兼容 LXMusic 社区脚本)
- **播放器**: AVQueuePlayer + MPNowPlayingInfoCenter
- **悬浮窗**: UIWindow + 私有 API (TrollStore 专属)

## 功能

- 多源音乐搜索 (kw/tx/mg/wy/kg)
- 自定义源脚本 (兼容 LXMusic 脚本格式)
- 流式播放 + 自动换源
- LRC 歌词同步显示
- 系统级悬浮歌词 (TrollStore 专属)
- 歌单管理 + 本地下载
- 后台播放 + 锁屏控制
- 排行榜 + 歌单导入

## 开发环境

- Windows + VS Code (无需 Mac)
- GitHub Actions CI 自动编译出 .ipa
- TrollStore 安装 (iOS 14.0 - 16.6.1)

## 构建

```bash
# 1. 安装 XcodeGen (CI 会自动安装)
brew install xcodegen

# 2. 生成 Xcode 项目
xcodegen generate

# 3. 编译 (需要 macOS + Xcode)
xcodebuild -project MoshouMusic.xcodeproj -scheme MoshouMusic -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO

# 4. 打包 IPA
mkdir -p Payload && cp -r build/Release-iphoneos/MoshouMusic.app Payload/ && zip -r MoshouMusic.ipa Payload
```

## 安装

1. 从 GitHub Actions 下载 `MoshouMusic.ipa`
2. 传到 iPhone
3. 用 TrollStore 安装

## 项目结构

```
MoshouMusic-iOS/
├── .github/workflows/build.yml    # CI 编译配置
├── MoshouMusic.entitlements       # 巨魔权限
├── project.yml                    # XcodeGen 配置
└── MoshouMusic/
    ├── App/                       # 入口 + Info.plist
    ├── Resources/                 # 资源 + 脚本
    ├── Source/
    │   ├── Engine/                # JS 脚本引擎
    │   ├── Player/                # 播放器 + 歌词
    │   ├── Network/               # 网络层
    │   ├── Storage/               # 数据存储
    │   ├── FloatingLyrics/        # 悬浮歌词
    │   ├── Models/                # 数据模型
    │   └── Utils/                 # 工具类
    └── UI/
        ├── Common/                # 通用组件
        ├── Search/                # 搜索页
        ├── Player/                # 播放页
        ├── Playlist/              # 歌单页
        ├── Ranking/               # 排行榜
        ├── Settings/              # 设置页
        └── Theme/                 # 主题色彩
```

## License

MIT
