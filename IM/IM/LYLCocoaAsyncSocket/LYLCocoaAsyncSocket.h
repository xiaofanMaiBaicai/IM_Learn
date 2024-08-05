//
//  LYLCocoaAsyncSocket.h
//  IM
//
//  Created by LYL on 2024/8/5.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LYLCocoaAsyncSocket : NSObject

@property (nonatomic, assign) uint8_t *preBuffer;       // 指向预缓冲区开始的指针，这里存储着实际的数据
@property (nonatomic, assign) size_t preBufferSize;     // 预缓冲区的总大小，表示可以存储的最大字节数
@property (nonatomic, assign) uint8_t *readPointer;     // 读指针，指向下一个要读取数据的位置
@property (nonatomic, assign) uint8_t *writePointer;    // 写指针，指向下一个要写入数据的位置

// 初始化一个 numBytes 容量的预缓存区
- (instancetype)initWithCapacity:(size_t)numBytes NS_DESIGNATED_INITIALIZER;
// 确保可写入大小满足，不够的时候扩容
- (void)ensureCapacityForWrite:(size_t)numBytes;
// 未读的字节数
- (size_t)availableBytes;
- (uint8_t *)readBuffer;

// 当前读区 可读的数据
- (void)getReadBuffer:(uint8_t **)bufferPtr availableBytes:(size_t *)availableBytesPtr;
// 剩余空间字节数
- (size_t)availableSpace;
- (uint8_t *)writeBuffer;

// 当前缓存区·可写的空间
- (void)getWriteBuffer:(uint8_t **)bufferPtr availableSpace:(size_t *)availableSpacePtr;

- (void)didRead:(size_t)bytesRead;
- (void)didWrite:(size_t)bytesWritten;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
