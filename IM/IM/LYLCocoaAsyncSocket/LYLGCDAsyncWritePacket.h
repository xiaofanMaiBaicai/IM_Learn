//
//  LYLGCDAsyncWritePacket.h
//  IM
//
//  Created by LYL on 2024/8/5.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LYLGCDAsyncWritePacket : NSObject

@property (nonatomic, strong) NSData *buffer;
@property (nonatomic, assign) NSUInteger bytesDone;
@property (nonatomic, assign) long tag;
@property (nonatomic, assign) NSTimeInterval timeout;

- (instancetype)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
