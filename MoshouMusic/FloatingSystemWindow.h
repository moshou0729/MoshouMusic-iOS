//
//  FloatingSystemWindow.h
//  墨守music
//
//  TrollStore 专属：系统级全局悬浮窗（跨应用 / 主屏 / 锁屏可见）
//
//  原理（参考 Helium / TrollSpeed 的 AssistiveTouch 逻辑）：
//  1. 覆写 UIWindow 的私有方法，让 backboardd 把该窗口当作「系统安全窗口」渲染；
//  2. 通过 SBSAccessibilityWindowHostingController 把窗口的 contextId 注册到
//     SpringBoard 的辅助功能窗口托管服务，窗口便脱离应用生命周期显示。
//
//  需要 entitlement：com.apple.springboard.accessibility-window-hosting
//  若权限缺失或系统版本不支持，register 会返回 NO，此时退化为应用内悬浮。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 系统级悬浮窗口：覆写 UIWindow 私有方法以启用系统窗口渲染路径
@interface FloatingSystemWindow : UIWindow
@end

/// SpringBoard 辅助功能窗口托管桥接
@interface FloatingWindowHosting : NSObject

/// 把窗口注册到系统托管服务（成功后即可跨应用显示）
/// @return YES 表示注册成功
+ (BOOL)registerWindow:(UIWindow *)window level:(double)level;

/// 注销窗口（隐藏悬浮窗时调用）
+ (void)unregisterWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
