# 系统相册视频进度条

- 插件名：系统相册视频进度条
- Package：`com.crctdd.mobileslideshowhook`
- Version：`0.0.1`
- 支持：iOS 15-17
- 注入：`com.apple.mobileslideshow`
- 无设置面板

## 本次调整

这一版不再自己额外监听“单击屏幕”来隐藏/显示进度条。

现在插件进度条直接跟随系统相册自己的控制栏状态：

- 系统相册原生进度条、顶部/底部控制栏显示 → 插件进度条显示
- 点一下画面，系统相册原生控制栏消失 → 插件进度条一起消失
- 再点一下，系统相册原生控制栏回来 → 插件进度条一起回来
- 系统相册自动隐藏控制栏时 → 插件也跟着隐藏

这样不会再出现系统控制栏已经消失、插件进度条还单独留在屏幕上的情况。

其他上一版已经正常的逻辑保持：

- 首次进入视频主动检测
- 普通照片不显示
- 视频切换自动重新绑定
- 插件进度条位置高于系统原生进度条
- rootless / roothide 工作流各只输出一个 deb

## GitHub Actions

Actions → Build MobileSlideShowHook → Run workflow

可选：

- `all`
- `rootless`
- `roothide`
