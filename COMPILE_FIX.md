# 0.0.1 compile fix

Fixed the GitHub Actions/Xcode 26 compile errors without changing the version:

- Removed the custom `beginTracking:withEvent:` override that the current SDK headers reject for `UISlider`.
- Replaced deprecated `UIApplication.windows` access with `UIScene` / `UIWindowScene.windows`.
- Kept the deployment target and package version at `0.0.1`.
