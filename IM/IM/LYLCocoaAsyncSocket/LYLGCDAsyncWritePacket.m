//
//  LYLGCDAsyncWritePacket.m
//  IM
//
//  Created by LYL on 2024/8/5.
//

#import "LYLGCDAsyncWritePacket.h"

@implementation LYLGCDAsyncWritePacket

// Cover the superclass' designated initializer
- (instancetype)init NS_UNAVAILABLE
{
    NSAssert(0, @"Use the designated initializer");
    return nil;
}

- (instancetype)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i
{
    if((self = [super init]))
    {
        self.buffer = d; // Retain not copy. For performance as documented in header file.
        self.bytesDone = 0;
        self.timeout = t;
        self.tag = i;
    }
    return self;
}

@end
