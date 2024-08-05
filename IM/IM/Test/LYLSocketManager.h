//
//  LYLSocketManager.h
//  IM
//
//  Created by LYL on 2023/5/22.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LYLSocketManager : NSObject

+ (instancetype)share;

- (void)connect;

- (void)disConnect;

- (void)sendMsg:(NSString*)str;

@end

NS_ASSUME_NONNULL_END
