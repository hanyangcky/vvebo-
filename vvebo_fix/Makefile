.RECIPEPREFIX = >
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  SDK := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
  ifeq ($(SDK),)
    SDK := $(shell ls -d /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk 2>/dev/null | head -1)
  endif
endif

CC   := clang
ARCH := arm64
MIN  := 11.0

vvebo_fix.dylib: vvebo_fix.m
>@echo ">> SDK = $(SDK)"
>$(CC) -dynamiclib -arch $(ARCH) -miphoneos-version-min=$(MIN) -isysroot $(SDK) -framework Foundation $< -o $@

clean:
>rm -f vvebo_fix.dylib

.PHONY: clean
