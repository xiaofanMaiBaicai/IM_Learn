//
//  LYLGCDAsyncSocketManger.m
//  IM
//
//  Created by L on 2023/5/29.
//

#import "LYLGCDAsyncSocketManger.h"
#import "GCDAsyncSocket.h"

@interface LYLGCDAsyncSocketManger() <GCDAsyncSocketDelegate>

@property (nonatomic , strong) GCDAsyncSocket *tcpSocket;

@property (nonatomic , strong) dispatch_queue_t socketQueue;

@end

@implementation LYLGCDAsyncSocketManger

+ (instancetype)share{
    static dispatch_once_t onceToken;
        static LYLGCDAsyncSocketManger *instance = nil;
        dispatch_once(&onceToken, ^{
            instance = [[self alloc]init];
            [instance _initSocket];
        });
        return instance;
}

- (BOOL)connectWith:(NSString*)host port:(uint16_t)port{
    return [self.tcpSocket connectToHost:host onPort:port error:nil];
}

- (void)disConnect{
    [self.tcpSocket disconnect];
}

- (void)sendMsg:(NSString *)msg{
    
    NSData *data  = [msg dataUsingEncoding:NSUTF8StringEncoding];
    [self.tcpSocket writeData:data withTimeout:-1 tag:100];
}

- (void)pullTheMsg{
    //监听读数据的代理  -1永远监听，不超时，但是只收一次消息，
    //所以每次接受到消息还得调用一次
    [self.tcpSocket readDataWithTimeout:-1 tag:110];
}

- (void)_initSocket {
    self.tcpSocket = [[GCDAsyncSocket alloc]initWithDelegate:self delegateQueue:self.socketQueue];
}

#pragma mark - GCDAsyncSocketDelegate
//连接成功调用
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    NSLog(@"连接成功,host:%@,port:%d",host,port);
    [self pullTheMsg];
    //心跳写在这...
}

//断开连接的时候调用
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(nullable NSError *)err {
    NSLog(@"断开连接,host:%@,port:%d",sock.localHost,sock.localPort);
    //断线重连写在这...
}

//写成功的回调
- (void)socket:(GCDAsyncSocket*)sock didWriteDataWithTag:(long)tag {
//    NSLog(@"写的回调,tag:%ld",tag);
}

//收到消息的回调
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {

    NSString *msg = [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"收到消息：%@",msg);
    [self pullTheMsg];
}

//分段去获取消息的回调
//- (void)socket:(GCDAsyncSocket *)sock didReadPartialDataOfLength:(NSUInteger)partialLength tag:(long)tag
//{
//
//    NSLog(@"读的回调,length:%ld,tag:%ld",partialLength,tag);
//
//}

//为上一次设置的读取数据代理续时 (如果设置超时为-1，则永远不会调用到)
//-(NSTimeInterval)socket:(GCDAsyncSocket *)sock shouldTimeoutReadWithTag:(long)tag elapsed:(NSTimeInterval)elapsed bytesDone:(NSUInteger)length
//{
//    NSLog(@"来延时，tag:%ld,elapsed:%f,length:%ld",tag,elapsed,length);
//    return 10;
//}

// 在 GCDAsyncSocket 中，为什么要每次收到- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag 这个代理之后··要调用一次- (void)readDataToLength:(NSUInteger)length withTimeout:(NSTimeInterval)timeout buffer:(nullable NSMutableData *)buffer bufferOffset:(NSUInteger)offset tag:(long)tag; 这个方法 ？

// 在 GCDAsyncSocket 中，每次收到数据时，需要调用 readDataToLength:withTimeout:buffer:bufferOffset:tag: 方法的目的是为了继续读取后续的数据。

//- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag 是 GCDAsyncSocketDelegate 协议中的一个代理方法，当 socket 接收到数据时，会触发这个方法。在这个方法中，你可以处理接收到的数据，比如解析数据、进行相应的处理等。

//但是，socket 一次接收到的数据可能并不完整，可能只是数据的一部分。因此，在处理完当前收到的数据后，需要继续读取后续的数据，以确保完整地接收到所需的数据。

//readDataToLength:withTimeout:buffer:bufferOffset:tag: 方法用于设置读取的数据长度、超时时间、缓冲区等参数，然后会触发相应的读取操作。通过调用这个方法，可以继续从 socket 中读取指定长度的数据，直到达到指定的长度或超时。

//这种方式的目的是确保你能够按照预期的数据长度进行处理，而不是仅仅处理接收到的第一部分数据。因此，在每次收到数据后，需要调用 readDataToLength:withTimeout:buffer:bufferOffset:tag: 方法来继续读取后续的数据，直到满足条件为止。

//这样可以保证你能够处理完整的数据流，而不会丢失任何数据。

@end
