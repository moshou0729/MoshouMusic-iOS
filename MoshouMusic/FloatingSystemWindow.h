//
//  FloatingSystemWindow.h
//  墨守music
//
//  TrollStore 专属：系统级全局悬浮窗（跨应用 / 主屏 / 锁屏可见）
//
//  实现照搬已真机验证的方案（参考 Lessica/TrollSpeed、墨守提词器）：
//  1. ObjC 子类覆写 UIWindow 私有方法，脱离 WindowServer 托管，
//     否则应用一退后台窗口立即被撤（注册成功也没用）；
//  2. dlopen SpringBoardServices 后，通过 SBSAccessibilityWindowHostingController
//     的 registerWindowWithContextID:atLevel: 把窗口注册进 SpringBoard 系统窗口树。
//
//  需要 entitlement：com.apple.springboard.accessibility-window-hosting（钥匙）
//  + HID 事件族（跨应用触摸路由）。CI 构建后必须用 codesign 注入 entitlements。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 系统级悬浮窗口：覆写 UIWindow 私有方法以脱离 WindowServer 托管
@interface FloatingSystemWindow : UIWindow
@end

/// SpringBoard 辅助功能窗口托管桥接（NSInvocation 动态调用，编译期零依赖）
@interface FloatingWindowHosting : NSObject

/// SBSAccessibilityWindowHostingController 类是否可用（未 dlopen 恒为 NO）
+ (BOOL)isAvailable NS_SWIFT_NAME(isAvailable());

/// 读取窗口的 contextId（窗口显示后才有值，取不到返回 0）
+ (unsigned int)contextIdOfWindow:(UIWindow *)window NS_SWIFT_NAME(contextIdOf(window:));

/// 把窗口注册到 SpringBoard 系统窗口树（成功后即可跨应用显示）
+ (BOOL)registerWindow:(UIWindow *)window level:(double)level NS_SWIFT_NAME(register(window:level:));

/// 注销窗口（用户手动关闭悬浮窗时调用）
+ (void)unregisterWindow:(UIWindow *)window NS_SWIFT_NAME(unregister(window:));

@end

NS_ASSUME_NONNULL_END
