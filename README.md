# 系统相册视频进度条

- 插件名：系统相册视频进度条
- Package：`com.crctdd.mobileslideshowhook`
- Version：`0.0.1`
- 支持：iOS 15-17
- 注入：`com.apple.mobileslideshow`
- 无设置面板

## 本次修复

1. 修复首次进入视频时进度条不主动出现的问题。
   - 旧版依赖 AVPlayer/AVPlayerLayer 的后续调用。
   - 新版每 0.20 秒主动扫描当前窗口中真正可见的 AVPlayerLayer。
   - 不再需要先拖动系统相册自己的进度条来“唤醒”插件。

2. 视频识别继续限制为当前屏幕真正可见的大尺寸 AVPlayerLayer。
   - 普通照片页面不显示。
   - 相邻页面预加载的小型或离屏播放器不会触发。

3. 单击视频画面隐藏/显示插件进度条增加 0.32 秒防抖。
   - 减少 Photos 自身手势与插件手势同时识别时造成的重复切换。

4. 插件进度条位置上移。
   - 竖屏：safe area 底部上方 118 pt。
   - 横屏：safe area 底部上方 72 pt。
   - 避开系统相册原生视频进度条区域。

5. GitHub Actions 保留单包输出逻辑。
   - rootless artifact 仅一个 deb。
   - roothide artifact 仅一个 deb。

## GitHub Actions

Actions → Build MobileSlideShowHook → Run workflow

可选：

- `all`
- `rootless`
- `roothide`

安装后彻底退出系统相册，再重新打开测试。
