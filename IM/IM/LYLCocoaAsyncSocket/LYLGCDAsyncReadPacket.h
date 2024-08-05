//
//  LYLGCDAsyncReadPacket.h
//  IM
//
//  Created by LYL on 2024/8/5.
//

#import <Foundation/Foundation.h>
#import "LYLGCDAsyncSocketPreBuffer.h"

NS_ASSUME_NONNULL_BEGIN

@interface LYLGCDAsyncReadPacket : NSObject

@property (nonatomic, strong) NSMutableData *buffer;           // 用于存储读取的数据
@property (nonatomic, assign) NSUInteger startOffset;          // 开始读取数据的偏移量
@property (nonatomic, assign) NSUInteger bytesDone;            // 已经完成的字节数
@property (nonatomic, assign) NSUInteger maxLength;            // 最大可读取的字节数
@property (nonatomic, assign) NSTimeInterval timeout;          // 读取操作的超时时间
@property (nonatomic, assign) NSUInteger readLength;           // 需要读取的数据长度
@property (nonatomic, strong) NSData *term;                    // 作为读取终止条件的数据分隔符
@property (nonatomic, assign) BOOL bufferOwner;                // 标记是否拥有缓冲区
@property (nonatomic, assign) NSUInteger originalBufferLength; // 原始缓冲区长度
@property (nonatomic, assign) long tag;                        // 用于标识读取操作的标签

//使用指定的参数初始化一个新的读取包。
- (instancetype)initWithData:(NSMutableData *)d
                 startOffset:(NSUInteger)s
                   maxLength:(NSUInteger)m
                     timeout:(NSTimeInterval)t
                  readLength:(NSUInteger)l
                  terminator:(NSData *)e
                         tag:(long)i NS_DESIGNATED_INITIALIZER;

// 确保缓冲区有足够的容量来存储指定长度的额外数据
- (void)ensureCapacityForAdditionalDataOfLength:(NSUInteger)bytesToRead;
// 确定读取的最佳数据长度，考虑到默认值和是否需要预缓冲
- (NSUInteger)optimalReadLengthWithDefault:(NSUInteger)defaultValue shouldPreBuffer:(BOOL *)shouldPreBufferPtr;
// 在没有终止符的情况下，根据可用字节计算要读取的数据长度。
- (NSUInteger)readLengthForNonTermWithHint:(NSUInteger)bytesAvailable;
// 在有终止符的情况下，根据可用字节和是否需要预缓冲来计算要读取的数据长度。
- (NSUInteger)readLengthForTermWithHint:(NSUInteger)bytesAvailable shouldPreBuffer:(BOOL *)shouldPreBufferPtr;
// 使用预缓冲确定要读取的数据长度，并判断是否找到了终止符。
- (NSUInteger)readLengthForTermWithPreBuffer:(LYLGCDAsyncSocketPreBuffer *)preBuffer found:(BOOL *)foundPtr;
// 在预缓冲一定数量的字节后，在缓冲区中搜索终止符。
- (NSInteger)searchForTermAfterPreBuffering:(ssize_t)numBytes;


@end

NS_ASSUME_NONNULL_END
