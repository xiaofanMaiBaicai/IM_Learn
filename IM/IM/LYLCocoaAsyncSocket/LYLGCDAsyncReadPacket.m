//
//  LYLGCDAsyncReadPacket.m
//  IM
//
//  Created by LYL on 2024/8/5.
//

#import "LYLGCDAsyncReadPacket.h"

@implementation LYLGCDAsyncReadPacket

- (instancetype)init NS_UNAVAILABLE
{
    NSAssert(0, @"Use the designated initializer");
    return nil;
}

- (instancetype)initWithData:(NSMutableData *)d
                 startOffset:(NSUInteger)s
                   maxLength:(NSUInteger)m
                     timeout:(NSTimeInterval)t
                  readLength:(NSUInteger)l
                  terminator:(NSData *)e
                         tag:(long)i
{
    if((self = [super init]))
    {
        self.bytesDone = 0;
        self.maxLength = m;
        self.timeout = t;
        self.readLength = l;
        self.term = [e copy];
        self.tag = i;
        
        if (d)
        {
            self.buffer = d;
            self.startOffset = s;
            self.bufferOwner = NO;
            self.originalBufferLength = [d length];
        }
        else
        {
            if (self.readLength > 0)
                self.buffer = [[NSMutableData alloc] initWithLength:self.readLength];
            else
                self.buffer = [[NSMutableData alloc] initWithLength:0];
            
            self.startOffset = 0;
            self.bufferOwner = YES;
            self.originalBufferLength = 0;
        }
    }
    return self;
}

/**
 * Increases the length of the buffer (if needed) to ensure a read of the given size will fit.
 * 如果需要的话，增加缓冲区的长度，以确保可以容纳给定大小的读取操作
**/
- (void)ensureCapacityForAdditionalDataOfLength:(NSUInteger)bytesToRead
{
    NSUInteger buffSize = [self.buffer length];
    NSUInteger buffUsed = self.startOffset + self.bytesDone;
    
    NSUInteger buffSpace = buffSize - buffUsed;
    
    if (bytesToRead > buffSpace)
    {
        NSUInteger buffInc = bytesToRead - buffSpace;
        
        [self.buffer increaseLengthBy:buffInc];
    }
}

/**
 * 这段注释说明了在不知道有多少数据可以从套接字读取时如何决定读取的数据长度。
 * 它返回默认值，除非默认值超过了指定的 readLength 或 maxLength。
 *
 * 此外，是否需要预缓冲的决定基于包的类型，以及返回的值是否可以在不需要扩大缓冲区的情况下适合当前缓冲区。
**/
- (NSUInteger)optimalReadLengthWithDefault:(NSUInteger)defaultValue shouldPreBuffer:(BOOL *)shouldPreBufferPtr
{
    NSUInteger result;
    
    if (self.readLength > 0)
    {
        // 剩余读取的大小
        result = self.readLength - self.bytesDone;

        //我们不需要预缓冲，因为我们知道需要读取多少数据。
        //即使当前缓冲区不够大，容纳不了这么多数据，
        //无论如何，它最终都会被调整大小
        
        if (shouldPreBufferPtr)
            *shouldPreBufferPtr = NO;
    }
    else
    {
        if (self.maxLength > 0)
            result =  MIN(defaultValue, (self.maxLength - self.bytesDone));
        else
            result = defaultValue;

        // 这段代码用于判断是否需要预缓冲（即在读取数据之前，是否应该先将数据存储在一个预先分配的缓冲区中）。如果当前缓冲区有足够的空间来容纳即将读取的数据量，那么就不需要预缓冲；
        // 否则，需要预缓冲以避免重新分配缓冲区的开销。这样做的目的是在可能的情况下避免过度分配读取缓冲区的空间。

        if (shouldPreBufferPtr)
        {
            NSUInteger buffSize = [self.buffer length];
            NSUInteger buffUsed = self.startOffset + self.bytesDone;
            
            NSUInteger buffSpace = buffSize - buffUsed;
            
            if (buffSpace >= result)
                *shouldPreBufferPtr = NO;
            else
                *shouldPreBufferPtr = YES;
        }
    }
    
    return result;
}

