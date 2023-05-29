//
//  LYLGCDAsyncSocketManger.h
//  IM
//
//  Created by L on 2023/5/29.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LYLGCDAsyncSocketManger : NSObject

+ (instancetype)share;

- (BOOL)connectWith:(NSString*)host port:(uint16_t)port;

- (void)disConnect;

- (void)sendMsg:(NSString *)msg;

- (void)pullTheMsg;

@end

NS_ASSUME_NONNULL_END
