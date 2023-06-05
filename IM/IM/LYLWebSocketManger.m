//
//  LYLWebSocketManger.m
//  IM
//
//  Created by LYL on 2023/5/30.
//

#import "LYLWebSocketManger.h"
#import "SocketRocket.h"

#define dispatch_main_async_safe(block)\
    if ([NSThread isMainThread]) {\
        block();\
    } else {\
        dispatch_async(dispatch_get_main_queue(), block);\
    }


@interface LYLWebSocketManger() <SRWebSocketDelegate>

@property (nonatomic, strong) SRWebSocket *webSocket;

@property (nonatomic, strong) NSTimer *heartBeat;

@property (nonatomic, assign) NSTimeInterval reConnectTime;


@end

@implementation LYLWebSocketManger

+ (instancetype)share{
    static dispatch_once_t onceToken;
        static LYLWebSocketManger *instance = nil;
        dispatch_once(&onceToken, ^{
            instance = [[self alloc]init];
            [instance _initSocket];
        });
        return instance;
}

- (void)_initSocket {
    
    if (self.webSocket) {
        return;
    }
    
    self.webSocket = [[SRWebSocket alloc]initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"ws://%@:%d", self.host, self.port]]];
    self.webSocket.delegate = self;
    //设置代理线程queue
    NSOperationQueue *queue = [[NSOperationQueue alloc]init];
    queue.maxConcurrentOperationCount = 1;
    [self.webSocket setDelegateOperationQueue:queue];
    //连接
    [self.webSocket open];
}

- (void)initHeartBeat {
    dispatch_main_async_safe(^{
        [self destoryHeartBeat];
        
        __weak typeof(self) weakSelf = self;
        self.heartBeat = [NSTimer scheduledTimerWithTimeInterval:3*60 repeats:YES block:^(NSTimer * _Nonnull timer) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf sendMsg:@"heart"];
        }];
    })
}

- (void)destoryHeartBeat {
    dispatch_main_async_safe(^{
        if (self.heartBeat){
            [self.heartBeat invalidate];
            self.heartBeat = nil;
        }
    })
}

- (void)connect{
    [self _initSocket];
    _reConnectTime = 0;
}

- (void)reConnect{
    if (_reConnectTime > 64){
        return;
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_reConnectTime * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
           self.webSocket = nil;
           [self _initSocket];
    });
    
    if (_reConnectTime == 0){
        _reConnectTime = 2;
    } else {
        _reConnectTime *= 2;
    }
    
}

- (void)disConnect{
    if (self.webSocket){
        [self.webSocket close];
        self.webSocket = nil;
    }
}

- (void)sendMsg:(NSString *)msg{
    [self.webSocket sendString:msg error:nil];
}

- (void)ping{
    [self.webSocket sendPing:nil error:nil];
}

#pragma mark - SRWebSocketDelegate

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message
{
    NSLog(@"服务器返回收到消息:%@",message);
}


- (void)webSocketDidOpen:(SRWebSocket *)webSocket
{
    NSLog(@"连接成功");
    
    //连接成功了开始发送心跳
    [self initHeartBeat];
}

//open失败的时候调用
- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error
{
    NSLog(@"连接失败.....\n%@",error);
    
    //失败了就去重连
    [self reConnect];
}

//网络连接中断被调用
- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {

    NSLog(@"被关闭连接，code:%ld,reason:%@,wasClean:%d",code,reason,wasClean);
    
    //如果是被用户自己中断的那么直接断开连接，否则开始重连
    if (code == 0) {
        [self disConnect];
    }else{
        [self reConnect];
    }
    //断开连接时销毁心跳
    [self destoryHeartBeat];

}

//sendPing的时候，如果网络通的话，则会收到回调，但是必须保证ScoketOpen，否则会crash
- (void)webSocket:(SRWebSocket *)webSocket didReceivePong:(NSData *)pongPayload
{
    NSLog(@"收到pong回调");

}

@end
