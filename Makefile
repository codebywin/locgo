TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ACBFace

ACBFace_FILES = $(wildcard src/*.m)
ACBFace_FRAMEWORKS = UIKit AVFoundation CoreGraphics CoreImage QuartzCore
ACBFace_LIBRARIES = z
ACBFace_CFLAGS = -fobjc-arc
ACBFace_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
