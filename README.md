# 系统相册视频进度条

- 插件名：系统相册视频进度条
- Package：`com.crctdd.mobileslideshowhook`
- Version：`0.0.1`
- 支持：iOS 15-17
- 注入：`com.apple.mobileslideshow`
- 无设置面板

## 这一版的播放器识别方式

不再只扫描 UIView/CALayer 树寻找播放器。

现在同时 Hook：

- `AVPlayerLayer`
- `AVPlayerViewController`
- `AVPlayer`

当系统相册把视频播放器交给 AVFoundation/AVKit 时直接捕获播放器，再把自定义进度条与该播放器绑定。

## GitHub Actions

Actions → Build MobileSlideShowHook → Run workflow

可选：

- `all`
- `rootless`
- `roothide`

安装后完全退出系统相册，再重新打开测试。
