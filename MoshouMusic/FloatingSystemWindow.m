//
//  FloatingSystemWindow.m
//  墨守music
//

#import "FloatingSystemWindow.h"

#import <objc/runtime.h>
#import <objc/message.h>

@implementation FloatingSystemWindow

// 声明为系统窗口：backboardd 不会因为应用进入后台而隐藏它
+ (BOOL)_isSystemWindow
{
    return YES;
}

// 窗口上下文不由 window server 托管（交由 SpringBoard 的辅助功能托管服务管理）
- (BOOL)_isWindowServerHostingManaged
{
    return NO;
}

// 不参与命中测试。系统安全窗口一旦参与触摸路由，会吃掉整屏事件
// （表现为 App 里所有按钮点不动）。悬浮框的拖拽 / 缩放改由普通 overlay 窗口承担。
- (BOOL)_ignoresHitTest
{
    return YES;
}

// 安全窗口：可以在锁屏/其他应用内容之上合成
- (BOOL)_isSecure
{
    return YES;
}

- (BOOL)_shouldCreateContextAsSecure
{
    return YES;
}

@end

@implementation FloatingWindowHosting

/// 共享的托管控制器（注册与注销必须是同一个实例）
+ (id)sharedHostingController
{
    Class hostingClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (hostingClass == Nil) {
        return nil;
    }
    static id hostingController = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hostingController = [[hostingClass alloc] init];
    });
    return hostingController;
}

/// 读取窗口的 contextId，取不到返回 0
+ (unsigned int)contextIdOfWindow:(UIWindow *)window
{
    SEL contextSelector = NSSelectorFromString(@"_contextId");
    if (![window respondsToSelector:contextSelector]) {
        return 0;
    }
    unsigned int (*contextIdIMP)(id, SEL) = (unsigned int (*)(id, SEL))objc_msgSend;
    return contextIdIMP(window, contextSelector);
}

+ (BOOL)registerWindow:(UIWindow *)window level:(double)level
{
    id hostingController = [self sharedHostingController];
    if (hostingController == nil) {
        return NO;
    }

    // UIWindow 私有属性 _contextId —— 窗口显示后才有有效值
    unsigned int contextId = [self contextIdOfWindow:window];
    if (contextId == 0) {
        return NO;
    }

    SEL registerSelector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if (![hostingController respondsToSelector:registerSelector]) {
        return NO;
    }
    void (*registerIMP)(id, SEL, unsigned int, double) = (void (*)(id, SEL, unsigned int, double))objc_msgSend;
    registerIMP(hostingController, registerSelector, contextId, level);

    return YES;
}

+ (void)unregisterWindow:(UIWindow *)window
{
    id hostingController = [self sharedHostingController];
    if (hostingController == nil) {
        return;
    }

    unsigned int contextId = [self contextIdOfWindow:window];
    if (contextId == 0) {
        return;
    }

    SEL unregisterSelector = NSSelectorFromString(@"unregisterWindowWithContextID:");
    if (![hostingController respondsToSelector:unregisterSelector]) {
        return;
    }
    void (*unregisterIMP)(id, SEL, unsigned int) = (void (*)(id, SEL, unsigned int))objc_msgSend;
    unregisterIMP(hostingController, unregisterSelector, contextId);
}

@end