/**
 * 对于没有设置终止符的读取包，它返回可以读取的数据量，而不会超过 readLength 或 maxLength。
 * 给定的参数表示估计在套接字上可用的字节数，这在计算过程中会被考虑。给定的提示必须大于零。
**/
- (NSUInteger)readLengthForNonTermWithHint:(NSUInteger)bytesAvailable
{
    NSAssert(self.term == nil, @"This method does not apply to term reads");
    NSAssert(bytesAvailable > 0, @"Invalid parameter: bytesAvailable");
    
    if (self.readLength > 0)
    {
        // Read a specific length of data
        
        return MIN(bytesAvailable, (self.readLength - self.bytesDone));
    }
    else
    {
        NSUInteger result = bytesAvailable;
        
        if (self.maxLength > 0)
        {
            result = MIN(result, (self.maxLength - self.bytesDone));
        }
        return result;
    }
}

/**
 * 对于设置了终止符的读取包，这段代码返回在不超过 maxLength 的情况下可以读取的数据量。
 * 给定的参数表示估计在套接字上可用的字节数，这在计算过程中会被考虑。
 * 为了优化内存分配、内存复制和内存移动，shouldPreBuffer 布尔值将指示数据是否应该先读取到预缓冲区中，或者是否可以直接读取到读取包的缓冲区中。
**/
- (NSUInteger)readLengthForTermWithHint:(NSUInteger)bytesAvailable shouldPreBuffer:(BOOL *)shouldPreBufferPtr
{
    NSAssert(self.term != nil, @"This method does not apply to non-term reads");
    NSAssert(bytesAvailable > 0, @"Invalid parameter: bytesAvailable");
    
    
    NSUInteger result = bytesAvailable;
    
    if (self.maxLength > 0)
    {
        result = MIN(result, (self.maxLength - self.bytesDone));
    }
    
    /*
     这段注释比较了直接将数据读取到读取包的缓冲区与先将数据读取到预缓冲区的性能。直接读取到包的缓冲区可能需要调整缓冲区大小、填充缓冲区、搜索终止符和可能将溢出数据复制到预缓冲区。而先读取到预缓冲区则可能需要调整预缓冲区大小、填充缓冲区、搜索终止符、将不足的数据复制到包的缓冲区和从预缓冲区中移除不足的数据。由于额外的内存移动操作，先读取到预缓冲区通常会更慢。

     然而，NSMutableData的实现可以动态增长但不会缩小，因此预缓冲区很少需要重新分配内存。另一方面，包的缓冲区可能经常需要重新分配内存，尤其是当我们拥有缓冲区时。如果我们不断地重新分配包的缓冲区，然后将溢出数据移动到预缓冲区，那么我们就会持续过度分配内存。这里存在速度与内存利用之间的权衡。

     最终结果是，两种方法的性能非常相似。如果我们可以直接将所有数据读取到包的缓冲区而不需要先调整其大小，那么我们就这样做。否则，我们使用预缓冲区。
     
     这个表达是指在读取到预缓冲区后，如果发现数据不足以满足读取包的需求，那么需要将这部分不足的数据从预缓冲区复制到读取包的缓冲区中。同时，为了维护预缓冲区的正确性，还需要从预缓冲区中移除已经复制到读取包缓冲区的数据。

     简而言之，就是把预缓冲区中的一部分数据转移到读取包的缓冲区中，然后从预缓冲区中删除这部分数据，以确保数据的完整性和准确性。
     
     */
    
    if (shouldPreBufferPtr)
    {
        NSUInteger buffSize = [self.buffer length];
        NSUInteger buffUsed = self.startOffset + self.bytesDone;
        
        if ((buffSize - buffUsed) >= result)
            *shouldPreBufferPtr = NO;
        else
            *shouldPreBufferPtr = YES;
    }
    
    return result;
}

