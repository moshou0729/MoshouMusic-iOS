//
//  FloatingSystemWindow.m
//  墨守music
//
//  方案照搬已真机验证的实现（TrollSpeed / 墨守提词器，iOS 14.7.1）。
//

#import "FloatingSystemWindow.h"

#include <dlfcn.h>

@implementation FloatingSystemWindow

// 系统窗口：退后台不被 backboardd 撤除
+ (BOOL)_isSystemWindow
{
    return YES;
}

// ★脱离 WindowServer 托管 —— 不做这条，应用退后台 1 秒窗口就消失
- (BOOL)_isWindowServerHostingManaged
{
    return NO;
}

// 参与命中测试。跨应用触摸由 HID entitlement + SpringBoard 托管路由负责；
// 空白处穿透由根视图 hitTest 返回 nil 实现（点击落到下层应用 / App 主窗口）。
- (BOOL)_ignoresHitTest
{
    return NO;
}

// 非安全上下文。⚠️ 安全上下文（YES）会破坏事件路由——
// 实测表现为整个界面（包括 App 自己的按钮）全部点不动。防录屏才用 YES。
- (BOOL)_isSecure
{
    return NO;
}

- (BOOL)_shouldCreateContextAsSecure
{
    return NO;
}

@end


@implementation FloatingWindowHosting

// 托管控制器必须强引用，否则失效
static id gHostingController = nil;

+ (void)initialize
{
    if (self == [FloatingWindowHosting class]) {
        // SpringBoardServices 默认不加载；不 dlopen，NSClassFromString 返回 nil
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
               RTLD_NOW);
    }
}

+ (BOOL)isAvailable
{
    return NSClassFromString(@"SBSAccessibilityWindowHostingController") != nil;
}

+ (unsigned int)contextIdOfWindow:(UIWindow *)window
{
    SEL sel = NSSelectorFromString(@"_contextId");
    if (![window respondsToSelector:sel]) {
        return 0;
    }
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"I@:"];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    [inv setTarget:window];
    [inv invoke];
    unsigned int ctx = 0;
    [inv getReturnValue:&ctx];
    return ctx;
}

+ (BOOL)registerWindow:(UIWindow *)window level:(double)level
{
    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        return NO;
    }
    unsigned int ctx = [self contextIdOfWindow:window];
    if (ctx == 0) {
        return NO;
    }
    if (gHostingController == nil) {
        gHostingController = [[cls alloc] init];
    }
    SEL sel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if (![gHostingController respondsToSelector:sel]) {
        return NO;
    }
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    [inv setTarget:gHostingController];
    [inv setArgument:&ctx atIndex:2];
    [inv setArgument:&level atIndex:3];
    [inv invoke];
    return YES;
}

+ (void)unregisterWindow:(UIWindow *)window
{
    if (!gHostingController) {
        return;
    }
    unsigned int ctx = [self contextIdOfWindow:window];
    if (ctx == 0) {
        return;
    }
    SEL sel = NSSelectorFromString(@"unregisterWindowWithContextID:");
    if (![gHostingController respondsToSelector:sel]) {
        return;
    }
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:I"];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    [inv setTarget:gHostingController];
    [inv setArgument:&ctx atIndex:2];
    [inv invoke];
}

@end
