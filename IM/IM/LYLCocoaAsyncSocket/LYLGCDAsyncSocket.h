//
//  LYLGCDAsyncSocket.h
//  IM
//
//  Created by LYL on 2024/8/6.
//

#import <Foundation/Foundation.h>
#import "LYLGCDAsyncSocketPreBuffer.h"
#import "LYLGCDAsyncReadPacket.h"
#import "LYLGCDAsyncWritePacket.h"
#import <CocoaAsyncSocket/GCDAsyncSocket.h>

NS_ASSUME_NONNULL_BEGIN

@interface LYLGCDAsyncSocket : NSObject

@property (nonatomic, assign) uint32_t flags; // 标记socket的状态
@property (nonatomic, assign) uint16_t config; // 标记socket的配置

@property (nonatomic, weak) id<GCDAsyncSocketDelegate> delegate;
@property (nonatomic, strong) dispatch_queue_t delegateQueue; // 代理队列

@property (nonatomic, assign) int socket4FD; // IPv4 文件描述符
@property (nonatomic, assign) int socket6FD; // IPv6 文件描述符
@property (nonatomic, assign) int socketUN; // UNIX域套接字 文件描述符
@property (nonatomic, strong) NSURL *socketUrl; // UNIX域套接字的路径
@property (nonatomic, assign) int stateIndex; // 跟踪socket的状态变化
@property (nonatomic, strong) NSData *connectInterface4; // 链接接口
@property (nonatomic, strong) NSData *connectInterface6;
@property (nonatomic, strong) NSData *connectInterfaceUN;

@property (nonatomic, strong) dispatch_queue_t socketQueue; // 执行套接字操作的调度队列

@property (nonatomic, strong) dispatch_source_t accept4Source; // 各种事情的回调
@property (nonatomic, strong) dispatch_source_t accept6Source;
@property (nonatomic, strong) dispatch_source_t acceptUNSource;
@property (nonatomic, strong) dispatch_source_t connectTimer;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) dispatch_source_t writeSource;
@property (nonatomic, strong) dispatch_source_t readTimer;
@property (nonatomic, strong) dispatch_source_t writeTimer;

@property (nonatomic, strong) NSMutableArray *readQueue;
@property (nonatomic, strong) NSMutableArray *writeQueue;

@property (nonatomic, strong) LYLGCDAsyncReadPacket *currentRead; // 当前正在处理的读操作
@property (nonatomic, strong) LYLGCDAsyncWritePacket *currentWrite; // 当前正在处理的写操作

@property (nonatomic, assign) unsigned long socketFDBytesAvailable; // 套接字可读取的字节数

@property (nonatomic, strong) LYLGCDAsyncSocketPreBuffer *preBuffer; // 预缓存区

#if TARGET_OS_IPHONE
@property (nonatomic, assign) CFStreamClientContext streamContext; // 流相关回调的上下文信息
@property (nonatomic, assign) CFReadStreamRef readStream; // 读取流对象
@property (nonatomic, assign) CFWriteStreamRef writeStream; // 写入流对象
#endif

@property (nonatomic, assign) SSLContextRef sslContext; // 管理 SSL 加密连接的上下文
@property (nonatomic, strong) LYLGCDAsyncSocketPreBuffer *sslPreBuffer; // SSL 预缓存区
@property (nonatomic, assign) size_t sslWriteCachedLength; // SSL 写 缓存的长度
@property (nonatomic, assign) OSStatus sslErrCode; // 管理 SSL/TLS 加密的属性
@property (nonatomic, assign) OSStatus lastSSLHandshakeError; // 管理 SSL/TLS 加密的属性

@property (nonatomic, assign) void *IsOnSocketQueueOrTargetQueueKey; // 确保操作在正确队列上执行的关键

@property (nonatomic, strong) id userData; // 自定义数据
@property (nonatomic, assign) NSTimeInterval alternateAddressDelay; // 处理连接到备用地址的延迟时间

@end

NS_ASSUME_NONNULL_END
