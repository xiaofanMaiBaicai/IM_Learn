//
//  LYLGCDAsyncSpecialPacket.h
//  IM
//
//  Created by LYL on 2024/8/5.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LYLGCDAsyncSpecialPacket : NSObject

@property (nonatomic, copy) NSDictionary *tlsSettings;

- (instancetype)initWithTLSSettings:(NSDictionary <NSString*,NSObject*>*)settings NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