/**
 * 对于设置了终止符的读取包，这段代码返回从给定的预缓冲区中可以读取的数据量，不会超过终止符或最大长度。
 * 假定终止符尚未被读取。
**/
- (NSUInteger)readLengthForTermWithPreBuffer:(LYLGCDAsyncSocketPreBuffer *)preBuffer found:(BOOL *)foundPtr
{
    NSAssert(self.term != nil, @"This method does not apply to non-term reads");
    NSAssert([preBuffer availableBytes] > 0, @"Invoked with empty pre buffer!");
    
    BOOL found = NO;
    
    NSUInteger termLength = [self.term length];
    NSUInteger preBufferLength = [preBuffer availableBytes];
    
    if ((self.bytesDone + preBufferLength) < termLength)
    {
        // Not enough data for a full term sequence yet
        return preBufferLength;
    }
    
    NSUInteger maxPreBufferLength;
    if (self.maxLength > 0) {
        maxPreBufferLength = MIN(preBufferLength, (self.maxLength - self.bytesDone));
        
        // Note: maxLength >= termLength
    }
    else {
        maxPreBufferLength = preBufferLength;
    }
    
    uint8_t seq[termLength];
    const void *termBuf = [self.term bytes];
    
    NSUInteger bufLen = MIN(self.bytesDone, (termLength - 1));
    uint8_t *buf = (uint8_t *)[self.buffer mutableBytes] + self.startOffset + self.bytesDone - bufLen;
    
    NSUInteger preLen = termLength - bufLen;
    const uint8_t *pre = [preBuffer readBuffer];
    
    NSUInteger loopCount = bufLen + maxPreBufferLength - termLength + 1; // Plus one. See example above.
    
    NSUInteger result = maxPreBufferLength;
    
    NSUInteger i;
    for (i = 0; i < loopCount; i++)
    {
        if (bufLen > 0)
        {
            // Combining bytes from buffer and preBuffer
            
            memcpy(seq, buf, bufLen);
            memcpy(seq + bufLen, pre, preLen);
            
            if (memcmp(seq, termBuf, termLength) == 0)
            {
                result = preLen;
                found = YES;
                break;
            }
            
            buf++;
            bufLen--;
            preLen++;
        }
        else
        {
            // Comparing directly from preBuffer
            
            if (memcmp(pre, termBuf, termLength) == 0)
            {
                NSUInteger preOffset = pre - [preBuffer readBuffer]; // pointer arithmetic
                
                result = preOffset + termLength;
                found = YES;
                break;
            }
            
            pre++;
        }
    }
    
    // There is no need to avoid resizing the buffer in this particular situation.
    
    if (foundPtr) *foundPtr = found;
    return result;
}

/**
 *
 * 对于设置了终止符的读取包，这段代码会扫描包缓冲区寻找终止符。
 * 假定在添加新字节之前，终止符尚未完全读取。
 * 如果找到终止符，则返回终止符后的多余字节数。
 * 如果没有找到终止符，这个方法会返回 -1。
 * 返回值为零意味着终止符位于缓冲区的末尾。
 * 前提条件是给定数量的字节已经添加到缓冲区的末尾，且 bytesDone 变量尚未因预缓冲的字节而改变。
**/
- (NSInteger)searchForTermAfterPreBuffering:(ssize_t)numBytes
{
    NSAssert(self.term != nil, @"This method does not apply to non-term reads");
    
    // The implementation of this method is very similar to the above method.
    // See the above method for a discussion of the algorithm used here.
    
    uint8_t *buff = [self.buffer mutableBytes];
    NSUInteger buffLength = self.bytesDone + numBytes;
    
    const void *termBuff = [self.term bytes];
    NSUInteger termLength = [self.term length];
    
    // Note: We are dealing with unsigned integers,
    // so make sure the math doesn't go below zero.
    
    NSUInteger i = ((buffLength - numBytes) >= termLength) ? (buffLength - numBytes - termLength + 1) : 0;
    
    while (i + termLength <= buffLength)
    {
        uint8_t *subBuffer = buff + self.startOffset + i;
        
        if (memcmp(subBuffer, termBuff, termLength) == 0)
        {
            return buffLength - (i + termLength);
        }
        
        i++;
    }
    
    return -1;
}

@end
