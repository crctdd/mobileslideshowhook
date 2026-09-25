# 系统相册视频进度条

- Package: `com.crctdd.mobileslideshowhook`
- Version: `0.0.1`
- Target: iOS 15-17
- Process: `MobileSlideShow`
- No preference bundle
- Installs a draggable video progress slider into the system Photos video player

## Build

Default scheme is rootless:

```sh
make clean package
```

Explicit rootless:

```sh
make clean package THEOS_PACKAGE_SCHEME=rootless
```

Roothide, when using a Theos environment that supports the roothide scheme:

```sh
make clean package THEOS_PACKAGE_SCHEME=roothide
```

After installation, fully close Photos from the app switcher and reopen it so the tweak is loaded.


## GitHub Actions

This project includes `.github/workflows/build.yml`.

Open the repository's **Actions** page, choose **Build MobileSlideShowHook**, click **Run workflow**, then select:

- `all` — build rootless + roothide
- `rootless` — build rootless only
- `roothide` — build roothide only

The workflow runs only when manually triggered and uploads the generated `.deb` files as GitHub Actions artifacts.
