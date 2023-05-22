//
//  LYLSocketManager.m
//  IM
//
//  Created by LYL on 2023/5/22.
//

#import "LYLSocketManager.h"

#import <sys/types.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

@interface LYLSocketManager()

@property (nonatomic,assign)int clientScoket;

@end

@implementation LYLSocketManager

+ (instancetype)share
{
    static dispatch_once_t onceToken;
    static LYLSocketManager *instance = nil;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc]init];
        [instance initScoket];
        [instance pullMsg];
    });
    return instance;
}

- (void)connect{
    [self initScoket];
}

- (void)disConnect{
    close(self.clientScoket);
}

- (void)sendMsg:(NSString*)str{
    const char *send_Message = [str UTF8String];
    send(self.clientScoket, send_Message, strlen(send_Message)+1, 0);
}

- (void)recieveAction {
    while (1) {
        char recv_Message[1024] = {0};
        recv(self.clientScoket, recv_Message, sizeof(recv_Message), 0);
        printf("%s\n",recv_Message);
    }
}




- (void)initScoket {
    if (_clientScoket != 0){
        [self disConnect];
        _clientScoket = 0;
        
        _clientScoket = CreateClinetSocket();
        const char * server_ip = "127.0.0.1";
        short server_port = 6969;
        if (ConnectToServer(_clientScoket, server_ip, server_port) == 0) {
            NSLog(@"error");
        }
        NSLog(@"OK");
    }
}

- (void)pullMsg {
    NSThread *thread = [[NSThread alloc]initWithTarget:self selector:@selector(recieveAction) object:nil];
    [thread start];
}

// 创建一个 socket 
static int CreateClinetSocket(void) {
    int clinetSocket = 0;
    clinetSocket = socket(AF_INET, SOCK_STREAM, 0);
    return clinetSocket;
}

static int ConnectToServer(int clientSockte, const char *server_ip, unsigned short port) {
    // 创建一个地址结构体
    struct sockaddr_in sAddr={0};
    // sin_family 网络地址族
    sAddr.sin_family = AF_INET;
    // 将字符串的ip地址转成32位的网络序列IP地址
    inet_aton(server_ip, &sAddr.sin_addr);
    //整型变量从主机字节顺序转变成网络字节顺序，赋值端口号
    sAddr.sin_port = htons(port);
    // 发起链接 0 为成功 , -1 为失败，此接口会阻塞当前线程
    if (connect(clientSockte, (struct sockaddr *)&sAddr, sizeof(sAddr)) == 0) {
        return clientSockte;
    }
    
    return 0;
}

@end
