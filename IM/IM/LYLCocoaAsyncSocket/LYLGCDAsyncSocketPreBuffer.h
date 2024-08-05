//
//  LYLGCDAsyncSocketPreBuffer.h
//  IM
//
//  Created by LYL on 2024/8/5.
//

/*
 预缓冲区用于当套接字上有更多的数据可用，而当前读取请求并未请求所有数据的情况。
 在这种情况下，我们会从套接字中读取所有数据（以最小化系统调用），并将未读取的额外数据存储在“预缓冲区”中。

 预缓冲区在我们再次从套接字读取数据之前会被完全清空。
 换句话说，大块数据会被写入预缓冲区。
 然后通过一系列的一个或多个读取请求（对于后续的读取请求），预缓冲区会被清空。

 曾经使用环形缓冲区来实现这个目的。
 但环形缓冲区会占用双倍的内存（镜像所需的双倍大小）。
 实际上，它通常占用超过两倍的大小，因为所有内容都需要向上舍入到 vm_page_size。
 由于预缓冲区在写入后总是会被完全清空，因此不需要完整的环形缓冲区。

 当前的设计非常简单直接，同时也降低了内存需求。
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LYLGCDAsyncSocketPreBuffer : NSObject

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
