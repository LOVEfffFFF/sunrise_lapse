# SunriseLapse 日出延时相机

解决 iOS 原生延时摄影「开始时锁定对焦，拍日出后面全糊」的问题。
**采集与合成策略完全复刻原生相机的延时摄影**，唯一改动：对焦改为连续自动对焦（`continuousAutoFocus` + 平滑对焦），曝光保持连续自动。

## 与原生相机一致的规则

- 动态抽帧间隔，随录制时长翻倍（0–10min：每秒 2 帧；10–20min：每秒 1 帧；20–40min：每 2 秒 1 帧；以此类推）
- 每跨一档，已拍帧隔帧丢弃一半
- 成片恒为 20–40 秒、1080p、30fps、HEVC，存入系统相册
- 白平衡/防抖/降噪等全部系统自动

## 构建

工程文件由 [XcodeGen](https://github.com/yonsm/XcodeGen) 生成：

```bash
brew install xcodegen
xcodegen
xcodebuild -project SunriseLapse.xcodeproj -scheme SunriseLapse \
  -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

CI 见 `.github/workflows/build_ios.yml`（手动触发，选 `release` 才会上传 IPA artifact，保留 1 天）。

## 当前限制（v1）

- 仅竖屏（日出三脚架场景）
- 录制中退后台/锁屏会被 iOS 回收相机，App 会把已录部分合成保存
- 免费 Apple ID 侧载签名 7 天有效，到期重签即可
