//
//  LYLGCDAsyncSocket.m
//  IM
//
//  Created by LYL on 2024/8/6.
//

#import "LYLGCDAsyncSocket.h"

#define SOCKET_NULL -1

@implementation LYLGCDAsyncSocket

- (instancetype)initWithDelegate:(id<GCDAsyncSocketDelegate>)aDelegate delegateQueue:(dispatch_queue_t)dq socketQueue:(dispatch_queue_t)sq
{
    if((self = [super init]))
    {
        self.delegate = aDelegate;
        
        // 代理回调都在这个队列中执行，可串可并，推荐串行
        self.delegateQueue = dq;
        
        self.socket4FD = SOCKET_NULL;
        self.socket6FD = SOCKET_NULL;
        self.socketUN = SOCKET_NULL;
        self.socketUrl = nil;
        self.stateIndex = 0;
        
        if (sq)
        {
            NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0),
                     @"The given socketQueue parameter must not be a concurrent queue.");
            NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                     @"The given socketQueue parameter must not be a concurrent queue.");
            NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                     @"The given socketQueue parameter must not be a concurrent queue.");
            
            // 必须是个串行队列
            self.socketQueue = sq;
            #if !OS_OBJECT_USE_OBJC
            dispatch_retain(sq);
            #endif
        }
        else
        {
            self.socketQueue = dispatch_queue_create([GCDAsyncSocketQueueName UTF8String], NULL);
        }
        
        // 这里是将 socketQueue 与 self 绑定起来，痛苦 IsOnSocketQueueOrTargetQueueKey 的方式，确保self 在socketQueue 的队列上保持操作
        
        _IsOnSocketQueueOrTargetQueueKey = &_IsOnSocketQueueOrTargetQueueKey;
        
        void *nonNullUnusedPointer = (__bridge void *)self;
        
        // 将上下文信息与特定队列关联，这对于实现队列特定的行为、避免重复的上下文设置以及调试和优化异步代码非常有用
        
        dispatch_queue_set_specific(self.socketQueue, self.IsOnSocketQueueOrTargetQueueKey, nonNullUnusedPointer, NULL);
        
        self.readQueue = [[NSMutableArray alloc] initWithCapacity:5];
        self.currentRead = nil;
        
        self.writeQueue = [[NSMutableArray alloc] initWithCapacity:5];
        self.currentWrite = nil;
        
        self.preBuffer = [[LYLGCDAsyncSocketPreBuffer alloc] initWithCapacity:(1024 * 4)];
        self.alternateAddressDelay = 0.3;
    }
    return self;
}

@end
