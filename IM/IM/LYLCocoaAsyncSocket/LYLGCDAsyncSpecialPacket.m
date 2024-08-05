//
//  LYLGCDAsyncSpecialPacket.m
//  IM
//
//  Created by LYL on 2024/8/5.
//

#import "LYLGCDAsyncSpecialPacket.h"

@implementation LYLGCDAsyncSpecialPacket

// Cover the superclass' designated initializer
- (instancetype)init NS_UNAVAILABLE
{
    NSAssert(0, @"Use the designated initializer");
    return nil;
}

- (instancetype)initWithTLSSettings:(NSDictionary <NSString*,NSObject*>*)settings
{
    if((self = [super init]))
    {
        self.tlsSettings = [settings copy];
    }
    return self;
}

@end
