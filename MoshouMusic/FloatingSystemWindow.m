//
//  FloatingSystemWindow.m
//  墨守music
//
//  方案照搬已真机验证的实现（TrollSpeed / 墨守提词器，iOS 14.7.1）。
//

#import "FloatingSystemWindow.h"

#include <dlfcn.h>
#include <notify.h>

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

// v1.0.127：脉冲期间锁定根视图尺寸。UIWindow 会在布局时把根视图拉成自身
// bounds —— 不拦截的话窗口扩 24pt 可见内容跟着拉伸（「底边下探」可见的根因）。
// 锁定后扩出的区域透明，SB 照样看到大幅几何变化并重合成，但用户什么都看不到。
- (void)layoutSubviews
{
    [super layoutSubviews];
    if (_pulseContentLock && self.rootViewController.view) {
        CGRect f = self.rootViewController.view.frame;
        f.size = _pulseContentSize;
        self.rootViewController.view.frame = f;
    }
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

#pragma mark - v1.0.156 屏幕熄灭状态

/// 读 SpringBoard 的 com.apple.springboard.hasBlankedScreen 通知状态。
/// notify_register_check / notify_get_state 是公开的 notify(3) API，
/// 不需要额外 entitlement，App 在后台也能读到。
+ (BOOL)isScreenBlanked
{
    static int blankToken = 0;
    if (blankToken == 0) {
        if (notify_register_check("com.apple.springboard.hasBlankedScreen", &blankToken) != NOTIFY_STATUS_OK) {
            blankToken = 0;
            return NO;
        }
    }
    uint64_t state = 0;
    if (notify_get_state(blankToken, &state) != NOTIFY_STATUS_OK) {
        return NO;
    }
    return state != 0;
}

@end
