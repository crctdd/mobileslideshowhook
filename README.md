# 系统相册视频进度条

- 插件名：系统相册视频进度条
- Package：`com.crctdd.mobileslideshowhook`
- Version：`0.0.1`
- 支持：iOS 15-17
- 注入：`com.apple.mobileslideshow`
- 无设置面板

## 本次调整

1. 只有当前页面存在真正可见的 `AVPlayerLayer`，且 `AVPlayerItem.presentationSize` 为有效视频尺寸时才显示进度条。
2. 从视频切换到普通照片后，检测不到可见视频层会立即隐藏进度条。
3. 观看视频时单击画面可隐藏自定义进度条，再单击一次恢复。
4. 点击进度条自身或系统按钮时，不触发隐藏/显示切换。
5. GitHub Actions 每次构建前清空 `packages`，并强制每个 artifact 只保留一个 `.deb`，解决 `roothide` 下载后出现两个包的问题。

## GitHub Actions

Actions → Build MobileSlideShowHook → Run workflow

可选：

- `all`
- `rootless`
- `roothide`

安装后彻底退出系统相册，再重新打开测试。
