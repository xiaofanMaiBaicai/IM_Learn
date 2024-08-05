//
//  LYLGCDAsyncSocketPreBuffer.m
//  IM
//
//  Created by LYL on 2024/8/5.
//

#import "LYLGCDAsyncSocketPreBuffer.h"

@implementation LYLGCDAsyncSocketPreBuffer

- (instancetype)init NS_UNAVAILABLE
{
    NSAssert(0, @"Use the designated initializer");
    return nil;
}

- (instancetype)initWithCapacity:(size_t)numBytes
{
    if ((self = [super init]))
    {
        self.preBufferSize = numBytes;
        self.preBuffer = malloc(self.preBufferSize);
        
        self.readPointer = self.preBuffer;
        self.writePointer = self.preBuffer;
    }
    return self;
}

- (void)dealloc
{
    if (self.preBuffer)
        free(self.preBuffer);
}

- (void)ensureCapacityForWrite:(size_t)numBytes
{
    
    size_t availableSpace = [self availableSpace];
    
    if (numBytes > availableSpace)
    {
        // 需要新增的容量字节数
        size_t additionalBytes = numBytes - availableSpace;
        // 生成新的预缓存区，大小是老的+的不足的，并生成新地址
        size_t newPreBufferSize = self.preBufferSize + additionalBytes;
        uint8_t *newPreBuffer = realloc(self.preBuffer, newPreBufferSize);
        
        // 计算读写偏移量 也就是读了多少数据，写了多少数据
        size_t readPointerOffset = self.readPointer - self.preBuffer;
        size_t writePointerOffset = self.writePointer - self.preBuffer;
        // 重新赋值初始内存地址
        self.preBuffer = newPreBuffer;
        self.preBufferSize = newPreBufferSize;
        // 重新设置读写指针偏移量
        self.readPointer = self.preBuffer + readPointerOffset;
        self.writePointer = self.preBuffer + writePointerOffset;
    }
}

- (size_t)availableBytes
{
    return self.writePointer - self.readPointer;
}

- (uint8_t *)readBuffer
{
    return self.readPointer;
}

- (void)getReadBuffer:(uint8_t **)bufferPtr availableBytes:(size_t *)availableBytesPtr
{
    if (bufferPtr) *bufferPtr = self.readPointer;
    if (availableBytesPtr) *availableBytesPtr = [self availableBytes];
}

- (void)didRead:(size_t)bytesRead
{
    self.readPointer += bytesRead;
    
    if (self.readPointer == self.writePointer)
    {
        // The prebuffer has been drained. Reset pointers.
        self.readPointer  = self.preBuffer;
        self.writePointer = self.preBuffer;
    }
}

- (size_t)availableSpace
{
    return self.preBufferSize - (self.writePointer - self.preBuffer);
}

- (uint8_t *)writeBuffer
{
    return self.writePointer;
}

- (void)getWriteBuffer:(uint8_t **)bufferPtr availableSpace:(size_t *)availableSpacePtr
{
    if (bufferPtr) *bufferPtr = self.writePointer;
    if (availableSpacePtr) *availableSpacePtr = [self availableSpace];
}

- (void)didWrite:(size_t)bytesWritten
{
    self.writePointer += bytesWritten;
}

- (void)reset
{
    self.readPointer  = self.preBuffer;
    self.writePointer = self.preBuffer;
}


@end
