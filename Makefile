ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MobileSlideShowHook
MobileSlideShowHook_FILES = Tweak.xm
MobileSlideShowHook_CFLAGS = -fobjc-arc
MobileSlideShowHook_FRAMEWORKS = UIKit AVFoundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
