# 编译 vvebo_fix.dylib（需在 macOS + Xcode 环境下执行）
# 用法：make
SDK  := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC   := clang
ARCH := arm64

vvebo_fix.dylib: vvebo_fix.m
	$(CC) -dynamiclib -arch $(ARCH) -isysroot $(SDK) -framework Foundation $< -o $@

clean:
	rm -f vvebo_fix.dylib

.PHONY: clean
