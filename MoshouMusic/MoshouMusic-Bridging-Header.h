//
//  MoshouMusic-Bridging-Header.h
//  桥接头文件 —— 引入系统 zlib，供 LX 同步的 gzip 编解码使用
//

#import <zlib.h>

// TrollStore 系统级全局悬浮窗（OC 私有 API 桥接）
#import "FloatingSystemWindow.h"
