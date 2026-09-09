// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <TargetConditionals.h>

// sdl_window.cpp's own SetWindowIcon already documents the split: macOS uses this
// AppKit-based native-dock-icon implementation, while iOS (no AppKit, no per-window
// dock icon concept) falls back to the generic SDL3+stb_image path there instead. This
// file itself never carried the matching guard, so it still tried to compile against
// <Cocoa/Cocoa.h> (a macOS-only framework header, absent from the iOS SDK) on iOS too.
#if !TARGET_OS_IPHONE

#include <filesystem>
#include <Cocoa/Cocoa.h>
#include <SDL3/SDL_video.h>

#include "sdl_window.h"

namespace Frontend {

void SetWindowIcon(SDL_Window* window, const std::vector<u8>& png) {
    @autoreleasepool {
        NSData* pngData = [NSData dataWithBytes:png.data() length:png.size()];
        NSImage* baseIcon = [[[NSImage alloc] initWithData:pngData] autorelease];

        // Transform the icon to match native look-and-feel.
        constexpr double ScaleFactor = 13.0 / 16.0;
        constexpr double CornerRadiusFactor = 22.0 / 100.0;

        const double baseIconWidth = baseIcon.size.width;
        const double baseIconHeight = baseIcon.size.height;
        const double iconWidth = baseIconWidth * ScaleFactor;
        const double iconHeight = baseIconHeight * ScaleFactor;
        const double iconX = (baseIconWidth - iconWidth) / 2.0;
        const double iconY = (baseIconHeight - iconHeight) / 2.0;
        const double cornerRadiusX = iconWidth * CornerRadiusFactor;
        const double cornerRadiusY = iconHeight * CornerRadiusFactor;

        NSRect bounds = NSMakeRect(iconX, iconY, iconWidth, iconHeight);
        NSBezierPath* maskPath = [NSBezierPath bezierPathWithRoundedRect:bounds
                                                                 xRadius:cornerRadiusX
                                                                 yRadius:cornerRadiusY];

        NSImage* nativeIcon = [[[NSImage alloc] initWithSize:baseIcon.size] autorelease];
        [nativeIcon lockFocus];
        [maskPath addClip];
        [baseIcon drawInRect:bounds
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0f];
        [nativeIcon unlockFocus];

        [NSApp setApplicationIconImage:nativeIcon];
    }
}

} // namespace Frontend

#endif // !TARGET_OS_IPHONE
