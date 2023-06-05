//
//  LYLWebSocketManger.h
//  IM
//
//  Created by LYL on 2023/5/30.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LYLWebSocketManger : NSObject

@property (nonatomic, copy) NSString *host;

@property (nonatomic, assign) uint16_t port;

+ (instancetype)share;

- (void)connect;

- (void)disConnect;

- (void)sendMsg:(NSString *)msg;

- (void)ping;

@end

NS_ASSUME_NONNULL_END
