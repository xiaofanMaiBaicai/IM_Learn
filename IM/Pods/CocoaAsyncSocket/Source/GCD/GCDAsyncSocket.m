//
//  GCDAsyncSocket.m
//  
//  This class is in the public domain.
//  Originally created by Robbie Hanson in Q4 2010.
//  Updated and maintained by Deusty LLC and the Apple development community.
//
//  https://github.com/robbiehanson/CocoaAsyncSocket
//

#import "GCDAsyncSocket.h"

//#if TARGET_OS_IPHONE
#import <CFNetwork/CFNetwork.h>
//#endif

#import <TargetConditionals.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <netinet/in.h>
#import <net/if.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <sys/ioctl.h>
#import <sys/poll.h>
#import <sys/uio.h>
#import <sys/un.h>
#import <unistd.h>

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
// For more information see: https://github.com/robbiehanson/CocoaAsyncSocket/wiki/ARC
#endif


#ifndef GCDAsyncSocketLoggingEnabled
#define GCDAsyncSocketLoggingEnabled 0
#endif

#if GCDAsyncSocketLoggingEnabled

// Logging Enabled - See log level below

// Logging uses the CocoaLumberjack framework (which is also GCD based).
// https://github.com/robbiehanson/CocoaLumberjack
// 
// It allows us to do a lot of logging without significantly slowing down the code.
#import "DDLog.h"

#define LogAsync   YES
#define LogContext GCDAsyncSocketLoggingContext

#define LogObjc(flg, frmt, ...) LOG_OBJC_MAYBE(LogAsync, logLevel, flg, LogContext, frmt, ##__VA_ARGS__)
#define LogC(flg, frmt, ...)    LOG_C_MAYBE(LogAsync, logLevel, flg, LogContext, frmt, ##__VA_ARGS__)

#define LogError(frmt, ...)     LogObjc(LOG_FLAG_ERROR,   (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogWarn(frmt, ...)      LogObjc(LOG_FLAG_WARN,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogInfo(frmt, ...)      LogObjc(LOG_FLAG_INFO,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogVerbose(frmt, ...)   LogObjc(LOG_FLAG_VERBOSE, (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)

#define LogCError(frmt, ...)    LogC(LOG_FLAG_ERROR,   (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCWarn(frmt, ...)     LogC(LOG_FLAG_WARN,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCInfo(frmt, ...)     LogC(LOG_FLAG_INFO,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCVerbose(frmt, ...)  LogC(LOG_FLAG_VERBOSE, (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)

#define LogTrace()              LogObjc(LOG_FLAG_VERBOSE, @"%@: %@", THIS_FILE, THIS_METHOD)
#define LogCTrace()             LogC(LOG_FLAG_VERBOSE, @"%@: %s", THIS_FILE, __FUNCTION__)

#ifndef GCDAsyncSocketLogLevel
#define GCDAsyncSocketLogLevel LOG_LEVEL_VERBOSE
#endif

// Log levels : off, error, warn, info, verbose
static const int logLevel = GCDAsyncSocketLogLevel;

#else

// Logging Disabled

#define LogError(frmt, ...)     {}
#define LogWarn(frmt, ...)      {}
#define LogInfo(frmt, ...)      {}
#define LogVerbose(frmt, ...)   {}

#define LogCError(frmt, ...)    {}
#define LogCWarn(frmt, ...)     {}
#define LogCInfo(frmt, ...)     {}
#define LogCVerbose(frmt, ...)  {}

#define LogTrace()              {}
#define LogCTrace(frmt, ...)    {}

#endif

/**
 * Seeing a return statements within an inner block
 * can sometimes be mistaken for a return point of the enclosing method.
 * This makes inline blocks a bit easier to read.
**/
#define return_from_block  return

/**
 * A socket file descriptor is really just an integer.
 * It represents the index of the socket within the kernel.
 * This makes invalid file descriptor comparisons easier to read.
**/
#define SOCKET_NULL -1


NSString *const GCDAsyncSocketException = @"GCDAsyncSocketException";
NSString *const GCDAsyncSocketErrorDomain = @"GCDAsyncSocketErrorDomain";

NSString *const GCDAsyncSocketQueueName = @"GCDAsyncSocket";
NSString *const GCDAsyncSocketThreadName = @"GCDAsyncSocket-CFStream";

NSString *const GCDAsyncSocketManuallyEvaluateTrust = @"GCDAsyncSocketManuallyEvaluateTrust";
//#if TARGET_OS_IPHONE
NSString *const GCDAsyncSocketUseCFStreamForTLS = @"GCDAsyncSocketUseCFStreamForTLS";
//#endif
NSString *const GCDAsyncSocketSSLPeerID = @"GCDAsyncSocketSSLPeerID";
NSString *const GCDAsyncSocketSSLProtocolVersionMin = @"GCDAsyncSocketSSLProtocolVersionMin";
NSString *const GCDAsyncSocketSSLProtocolVersionMax = @"GCDAsyncSocketSSLProtocolVersionMax";
NSString *const GCDAsyncSocketSSLSessionOptionFalseStart = @"GCDAsyncSocketSSLSessionOptionFalseStart";
NSString *const GCDAsyncSocketSSLSessionOptionSendOneByteRecord = @"GCDAsyncSocketSSLSessionOptionSendOneByteRecord";
NSString *const GCDAsyncSocketSSLCipherSuites = @"GCDAsyncSocketSSLCipherSuites";
NSString *const GCDAsyncSocketSSLALPN = @"GCDAsyncSocketSSLALPN";
#if !TARGET_OS_IPHONE
NSString *const GCDAsyncSocketSSLDiffieHellmanParameters = @"GCDAsyncSocketSSLDiffieHellmanParameters";
#endif

enum GCDAsyncSocketFlags
{
	kSocketStarted                 = 1 <<  0,  // If set, socket has been started (accepting/connecting)
	kConnected                     = 1 <<  1,  // If set, the socket is connected
	kForbidReadsWrites             = 1 <<  2,  // If set, no new reads or writes are allowed
	kReadsPaused                   = 1 <<  3,  // If set, reads are paused due to possible timeout
	kWritesPaused                  = 1 <<  4,  // If set, writes are paused due to possible timeout
	kDisconnectAfterReads          = 1 <<  5,  // If set, disconnect after no more reads are queued
	kDisconnectAfterWrites         = 1 <<  6,  // If set, disconnect after no more writes are queued
	kSocketCanAcceptBytes          = 1 <<  7,  // If set, we know socket can accept bytes. If unset, it's unknown.
	kReadSourceSuspended           = 1 <<  8,  // If set, the read source is suspended
	kWriteSourceSuspended          = 1 <<  9,  // If set, the write source is suspended
	kQueuedTLS                     = 1 << 10,  // If set, we've queued an upgrade to TLS
	kStartingReadTLS               = 1 << 11,  // If set, we're waiting for TLS negotiation to complete
	kStartingWriteTLS              = 1 << 12,  // If set, we're waiting for TLS negotiation to complete
	kSocketSecure                  = 1 << 13,  // If set, socket is using secure communication via SSL/TLS
	kSocketHasReadEOF              = 1 << 14,  // If set, we have read EOF from socket
	kReadStreamClosed              = 1 << 15,  // If set, we've read EOF plus prebuffer has been drained
	kDealloc                       = 1 << 16,  // If set, the socket is being deallocated
//#if TARGET_OS_IPHONE
	kAddedStreamsToRunLoop         = 1 << 17,  // If set, CFStreams have been added to listener thread
	kUsingCFStreamForTLS           = 1 << 18,  // If set, we're forced to use CFStream instead of SecureTransport
	kSecureSocketHasBytesAvailable = 1 << 19,  // If set, CFReadStream has notified us of bytes available
//#endif
};

enum GCDAsyncSocketConfig
{
	kIPv4Disabled              = 1 << 0,  // If set, IPv4 is disabled
	kIPv6Disabled              = 1 << 1,  // If set, IPv6 is disabled
	kPreferIPv6                = 1 << 2,  // If set, IPv6 is preferred over IPv4
	kAllowHalfDuplexConnection = 1 << 3,  // If set, the socket will stay open even if the read stream closes
};

//#if TARGET_OS_IPHONE
  static NSThread *cfstreamThread;  // Used for CFStreams


  static uint64_t cfstreamThreadRetainCount;   // setup & teardown
  static dispatch_queue_t cfstreamThreadSetupQueue; // setup & teardown
//#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * A PreBuffer is used when there is more data available on the socket
 * than is being requested by current read request.
 * In this case we slurp up all data from the socket (to minimize sys calls),
 * and store additional yet unread data in a "prebuffer".
 * 
 * The prebuffer is entirely drained before we read from the socket again.
 * In other words, a large chunk of data is written is written to the prebuffer.
 * The prebuffer is then drained via a series of one or more reads (for subsequent read request(s)).
 * 
 * A ring buffer was once used for this purpose.
 * But a ring buffer takes up twice as much memory as needed (double the size for mirroring).
 * In fact, it generally takes up more than twice the needed size as everything has to be rounded up to vm_page_size.
 * And since the prebuffer is always completely drained after being written to, a full ring buffer isn't needed.
 * 
 * The current design is very simple and straight-forward, while also keeping memory requirements lower.
**/

@interface GCDAsyncSocketPreBuffer : NSObject
{
	uint8_t *preBuffer;
	size_t preBufferSize;
	
	uint8_t *readPointer;
	uint8_t *writePointer;
}

- (instancetype)initWithCapacity:(size_t)numBytes NS_DESIGNATED_INITIALIZER;

- (void)ensureCapacityForWrite:(size_t)numBytes;

- (size_t)availableBytes;
- (uint8_t *)readBuffer;

- (void)getReadBuffer:(uint8_t **)bufferPtr availableBytes:(size_t *)availableBytesPtr;

- (size_t)availableSpace;
- (uint8_t *)writeBuffer;

- (void)getWriteBuffer:(uint8_t **)bufferPtr availableSpace:(size_t *)availableSpacePtr;

- (void)didRead:(size_t)bytesRead;
- (void)didWrite:(size_t)bytesWritten;

- (void)reset;

@end

@implementation GCDAsyncSocketPreBuffer

// Cover the superclass' designated initializer
- (instancetype)init NS_UNAVAILABLE
{
	NSAssert(0, @"Use the designated initializer");
	return nil;
}

- (instancetype)initWithCapacity:(size_t)numBytes
{
	if ((self = [super init]))
	{
		preBufferSize = numBytes;
		preBuffer = malloc(preBufferSize);
		
		readPointer = preBuffer;
		writePointer = preBuffer;
	}
	return self;
}

- (void)dealloc
{
	if (preBuffer)
		free(preBuffer);
}

- (void)ensureCapacityForWrite:(size_t)numBytes
{
	size_t availableSpace = [self availableSpace];
	
	if (numBytes > availableSpace)
	{
		size_t additionalBytes = numBytes - availableSpace;
		
		size_t newPreBufferSize = preBufferSize + additionalBytes;
		uint8_t *newPreBuffer = realloc(preBuffer, newPreBufferSize);
		
		size_t readPointerOffset = readPointer - preBuffer;
		size_t writePointerOffset = writePointer - preBuffer;
		
		preBuffer = newPreBuffer;
		preBufferSize = newPreBufferSize;
		
		readPointer = preBuffer + readPointerOffset;
		writePointer = preBuffer + writePointerOffset;
	}
}

- (size_t)availableBytes
{
	return writePointer - readPointer;
}

- (uint8_t *)readBuffer
{
	return readPointer;
}

- (void)getReadBuffer:(uint8_t **)bufferPtr availableBytes:(size_t *)availableBytesPtr
{
	if (bufferPtr) *bufferPtr = readPointer;
	if (availableBytesPtr) *availableBytesPtr = [self availableBytes];
}

- (void)didRead:(size_t)bytesRead
{
	readPointer += bytesRead;
	
	if (readPointer == writePointer)
	{
		// The prebuffer has been drained. Reset pointers.
		readPointer  = preBuffer;
		writePointer = preBuffer;
	}
}

- (size_t)availableSpace
{
	return preBufferSize - (writePointer - preBuffer);
}

- (uint8_t *)writeBuffer
{
	return writePointer;
}

- (void)getWriteBuffer:(uint8_t **)bufferPtr availableSpace:(size_t *)availableSpacePtr
{
	if (bufferPtr) *bufferPtr = writePointer;
	if (availableSpacePtr) *availableSpacePtr = [self availableSpace];
}

- (void)didWrite:(size_t)bytesWritten
{
	writePointer += bytesWritten;
}

- (void)reset
{
	readPointer  = preBuffer;
	writePointer = preBuffer;
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The GCDAsyncReadPacket encompasses the instructions for any given read.
 * The content of a read packet allows the code to determine if we're:
 *  - reading to a certain length
 *  - reading to a certain separator
 *  - or simply reading the first chunk of available data
**/
@interface GCDAsyncReadPacket : NSObject
{
  @public
	NSMutableData *buffer;
	NSUInteger startOffset;
	NSUInteger bytesDone;
	NSUInteger maxLength;
	NSTimeInterval timeout;
	NSUInteger readLength;
	NSData *term;
	BOOL bufferOwner;
	NSUInteger originalBufferLength;
	long tag;
}
- (instancetype)initWithData:(NSMutableData *)d
                 startOffset:(NSUInteger)s
                   maxLength:(NSUInteger)m
                     timeout:(NSTimeInterval)t
                  readLength:(NSUInteger)l
                  terminator:(NSData *)e
                         tag:(long)i NS_DESIGNATED_INITIALIZER;

- (void)ensureCapacityForAdditionalDataOfLength:(NSUInteger)bytesToRead;

- (NSUInteger)optimalReadLengthWithDefault:(NSUInteger)defaultValue shouldPreBuffer:(BOOL *)shouldPreBufferPtr;

- (NSUInteger)readLengthForNonTermWithHint:(NSUInteger)bytesAvailable;
- (NSUInteger)readLengthForTermWithHint:(NSUInteger)bytesAvailable shouldPreBuffer:(BOOL *)shouldPreBufferPtr;
- (NSUInteger)readLengthForTermWithPreBuffer:(GCDAsyncSocketPreBuffer *)preBuffer found:(BOOL *)foundPtr;

- (NSInteger)searchForTermAfterPreBuffering:(ssize_t)numBytes;

@end

@implementation GCDAsyncReadPacket

// Cover the superclass' designated initializer
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
		bytesDone = 0;
		maxLength = m;
		timeout = t;
		readLength = l;
		term = [e copy];
		tag = i;
		
		if (d)
		{
			buffer = d;
			startOffset = s;
			bufferOwner = NO;
			originalBufferLength = [d length];
		}
		else
		{
			if (readLength > 0)
				buffer = [[NSMutableData alloc] initWithLength:readLength];
			else
				buffer = [[NSMutableData alloc] initWithLength:0];
			
			startOffset = 0;
			bufferOwner = YES;
			originalBufferLength = 0;
		}
	}
	return self;
}

/**
 * Increases the length of the buffer (if needed) to ensure a read of the given size will fit.
**/
- (void)ensureCapacityForAdditionalDataOfLength:(NSUInteger)bytesToRead
{
	NSUInteger buffSize = [buffer length];
	NSUInteger buffUsed = startOffset + bytesDone;
	
	NSUInteger buffSpace = buffSize - buffUsed;
	
	if (bytesToRead > buffSpace)
	{
		NSUInteger buffInc = bytesToRead - buffSpace;
		
		[buffer increaseLengthBy:buffInc];
	}
}

/**
 * This method is used when we do NOT know how much data is available to be read from the socket.
 * This method returns the default value unless it exceeds the specified readLength or maxLength.
 * 
 * Furthermore, the shouldPreBuffer decision is based upon the packet type,
 * and whether the returned value would fit in the current buffer without requiring a resize of the buffer.
**/
- (NSUInteger)optimalReadLengthWithDefault:(NSUInteger)defaultValue shouldPreBuffer:(BOOL *)shouldPreBufferPtr
{
	NSUInteger result;
	
	if (readLength > 0)
	{
		// Read a specific length of data
		result = readLength - bytesDone;
		
		// There is no need to prebuffer since we know exactly how much data we need to read.
		// Even if the buffer isn't currently big enough to fit this amount of data,
		// it would have to be resized eventually anyway.
		
		if (shouldPreBufferPtr)
			*shouldPreBufferPtr = NO;
	}
	else
	{
		// Either reading until we find a specified terminator,
		// or we're simply reading all available data.
		// 
		// In other words, one of:
		// 
		// - readDataToData packet
		// - readDataWithTimeout packet
		
		if (maxLength > 0)
			result =  MIN(defaultValue, (maxLength - bytesDone));
		else
			result = defaultValue;
		
		// Since we don't know the size of the read in advance,
		// the shouldPreBuffer decision is based upon whether the returned value would fit
		// in the current buffer without requiring a resize of the buffer.
		// 
		// This is because, in all likelyhood, the amount read from the socket will be less than the default value.
		// Thus we should avoid over-allocating the read buffer when we can simply use the pre-buffer instead.
		
		if (shouldPreBufferPtr)
		{
			NSUInteger buffSize = [buffer length];
			NSUInteger buffUsed = startOffset + bytesDone;
			
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
 * For read packets without a set terminator, returns the amount of data
 * that can be read without exceeding the readLength or maxLength.
 * 
 * The given parameter indicates the number of bytes estimated to be available on the socket,
 * which is taken into consideration during the calculation.
 * 
 * The given hint MUST be greater than zero.
**/
- (NSUInteger)readLengthForNonTermWithHint:(NSUInteger)bytesAvailable
{
	NSAssert(term == nil, @"This method does not apply to term reads");
	NSAssert(bytesAvailable > 0, @"Invalid parameter: bytesAvailable");
	
	if (readLength > 0)
	{
		// Read a specific length of data
		
		return MIN(bytesAvailable, (readLength - bytesDone));
		
		// No need to avoid resizing the buffer.
		// If the user provided their own buffer,
		// and told us to read a certain length of data that exceeds the size of the buffer,
		// then it is clear that our code will resize the buffer during the read operation.
		// 
		// This method does not actually do any resizing.
		// The resizing will happen elsewhere if needed.
	}
	else
	{
		// Read all available data
		
		NSUInteger result = bytesAvailable;
		
		if (maxLength > 0)
		{
			result = MIN(result, (maxLength - bytesDone));
		}
		
		// No need to avoid resizing the buffer.
		// If the user provided their own buffer,
		// and told us to read all available data without giving us a maxLength,
		// then it is clear that our code might resize the buffer during the read operation.
		// 
		// This method does not actually do any resizing.
		// The resizing will happen elsewhere if needed.
		
		return result;
	}
}

/**
 * For read packets with a set terminator, returns the amount of data
 * that can be read without exceeding the maxLength.
 * 
 * The given parameter indicates the number of bytes estimated to be available on the socket,
 * which is taken into consideration during the calculation.
 * 
 * To optimize memory allocations, mem copies, and mem moves
 * the shouldPreBuffer boolean value will indicate if the data should be read into a prebuffer first,
 * or if the data can be read directly into the read packet's buffer.
**/
- (NSUInteger)readLengthForTermWithHint:(NSUInteger)bytesAvailable shouldPreBuffer:(BOOL *)shouldPreBufferPtr
{
	NSAssert(term != nil, @"This method does not apply to non-term reads");
	NSAssert(bytesAvailable > 0, @"Invalid parameter: bytesAvailable");
	
	
	NSUInteger result = bytesAvailable;
	
	if (maxLength > 0)
	{
		result = MIN(result, (maxLength - bytesDone));
	}
	
	// Should the data be read into the read packet's buffer, or into a pre-buffer first?
	// 
	// One would imagine the preferred option is the faster one.
	// So which one is faster?
	// 
	// Reading directly into the packet's buffer requires:
	// 1. Possibly resizing packet buffer (malloc/realloc)
	// 2. Filling buffer (read)
	// 3. Searching for term (memcmp)
	// 4. Possibly copying overflow into prebuffer (malloc/realloc, memcpy)
	// 
	// Reading into prebuffer first:
	// 1. Possibly resizing prebuffer (malloc/realloc)
	// 2. Filling buffer (read)
	// 3. Searching for term (memcmp)
	// 4. Copying underflow into packet buffer (malloc/realloc, memcpy)
	// 5. Removing underflow from prebuffer (memmove)
	// 
	// Comparing the performance of the two we can see that reading
	// data into the prebuffer first is slower due to the extra memove.
	// 
	// However:
	// The implementation of NSMutableData is open source via core foundation's CFMutableData.
	// Decreasing the length of a mutable data object doesn't cause a realloc.
	// In other words, the capacity of a mutable data object can grow, but doesn't shrink.
	// 
	// This means the prebuffer will rarely need a realloc.
	// The packet buffer, on the other hand, may often need a realloc.
	// This is especially true if we are the buffer owner.
	// Furthermore, if we are constantly realloc'ing the packet buffer,
	// and then moving the overflow into the prebuffer,
	// then we're consistently over-allocating memory for each term read.
	// And now we get into a bit of a tradeoff between speed and memory utilization.
	// 
	// The end result is that the two perform very similarly.
	// And we can answer the original question very simply by another means.
	// 
	// If we can read all the data directly into the packet's buffer without resizing it first,
	// then we do so. Otherwise we use the prebuffer.
	
	if (shouldPreBufferPtr)
	{
		NSUInteger buffSize = [buffer length];
		NSUInteger buffUsed = startOffset + bytesDone;
		
		if ((buffSize - buffUsed) >= result)
			*shouldPreBufferPtr = NO;
		else
			*shouldPreBufferPtr = YES;
	}
	
	return result;
}

/**
 * For read packets with a set terminator,
 * returns the amount of data that can be read from the given preBuffer,
 * without going over a terminator or the maxLength.
 * 
 * It is assumed the terminator has not already been read.
**/
- (NSUInteger)readLengthForTermWithPreBuffer:(GCDAsyncSocketPreBuffer *)preBuffer found:(BOOL *)foundPtr
{
	NSAssert(term != nil, @"This method does not apply to non-term reads");
	NSAssert([preBuffer availableBytes] > 0, @"Invoked with empty pre buffer!");
	
	// We know that the terminator, as a whole, doesn't exist in our own buffer.
	// But it is possible that a _portion_ of it exists in our buffer.
	// So we're going to look for the terminator starting with a portion of our own buffer.
	// 
	// Example:
	// 
	// term length      = 3 bytes
	// bytesDone        = 5 bytes
	// preBuffer length = 5 bytes
	// 
	// If we append the preBuffer to our buffer,
	// it would look like this:
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// ---------------------
	// 
	// So we start our search here:
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// -------^-^-^---------
	// 
	// And move forwards...
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// ---------^-^-^-------
	// 
	// Until we find the terminator or reach the end.
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// ---------------^-^-^-
	
	BOOL found = NO;
	
	NSUInteger termLength = [term length];
	NSUInteger preBufferLength = [preBuffer availableBytes];
	
	if ((bytesDone + preBufferLength) < termLength)
	{
		// Not enough data for a full term sequence yet
		return preBufferLength;
	}
	
	NSUInteger maxPreBufferLength;
	if (maxLength > 0) {
		maxPreBufferLength = MIN(preBufferLength, (maxLength - bytesDone));
		
		// Note: maxLength >= termLength
	}
	else {
		maxPreBufferLength = preBufferLength;
	}
	
	uint8_t seq[termLength];
	const void *termBuf = [term bytes];
	
	NSUInteger bufLen = MIN(bytesDone, (termLength - 1));
	uint8_t *buf = (uint8_t *)[buffer mutableBytes] + startOffset + bytesDone - bufLen;
	
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
 * For read packets with a set terminator, scans the packet buffer for the term.
 * It is assumed the terminator had not been fully read prior to the new bytes.
 * 
 * If the term is found, the number of excess bytes after the term are returned.
 * If the term is not found, this method will return -1.
 * 
 * Note: A return value of zero means the term was found at the very end.
 * 
 * Prerequisites:
 * The given number of bytes have been added to the end of our buffer.
 * Our bytesDone variable has NOT been changed due to the prebuffered bytes.
**/
- (NSInteger)searchForTermAfterPreBuffering:(ssize_t)numBytes
{
	NSAssert(term != nil, @"This method does not apply to non-term reads");
	
	// The implementation of this method is very similar to the above method.
	// See the above method for a discussion of the algorithm used here.
	
	uint8_t *buff = [buffer mutableBytes];
	NSUInteger buffLength = bytesDone + numBytes;
	
	const void *termBuff = [term bytes];
	NSUInteger termLength = [term length];
	
	// Note: We are dealing with unsigned integers,
	// so make sure the math doesn't go below zero.
	
	NSUInteger i = ((buffLength - numBytes) >= termLength) ? (buffLength - numBytes - termLength + 1) : 0;
	
	while (i + termLength <= buffLength)
	{
		uint8_t *subBuffer = buff + startOffset + i;
		
		if (memcmp(subBuffer, termBuff, termLength) == 0)
		{
			return buffLength - (i + termLength);
		}
		
		i++;
	}
	
	return -1;
}


@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The GCDAsyncWritePacket encompasses the instructions for any given write.
**/
@interface GCDAsyncWritePacket : NSObject
{
  @public
	NSData *buffer;
	NSUInteger bytesDone;
	long tag;
	NSTimeInterval timeout;
}
- (instancetype)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i NS_DESIGNATED_INITIALIZER;
@end

@implementation GCDAsyncWritePacket

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
		buffer = d; // Retain not copy. For performance as documented in header file.
		bytesDone = 0;
		timeout = t;
		tag = i;
	}
	return self;
}


@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The GCDAsyncSpecialPacket encompasses special instructions for interruptions in the read/write queues.
 * This class my be altered to support more than just TLS in the future.
**/
@interface GCDAsyncSpecialPacket : NSObject
{
  @public
	NSDictionary *tlsSettings;
}
- (instancetype)initWithTLSSettings:(NSDictionary <NSString*,NSObject*>*)settings NS_DESIGNATED_INITIALIZER;
@end

@implementation GCDAsyncSpecialPacket

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
		tlsSettings = [settings copy];
	}
	return self;
}


@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation GCDAsyncSocket
{
	uint32_t flags;
	uint16_t config;
	
	__weak id<GCDAsyncSocketDelegate> delegate;
	dispatch_queue_t delegateQueue;
	
	int socket4FD;
	int socket6FD;
	int socketUN;
	NSURL *socketUrl;
	int stateIndex;
	NSData * connectInterface4;
	NSData * connectInterface6;
	NSData * connectInterfaceUN;
	
	dispatch_queue_t socketQueue;
	
	dispatch_source_t accept4Source;
	dispatch_source_t accept6Source;
	dispatch_source_t acceptUNSource;
	dispatch_source_t connectTimer;
	dispatch_source_t readSource;
	dispatch_source_t writeSource;
	dispatch_source_t readTimer;
	dispatch_source_t writeTimer;
	
	NSMutableArray *readQueue;
	NSMutableArray *writeQueue;
	
	GCDAsyncReadPacket *currentRead;
	GCDAsyncWritePacket *currentWrite;
	
	unsigned long socketFDBytesAvailable; // 套接字可读取的字节数
	
	GCDAsyncSocketPreBuffer *preBuffer;
		
//#if TARGET_OS_IPHONE
	CFStreamClientContext streamContext;
	CFReadStreamRef readStream;
	CFWriteStreamRef writeStream;
//#endif
	SSLContextRef sslContext;
	GCDAsyncSocketPreBuffer *sslPreBuffer;
	size_t sslWriteCachedLength;
	OSStatus sslErrCode;
    OSStatus lastSSLHandshakeError;
	
	void *IsOnSocketQueueOrTargetQueueKey;
	
	id userData;
    NSTimeInterval alternateAddressDelay;
}

- (instancetype)init
{
	return [self initWithDelegate:nil delegateQueue:NULL socketQueue:NULL];
}

- (instancetype)initWithSocketQueue:(dispatch_queue_t)sq
{
	return [self initWithDelegate:nil delegateQueue:NULL socketQueue:sq];
}

- (instancetype)initWithDelegate:(id<GCDAsyncSocketDelegate>)aDelegate delegateQueue:(dispatch_queue_t)dq
{
	return [self initWithDelegate:aDelegate delegateQueue:dq socketQueue:NULL];
}

- (instancetype)initWithDelegate:(id<GCDAsyncSocketDelegate>)aDelegate delegateQueue:(dispatch_queue_t)dq socketQueue:(dispatch_queue_t)sq
{
	if((self = [super init]))
	{
		delegate = aDelegate;
		delegateQueue = dq;
		
		#if !OS_OBJECT_USE_OBJC
		if (dq) dispatch_retain(dq);
		#endif
		
		socket4FD = SOCKET_NULL;
		socket6FD = SOCKET_NULL;
		socketUN = SOCKET_NULL;
		socketUrl = nil;
		stateIndex = 0;
		
		if (sq)
		{
            // 要求队列为 串行队列
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0),
			         @"The given socketQueue parameter must not be a concurrent queue.");
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
			         @"The given socketQueue parameter must not be a concurrent queue.");
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
			         @"The given socketQueue parameter must not be a concurrent queue.");
			
			socketQueue = sq;
			#if !OS_OBJECT_USE_OBJC
			dispatch_retain(sq);
			#endif
		}
		else
		{
            // 创建一个串行队列
			socketQueue = dispatch_queue_create([GCDAsyncSocketQueueName UTF8String], NULL);
		}
		/*
        在 GCDAsyncSocket 中，IsOnSocketQueueOrTargetQueueKey 是一个用于标识当前操作是否在 Socket 队列或目标队列上的键值。这种写法是为了确保多线程环境下的线程安全性。

        IsOnSocketQueueOrTargetQueueKey 实际上是一个指向静态变量的指针，它用作一个唯一的键值，用于在 GCDAsyncSocket 类的实例中保存和获取相关信息。在 Objective-C 中，静态变量的地址可以被用作键值，以便在多个方法和线程之间传递和共享数据。

        为了更好地理解这个用法，让我们看看 GCDAsyncSocket 是如何使用它的。在 GCDAsyncSocket 的实现中，经常会用到一个叫做 socketQueue 的串行队列，用于管理所有的 Socket 操作。这个队列是一个私有队列，确保了在队列上的所有操作都是按顺序执行的，从而保证了线程安全性。

        在 GCDAsyncSocket 的实现中，有一些方法可以在任何线程上调用，但它们内部需要确定当前操作是否在 socketQueue 上执行。为了实现这个目的，IsOnSocketQueueOrTargetQueueKey 被用作一个上下文键，存储在相关操作的 GCD 队列上。

        在每个方法中，可以通过检查当前线程是否在 socketQueue 上来确定是否在正确的队列上执行。如果不在 socketQueue 上，它将检查当前线程是否在目标队列上执行，目标队列是方法的参数之一。这个检查是通过判断 IsOnSocketQueueOrTargetQueueKey 键对应的值是否为真来进行的。这样，就能保证操作在正确的队列上执行，避免了线程安全问题。

        总结一下，IsOnSocketQueueOrTargetQueueKey 的写法是为了提供一种简单而可靠的方法，用于判断当前操作是否在正确的队列上执行，以确保 GCDAsyncSocket 在多线程环境下的线程安全性。
         */
		
		IsOnSocketQueueOrTargetQueueKey = &IsOnSocketQueueOrTargetQueueKey;
		
		void *nonNullUnusedPointer = (__bridge void *)self;
        
        
        // 是一个 GCD（Grand Central Dispatch）函数，用于在指定的调度队列上设置特定的上下文信息，
        // 在 socketQueue 队列上，通过 IsOnSocketQueueOrTargetQueueKey key 设定上下文，绑定 nonNullUnusedPointer 上下文信息，产生关联
        
		dispatch_queue_set_specific(socketQueue, IsOnSocketQueueOrTargetQueueKey, nonNullUnusedPointer, NULL);
		
		readQueue = [[NSMutableArray alloc] initWithCapacity:5];
		currentRead = nil;
		
		writeQueue = [[NSMutableArray alloc] initWithCapacity:5];
		currentWrite = nil;
		
		preBuffer = [[GCDAsyncSocketPreBuffer alloc] initWithCapacity:(1024 * 4)];
        alternateAddressDelay = 0.3;
	}
	return self;
}

- (void)dealloc
{
	LogInfo(@"%@ - %@ (start)", THIS_METHOD, self);
	
	// Set dealloc flag.
	// This is used by closeWithError to ensure we don't accidentally retain ourself.
	flags |= kDealloc;
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		[self closeWithError:nil];
	}
	else
	{
		dispatch_sync(socketQueue, ^{
			[self closeWithError:nil];
		});
	}
	
	delegate = nil;
	
	#if !OS_OBJECT_USE_OBJC
	if (delegateQueue) dispatch_release(delegateQueue);
	#endif
	delegateQueue = NULL;
	
	#if !OS_OBJECT_USE_OBJC
	if (socketQueue) dispatch_release(socketQueue);
	#endif
	socketQueue = NULL;
	
	LogInfo(@"%@ - %@ (finish)", THIS_METHOD, self);
}

#pragma mark -

+ (nullable instancetype)socketFromConnectedSocketFD:(int)socketFD socketQueue:(nullable dispatch_queue_t)sq error:(NSError**)error {
  return [self socketFromConnectedSocketFD:socketFD delegate:nil delegateQueue:NULL socketQueue:sq error:error];
}

+ (nullable instancetype)socketFromConnectedSocketFD:(int)socketFD delegate:(nullable id<GCDAsyncSocketDelegate>)aDelegate delegateQueue:(nullable dispatch_queue_t)dq error:(NSError**)error {
  return [self socketFromConnectedSocketFD:socketFD delegate:aDelegate delegateQueue:dq socketQueue:NULL error:error];
}

+ (nullable instancetype)socketFromConnectedSocketFD:(int)socketFD delegate:(nullable id<GCDAsyncSocketDelegate>)aDelegate delegateQueue:(nullable dispatch_queue_t)dq socketQueue:(nullable dispatch_queue_t)sq error:(NSError* __autoreleasing *)error
{
  __block BOOL errorOccured = NO;
  
  GCDAsyncSocket *socket = [[[self class] alloc] initWithDelegate:aDelegate delegateQueue:dq socketQueue:sq];
  
  dispatch_sync(socket->socketQueue, ^{ @autoreleasepool {
    struct sockaddr addr;
    socklen_t addr_size = sizeof(struct sockaddr);
    int retVal = getpeername(socketFD, (struct sockaddr *)&addr, &addr_size);
    if (retVal)
    {
      NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketOtherError",
                                                           @"GCDAsyncSocket", [NSBundle mainBundle],
                                                           @"Attempt to create socket from socket FD failed. getpeername() failed", nil);
      
      NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};

      errorOccured = YES;
      if (error)
        *error = [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketOtherError userInfo:userInfo];
      return;
    }
    
    if (addr.sa_family == AF_INET)
    {
      socket->socket4FD = socketFD;
    }
    else if (addr.sa_family == AF_INET6)
    {
      socket->socket6FD = socketFD;
    }
    else
    {
      NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketOtherError",
                                                           @"GCDAsyncSocket", [NSBundle mainBundle],
                                                           @"Attempt to create socket from socket FD failed. socket FD is neither IPv4 nor IPv6", nil);
      
      NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
      
      errorOccured = YES;
      if (error)
        *error = [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketOtherError userInfo:userInfo];
      return;
    }
    
    socket->flags = kSocketStarted;
    [socket didConnect:socket->stateIndex];
  }});
  
  return errorOccured? nil: socket;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Configuration
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (id)delegate
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return delegate;
	}
	else
	{
		__block id result;
		
		dispatch_sync(socketQueue, ^{
            result = self->delegate;
		});
		
		return result;
	}
}

- (void)setDelegate:(id)newDelegate synchronously:(BOOL)synchronously
{
	dispatch_block_t block = ^{
        self->delegate = newDelegate;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey)) {
		block();
	}
	else {
		if (synchronously)
			dispatch_sync(socketQueue, block);
		else
			dispatch_async(socketQueue, block);
	}
}

- (void)setDelegate:(id<GCDAsyncSocketDelegate>)newDelegate
{
	[self setDelegate:newDelegate synchronously:NO];
}

- (void)synchronouslySetDelegate:(id<GCDAsyncSocketDelegate>)newDelegate
{
	[self setDelegate:newDelegate synchronously:YES];
}

- (dispatch_queue_t)delegateQueue
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return delegateQueue;
	}
	else
	{
		__block dispatch_queue_t result;
		
		dispatch_sync(socketQueue, ^{
            result = self->delegateQueue;
		});
		
		return result;
	}
}

- (void)setDelegateQueue:(dispatch_queue_t)newDelegateQueue synchronously:(BOOL)synchronously
{
	dispatch_block_t block = ^{
		
		#if !OS_OBJECT_USE_OBJC
        if (self->delegateQueue) dispatch_release(self->delegateQueue);
		if (newDelegateQueue) dispatch_retain(newDelegateQueue);
		#endif
		
        self->delegateQueue = newDelegateQueue;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey)) {
		block();
	}
	else {
		if (synchronously)
			dispatch_sync(socketQueue, block);
		else
			dispatch_async(socketQueue, block);
	}
}

- (void)setDelegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegateQueue:newDelegateQueue synchronously:NO];
}

- (void)synchronouslySetDelegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegateQueue:newDelegateQueue synchronously:YES];
}

- (void)getDelegate:(id<GCDAsyncSocketDelegate> *)delegatePtr delegateQueue:(dispatch_queue_t *)delegateQueuePtr
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (delegatePtr) *delegatePtr = delegate;
		if (delegateQueuePtr) *delegateQueuePtr = delegateQueue;
	}
	else
	{
		__block id dPtr = NULL;
		__block dispatch_queue_t dqPtr = NULL;
		
		dispatch_sync(socketQueue, ^{
            dPtr = self->delegate;
            dqPtr = self->delegateQueue;
		});
		
		if (delegatePtr) *delegatePtr = dPtr;
		if (delegateQueuePtr) *delegateQueuePtr = dqPtr;
	}
}

- (void)setDelegate:(id)newDelegate delegateQueue:(dispatch_queue_t)newDelegateQueue synchronously:(BOOL)synchronously
{
	dispatch_block_t block = ^{
		
        self->delegate = newDelegate;
		
		#if !OS_OBJECT_USE_OBJC
        if (self->delegateQueue) dispatch_release(self->delegateQueue);
		if (newDelegateQueue) dispatch_retain(newDelegateQueue);
		#endif
		
        self->delegateQueue = newDelegateQueue;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey)) {
		block();
	}
	else {
		if (synchronously)
			dispatch_sync(socketQueue, block);
		else
			dispatch_async(socketQueue, block);
	}
}

- (void)setDelegate:(id<GCDAsyncSocketDelegate>)newDelegate delegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegate:newDelegate delegateQueue:newDelegateQueue synchronously:NO];
}

- (void)synchronouslySetDelegate:(id<GCDAsyncSocketDelegate>)newDelegate delegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegate:newDelegate delegateQueue:newDelegateQueue synchronously:YES];
}

- (BOOL)isIPv4Enabled
{
	// Note: YES means kIPv4Disabled is OFF
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return ((config & kIPv4Disabled) == 0);
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
            result = ((self->config & kIPv4Disabled) == 0);
		});
		
		return result;
	}
}

- (void)setIPv4Enabled:(BOOL)flag
{
	// Note: YES means kIPv4Disabled is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
            self->config &= ~kIPv4Disabled;
		else
            self->config |= kIPv4Disabled;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}

- (BOOL)isIPv6Enabled
{
	// Note: YES means kIPv6Disabled is OFF
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return ((config & kIPv6Disabled) == 0);
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
            result = ((self->config & kIPv6Disabled) == 0);
		});
		
		return result;
	}
}

- (void)setIPv6Enabled:(BOOL)flag
{
	// Note: YES means kIPv6Disabled is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
            self->config &= ~kIPv6Disabled;
		else
            self->config |= kIPv6Disabled;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}

- (BOOL)isIPv4PreferredOverIPv6
{
	// Note: YES means kPreferIPv6 is OFF
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return ((config & kPreferIPv6) == 0);
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
            result = ((self->config & kPreferIPv6) == 0);
		});
		
		return result;
	}
}

- (void)setIPv4PreferredOverIPv6:(BOOL)flag
{
	// Note: YES means kPreferIPv6 is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
            self->config &= ~kPreferIPv6;
		else
            self->config |= kPreferIPv6;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}

- (NSTimeInterval) alternateAddressDelay {
    __block NSTimeInterval delay;
    dispatch_block_t block = ^{
        delay = self->alternateAddressDelay;
    };
    if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
        block();
    else
        dispatch_sync(socketQueue, block);
    return delay;
}

- (void) setAlternateAddressDelay:(NSTimeInterval)delay {
    dispatch_block_t block = ^{
        self->alternateAddressDelay = delay;
    };
    if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
        block();
    else
        dispatch_async(socketQueue, block);
}

- (id)userData
{
	__block id result = nil;
	
	dispatch_block_t block = ^{
		
        result = self->userData;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

- (void)setUserData:(id)arbitraryUserData
{
	dispatch_block_t block = ^{
		
        if (self->userData != arbitraryUserData)
		{
            self->userData = arbitraryUserData;
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Accepting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)acceptOnPort:(uint16_t)port error:(NSError **)errPtr
{
	return [self acceptOnInterface:nil port:port error:errPtr];
}

- (BOOL)acceptOnInterface:(NSString *)inInterface port:(uint16_t)port error:(NSError **)errPtr
{
	LogTrace();
	
	// Just in-case interface parameter is immutable.
	NSString *interface = [inInterface copy];
	
	__block BOOL result = NO;
	__block NSError *err = nil;
	
	// CreateSocket Block
	// This block will be invoked within the dispatch block below.
	
	int(^createSocket)(int, NSData*) = ^int (int domain, NSData *interfaceAddr) {
		
		int socketFD = socket(domain, SOCK_STREAM, 0);
		
		if (socketFD == SOCKET_NULL)
		{
			NSString *reason = @"Error in socket() function";
			err = [self errorWithErrno:errno reason:reason];
			
			return SOCKET_NULL;
		}
		
		int status;
		
		// Set socket options
		
		status = fcntl(socketFD, F_SETFL, O_NONBLOCK);
		if (status == -1)
		{
			NSString *reason = @"Error enabling non-blocking IO on socket (fcntl)";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		int reuseOn = 1;
		status = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
		if (status == -1)
		{
			NSString *reason = @"Error enabling address reuse (setsockopt)";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		// Bind socket
		
		status = bind(socketFD, (const struct sockaddr *)[interfaceAddr bytes], (socklen_t)[interfaceAddr length]);
		if (status == -1)
		{
			NSString *reason = @"Error in bind() function";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		// Listen
		
		status = listen(socketFD, 1024);
		if (status == -1)
		{
			NSString *reason = @"Error in listen() function";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		return socketFD;
	};
	
	// Create dispatch block and run on socketQueue
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
        if (self->delegate == nil) // Must have delegate set
		{
			NSString *msg = @"Attempting to accept without a delegate. Set a delegate first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
        if (self->delegateQueue == NULL) // Must have delegate queue set
		{
			NSString *msg = @"Attempting to accept without a delegate queue. Set a delegate queue first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
        BOOL isIPv4Disabled = (self->config & kIPv4Disabled) ? YES : NO;
        BOOL isIPv6Disabled = (self->config & kIPv6Disabled) ? YES : NO;
		
		if (isIPv4Disabled && isIPv6Disabled) // Must have IPv4 or IPv6 enabled
		{
			NSString *msg = @"Both IPv4 and IPv6 have been disabled. Must enable at least one protocol first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
		if (![self isDisconnected]) // Must be disconnected
		{
			NSString *msg = @"Attempting to accept while connected or accepting connections. Disconnect first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
		// Clear queues (spurious read/write requests post disconnect)
        [self->readQueue removeAllObjects];
        [self->writeQueue removeAllObjects];
		
		// Resolve interface from description
		
		NSMutableData *interface4 = nil;
		NSMutableData *interface6 = nil;
		
		[self getInterfaceAddress4:&interface4 address6:&interface6 fromDescription:interface port:port];
		
		if ((interface4 == nil) && (interface6 == nil))
		{
			NSString *msg = @"Unknown interface. Specify valid interface by name (e.g. \"en1\") or IP address.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		if (isIPv4Disabled && (interface6 == nil))
		{
			NSString *msg = @"IPv4 has been disabled and specified interface doesn't support IPv6.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		if (isIPv6Disabled && (interface4 == nil))
		{
			NSString *msg = @"IPv6 has been disabled and specified interface doesn't support IPv4.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		BOOL enableIPv4 = !isIPv4Disabled && (interface4 != nil);
		BOOL enableIPv6 = !isIPv6Disabled && (interface6 != nil);
		
		// Create sockets, configure, bind, and listen
		
		if (enableIPv4)
		{
			LogVerbose(@"Creating IPv4 socket");
            self->socket4FD = createSocket(AF_INET, interface4);
			
            if (self->socket4FD == SOCKET_NULL)
			{
				return_from_block;
			}
		}
		
		if (enableIPv6)
		{
			LogVerbose(@"Creating IPv6 socket");
			
			if (enableIPv4 && (port == 0))
			{
				// No specific port was specified, so we allowed the OS to pick an available port for us.
				// Now we need to make sure the IPv6 socket listens on the same port as the IPv4 socket.
				
				struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)[interface6 mutableBytes];
				addr6->sin6_port = htons([self localPort4]);
			}
			
            self->socket6FD = createSocket(AF_INET6, interface6);
			
            if (self->socket6FD == SOCKET_NULL)
			{
                if (self->socket4FD != SOCKET_NULL)
				{
					LogVerbose(@"close(socket4FD)");
                    close(self->socket4FD);
                    self->socket4FD = SOCKET_NULL;
				}
				
				return_from_block;
			}
		}
		
		// Create accept sources
		
		if (enableIPv4)
		{
            self->accept4Source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self->socket4FD, 0, self->socketQueue);
			
            int socketFD = self->socket4FD;
            dispatch_source_t acceptSource = self->accept4Source;
			
			__weak GCDAsyncSocket *weakSelf = self;
			
            dispatch_source_set_event_handler(self->accept4Source, ^{ @autoreleasepool {
			#pragma clang diagnostic push
			#pragma clang diagnostic warning "-Wimplicit-retain-self"
				
				__strong GCDAsyncSocket *strongSelf = weakSelf;
				if (strongSelf == nil) return_from_block;
				
				LogVerbose(@"event4Block");
				
				unsigned long i = 0;
				unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
				
				LogVerbose(@"numPendingConnections: %lu", numPendingConnections);
				
				while ([strongSelf doAccept:socketFD] && (++i < numPendingConnections));
				
			#pragma clang diagnostic pop
			}});
			
			
            dispatch_source_set_cancel_handler(self->accept4Source, ^{
			#pragma clang diagnostic push
			#pragma clang diagnostic warning "-Wimplicit-retain-self"
				
				#if !OS_OBJECT_USE_OBJC
				LogVerbose(@"dispatch_release(accept4Source)");
				dispatch_release(acceptSource);
				#endif
				
				LogVerbose(@"close(socket4FD)");
				close(socketFD);
			
			#pragma clang diagnostic pop
			});
			
			LogVerbose(@"dispatch_resume(accept4Source)");
            dispatch_resume(self->accept4Source);
		}
		
		if (enableIPv6)
		{
            self->accept6Source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self->socket6FD, 0, self->socketQueue);
			
            int socketFD = self->socket6FD;
            dispatch_source_t acceptSource = self->accept6Source;
			
			__weak GCDAsyncSocket *weakSelf = self;
			
            dispatch_source_set_event_handler(self->accept6Source, ^{ @autoreleasepool {
			#pragma clang diagnostic push
			#pragma clang diagnostic warning "-Wimplicit-retain-self"
				
				__strong GCDAsyncSocket *strongSelf = weakSelf;
				if (strongSelf == nil) return_from_block;
				
				LogVerbose(@"event6Block");
				
				unsigned long i = 0;
				unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
				
				LogVerbose(@"numPendingConnections: %lu", numPendingConnections);
				
				while ([strongSelf doAccept:socketFD] && (++i < numPendingConnections));
				
			#pragma clang diagnostic pop
			}});
			
            dispatch_source_set_cancel_handler(self->accept6Source, ^{
			#pragma clang diagnostic push
			#pragma clang diagnostic warning "-Wimplicit-retain-self"
				
				#if !OS_OBJECT_USE_OBJC
				LogVerbose(@"dispatch_release(accept6Source)");
				dispatch_release(acceptSource);
				#endif
				
				LogVerbose(@"close(socket6FD)");
				close(socketFD);
				
			#pragma clang diagnostic pop
			});
			
			LogVerbose(@"dispatch_resume(accept6Source)");
            dispatch_resume(self->accept6Source);
		}
		
        self->flags |= kSocketStarted;
		
		result = YES;
	}};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		LogInfo(@"Error in accept: %@", err);
		
		if (errPtr)
			*errPtr = err;
	}
	
	return result;
}

- (BOOL)acceptOnUrl:(NSURL *)url error:(NSError **)errPtr
{
	LogTrace();
	
	__block BOOL result = NO;
	__block NSError *err = nil;
	
	// CreateSocket Block
	// This block will be invoked within the dispatch block below.
	
	int(^createSocket)(int, NSData*) = ^int (int domain, NSData *interfaceAddr) {
		
		int socketFD = socket(domain, SOCK_STREAM, 0);
		
		if (socketFD == SOCKET_NULL)
		{
			NSString *reason = @"Error in socket() function";
			err = [self errorWithErrno:errno reason:reason];
			
			return SOCKET_NULL;
		}
		
		int status;
		
		// Set socket options
		
		status = fcntl(socketFD, F_SETFL, O_NONBLOCK);
		if (status == -1)
		{
			NSString *reason = @"Error enabling non-blocking IO on socket (fcntl)";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		int reuseOn = 1;
		status = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
		if (status == -1)
		{
			NSString *reason = @"Error enabling address reuse (setsockopt)";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		// Bind socket
		
		status = bind(socketFD, (const struct sockaddr *)[interfaceAddr bytes], (socklen_t)[interfaceAddr length]);
		if (status == -1)
		{
			NSString *reason = @"Error in bind() function";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		// Listen
		
		status = listen(socketFD, 1024);
		if (status == -1)
		{
			NSString *reason = @"Error in listen() function";
			err = [self errorWithErrno:errno reason:reason];
			
			LogVerbose(@"close(socketFD)");
			close(socketFD);
			return SOCKET_NULL;
		}
		
		return socketFD;
	};
	
	// Create dispatch block and run on socketQueue
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
        if (self->delegate == nil) // Must have delegate set
		{
			NSString *msg = @"Attempting to accept without a delegate. Set a delegate first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
        if (self->delegateQueue == NULL) // Must have delegate queue set
		{
			NSString *msg = @"Attempting to accept without a delegate queue. Set a delegate queue first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
		if (![self isDisconnected]) // Must be disconnected
		{
			NSString *msg = @"Attempting to accept while connected or accepting connections. Disconnect first.";
			err = [self badConfigError:msg];
			
			return_from_block;
		}
		
		// Clear queues (spurious read/write requests post disconnect)
        [self->readQueue removeAllObjects];
        [self->writeQueue removeAllObjects];
		
		// Remove a previous socket
		
		NSError *error = nil;
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSString *urlPath = url.path;
		if (urlPath && [fileManager fileExistsAtPath:urlPath]) {
			if (![fileManager removeItemAtURL:url error:&error]) {
				NSString *msg = @"Could not remove previous unix domain socket at given url.";
				err = [self otherError:msg];
				
				return_from_block;
			}
		}
		
		// Resolve interface from description
		
		NSData *interface = [self getInterfaceAddressFromUrl:url];
		
		if (interface == nil)
		{
			NSString *msg = @"Invalid unix domain url. Specify a valid file url that does not exist (e.g. \"file:///tmp/socket\")";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		// Create sockets, configure, bind, and listen
		
		LogVerbose(@"Creating unix domain socket");
        self->socketUN = createSocket(AF_UNIX, interface);
		
        if (self->socketUN == SOCKET_NULL)
		{
			return_from_block;
		}
		
        self->socketUrl = url;
		
		// Create accept sources
		
        self->acceptUNSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self->socketUN, 0, self->socketQueue);
		
        int socketFD = self->socketUN;
        dispatch_source_t acceptSource = self->acceptUNSource;
		
		__weak GCDAsyncSocket *weakSelf = self;
		
        dispatch_source_set_event_handler(self->acceptUNSource, ^{ @autoreleasepool {
			
			__strong GCDAsyncSocket *strongSelf = weakSelf;
			
			LogVerbose(@"eventUNBlock");
			
			unsigned long i = 0;
			unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
			
			LogVerbose(@"numPendingConnections: %lu", numPendingConnections);
			
			while ([strongSelf doAccept:socketFD] && (++i < numPendingConnections));
		}});
		
        dispatch_source_set_cancel_handler(self->acceptUNSource, ^{
			
#if !OS_OBJECT_USE_OBJC
			LogVerbose(@"dispatch_release(acceptUNSource)");
			dispatch_release(acceptSource);
#endif
			
			LogVerbose(@"close(socketUN)");
			close(socketFD);
		});
		
		LogVerbose(@"dispatch_resume(acceptUNSource)");
        dispatch_resume(self->acceptUNSource);
		
        self->flags |= kSocketStarted;
		
		result = YES;
	}};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		LogInfo(@"Error in accept: %@", err);
		
		if (errPtr)
			*errPtr = err;
	}
	
	return result;	
}

- (BOOL)doAccept:(int)parentSocketFD
{
	LogTrace();
	
	int socketType;
	int childSocketFD;
	NSData *childSocketAddress;
	
	if (parentSocketFD == socket4FD)
	{
		socketType = 0;
		
		struct sockaddr_in addr;
		socklen_t addrLen = sizeof(addr);
		
		childSocketFD = accept(parentSocketFD, (struct sockaddr *)&addr, &addrLen);
		
		if (childSocketFD == -1)
		{
			LogWarn(@"Accept failed with error: %@", [self errnoError]);
			return NO;
		}
		
		childSocketAddress = [NSData dataWithBytes:&addr length:addrLen];
	}
	else if (parentSocketFD == socket6FD)
	{
		socketType = 1;
		
		struct sockaddr_in6 addr;
		socklen_t addrLen = sizeof(addr);
		
		childSocketFD = accept(parentSocketFD, (struct sockaddr *)&addr, &addrLen);
		
		if (childSocketFD == -1)
		{
			LogWarn(@"Accept failed with error: %@", [self errnoError]);
			return NO;
		}
		
		childSocketAddress = [NSData dataWithBytes:&addr length:addrLen];
	}
	else // if (parentSocketFD == socketUN)
	{
		socketType = 2;
		
		struct sockaddr_un addr;
		socklen_t addrLen = sizeof(addr);
		
		childSocketFD = accept(parentSocketFD, (struct sockaddr *)&addr, &addrLen);
		
		if (childSocketFD == -1)
		{
			LogWarn(@"Accept failed with error: %@", [self errnoError]);
			return NO;
		}
		
		childSocketAddress = [NSData dataWithBytes:&addr length:addrLen];
	}
	
	// Enable non-blocking IO on the socket
	
	int result = fcntl(childSocketFD, F_SETFL, O_NONBLOCK);
	if (result == -1)
	{
		LogWarn(@"Error enabling non-blocking IO on accepted socket (fcntl)");
		LogVerbose(@"close(childSocketFD)");
		close(childSocketFD);
		return NO;
	}
	
	// Prevent SIGPIPE signals
	
	int nosigpipe = 1;
	setsockopt(childSocketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
	
	// Notify delegate
	
	if (delegateQueue)
	{
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			// Query delegate for custom socket queue
			
			dispatch_queue_t childSocketQueue = NULL;
			
			if ([theDelegate respondsToSelector:@selector(newSocketQueueForConnectionFromAddress:onSocket:)])
			{
				childSocketQueue = [theDelegate newSocketQueueForConnectionFromAddress:childSocketAddress
				                                                              onSocket:self];
			}
			
			// Create GCDAsyncSocket instance for accepted socket
			
			GCDAsyncSocket *acceptedSocket = [[[self class] alloc] initWithDelegate:theDelegate
                                                                      delegateQueue:self->delegateQueue
																		socketQueue:childSocketQueue];
			
			if (socketType == 0)
				acceptedSocket->socket4FD = childSocketFD;
			else if (socketType == 1)
				acceptedSocket->socket6FD = childSocketFD;
			else
				acceptedSocket->socketUN = childSocketFD;
			
			acceptedSocket->flags = (kSocketStarted | kConnected);
			
			// Setup read and write sources for accepted socket
			
			dispatch_async(acceptedSocket->socketQueue, ^{ @autoreleasepool {
				
				[acceptedSocket setupReadAndWriteSourcesForNewlyConnectedSocket:childSocketFD];
			}});
			
			// Notify delegate
			
			if ([theDelegate respondsToSelector:@selector(socket:didAcceptNewSocket:)])
			{
				[theDelegate socket:self didAcceptNewSocket:acceptedSocket];
			}
			
			// Release the socket queue returned from the delegate (it was retained by acceptedSocket)
			#if !OS_OBJECT_USE_OBJC
			if (childSocketQueue) dispatch_release(childSocketQueue);
			#endif
			
			// The accepted socket should have been retained by the delegate.
			// Otherwise it gets properly released when exiting the block.
		}});
	}
	
	return YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Connecting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * This method runs through the various checks required prior to a connection attempt.
 * It is shared between the connectToHost and connectToAddress methods.
 * 
**/

// 链接之前常规检查
- (BOOL)preConnectWithInterface:(NSString *)interface error:(NSError **)errPtr
{
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
    // 代理
	if (delegate == nil) // Must have delegate set
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate. Set a delegate first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
    // 代理队列
	if (delegateQueue == NULL) // Must have delegate queue set
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate queue. Set a delegate queue first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
    // 必须 是非连接的状态
	if (![self isDisconnected]) // Must be disconnected
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect while connected or accepting connections. Disconnect first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
    // 是否支持 ipv4 与 ipv6
	BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
	BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
	
    // 都不支持
	if (isIPv4Disabled && isIPv6Disabled) // Must have IPv4 or IPv6 enabled
	{
		if (errPtr)
		{
			NSString *msg = @"Both IPv4 and IPv6 have been disabled. Must enable at least one protocol first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (interface)
	{
		NSMutableData *interface4 = nil;
		NSMutableData *interface6 = nil;
		
        // 去获取地址及绑定端口
		[self getInterfaceAddress4:&interface4 address6:&interface6 fromDescription:interface port:0];
		
		if ((interface4 == nil) && (interface6 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"Unknown interface. Specify valid interface by name (e.g. \"en1\") or IP address.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
		if (isIPv4Disabled && (interface6 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"IPv4 has been disabled and specified interface doesn't support IPv6.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
		if (isIPv6Disabled && (interface4 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"IPv6 has been disabled and specified interface doesn't support IPv4.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
		connectInterface4 = interface4;
		connectInterface6 = interface6;
	}
	
	// Clear queues (spurious read/write requests post disconnect)
	[readQueue removeAllObjects];
	[writeQueue removeAllObjects];
	
	return YES;
}

- (BOOL)preConnectWithUrl:(NSURL *)url error:(NSError **)errPtr
{
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	if (delegate == nil) // Must have delegate set
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate. Set a delegate first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (delegateQueue == NULL) // Must have delegate queue set
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate queue. Set a delegate queue first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	if (![self isDisconnected]) // Must be disconnected
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect while connected or accepting connections. Disconnect first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
	NSData *interface = [self getInterfaceAddressFromUrl:url];
	
	if (interface == nil)
	{
		if (errPtr)
		{
			NSString *msg = @"Unknown interface. Specify valid interface by name (e.g. \"en1\") or IP address.";
			*errPtr = [self badParamError:msg];
		}
		return NO;
	}
	
	connectInterfaceUN = interface;
	
	// Clear queues (spurious read/write requests post disconnect)
	[readQueue removeAllObjects];
	[writeQueue removeAllObjects];
	
	return YES;
}

- (BOOL)connectToHost:(NSString*)host onPort:(uint16_t)port error:(NSError **)errPtr
{
	return [self connectToHost:host onPort:port withTimeout:-1 error:errPtr];
}

- (BOOL)connectToHost:(NSString *)host
               onPort:(uint16_t)port
          withTimeout:(NSTimeInterval)timeout
                error:(NSError **)errPtr
{
	return [self connectToHost:host onPort:port viaInterface:nil withTimeout:timeout error:errPtr];
}

// 链接
- (BOOL)connectToHost:(NSString *)inHost
               onPort:(uint16_t)port
         viaInterface:(NSString *)inInterface
          withTimeout:(NSTimeInterval)timeout
                error:(NSError **)errPtr
{
	LogTrace();
	
	// Just in case immutable objects were passed
    // 防止传入一个可变数据，被改变了
    
	NSString *host = [inHost copy];
	NSString *interface = [inInterface copy];
	
	__block BOOL result = NO;
	__block NSError *preConnectErr = nil;
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		// Check for problems with host parameter
		
		if ([host length] == 0)
		{
			NSString *msg = @"Invalid host parameter (nil or \"\"). Should be a domain name or IP address string.";
			preConnectErr = [self badParamError:msg];
			
			return_from_block;
		}
		
		// Run through standard pre-connect checks
		
        // 常规检查 ，确定代理，代理队列，是否链接，如果 interface 不为nil 要绑定指定地址及端口
		if (![self preConnectWithInterface:interface error:&preConnectErr])
		{
			return_from_block;
		}
		
		// We've made it past all the checks.
		// It's time to start the connection process.
		
        self->flags |= kSocketStarted;
		
		LogVerbose(@"Dispatching DNS lookup...");
		
		// It's possible that the given host parameter is actually a NSMutableString.
		// So we want to copy it now, within this block that will be executed synchronously.
		// This way the asynchronous lookup block below doesn't have to worry about it changing.
		
		NSString *hostCpy = [host copy];
		
        int aStateIndex = self->stateIndex;
		__weak GCDAsyncSocket *weakSelf = self;
		
        // 异步到全局并发队列执行
		dispatch_queue_t globalConcurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
		dispatch_async(globalConcurrentQueue, ^{ @autoreleasepool {
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			NSError *lookupErr = nil;
            //获取 服务端 ipv4 或者 ipv6 地址 数组返回·可能有多个，内部获取服务器地址为同步
			NSMutableArray *addresses = [[self class] lookupHost:hostCpy port:port error:&lookupErr];
			
			__strong GCDAsyncSocket *strongSelf = weakSelf;
			if (strongSelf == nil) return_from_block;
			
			if (lookupErr)
			{
				dispatch_async(strongSelf->socketQueue, ^{ @autoreleasepool {
					[strongSelf lookup:aStateIndex didFail:lookupErr];
				}});
			}
			else
			{
				NSData *address4 = nil;
				NSData *address6 = nil;
				
				for (NSData *address in addresses)
				{
                    // 交验合法性，
					if (!address4 && [[self class] isIPv4Address:address])
					{
						address4 = address;
					}
					else if (!address6 && [[self class] isIPv6Address:address])
					{
						address6 = address;
					}
				}
				
				dispatch_async(strongSelf->socketQueue, ^{ @autoreleasepool {
					
                    // 去链接了
					[strongSelf lookup:aStateIndex didSucceedWithAddress4:address4 address6:address6];
				}});
			}
			
		#pragma clang diagnostic pop
		}});
		
        // 开始设置超时时间
		[self startConnectTimeout:timeout];
		
		result = YES;
	}};
	
    // dispatch_get_specific 是 Grand Central Dispatch (GCD) 提供的一个函数，用于在当前执行的任务上下文中检索先前与调度队列或特定任务关联的特定上下文信息。这在调度队列的任务之间共享数据或状态信息时非常有用。
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	
	if (errPtr) *errPtr = preConnectErr;
	return result;
}

- (BOOL)connectToAddress:(NSData *)remoteAddr error:(NSError **)errPtr
{
	return [self connectToAddress:remoteAddr viaInterface:nil withTimeout:-1 error:errPtr];
}

- (BOOL)connectToAddress:(NSData *)remoteAddr withTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr
{
	return [self connectToAddress:remoteAddr viaInterface:nil withTimeout:timeout error:errPtr];
}

- (BOOL)connectToAddress:(NSData *)inRemoteAddr
            viaInterface:(NSString *)inInterface
             withTimeout:(NSTimeInterval)timeout
                   error:(NSError **)errPtr
{
	LogTrace();
	
	// Just in case immutable objects were passed
	NSData *remoteAddr = [inRemoteAddr copy];
	NSString *interface = [inInterface copy];
	
	__block BOOL result = NO;
	__block NSError *err = nil;
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		// Check for problems with remoteAddr parameter
		
		NSData *address4 = nil;
		NSData *address6 = nil;
		
		if ([remoteAddr length] >= sizeof(struct sockaddr))
		{
			const struct sockaddr *sockaddr = (const struct sockaddr *)[remoteAddr bytes];
			
			if (sockaddr->sa_family == AF_INET)
			{
				if ([remoteAddr length] == sizeof(struct sockaddr_in))
				{
					address4 = remoteAddr;
				}
			}
			else if (sockaddr->sa_family == AF_INET6)
			{
				if ([remoteAddr length] == sizeof(struct sockaddr_in6))
				{
					address6 = remoteAddr;
				}
			}
		}
		
		if ((address4 == nil) && (address6 == nil))
		{
			NSString *msg = @"A valid IPv4 or IPv6 address was not given";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
        BOOL isIPv4Disabled = (self->config & kIPv4Disabled) ? YES : NO;
        BOOL isIPv6Disabled = (self->config & kIPv6Disabled) ? YES : NO;
		
		if (isIPv4Disabled && (address4 != nil))
		{
			NSString *msg = @"IPv4 has been disabled and an IPv4 address was passed.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		if (isIPv6Disabled && (address6 != nil))
		{
			NSString *msg = @"IPv6 has been disabled and an IPv6 address was passed.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		// Run through standard pre-connect checks
		
		if (![self preConnectWithInterface:interface error:&err])
		{
			return_from_block;
		}
		
		// We've made it past all the checks.
		// It's time to start the connection process.
		
		if (![self connectWithAddress4:address4 address6:address6 error:&err])
		{
			return_from_block;
		}
		
        self->flags |= kSocketStarted;
		
		[self startConnectTimeout:timeout];
		
		result = YES;
	}};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		if (errPtr)
			*errPtr = err;
	}
	
	return result;
}

- (BOOL)connectToUrl:(NSURL *)url withTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr
{
	LogTrace();
	
	__block BOOL result = NO;
	__block NSError *err = nil;
	
	dispatch_block_t block = ^{ @autoreleasepool {
		
		// Check for problems with host parameter
		
		if ([url.path length] == 0)
		{
			NSString *msg = @"Invalid unix domain socket url.";
			err = [self badParamError:msg];
			
			return_from_block;
		}
		
		// Run through standard pre-connect checks
		
		if (![self preConnectWithUrl:url error:&err])
		{
			return_from_block;
		}
		
		// We've made it past all the checks.
		// It's time to start the connection process.
		
        self->flags |= kSocketStarted;
		
		// Start the normal connection process
		
		NSError *connectError = nil;
        if (![self connectWithAddressUN:self->connectInterfaceUN error:&connectError])
		{
			[self closeWithError:connectError];
			
			return_from_block;
		}

		[self startConnectTimeout:timeout];
		
		result = YES;
	}};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		if (errPtr)
			*errPtr = err;
	}
	
	return result;
}

- (BOOL)connectToNetService:(NSNetService *)netService error:(NSError **)errPtr
{
	NSArray* addresses = [netService addresses];
	for (NSData* address in addresses)
	{
		BOOL result = [self connectToAddress:address error:errPtr];
		if (result)
		{
			return YES;
		}
	}
	
	return NO;
}

- (void)lookup:(int)aStateIndex didSucceedWithAddress4:(NSData *)address4 address6:(NSData *)address6
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert(address4 || address6, @"Expected at least one valid address");
	
	if (aStateIndex != stateIndex)
	{
		LogInfo(@"Ignoring lookupDidSucceed, already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	
	// Check for problems
	
	BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
	BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
	
	if (isIPv4Disabled && (address6 == nil))
	{
		NSString *msg = @"IPv4 has been disabled and DNS lookup found no IPv6 address.";
		
		[self closeWithError:[self otherError:msg]];
		return;
	}
	
	if (isIPv6Disabled && (address4 == nil))
	{
		NSString *msg = @"IPv6 has been disabled and DNS lookup found no IPv4 address.";
		
		[self closeWithError:[self otherError:msg]];
		return;
	}
	
	// Start the normal connection process
	
	NSError *err = nil;
	if (![self connectWithAddress4:address4 address6:address6 error:&err])
	{
		[self closeWithError:err];
	}
}

/**
 * This method is called if the DNS lookup fails.
 * This method is executed on the socketQueue.
 * 
 * Since the DNS lookup executed synchronously on a global concurrent queue,
 * the original connection request may have already been cancelled or timed-out by the time this method is invoked.
 * The lookupIndex tells us whether the lookup is still valid or not.
**/
- (void)lookup:(int)aStateIndex didFail:(NSError *)error
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	if (aStateIndex != stateIndex)
	{
		LogInfo(@"Ignoring lookup:didFail: - already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	
	[self endConnectTimeout];
	[self closeWithError:error];
}

- (BOOL)bindSocket:(int)socketFD toInterface:(NSData *)connectInterface error:(NSError **)errPtr
{
    // Bind the socket to the desired interface (if needed)
    
    if (connectInterface)
    {
        LogVerbose(@"Binding socket...");
        
        if ([[self class] portFromAddress:connectInterface] > 0)
        {
            // Since we're going to be binding to a specific port,
            // we should turn on reuseaddr to allow us to override sockets in time_wait.
            
            // 设置当前 socketFD 可在销毁后重用
            // 这个选项允许你重新使用本地地址，让你的应用程序能够在同一台主机上的同一个端口上打开多个套接字
            //这里调用这个函数的主要目的是为了调用close的时候，不立即去关闭socket连接，而是经历一个TIME_WAIT过程。在这个过程中，socket是可以被复用的。我们注意到之前的connect流程并没有看到复用socket的代码。注意，我们现在走的连接流程是客户端的流程，等我们讲到服务端accept进行连接的时候，我们就能看到这个复用的作用了。
            
            int reuseOn = 1;
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
        }
        
        const struct sockaddr *interfaceAddr = (const struct sockaddr *)[connectInterface bytes];
        
        // 绑定·根据接口返回逻辑
        int result = bind(socketFD, interfaceAddr, (socklen_t)[connectInterface length]);
        if (result != 0)
        {
            if (errPtr)
                *errPtr = [self errorWithErrno:errno reason:@"Error in bind() function"];
            
            return NO;
        }
    }
    
    return YES;
}

- (int)createSocket:(int)family connectInterface:(NSData *)connectInterface errPtr:(NSError **)errPtr
{
    // 创建 stock 链接，返回一个 id 号
    
    int socketFD = socket(family, SOCK_STREAM, 0);
    
    if (socketFD == SOCKET_NULL)
    {
        if (errPtr)
            *errPtr = [self errorWithErrno:errno reason:@"Error in socket() function"];
        
        return socketFD;
    }
    
    // 将 socketFD 与 connectInterface 绑定 connectInterface 包含 host 和 port
    if (![self bindSocket:socketFD toInterface:connectInterface error:errPtr])
    {
        [self closeSocket:socketFD];
        
        return SOCKET_NULL;
    }
    
    // Prevent SIGPIPE signals
    
//    SO_NOSIGPIPE 是一个套接字选项，用于在 macOS 和 iOS 系统上禁用 SIGPIPE 信号的默认行为。
//
//    SIGPIPE 是一种信号，它在对一个已关闭的套接字执行写操作时触发。默认情况下，当你向一个已关闭的套接字写入数据时，操作系统会向进程发送 SIGPIPE 信号，该信号可能会终止进程。
//
//    通过设置 SO_NOSIGPIPE 选项为 1，你可以禁用 SIGPIPE 信号的默认行为。这样，当你向一个已关闭的套接字写入数据时，不会触发 SIGPIPE 信号，而是会返回一个错误（EPIPE），以便你在代码中进行适当的处理。
//
//    禁用 SIGPIPE 信号通常用于处理网络编程中的写入操作，以避免进程被 SIGPIPE 信号中断而导致的意外终止。
//
//    在使用 setsockopt 函数设置套接字选项时，SO_NOSIGPIPE 的级别参数应为 SOL_SOCKET，选项参数应为 SO_NOSIGPIPE，选项值为 int 类型的指针，长度为 sizeof(int)。
    
    
//    请注意，SO_NOSIGPIPE 选项仅在 macOS 和 iOS 系统上可用，其他操作系统可能具有不同的机制来处理类似的信号。
    
    // 用于设置套接字的选项。它允许你配置套接字的行为，包括套接字层（SOL_SOCKET）、协议层（IPPROTO_IP、IPPROTO_TCP、IPPROTO_UDP等）的选项。通过 setsockopt 函数，你可以调整各种参数，以满足特定的网络编程需求。
    
    int nosigpipe = 1;
    setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
    
    return socketFD;
}

- (void)connectSocket:(int)socketFD address:(NSData *)address stateIndex:(int)aStateIndex
{
    // If there already is a socket connected, we close socketFD and return
    if (self.isConnected)
    {
        [self closeSocket:socketFD];
        return;
    }
    
    // Start the connection process in a background queue
    
    __weak GCDAsyncSocket *weakSelf = self;
    
    dispatch_queue_t globalConcurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(globalConcurrentQueue, ^{
#pragma clang diagnostic push
#pragma clang diagnostic warning "-Wimplicit-retain-self"
        
        
        // 异步·因为会阻塞线程，在全局并发队列里面
        int result = connect(socketFD, (const struct sockaddr *)[address bytes], (socklen_t)[address length]);
        int err = errno;
        
        __strong GCDAsyncSocket *strongSelf = weakSelf;
        if (strongSelf == nil) return_from_block;
        
        dispatch_async(strongSelf->socketQueue, ^{ @autoreleasepool {
            
            // 如果已链接，则关闭 socketFD
            if (strongSelf.isConnected)
            {
                [strongSelf closeSocket:socketFD];
                return_from_block;
            }
        
            // 链接成功了··关闭另外一个，就不需要链接了
            if (result == 0)
            {
                
                [self closeUnusedSocket:socketFD];
                
                //已经链接成功了
                [strongSelf didConnect:aStateIndex];
            }
            else
            {
                // 如果没有链接成功  就关闭当前的
                [strongSelf closeSocket:socketFD];
                
                // If there are no more sockets trying to connect, we inform the error to the delegate
                if (strongSelf.socket4FD == SOCKET_NULL && strongSelf.socket6FD == SOCKET_NULL)
                {
                    NSError *error = [strongSelf errorWithErrno:err reason:@"Error in connect() function"];
                    [strongSelf didNotConnect:aStateIndex error:error];
                }
            }
        }});
        
#pragma clang diagnostic pop
    });
    
    LogVerbose(@"Connecting...");
}

- (void)closeSocket:(int)socketFD
{
    if (socketFD != SOCKET_NULL &&
        (socketFD == socket6FD || socketFD == socket4FD))
    {
        close(socketFD);
        
        if (socketFD == socket4FD)
        {
            LogVerbose(@"close(socket4FD)");
            socket4FD = SOCKET_NULL;
        }
        else if (socketFD == socket6FD)
        {
            LogVerbose(@"close(socket6FD)");
            socket6FD = SOCKET_NULL;
        }
    }
}

- (void)closeUnusedSocket:(int)usedSocketFD
{
    if (usedSocketFD != socket4FD)
    {
        [self closeSocket:socket4FD];
    }
    else if (usedSocketFD != socket6FD)
    {
        [self closeSocket:socket6FD];
    }
}

- (BOOL)connectWithAddress4:(NSData *)address4 address6:(NSData *)address6 error:(NSError **)errPtr
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	LogVerbose(@"IPv4: %@:%hu", [[self class] hostFromAddress:address4], [[self class] portFromAddress:address4]);
	LogVerbose(@"IPv6: %@:%hu", [[self class] hostFromAddress:address6], [[self class] portFromAddress:address6]);
	
	// Determine socket type
	
	BOOL preferIPv6 = (config & kPreferIPv6) ? YES : NO;
	
	// Create and bind the sockets
    
    if (address4)
    {
        LogVerbose(@"Creating IPv4 socket");
        
        // 创建 Socket 链接 ··与 connectInterface4 绑定， 并且设置 一些相关属性
        socket4FD = [self createSocket:AF_INET connectInterface:connectInterface4 errPtr:errPtr];
    }
    
    if (address6)
    {
        LogVerbose(@"Creating IPv6 socket");
        
        socket6FD = [self createSocket:AF_INET6 connectInterface:connectInterface6 errPtr:errPtr];
    }
    
    if (socket4FD == SOCKET_NULL && socket6FD == SOCKET_NULL)
    {
        return NO;
    }
	
	int socketFD, alternateSocketFD;
	NSData *address, *alternateAddress;
	
    // 如果 允许使用 preferIPv6 并且 socket6FD 不等于空  或者 socket4FD == 空··就使用ipv6
    if ((preferIPv6 && socket6FD != SOCKET_NULL) || socket4FD == SOCKET_NULL)
    {
        socketFD = socket6FD;
        alternateSocketFD = socket4FD;
        address = address6;
        alternateAddress = address4;
    }
    else
    {
        socketFD = socket4FD;
        alternateSocketFD = socket6FD;
        address = address4;
        alternateAddress = address6;
    }

    int aStateIndex = stateIndex;
    
    [self connectSocket:socketFD address:address stateIndex:aStateIndex];
    
    // 候补
    if (alternateAddress)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(alternateAddressDelay * NSEC_PER_SEC)), socketQueue, ^{
            // 如果正常没连上，就使用候补地址去链接，方法内部会有 连没连上的 判断
            [self connectSocket:alternateSocketFD address:alternateAddress stateIndex:aStateIndex];
        });
    }
	
	return YES;
}

- (BOOL)connectWithAddressUN:(NSData *)address error:(NSError **)errPtr
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	// Create the socket
	
	int socketFD;
	
	LogVerbose(@"Creating unix domain socket");
	
	socketUN = socket(AF_UNIX, SOCK_STREAM, 0);
	
	socketFD = socketUN;
	
	if (socketFD == SOCKET_NULL)
	{
		if (errPtr)
			*errPtr = [self errorWithErrno:errno reason:@"Error in socket() function"];
		
		return NO;
	}
	
	// Bind the socket to the desired interface (if needed)
	
	LogVerbose(@"Binding socket...");
	
	int reuseOn = 1;
	setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));

//	const struct sockaddr *interfaceAddr = (const struct sockaddr *)[address bytes];
//	
//	int result = bind(socketFD, interfaceAddr, (socklen_t)[address length]);
//	if (result != 0)
//	{
//		if (errPtr)
//			*errPtr = [self errnoErrorWithReason:@"Error in bind() function"];
//		
//		return NO;
//	}
	
	// Prevent SIGPIPE signals
	
	int nosigpipe = 1;
	setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
	
	// Start the connection process in a background queue
	
	int aStateIndex = stateIndex;
	
	dispatch_queue_t globalConcurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	dispatch_async(globalConcurrentQueue, ^{
		
		const struct sockaddr *addr = (const struct sockaddr *)[address bytes];
		int result = connect(socketFD, addr, addr->sa_len);
		if (result == 0)
		{
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				[self didConnect:aStateIndex];
			}});
		}
		else
		{
			// TODO: Bad file descriptor
			perror("connect");
			NSError *error = [self errorWithErrno:errno reason:@"Error in connect() function"];
			
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				[self didNotConnect:aStateIndex error:error];
			}});
		}
	});
	
	LogVerbose(@"Connecting...");
	
	return YES;
}

- (void)didConnect:(int)aStateIndex
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	if (aStateIndex != stateIndex)
	{
		LogInfo(@"Ignoring didConnect, already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	
	flags |= kConnected;
	
    // 停止链接超时
	[self endConnectTimeout];
	
//	#if TARGET_OS_IPHONE
	// The endConnectTimeout method executed above incremented the stateIndex.
	aStateIndex = stateIndex;
//	#endif
	
	// Setup read/write streams (as workaround for specific shortcomings in the iOS platform)
	// 
	// Note:
	// There may be configuration options that must be set by the delegate before opening the streams.
	// The primary example is the kCFStreamNetworkServiceTypeVoIP flag, which only works on an unopened stream.
	// 
	// Thus we wait until after the socket:didConnectToHost:port: delegate method has completed.
	// This gives the delegate time to properly configure the streams if needed.
	
	dispatch_block_t SetupStreamsPart1 = ^{
//		#if TARGET_OS_IPHONE
		
        // 创建读写流
		if (![self createReadAndWriteStream])
		{
			[self closeWithError:[self otherError:@"Error creating CFStreams"]];
			return;
		}
		// 为读写流设置callback 这里设置不包含可读可写的监听，
		if (![self registerForStreamCallbacksIncludingReadWrite:NO])
		{
			[self closeWithError:[self otherError:@"Error in CFStreamSetClient"]];
			return;
		}
		
//		#endif
	};
	dispatch_block_t SetupStreamsPart2 = ^{
//		#if TARGET_OS_IPHONE
		
        if (aStateIndex != self->stateIndex)
		{
			// The socket has been disconnected.
			return;
		}
		
        // 创建子线程，并将子线程保活，将读写流与子线程的runloop关联起来
		if (![self addStreamsToRunLoop])
		{
			[self closeWithError:[self otherError:@"Error in CFStreamScheduleWithRunLoop"]];
			return;
		}
		// 开启读写流
		if (![self openStreams])
		{
			[self closeWithError:[self otherError:@"Error creating CFStreams"]];
			return;
		}
		
//		#endif
	};
	
	// Notify delegate
	
	NSString *host = [self connectedHost];
	uint16_t port = [self connectedPort];
	NSURL *url = [self connectedUrl];
	
	__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

	if (delegateQueue && host != nil && [theDelegate respondsToSelector:@selector(socket:didConnectToHost:port:)])
	{
        
        // 巧妙的顺序
        
		SetupStreamsPart1();
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didConnectToHost:host port:port];
			
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				SetupStreamsPart2();
			}});
		}});
	}
	else if (delegateQueue && url != nil && [theDelegate respondsToSelector:@selector(socket:didConnectToUrl:)])
	{
		SetupStreamsPart1();
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didConnectToUrl:url];
			
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				SetupStreamsPart2();
			}});
		}});
	}
	else
	{
		SetupStreamsPart1();
		SetupStreamsPart2();
	}
		
	// Get the connected socket
	
	int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
	
	// Enable non-blocking IO on the socket
	
    // 将 socketFD 设置为非阻塞
	int result = fcntl(socketFD, F_SETFL, O_NONBLOCK);
	if (result == -1)
	{
		NSString *errMsg = @"Error enabling non-blocking IO on socket (fcntl)";
		[self closeWithError:[self otherError:errMsg]];
		
		return;
	}
	

	// 设置我们自己的读写流，并启动了读源
	[self setupReadAndWriteSourcesForNewlyConnectedSocket:socketFD];
	
	// Dequeue any pending read/write requests
	
	[self maybeDequeueRead];
	[self maybeDequeueWrite];
}

- (void)didNotConnect:(int)aStateIndex error:(NSError *)error
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	if (aStateIndex != stateIndex)
	{
		LogInfo(@"Ignoring didNotConnect, already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	
	[self closeWithError:error];
}

- (void)startConnectTimeout:(NSTimeInterval)timeout
{
	if (timeout >= 0.0)
	{
        // 创建一个source 用于监听timer的，触发的时候在 socketQueue 队列上执行
		connectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
		__weak GCDAsyncSocket *weakSelf = self;
		
        // 绑定触发时候的回调
		dispatch_source_set_event_handler(connectTimer, ^{ @autoreleasepool {
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
		
			__strong GCDAsyncSocket *strongSelf = weakSelf;
			if (strongSelf == nil) return_from_block;
			//超时
			[strongSelf doConnectTimeout];
			
		#pragma clang diagnostic pop
		}});
		
		#if !OS_OBJECT_USE_OBJC
		dispatch_source_t theConnectTimer = connectTimer;
		dispatch_source_set_cancel_handler(connectTimer, ^{
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			LogVerbose(@"dispatch_release(connectTimer)");
			dispatch_release(theConnectTimer);
			
		#pragma clang diagnostic pop
		});
		#endif
		
        
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
        
        // 设置一个定时器，timeout 后触发，等待时间无限期 ，容忍度为0
		dispatch_source_set_timer(connectTimer, tt, DISPATCH_TIME_FOREVER, 0);
		
		dispatch_resume(connectTimer);
	}
}

- (void)endConnectTimeout
{
	LogTrace();
	
	if (connectTimer)
	{
		dispatch_source_cancel(connectTimer);
		connectTimer = NULL;
	}
	
	// Increment stateIndex.
	// This will prevent us from processing results from any related background asynchronous operations.
	// 
	// Note: This should be called from close method even if connectTimer is NULL.
	// This is because one might disconnect a socket prior to a successful connection which had no timeout.
	
	stateIndex++;
	
	if (connectInterface4)
	{
		connectInterface4 = nil;
	}
	if (connectInterface6)
	{
		connectInterface6 = nil;
	}
}

- (void)doConnectTimeout
{
	LogTrace();
	
	[self endConnectTimeout];
	[self closeWithError:[self connectTimeoutError]];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Disconnecting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)closeWithError:(NSError *)error
{
	LogTrace();
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	[self endConnectTimeout];
	
	if (currentRead != nil)  [self endCurrentRead];
	if (currentWrite != nil) [self endCurrentWrite];
	
	[readQueue removeAllObjects];
	[writeQueue removeAllObjects];
	
	[preBuffer reset];
	
//	#if TARGET_OS_IPHONE
	{
		if (readStream || writeStream)
		{
			[self removeStreamsFromRunLoop];
			
			if (readStream)
			{
				CFReadStreamSetClient(readStream, kCFStreamEventNone, NULL, NULL);
				CFReadStreamClose(readStream);
				CFRelease(readStream);
				readStream = NULL;
			}
			if (writeStream)
			{
				CFWriteStreamSetClient(writeStream, kCFStreamEventNone, NULL, NULL);
				CFWriteStreamClose(writeStream);
				CFRelease(writeStream);
				writeStream = NULL;
			}
		}
	}
//	#endif
	
	[sslPreBuffer reset];
	sslErrCode = lastSSLHandshakeError = noErr;
	
	if (sslContext)
	{
		// Getting a linker error here about the SSLx() functions?
		// You need to add the Security Framework to your application.
		
		SSLClose(sslContext);
		
		#if (__MAC_OS_X_VERSION_MIN_REQUIRED >= 1080)
		CFRelease(sslContext);
		#else
		SSLDisposeContext(sslContext);
		#endif
		
		sslContext = NULL;
	}
	
	// For some crazy reason (in my opinion), cancelling a dispatch source doesn't
	// invoke the cancel handler if the dispatch source is paused.
	// So we have to unpause the source if needed.
	// This allows the cancel handler to be run, which in turn releases the source and closes the socket.
	
	if (!accept4Source && !accept6Source && !acceptUNSource && !readSource && !writeSource)
	{
		LogVerbose(@"manually closing close");

		if (socket4FD != SOCKET_NULL)
		{
			LogVerbose(@"close(socket4FD)");
			close(socket4FD);
			socket4FD = SOCKET_NULL;
		}

		if (socket6FD != SOCKET_NULL)
		{
			LogVerbose(@"close(socket6FD)");
			close(socket6FD);
			socket6FD = SOCKET_NULL;
		}
		
		if (socketUN != SOCKET_NULL)
		{
			LogVerbose(@"close(socketUN)");
			close(socketUN);
			socketUN = SOCKET_NULL;
			unlink(socketUrl.path.fileSystemRepresentation);
			socketUrl = nil;
		}
	}
	else
	{
		if (accept4Source)
		{
			LogVerbose(@"dispatch_source_cancel(accept4Source)");
			dispatch_source_cancel(accept4Source);
			
			// We never suspend accept4Source
			
			accept4Source = NULL;
		}
		
		if (accept6Source)
		{
			LogVerbose(@"dispatch_source_cancel(accept6Source)");
			dispatch_source_cancel(accept6Source);
			
			// We never suspend accept6Source
			
			accept6Source = NULL;
		}
		
		if (acceptUNSource)
		{
			LogVerbose(@"dispatch_source_cancel(acceptUNSource)");
			dispatch_source_cancel(acceptUNSource);
			
			// We never suspend acceptUNSource
			
			acceptUNSource = NULL;
		}
	
		if (readSource)
		{
			LogVerbose(@"dispatch_source_cancel(readSource)");
			dispatch_source_cancel(readSource);
			
			[self resumeReadSource];
			
			readSource = NULL;
		}
		
		if (writeSource)
		{
			LogVerbose(@"dispatch_source_cancel(writeSource)");
			dispatch_source_cancel(writeSource);
			
			[self resumeWriteSource];
			
			writeSource = NULL;
		}
		
		// The sockets will be closed by the cancel handlers of the corresponding source
		
		socket4FD = SOCKET_NULL;
		socket6FD = SOCKET_NULL;
		socketUN = SOCKET_NULL;
	}
	
	// If the client has passed the connect/accept method, then the connection has at least begun.
	// Notify delegate that it is now ending.
	BOOL shouldCallDelegate = (flags & kSocketStarted) ? YES : NO;
	BOOL isDeallocating = (flags & kDealloc) ? YES : NO;
	
	// Clear stored socket info and all flags (config remains as is)
	socketFDBytesAvailable = 0;
	flags = 0;
	sslWriteCachedLength = 0;
	
	if (shouldCallDelegate)
	{
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
		__strong id theSelf = isDeallocating ? nil : self;
		
		if (delegateQueue && [theDelegate respondsToSelector: @selector(socketDidDisconnect:withError:)])
		{
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socketDidDisconnect:theSelf withError:error];
			}});
		}	
	}
}

- (void)disconnect
{
	dispatch_block_t block = ^{ @autoreleasepool {
		
        if (self->flags & kSocketStarted)
		{
			[self closeWithError:nil];
		}
	}};
	
	// Synchronous disconnection, as documented in the header file
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
}

- (void)disconnectAfterReading
{
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
        if (self->flags & kSocketStarted)
		{
            self->flags |= (kForbidReadsWrites | kDisconnectAfterReads);
			[self maybeClose];
		}
	}});
}

- (void)disconnectAfterWriting
{
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
        if (self->flags & kSocketStarted)
		{
            self->flags |= (kForbidReadsWrites | kDisconnectAfterWrites);
			[self maybeClose];
		}
	}});
}

- (void)disconnectAfterReadingAndWriting
{
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
        if (self->flags & kSocketStarted)
		{
            self->flags |= (kForbidReadsWrites | kDisconnectAfterReads | kDisconnectAfterWrites);
			[self maybeClose];
		}
	}});
}

/**
 * Closes the socket if possible.
 * That is, if all writes have completed, and we're set to disconnect after writing,
 * or if all reads have completed, and we're set to disconnect after reading.
**/
- (void)maybeClose
{
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	BOOL shouldClose = NO;
	
	if (flags & kDisconnectAfterReads)
	{
		if (([readQueue count] == 0) && (currentRead == nil))
		{
			if (flags & kDisconnectAfterWrites)
			{
				if (([writeQueue count] == 0) && (currentWrite == nil))
				{
					shouldClose = YES;
				}
			}
			else
			{
				shouldClose = YES;
			}
		}
	}
	else if (flags & kDisconnectAfterWrites)
	{
		if (([writeQueue count] == 0) && (currentWrite == nil))
		{
			shouldClose = YES;
		}
	}
	
	if (shouldClose)
	{
		[self closeWithError:nil];
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Errors
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSError *)badConfigError:(NSString *)errMsg
{
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketBadConfigError userInfo:userInfo];
}

- (NSError *)badParamError:(NSString *)errMsg
{
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketBadParamError userInfo:userInfo];
}

+ (NSError *)gaiError:(int)gai_error
{
	NSString *errMsg = [NSString stringWithCString:gai_strerror(gai_error) encoding:NSASCIIStringEncoding];
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:@"kCFStreamErrorDomainNetDB" code:gai_error userInfo:userInfo];
}

- (NSError *)errorWithErrno:(int)err reason:(NSString *)reason
{
	NSString *errMsg = [NSString stringWithUTF8String:strerror(err)];
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg,
							   NSLocalizedFailureReasonErrorKey : reason};
	
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:userInfo];
}

- (NSError *)errnoError
{
	NSString *errMsg = [NSString stringWithUTF8String:strerror(errno)];
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:userInfo];
}

- (NSError *)sslError:(OSStatus)ssl_error
{
	NSString *msg = @"Error code definition can be found in Apple's SecureTransport.h";
	NSDictionary *userInfo = @{NSLocalizedRecoverySuggestionErrorKey : msg};
	
	return [NSError errorWithDomain:@"kCFStreamErrorDomainSSL" code:ssl_error userInfo:userInfo];
}

- (NSError *)connectTimeoutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketConnectTimeoutError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Attempt to connect to host timed out", nil);
	
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketConnectTimeoutError userInfo:userInfo];
}

/**
 * Returns a standard AsyncSocket maxed out error.
**/
- (NSError *)readMaxedOutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketReadMaxedOutError",
														 @"GCDAsyncSocket", [NSBundle mainBundle],
														 @"Read operation reached set maximum length", nil);
	
	NSDictionary *info = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketReadMaxedOutError userInfo:info];
}

/**
 * Returns a standard AsyncSocket write timeout error.
**/
- (NSError *)readTimeoutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketReadTimeoutError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Read operation timed out", nil);
	
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketReadTimeoutError userInfo:userInfo];
}

/**
 * Returns a standard AsyncSocket write timeout error.
**/
- (NSError *)writeTimeoutError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketWriteTimeoutError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Write operation timed out", nil);
	
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketWriteTimeoutError userInfo:userInfo];
}

- (NSError *)connectionClosedError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketClosedError",
	                                                     @"GCDAsyncSocket", [NSBundle mainBundle],
	                                                     @"Socket closed by remote peer", nil);
	
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketClosedError userInfo:userInfo];
}

- (NSError *)otherError:(NSString *)errMsg
{
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey : errMsg};
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketOtherError userInfo:userInfo];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Diagnostics
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)isDisconnected
{
	__block BOOL result = NO;
	
	dispatch_block_t block = ^{
        result = (self->flags & kSocketStarted) ? NO : YES;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

- (BOOL)isConnected
{
	__block BOOL result = NO;
	
	dispatch_block_t block = ^{
        result = (self->flags & kConnected) ? YES : NO;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

- (NSString *)connectedHost
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self connectedHostFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self connectedHostFromSocket6:socket6FD];
		
		return nil;
	}
	else
	{
		__block NSString *result = nil;
		
		dispatch_sync(socketQueue, ^{ @autoreleasepool {
			
            if (self->socket4FD != SOCKET_NULL)
                result = [self connectedHostFromSocket4:self->socket4FD];
            else if (self->socket6FD != SOCKET_NULL)
                result = [self connectedHostFromSocket6:self->socket6FD];
		}});
		
		return result;
	}
}

- (uint16_t)connectedPort
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self connectedPortFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self connectedPortFromSocket6:socket6FD];
		
		return 0;
	}
	else
	{
		__block uint16_t result = 0;
		
		dispatch_sync(socketQueue, ^{
			// No need for autorelease pool
			
            if (self->socket4FD != SOCKET_NULL)
                result = [self connectedPortFromSocket4:self->socket4FD];
            else if (self->socket6FD != SOCKET_NULL)
                result = [self connectedPortFromSocket6:self->socket6FD];
		});
		
		return result;
	}
}

- (NSURL *)connectedUrl
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socketUN != SOCKET_NULL)
			return [self connectedUrlFromSocketUN:socketUN];
		
		return nil;
	}
	else
	{
		__block NSURL *result = nil;
		
		dispatch_sync(socketQueue, ^{ @autoreleasepool {
			
            if (self->socketUN != SOCKET_NULL)
                result = [self connectedUrlFromSocketUN:self->socketUN];
		}});
		
		return result;
	}
}

- (NSString *)localHost
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self localHostFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self localHostFromSocket6:socket6FD];
		
		return nil;
	}
	else
	{
		__block NSString *result = nil;
		
		dispatch_sync(socketQueue, ^{ @autoreleasepool {
			
            if (self->socket4FD != SOCKET_NULL)
                result = [self localHostFromSocket4:self->socket4FD];
            else if (self->socket6FD != SOCKET_NULL)
                result = [self localHostFromSocket6:self->socket6FD];
		}});
		
		return result;
	}
}

- (uint16_t)localPort
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		if (socket4FD != SOCKET_NULL)
			return [self localPortFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self localPortFromSocket6:socket6FD];
		
		return 0;
	}
	else
	{
		__block uint16_t result = 0;
		
		dispatch_sync(socketQueue, ^{
			// No need for autorelease pool
			
            if (self->socket4FD != SOCKET_NULL)
                result = [self localPortFromSocket4:self->socket4FD];
            else if (self->socket6FD != SOCKET_NULL)
                result = [self localPortFromSocket6:self->socket6FD];
		});
		
		return result;
	}
}

- (NSString *)connectedHost4
{
	if (socket4FD != SOCKET_NULL)
		return [self connectedHostFromSocket4:socket4FD];
	
	return nil;
}

- (NSString *)connectedHost6
{
	if (socket6FD != SOCKET_NULL)
		return [self connectedHostFromSocket6:socket6FD];
	
	return nil;
}

- (uint16_t)connectedPort4
{
	if (socket4FD != SOCKET_NULL)
		return [self connectedPortFromSocket4:socket4FD];
	
	return 0;
}

- (uint16_t)connectedPort6
{
	if (socket6FD != SOCKET_NULL)
		return [self connectedPortFromSocket6:socket6FD];
	
	return 0;
}

- (NSString *)localHost4
{
	if (socket4FD != SOCKET_NULL)
		return [self localHostFromSocket4:socket4FD];
	
	return nil;
}

- (NSString *)localHost6
{
	if (socket6FD != SOCKET_NULL)
		return [self localHostFromSocket6:socket6FD];
	
	return nil;
}

- (uint16_t)localPort4
{
	if (socket4FD != SOCKET_NULL)
		return [self localPortFromSocket4:socket4FD];
	
	return 0;
}

- (uint16_t)localPort6
{
	if (socket6FD != SOCKET_NULL)
		return [self localPortFromSocket6:socket6FD];
	
	return 0;
}

- (NSString *)connectedHostFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr4:&sockaddr4];
}

- (NSString *)connectedHostFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr6:&sockaddr6];
}

- (uint16_t)connectedPortFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr4:&sockaddr4];
}

- (uint16_t)connectedPortFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr6:&sockaddr6];
}

- (NSURL *)connectedUrlFromSocketUN:(int)socketFD
{
	struct sockaddr_un sockaddr;
	socklen_t sockaddrlen = sizeof(sockaddr);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr, &sockaddrlen) < 0)
	{
		return 0;
	}
	return [[self class] urlFromSockaddrUN:&sockaddr];
}

- (NSString *)localHostFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr4:&sockaddr4];
}

- (NSString *)localHostFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromSockaddr6:&sockaddr6];
}

- (uint16_t)localPortFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr4:&sockaddr4];
}

- (uint16_t)localPortFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return 0;
	}
	return [[self class] portFromSockaddr6:&sockaddr6];
}

- (NSData *)connectedAddress
{
	__block NSData *result = nil;
	
	dispatch_block_t block = ^{
        if (self->socket4FD != SOCKET_NULL)
		{
			struct sockaddr_in sockaddr4;
			socklen_t sockaddr4len = sizeof(sockaddr4);
			
            if (getpeername(self->socket4FD, (struct sockaddr *)&sockaddr4, &sockaddr4len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr4 length:sockaddr4len];
			}
		}
		
        if (self->socket6FD != SOCKET_NULL)
		{
			struct sockaddr_in6 sockaddr6;
			socklen_t sockaddr6len = sizeof(sockaddr6);
			
            if (getpeername(self->socket6FD, (struct sockaddr *)&sockaddr6, &sockaddr6len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr6 length:sockaddr6len];
			}
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

- (NSData *)localAddress
{
	__block NSData *result = nil;
	
	dispatch_block_t block = ^{
        if (self->socket4FD != SOCKET_NULL)
		{
			struct sockaddr_in sockaddr4;
			socklen_t sockaddr4len = sizeof(sockaddr4);
			
            if (getsockname(self->socket4FD, (struct sockaddr *)&sockaddr4, &sockaddr4len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr4 length:sockaddr4len];
			}
		}
		
        if (self->socket6FD != SOCKET_NULL)
		{
			struct sockaddr_in6 sockaddr6;
			socklen_t sockaddr6len = sizeof(sockaddr6);
			
            if (getsockname(self->socket6FD, (struct sockaddr *)&sockaddr6, &sockaddr6len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr6 length:sockaddr6len];
			}
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

- (BOOL)isIPv4
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return (socket4FD != SOCKET_NULL);
	}
	else
	{
		__block BOOL result = NO;
		
		dispatch_sync(socketQueue, ^{
            result = (self->socket4FD != SOCKET_NULL);
		});
		
		return result;
	}
}

- (BOOL)isIPv6
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return (socket6FD != SOCKET_NULL);
	}
	else
	{
		__block BOOL result = NO;
		
		dispatch_sync(socketQueue, ^{
            result = (self->socket6FD != SOCKET_NULL);
		});
		
		return result;
	}
}

- (BOOL)isSecure
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return (flags & kSocketSecure) ? YES : NO;
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
            result = (self->flags & kSocketSecure) ? YES : NO;
		});
		
		return result;
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Finds the address of an interface description.
 * An inteface description may be an interface name (en0, en1, lo0) or corresponding IP (192.168.4.34).
 * 
 * The interface description may optionally contain a port number at the end, separated by a colon.
 * If a non-zero port parameter is provided, any port number in the interface description is ignored.
 * 
 * The returned value is a 'struct sockaddr' wrapped in an NSMutableData object.
**/


/**
查找接口描述的地址。
接口描述可以是接口名称（en0、en1、lo0）或相应的IP（192.168.4.34）。
接口描述可以选择性地在末尾包含一个冒号分隔的端口号。
如果提供了非零的端口参数，则会忽略接口描述中的任何端口号。
返回值是一个以NSMutableData对象封装的'struct sockaddr'。
**/

- (void)getInterfaceAddress4:(NSMutableData **)interfaceAddr4Ptr
                    address6:(NSMutableData **)interfaceAddr6Ptr
             fromDescription:(NSString *)interfaceDescription
                        port:(uint16_t)port
{
	NSMutableData *addr4 = nil;
	NSMutableData *addr6 = nil;
	
	NSString *interface = nil;
	
    // 先用: 分割··前面可能是ip··后面可能是port
	NSArray *components = [interfaceDescription componentsSeparatedByString:@":"];
    
	if ([components count] > 0)
	{
		NSString *temp = [components objectAtIndex:0];
		if ([temp length] > 0)
		{
            // 第一个就是地址
			interface = temp;
		}
	}
    // 获取port ， 并且port 没有设置
	if ([components count] > 1 && port == 0)
	{
		NSString *temp = [components objectAtIndex:1];
        
        // temp 转成 long 类型的数据
		long portL = strtol([temp UTF8String], NULL, 10);
		
        // UINT16_MAX 为 65535 port 数
		if (portL > 0 && portL <= UINT16_MAX)
		{
			port = (uint16_t)portL;
		}
	}
	
	if (interface == nil)
	{
		// ANY address
		
        // 创建
		struct sockaddr_in sockaddr4;
		memset(&sockaddr4, 0, sizeof(sockaddr4));
		
		sockaddr4.sin_len         = sizeof(sockaddr4);
		sockaddr4.sin_family      = AF_INET;
		sockaddr4.sin_port        = htons(port);
		sockaddr4.sin_addr.s_addr = htonl(INADDR_ANY);
		
		struct sockaddr_in6 sockaddr6;
		memset(&sockaddr6, 0, sizeof(sockaddr6));
		
		sockaddr6.sin6_len       = sizeof(sockaddr6);
		sockaddr6.sin6_family    = AF_INET6;
		sockaddr6.sin6_port      = htons(port);
		sockaddr6.sin6_addr      = in6addr_any;
		
		addr4 = [NSMutableData dataWithBytes:&sockaddr4 length:sizeof(sockaddr4)];
		addr6 = [NSMutableData dataWithBytes:&sockaddr6 length:sizeof(sockaddr6)];
	}
	else if ([interface isEqualToString:@"localhost"] || [interface isEqualToString:@"loopback"])
	{
        //如果localhost、loopback 回环地址，虚拟地址，路由器工作它就存在。一般用来标识路由器
        //这两种的话就赋值为127.0.0.1，端口为port
		// LOOPBACK address
		
		struct sockaddr_in sockaddr4;
		memset(&sockaddr4, 0, sizeof(sockaddr4));
		
		sockaddr4.sin_len         = sizeof(sockaddr4);
		sockaddr4.sin_family      = AF_INET;
		sockaddr4.sin_port        = htons(port);
		sockaddr4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		
		struct sockaddr_in6 sockaddr6;
		memset(&sockaddr6, 0, sizeof(sockaddr6));
		
		sockaddr6.sin6_len       = sizeof(sockaddr6);
		sockaddr6.sin6_family    = AF_INET6;
		sockaddr6.sin6_port      = htons(port);
		sockaddr6.sin6_addr      = in6addr_loopback;
		
		addr4 = [NSMutableData dataWithBytes:&sockaddr4 length:sizeof(sockaddr4)];
		addr6 = [NSMutableData dataWithBytes:&sockaddr6 length:sizeof(sockaddr6)];
	}
	else
	{
		const char *iface = [interface UTF8String];
		
        //定义结构体指针，这个指针是本地IP
		struct ifaddrs *addrs;
		const struct ifaddrs *cursor;
		
        // 获取本机ip地址··== 0 是代表成功
        
//        getifaddrs 获取系统中所有网络接口
        
		if ((getifaddrs(&addrs) == 0))
		{
			cursor = addrs;
			while (cursor != NULL)
			{
				if ((addr4 == nil) && (cursor->ifa_addr->sa_family == AF_INET))
				{
					// IPv4
					
					struct sockaddr_in nativeAddr4;
                    //memcpy内存copy函数将 scr地址 copy 到 dest上··len 代表要拷贝的字节数
                    // memcpy(dest, src, len)
//
//                __dst: 这是目标地址，你要将数据复制到这个地址。它必须指向足够大的内存区域，能够容纳 n 个字节。
//
//                __src: 这是源地址，你要从这个地址复制数据。它必须指向至少 n 个字节的内存区域。
//
//                __n: 这是你想要复制的字节数。它必须是一个有效的大小，并且源和目标内存区域都必须大到足以容纳这么多字节。
                    
					memcpy(&nativeAddr4, cursor->ifa_addr, sizeof(nativeAddr4));
					
                    // 字符串比较   获取的本机ip 与 interface 做对比
                    
                    // cursor->ifa_name 接口名称
					if (strcmp(cursor->ifa_name, iface) == 0)
					{
						// Name match
						// 如果相同就绑定
						nativeAddr4.sin_port = htons(port);
						
						addr4 = [NSMutableData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
					}
					else
					{
						char ip[INET_ADDRSTRLEN];
						//  接口名称不同···就比较ip地址
						const char *conversion = inet_ntop(AF_INET, &nativeAddr4.sin_addr, ip, sizeof(ip));
						
						if ((conversion != NULL) && (strcmp(ip, iface) == 0))
						{
							// IP match
							
							nativeAddr4.sin_port = htons(port);
							
							addr4 = [NSMutableData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
						}
					}
				}
                // 如果是ipv6的话··和Ipv4相同
				else if ((addr6 == nil) && (cursor->ifa_addr->sa_family == AF_INET6))
				{
					// IPv6
					
					struct sockaddr_in6 nativeAddr6;
					memcpy(&nativeAddr6, cursor->ifa_addr, sizeof(nativeAddr6));
					
					if (strcmp(cursor->ifa_name, iface) == 0)
					{
						// Name match
						
						nativeAddr6.sin6_port = htons(port);
						
						addr6 = [NSMutableData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
					}
					else
					{
						char ip[INET6_ADDRSTRLEN];
						
						const char *conversion = inet_ntop(AF_INET6, &nativeAddr6.sin6_addr, ip, sizeof(ip));
						
						if ((conversion != NULL) && (strcmp(ip, iface) == 0))
						{
							// IP match
							
							nativeAddr6.sin6_port = htons(port);
							
							addr6 = [NSMutableData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
						}
					}
				}
				//
				cursor = cursor->ifa_next;
			}
			
			freeifaddrs(addrs);
		}
	}
	
	if (interfaceAddr4Ptr) *interfaceAddr4Ptr = addr4;
	if (interfaceAddr6Ptr) *interfaceAddr6Ptr = addr6;
}

- (NSData *)getInterfaceAddressFromUrl:(NSURL *)url
{
	NSString *path = url.path;
	if (path.length == 0) {
		return nil;
	}
	
    struct sockaddr_un nativeAddr;
    nativeAddr.sun_family = AF_UNIX;
    strlcpy(nativeAddr.sun_path, path.fileSystemRepresentation, sizeof(nativeAddr.sun_path));
    nativeAddr.sun_len = (unsigned char)SUN_LEN(&nativeAddr);
    NSData *interface = [NSData dataWithBytes:&nativeAddr length:sizeof(struct sockaddr_un)];
	
	return interface;
}

- (void)setupReadAndWriteSourcesForNewlyConnectedSocket:(int)socketFD
{
    // 创新读写source 来监听 socketFD 在 socketQueue 中处理
	readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socketFD, 0, socketQueue);
	writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, socketFD, 0, socketQueue);
	
	// Setup event handlers
	
	__weak GCDAsyncSocket *weakSelf = self;
	
    // 给读source 设置触发的回调
	dispatch_source_set_event_handler(readSource, ^{ @autoreleasepool {
	#pragma clang diagnostic push
	#pragma clang diagnostic warning "-Wimplicit-retain-self"
		
		__strong GCDAsyncSocket *strongSelf = weakSelf;
		if (strongSelf == nil) return_from_block;
		
		LogVerbose(@"readEventBlock");
		
		strongSelf->socketFDBytesAvailable = dispatch_source_get_data(strongSelf->readSource);
		LogVerbose(@"socketFDBytesAvailable: %lu", strongSelf->socketFDBytesAvailable);
		
		if (strongSelf->socketFDBytesAvailable > 0)
			[strongSelf doReadData];
		else
			[strongSelf doReadEOF];
		
	#pragma clang diagnostic pop
	}});
	
	dispatch_source_set_event_handler(writeSource, ^{ @autoreleasepool {
	#pragma clang diagnostic push
	#pragma clang diagnostic warning "-Wimplicit-retain-self"
		
		__strong GCDAsyncSocket *strongSelf = weakSelf;
		if (strongSelf == nil) return_from_block;
		
		LogVerbose(@"writeEventBlock");
		
		strongSelf->flags |= kSocketCanAcceptBytes;
		[strongSelf doWriteData];
		
	#pragma clang diagnostic pop
	}});
	
	// Setup cancel handlers
	
	__block int socketFDRefCount = 2;
	
	#if !OS_OBJECT_USE_OBJC
	dispatch_source_t theReadSource = readSource;
	dispatch_source_t theWriteSource = writeSource;
	#endif
	
    // source 被取消的时候，才会触发这个方法，可能不会立即触发，要等source其他任务都处理完以后，才会触发下面的回调，并且执行了 cancel就不会在被启用，只能重新创建，一般用于清洁工作，内存释放什么的
	dispatch_source_set_cancel_handler(readSource, ^{
	#pragma clang diagnostic push
	#pragma clang diagnostic warning "-Wimplicit-retain-self"
		
		LogVerbose(@"readCancelBlock");
		
		#if !OS_OBJECT_USE_OBJC
		LogVerbose(@"dispatch_release(readSource)");
		dispatch_release(theReadSource);
		#endif
		
		if (--socketFDRefCount == 0)
		{
			LogVerbose(@"close(socketFD)");
			close(socketFD);
		}
		
	#pragma clang diagnostic pop
	});
	
	dispatch_source_set_cancel_handler(writeSource, ^{
	#pragma clang diagnostic push
	#pragma clang diagnostic warning "-Wimplicit-retain-self"
		
		LogVerbose(@"writeCancelBlock");
		
		#if !OS_OBJECT_USE_OBJC
		LogVerbose(@"dispatch_release(writeSource)");
		dispatch_release(theWriteSource);
		#endif
		
		if (--socketFDRefCount == 0)
		{
			LogVerbose(@"close(socketFD)");
			close(socketFD);
		}
		
	#pragma clang diagnostic pop
	});
	
	// We will not be able to read until data arrives.
	// But we should be able to write immediately.
	
	socketFDBytesAvailable = 0;
	flags &= ~kReadSourceSuspended;
	
	LogVerbose(@"dispatch_resume(readSource)");
    // 启动读源
	dispatch_resume(readSource);
	
	flags |= kSocketCanAcceptBytes;
	flags |= kWriteSourceSuspended;
}

- (BOOL)usingCFStreamForTLS
{
//	#if TARGET_OS_IPHONE
	
	if ((flags & kSocketSecure) && (flags & kUsingCFStreamForTLS))
	{
		// The startTLS method was given the GCDAsyncSocketUseCFStreamForTLS flag.
		
		return YES;
	}
	
//	#endif
	
	return NO;
}

- (BOOL)usingSecureTransportForTLS
{
	// Invoking this method is equivalent to ![self usingCFStreamForTLS] (just more readable)
	
//	#if TARGET_OS_IPHONE
	
	if ((flags & kSocketSecure) && (flags & kUsingCFStreamForTLS))
	{
		// The startTLS method was given the GCDAsyncSocketUseCFStreamForTLS flag.
		
		return NO;
	}
	
//	#endif
	
	return YES;
}

- (void)suspendReadSource
{
	if (!(flags & kReadSourceSuspended))
	{
		LogVerbose(@"dispatch_suspend(readSource)");
		
		dispatch_suspend(readSource);
		flags |= kReadSourceSuspended;
	}
}

- (void)resumeReadSource
{
	if (flags & kReadSourceSuspended)
	{
		LogVerbose(@"dispatch_resume(readSource)");
		
		dispatch_resume(readSource);
		flags &= ~kReadSourceSuspended;
	}
}

- (void)suspendWriteSource
{
	if (!(flags & kWriteSourceSuspended))
	{
		LogVerbose(@"dispatch_suspend(writeSource)");
		
		dispatch_suspend(writeSource);
		flags |= kWriteSourceSuspended;
	}
}

- (void)resumeWriteSource
{
	if (flags & kWriteSourceSuspended)
	{
		LogVerbose(@"dispatch_resume(writeSource)");
		
		dispatch_resume(writeSource);
		flags &= ~kWriteSourceSuspended;
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Reading
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)readDataWithTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	[self readDataWithTimeout:timeout buffer:nil bufferOffset:0 maxLength:0 tag:tag];
}

- (void)readDataWithTimeout:(NSTimeInterval)timeout
                     buffer:(NSMutableData *)buffer
               bufferOffset:(NSUInteger)offset
                        tag:(long)tag
{
	[self readDataWithTimeout:timeout buffer:buffer bufferOffset:offset maxLength:0 tag:tag];
}

- (void)readDataWithTimeout:(NSTimeInterval)timeout
                     buffer:(NSMutableData *)buffer
               bufferOffset:(NSUInteger)offset
                  maxLength:(NSUInteger)length
                        tag:(long)tag
{
	if (offset > [buffer length]) {
		LogWarn(@"Cannot read: offset > [buffer length]");
		return;
	}
	
	GCDAsyncReadPacket *packet = [[GCDAsyncReadPacket alloc] initWithData:buffer
	                                                          startOffset:offset
	                                                            maxLength:length
	                                                              timeout:timeout
	                                                           readLength:0
	                                                           terminator:nil
	                                                                  tag:tag];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		LogTrace();
		
        if ((self->flags & kSocketStarted) && !(self->flags & kForbidReadsWrites))
		{
            [self->readQueue addObject:packet];
			[self maybeDequeueRead];
		}
	}});
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
}

- (void)readDataToLength:(NSUInteger)length withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	[self readDataToLength:length withTimeout:timeout buffer:nil bufferOffset:0 tag:tag];
}

- (void)readDataToLength:(NSUInteger)length
             withTimeout:(NSTimeInterval)timeout
                  buffer:(NSMutableData *)buffer
            bufferOffset:(NSUInteger)offset
                     tag:(long)tag
{
	if (length == 0) {
		LogWarn(@"Cannot read: length == 0");
		return;
	}
	if (offset > [buffer length]) {
		LogWarn(@"Cannot read: offset > [buffer length]");
		return;
	}
	
	GCDAsyncReadPacket *packet = [[GCDAsyncReadPacket alloc] initWithData:buffer
	                                                          startOffset:offset
	                                                            maxLength:0
	                                                              timeout:timeout
	                                                           readLength:length
	                                                           terminator:nil
	                                                                  tag:tag];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		LogTrace();
		
        if ((self->flags & kSocketStarted) && !(self->flags & kForbidReadsWrites))
		{
            [self->readQueue addObject:packet];
			[self maybeDequeueRead];
		}
	}});
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
}

- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	[self readDataToData:data withTimeout:timeout buffer:nil bufferOffset:0 maxLength:0 tag:tag];
}

- (void)readDataToData:(NSData *)data
           withTimeout:(NSTimeInterval)timeout
                buffer:(NSMutableData *)buffer
          bufferOffset:(NSUInteger)offset
                   tag:(long)tag
{
	[self readDataToData:data withTimeout:timeout buffer:buffer bufferOffset:offset maxLength:0 tag:tag];
}

- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout maxLength:(NSUInteger)length tag:(long)tag
{
	[self readDataToData:data withTimeout:timeout buffer:nil bufferOffset:0 maxLength:length tag:tag];
}

- (void)readDataToData:(NSData *)data
           withTimeout:(NSTimeInterval)timeout
                buffer:(NSMutableData *)buffer
          bufferOffset:(NSUInteger)offset
             maxLength:(NSUInteger)maxLength
                   tag:(long)tag
{
	if ([data length] == 0) {
		LogWarn(@"Cannot read: [data length] == 0");
		return;
	}
	if (offset > [buffer length]) {
		LogWarn(@"Cannot read: offset > [buffer length]");
		return;
	}
	if (maxLength > 0 && maxLength < [data length]) {
		LogWarn(@"Cannot read: maxLength > 0 && maxLength < [data length]");
		return;
	}
	
	GCDAsyncReadPacket *packet = [[GCDAsyncReadPacket alloc] initWithData:buffer
	                                                          startOffset:offset
	                                                            maxLength:maxLength
	                                                              timeout:timeout
	                                                           readLength:0
	                                                           terminator:data
	                                                                  tag:tag];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		LogTrace();
		
        if ((self->flags & kSocketStarted) && !(self->flags & kForbidReadsWrites))
		{
            [self->readQueue addObject:packet];
			[self maybeDequeueRead];
		}
	}});
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
}

- (float)progressOfReadReturningTag:(long *)tagPtr bytesDone:(NSUInteger *)donePtr total:(NSUInteger *)totalPtr
{
	__block float result = 0.0F;
	
	dispatch_block_t block = ^{
		
        if (!self->currentRead || ![self->currentRead isKindOfClass:[GCDAsyncReadPacket class]])
		{
			// We're not reading anything right now.
			
			if (tagPtr != NULL)   *tagPtr = 0;
			if (donePtr != NULL)  *donePtr = 0;
			if (totalPtr != NULL) *totalPtr = 0;
			
			result = NAN;
		}
		else
		{
			// It's only possible to know the progress of our read if we're reading to a certain length.
			// If we're reading to data, we of course have no idea when the data will arrive.
			// If we're reading to timeout, then we have no idea when the next chunk of data will arrive.
			
            NSUInteger done = self->currentRead->bytesDone;
            NSUInteger total = self->currentRead->readLength;
			
            if (tagPtr != NULL)   *tagPtr = self->currentRead->tag;
			if (donePtr != NULL)  *donePtr = done;
			if (totalPtr != NULL) *totalPtr = total;
			
			if (total > 0)
				result = (float)done / (float)total;
			else
				result = 1.0F;
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

/**
 * This method starts a new read, if needed.
 * 
 * It is called when:
 * - a user requests a read
 * - after a read request has finished (to handle the next request)
 * - immediately after the socket opens to handle any pending requests
 * 
 * This method also handles auto-disconnect post read/write completion.
**/
- (void)maybeDequeueRead
{
	LogTrace();
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	// If we're not currently processing a read AND we have an available read stream
	if ((currentRead == nil) && (flags & kConnected))
	{
		if ([readQueue count] > 0)
		{
			// Dequeue the next object in the write queue
			currentRead = [readQueue objectAtIndex:0];
			[readQueue removeObjectAtIndex:0];
			
			
			if ([currentRead isKindOfClass:[GCDAsyncSpecialPacket class]])
			{
				LogVerbose(@"Dequeued GCDAsyncSpecialPacket");
				
				// Attempt to start TLS
				flags |= kStartingReadTLS;
				
				// This method won't do anything unless both kStartingReadTLS and kStartingWriteTLS are set
                //只有读写都开启了TLS,才会做TLS认证
				[self maybeStartTLS];
			}
			else
			{
				LogVerbose(@"Dequeued GCDAsyncReadPacket");
				
				// Setup read timer (if needed)
                // 设置读的超时时间
				[self setupReadTimerWithTimeout:currentRead->timeout];
				
				// Immediately read, if possible
                //
				[self doReadData];
			}
		}
		else if (flags & kDisconnectAfterReads)
		{
			if (flags & kDisconnectAfterWrites)
			{
				if (([writeQueue count] == 0) && (currentWrite == nil))
				{
					[self closeWithError:nil];
				}
			}
			else
			{
				[self closeWithError:nil];
			}
		}
		else if (flags & kSocketSecure)
		{
			[self flushSSLBuffers];
			
			// Edge case:
			// 
			// We just drained all data from the ssl buffers,
			// and all known data from the socket (socketFDBytesAvailable).
			// 
			// If we didn't get any data from this process,
			// then we may have reached the end of the TCP stream.
			// 
			// Be sure callbacks are enabled so we're notified about a disconnection.
			
			if ([preBuffer availableBytes] == 0)
			{
				if ([self usingCFStreamForTLS]) {
					// Callbacks never disabled
				}
				else {
					[self resumeReadSource];
				}
			}
		}
	}
}

- (void)flushSSLBuffers
{
	LogTrace();
	
	NSAssert((flags & kSocketSecure), @"Cannot flush ssl buffers on non-secure socket");
	
	if ([preBuffer availableBytes] > 0)
	{
		// Only flush the ssl buffers if the prebuffer is empty.
		// This is to avoid growing the prebuffer inifinitely large.
		
        //仅在预缓冲区为空时刷新ssl缓冲区。
        //这是为了避免预缓冲区变得无限大

		return;
	}
	
//	#if TARGET_OS_IPHONE
	
    // 使用 cfstream
	if ([self usingCFStreamForTLS])
	{
        // 校验 flags 与 readStream 是否支持文字读写
		if ((flags & kSecureSocketHasBytesAvailable) && CFReadStreamHasBytesAvailable(readStream))
		{
			LogVerbose(@"%@ - Flushing ssl buffers into prebuffer...", THIS_METHOD);
			
			CFIndex defaultBytesToRead = (1024 * 4);
			// 校验缓冲区是否能放下4k，不能就扩容
			[preBuffer ensureCapacityForWrite:defaultBytesToRead];
			
			uint8_t *buffer = [preBuffer writeBuffer];
			
            // 这里是将数据从 readStream 中，将数据读到了缓冲区，并且已经是解密完成的
            // 从 readStream 中读取 defaultBytesToRead 大小的数据到 buffer 中，并且已经解密
			CFIndex result = CFReadStreamRead(readStream, buffer, defaultBytesToRead);
			LogVerbose(@"%@ - CFReadStreamRead(): result = %i", THIS_METHOD, (int)result);
			
			if (result > 0)
			{   // 更新 write 下标
				[preBuffer didWrite:result];
			}
			
			flags &= ~kSecureSocketHasBytesAvailable;
		}
		
		return;
	}
	
//	#endif
	
	__block NSUInteger estimatedBytesAvailable = 0;
	
	dispatch_block_t updateEstimatedBytesAvailable = ^{
		
		// Figure out if there is any data available to be read
		// 
		// socketFDBytesAvailable        <- Number of encrypted bytes we haven't read from the bsd socket
		// [sslPreBuffer availableBytes] <- Number of encrypted bytes we've buffered from bsd socket
		// sslInternalBufSize            <- Number of decrypted bytes SecureTransport has buffered
		// 
		// We call the variable "estimated" because we don't know how many decrypted bytes we'll get
		// from the encrypted bytes in the sslPreBuffer.
		// However, we do know this is an upper bound on the estimation.
        
        /* 在处理 SSL/TLS 连接时，数据在网络上传输时是加密的。为了从中读取明文数据，需要依赖 SSL/TLS 库（如 SecureTransport）对接收到的数据进行解密。在这个过程中，可能涉及几个不同的缓冲区：

            1.socketFDBytesAvailable:
            •    这是从底层 BSD 套接字中读取的加密数据的字节数。尚未被读入用户空间缓冲区，即在套接字缓冲区中仍然有多少加密数据可供读取。
            2.[sslPreBuffer availableBytes]:
            •    这是从 BSD 套接字中读取但尚未解密的数据。这些数据已经被缓冲在 sslPreBuffer 中，但还没有被传递给 SecureTransport 进行解密。
            3.sslInternalBufSize:
            •    这是 SecureTransport 已经解密但尚未被应用程序读取的字节数。它表示 SecureTransport 内部缓冲区中可供读取的明文数据量。
         */
		
        estimatedBytesAvailable = self->socketFDBytesAvailable + [self->sslPreBuffer availableBytes];
		
		size_t sslInternalBufSize = 0;
        
        // SSLGetBufferedReadSize 是 SecureTransport API 中的一个函数，用于获取 SSL/TLS 连接上下文中已经解密并且在内部缓冲区中等待读取的字节数。换句话说，这个函数告诉你还有多少已经解密的数据在 SSL/TLS 层中等待被你的应用程序读取
        SSLGetBufferedReadSize(self->sslContext, &sslInternalBufSize);
		
		estimatedBytesAvailable += sslInternalBufSize;
	};
	
	updateEstimatedBytesAvailable();
	
    // 确实有可读的信息
	if (estimatedBytesAvailable > 0)
	{
		LogVerbose(@"%@ - Flushing ssl buffers into prebuffer...", THIS_METHOD);
		
		BOOL done = NO;
		do
		{
			LogVerbose(@"%@ - estimatedBytesAvailable = %lu", THIS_METHOD, (unsigned long)estimatedBytesAvailable);
			
			// Make sure there's enough room in the prebuffer
			// 校验大小并扩容
			[preBuffer ensureCapacityForWrite:estimatedBytesAvailable];
			
			// Read data into prebuffer
			
			uint8_t *buffer = [preBuffer writeBuffer];
			size_t bytesRead = 0;
			
            // estimatedBytesAvailable 需要读取的
            // bytesRead 实际读取的
            // 从sslContext中读取数据，解密，并写入到buffer中，，这个方法涉及了解密
			OSStatus result = SSLRead(sslContext, buffer, (size_t)estimatedBytesAvailable, &bytesRead);
			LogVerbose(@"%@ - read from secure socket = %u", THIS_METHOD, (unsigned)bytesRead);
			
			if (bytesRead > 0)
			{
				[preBuffer didWrite:bytesRead];
			}
			
			LogVerbose(@"%@ - prebuffer.length = %zu", THIS_METHOD, [preBuffer availableBytes]);
			
			if (result != noErr)
			{
				done = YES;
			}
			else
			{
                // 更新下一次可读的大小
				updateEstimatedBytesAvailable();
			}
			// 这里可以多次读取
		} while (!done && estimatedBytesAvailable > 0);
	}
}

- (void)doReadData
{
    
    /*
     这段代码有进行优化，主要通过以下几点避免了重复读取的性能损耗：

         1.    暂停 readSource：当检测到有数据可读时，代码会主动暂停 readSource，以避免其反复触发读取操作。这避免了由于底层 GCD 机制频繁触发回调，导致 doReadData 的多次调用。
         2.    SSL/TLS 数据解密优化：在 SSL/TLS 模式下，代码通过提前解密缓冲数据，减少了后续用户请求时的等待时间。此外，代码会尽可能通过一次调用读取大量解密数据，减少了系统调用的次数。
         3.    判断是否有数据可读：代码会根据当前数据缓冲区的可用性，决定是否继续读取数据，避免在没有数据可读时无效调用读取操作。
     */
    
    
	LogTrace();
	
	// This method is called on the socketQueue.
	// It might be called directly, or via the readSource when data is available to be read.
	
	if ((currentRead == nil) || (flags & kReadsPaused))
	{
		LogVerbose(@"No currentRead or kReadsPaused");
		
		// Unable to read at this time
		// 使用ssl 安全通信
		if (flags & kSocketSecure)
		{
			// Here's the situation:
			// 
			// We have an established secure connection.
			// There may not be a currentRead, but there might be encrypted data sitting around for us.
			// When the user does get around to issuing a read, that encrypted data will need to be decrypted.
			// 
			// So why make the user wait?
			// We might as well get a head start on decrypting some data now.
			// 
			// The other reason we do this has to do with detecting a socket disconnection.
			// The SSL/TLS protocol has it's own disconnection handshake.
			// So when a secure socket is closed, a "goodbye" packet comes across the wire.
			// We want to make sure we read the "goodbye" packet so we can properly detect the TCP disconnection.
            
            // 这里处理的很巧妙，主要是有2个原因
            // 1. 提前解密数据以减少用户等待时间
            /* •    情境：已经建立了一个安全连接（即使用 SSL/TLS 协议进行加密通信的连接）。
            •    可能性：当前可能没有要读取的数据请求（currentRead 为空），但是可能有一些加密的数据已经到达并存储在缓冲区中。
            •    问题：当用户稍后发起读取请求时，如果这些加密数据没有提前解密，用户将不得不等待数据解密过程。
            •    解决方案：与其让用户在发起读取请求时等待数据解密，不如提前处理缓冲区中的加密数据，这样可以减少用户等待时间，提高响应速度。
             */
            
            // 2. 正确检测安全连接的断开
            /*
             •    背景：在 SSL/TLS 连接中，协议规定了专门的断开连接握手过程。当安全连接关闭时，服务器会发送一个“再见”数据包（goodbye packet），表示连接的正常终止。
             •    问题：如果没有及时读取并处理这个“再见”数据包，可能会导致无法正确检测到 TCP 连接的断开，从而造成错误处理或资源泄漏。
             •    目的：通过提前读取和处理这些加密数据，确保在连接断开时能够正确接收和处理“再见”数据包，从而正确地检测到连接的终止并执行相应的清理工作。
             */
			
			[self flushSSLBuffers];
		}
		
		if ([self usingCFStreamForTLS])
		{
			// CFReadStream only fires once when there is available data.
			// It won't fire again until we've invoked CFReadStreamRead.
		}
		else
		{
			// If the readSource is firing, we need to pause it
			// or else it will continue to fire over and over again.
			// 
			// If the readSource is not firing,
			// we want it to continue monitoring the socket.
			
			if (socketFDBytesAvailable > 0)
			{
				[self suspendReadSource];
			}
		}
        
//        我们绕了一圈，讲完了这个包为空或者当前暂停状态下的前置处理，总结一下：
//        1 就是如果是SSL类型的数据，那么先解密了，缓冲到prebuffer中去。
//        2 判断当前socket可读数据大于0，非CFStreamSSL类型，则挂起source，防止反复触发。

		return;
	}
	
	BOOL hasBytesAvailable = NO;
	unsigned long estimatedBytesAvailable = 0;
	
	if ([self usingCFStreamForTLS])
	{
//		#if TARGET_OS_IPHONE
		
		// Requested CFStream, rather than SecureTransport, for TLS (via GCDAsyncSocketUseCFStreamForTLS)
		
        // 如果使用的是 CFStream 方式，则判断一下 readStream 中是否有可读内容
		estimatedBytesAvailable = 0;
		if ((flags & kSecureSocketHasBytesAvailable) && CFReadStreamHasBytesAvailable(readStream))
			hasBytesAvailable = YES;
		else
			hasBytesAvailable = NO;
		
//		#endif
	}
	else
	{
		estimatedBytesAvailable = socketFDBytesAvailable;

        // 处于 ssl/tsl 模式
		if (flags & kSocketSecure)
		{
			// There are 2 buffers to be aware of here.
			// 
			// We are using SecureTransport, a TLS/SSL security layer which sits atop TCP.
			// We issue a read to the SecureTranport API, which in turn issues a read to our SSLReadFunction.
			// Our SSLReadFunction then reads from the BSD socket and returns the encrypted data to SecureTransport.
			// SecureTransport then decrypts the data, and finally returns the decrypted data back to us.
			// 
			// The first buffer is one we create.
			// SecureTransport often requests small amounts of data.
			// This has to do with the encypted packets that are coming across the TCP stream.
			// But it's non-optimal to do a bunch of small reads from the BSD socket.
			// So our SSLReadFunction reads all available data from the socket (optimizing the sys call)
			// and may store excess in the sslPreBuffer.
            
            /*
             •    SecureTransport 是一个TLS/SSL安全层，它在TCP之上工作，为数据传输提供加密和安全性。在使用SecureTransport时，数据从TCP层传输到应用程序，需要经过加密和解密的处理。
             •    为了进行安全通信，应用程序通过调用SecureTransport的API请求数据。当应用程序请求读取数据时，SecureTransport API会进一步调用一个自定义的读取函数，这个函数负责从底层的BSD socket读取数据。
             2.    数据流动过程：
             •    请求读取数据：应用程序请求读取数据时，调用SecureTransport的API。
             •    SecureTransport调用自定义读取函数：SecureTransport API不会直接访问底层的socket，而是通过一个自定义的SSLReadFunction函数来读取数据。
             •    自定义读取函数处理数据：SSLReadFunction从BSD socket读取数据，但这些数据是加密的。函数读取到加密数据后，将其返回给SecureTransport。
             •    SecureTransport解密数据：SecureTransport收到加密数据后，对其进行解密，然后将解密后的数据返回给应用程序。
             3.    缓冲区的作用：
             •    第一个缓冲区：是由应用程序创建的，称为sslPreBuffer。这个缓冲区的作用是优化数据读取操作。因为SecureTransport往往请求少量的数据（这与通过TCP流传输的小型加密数据包有关），如果每次都直接从BSD socket读取少量数据，效率很低。为了解决这个问题，SSLReadFunction会一次性从socket读取尽可能多的数据，并将多余的数据存储在sslPreBuffer中，以供后续读取需求。
             •    第二个缓冲区：位于SecureTransport内部。当SecureTransport解密数据时，如果解密后的数据量超出了应用程序当前请求的量，SecureTransport会将多余的数据存储在其内部缓冲区中，以便下次请求时直接使用
             
             */
			
            // 这里先获取 sslPreBuffer 中可读的数据大小
			estimatedBytesAvailable += [sslPreBuffer availableBytes];
			
			// The second buffer is within SecureTransport.
			// As mentioned earlier, there are encrypted packets coming across the TCP stream.
			// SecureTransport needs the entire packet to decrypt it.
			// But if the entire packet produces X bytes of decrypted data,
			// and we only asked SecureTransport for X/2 bytes of data,
			// it must store the extra X/2 bytes of decrypted data for the next read.
			// 
			// The SSLGetBufferedReadSize function will tell us the size of this internal buffer.
			// From the documentation:
			// 
			// "This function does not block or cause any low-level read operations to occur."
            
            /*
             1.    背景：
                 •    当通过TCP流传输数据时，这些数据是加密的。为了确保数据的安全性，SecureTransport会对这些加密的数据包进行解密。
                 •    解密操作需要完整的加密数据包才能完成。SecureTransport将从TCP流中读取的加密数据解密，然后将解密后的数据传递给应用程序。
                 2.    SecureTransport内部的第二个缓冲区：
                 •    加密数据包的解密：如注释所述，SecureTransport需要完整的加密数据包才能进行解密。如果整个数据包在解密后产生了X字节的数据，而应用程序只请求了X/2字节的数据，那么SecureTransport必须处理这种不匹配情况。
                 •    缓冲区的作用：当应用程序请求的数据量小于解密后的数据量时，多余的解密数据会被存储在SecureTransport内部的缓冲区中。这意味着应用程序在下次请求读取数据时，SecureTransport可以直接从这个缓冲区提供剩余的数据，而不需要再次解密或读取TCP流。
                 3.    SSLGetBufferedReadSize函数的作用：
                 •    获取内部缓冲区的大小：SSLGetBufferedReadSize是一个SecureTransport API函数，用于获取SecureTransport内部缓冲区中存储的解密数据的大小。这一函数对于应用程序了解当前可以读取的数据量非常有用。
                 •    非阻塞操作：重要的是，这个函数不会阻塞调用，也不会触发任何底层读取操作。这意味着调用SSLGetBufferedReadSize不会影响应用程序的性能或导致额外的网络延迟。
             */
            
            // SecureTransport 内部的解密过程完全由 SecureTransport 自己完成
			
			size_t sslInternalBufSize = 0;
            
            // 所以这里只是获取如果没有的话，只是获取sslContext中可读已解密的数据size
            
			SSLGetBufferedReadSize(sslContext, &sslInternalBufSize);
			
			estimatedBytesAvailable += sslInternalBufSize;
		}
		
		hasBytesAvailable = (estimatedBytesAvailable > 0);
	}
	
    // 如果没有可读信息
	if ((hasBytesAvailable == NO) && ([preBuffer availableBytes] == 0))
	{
		LogVerbose(@"No data available to read...");
		
		// No data available to read.
		
		if (![self usingCFStreamForTLS])
		{
			// Need to wait for readSource to fire and notify us of
			// available data in the socket's internal read buffer.
			
            // 如果是非 CFStream ，则恢复读取 readSource
			[self resumeReadSource];
		}
		return;
	}
    
    /*
     这段代码处理了TLS/SSL握手期间的读取操作管理。它首先检查是否正在进行TLS/SSL握手，如果是，则进一步处理握手过程中需要的操作。

         1.    如果正在等待写操作（kStartingWriteTLS）：并且使用了SecureTransport，且遇到errSSLWouldBlock错误，则会继续SSL握手。
         2.    如果没有写操作等待：则程序会处理读取源的暂停，以防止读取源不断触发。

     这段代码确保在TLS/SSL握手期间正确管理读取和写入操作，防止不必要的资源浪费，同时确保握手过程能够顺利完成。
     */
	
    // 当前属于正在握手的环节
    
    /*
     
     这段代码是在 SSL/TLS 握手过程中触发的，具体来说，当 CocoaAsyncSocket 检测到正在进行 SSL/TLS 握手时，会执行这段逻辑。下面是代码可能触发的场景：

         1.    正在进行 SSL/TLS 握手 (flags & kStartingReadTLS)：代码块最开始的判断条件 flags & kStartingReadTLS 用于检查是否已经进入了 SSL/TLS 握手的读取阶段。如果是，它意味着当前连接正在执行 SSL/TLS 握手，正在等待从对端接收数据。
         2.    同时处理写操作 (flags & kStartingWriteTLS)：如果 flags & kStartingWriteTLS 也被设置，说明此时同时在处理写操作。这是因为在握手过程中，既需要发送数据也需要接收数据。代码会检查是否正在使用 SecureTransport 处理 TLS，并且最后一次 SSL 握手返回的错误是否是 errSSLWouldBlock，这通常意味着握手正在等待更多的数据到达以继续。
         3.    继续 SSL/TLS 握手 ([self ssl_continueSSLHandshake])：如果上面的条件成立，意味着已经有数据到达，可以继续 SSL/TLS 握手过程，因此调用 [self ssl_continueSSLHandshake] 来继续处理。
         4.    等待写入队列清空：如果没有正在处理写操作（即 flags & kStartingWriteTLS 不成立），则表示握手过程尚未完成，仍然需要等待写入队列清空，以便开始 SSL/TLS 过程。
         5.    挂起读取源 ([self suspendReadSource])：在这种情况下，如果没有使用 CFStream 处理 TLS，则会调用 [self suspendReadSource] 暂停读取源。这是为了避免在握手尚未完成时，读取源不断触发，造成不必要的资源消耗。
     
     */
    
    
	if (flags & kStartingReadTLS)
	{
		LogVerbose(@"Waiting for SSL/TLS handshake to complete");
		
		// The readQueue is waiting for SSL/TLS handshake to complete.
		
		if (flags & kStartingWriteTLS)
		{
			if ([self usingSecureTransportForTLS] && lastSSLHandshakeError == errSSLWouldBlock)
			{
				// We are in the process of a SSL Handshake.
				// We were waiting for incoming data which has just arrived.
				
				[self ssl_continueSSLHandshake];
			}
		}
		else
		{
			// We are still waiting for the writeQueue to drain and start the SSL/TLS process.
			// We now know data is available to read.
			
			if (![self usingCFStreamForTLS])
			{
				// Suspend the read source or else it will continue to fire nonstop.
				// 这里会先将 ReadSource 挂起··如果不暂停，读取源可能会不断触发，导致不必要的资源消耗和处理。
				[self suspendReadSource];
			}
		}
		
		return;
	}
	
	BOOL done        = NO;  // Completed read operation
	NSError *error   = nil; // Error occurred
	
	NSUInteger totalBytesReadForCurrentRead = 0;
	
	// 
	// STEP 1 - READ FROM PREBUFFER
	// 先从缓冲区 PREBUFFER 读取
	
	if ([preBuffer availableBytes] > 0)
	{
		// There are 3 types of read packets:
		// 
		// 1) Read all available data.
		// 2) Read a specific length of data.
		// 3) Read up to a particular terminator.
		
		NSUInteger bytesToCopy;
		
		if (currentRead->term != nil)
		{
			// Read type #3 - read up to a terminator
			// 从 preBuffer 读取标记为 currentRead->term 为止，不能超过 preBuffer 的最大，返回可读取的大小
			bytesToCopy = [currentRead readLengthForTermWithPreBuffer:preBuffer found:&done];
		}
		else
		{
			// Read type #1 or #2
			
            /*
            * 对于没有设置终止符的读取包，它返回可以读取的数据量，而不会超过 readLength 或 maxLength。
            * 给定的参数表示估计在套接字上可用的字节数，这在计算过程中会被考虑。给定的提示必须大于零。
             */
            
            // 返回了 currentRead 可以读区的数量
			bytesToCopy = [currentRead readLengthForNonTermWithHint:[preBuffer availableBytes]];
		}
		
		// Make sure we have enough room in the buffer for our read.
		// 确保能放的下··不能就扩容
		[currentRead ensureCapacityForAdditionalDataOfLength:bytesToCopy];
		
		// Copy bytes from prebuffer into packet buffer
		
        // 
        
        /**
         •    创建指向目标缓冲区的指针：
         •    uint8_t *buffer：定义一个指向无符号8位整数（即字节）的指针。这个指针将用于访问目标缓冲区中的位置。
         •    (uint8_t *)[currentRead->buffer mutableBytes]：[currentRead->buffer mutableBytes] 返回一个指向当前读取操作的目标缓冲区（currentRead->buffer）的可变字节指针。此指针被强制转换为 uint8_t * 类型，以便可以按字节操作。
         •    currentRead->startOffset：这是当前读取操作在目标缓冲区中的起始偏移量。它表示应当将数据写入缓冲区的起始位置。
         •    currentRead->bytesDone：表示在当前读取操作中已经完成的字节数。这个值用于计算下一个要写入的缓冲区位置。
         •    指针运算：
         •    buffer 指针的最终值是目标缓冲区（currentRead->buffer）的起始地址，加上 startOffset 和 bytesDone。这意味着数据将被写入缓冲区中尚未使用的部分，从 startOffset + bytesDone 位置开始。
         */
        
        // buffer 是currentRead 上可读的起始位置的计算
        
		uint8_t *buffer = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset + currentRead->bytesDone;
		
        //  从 preBuffer的 readBuffer 中，拷贝数据，数据大小是bytesToCopy ，到buffer 所指的内存地址上
        
		memcpy(buffer, [preBuffer readBuffer], bytesToCopy);
		
		// Remove the copied bytes from the preBuffer
        // 标记已读内容
		[preBuffer didRead:bytesToCopy];
		
		LogVerbose(@"copied(%lu) preBufferLength(%zu)", (unsigned long)bytesToCopy, [preBuffer availableBytes]);
		
		// Update totals
		
        // 当前已读
		currentRead->bytesDone += bytesToCopy;
		totalBytesReadForCurrentRead += bytesToCopy;
		
		// Check to see if the read operation is done
        //判断是不是读完了
		if (currentRead->readLength > 0)
		{
			// Read type #2 - read a specific length of data
			
			done = (currentRead->bytesDone == currentRead->readLength);
		}
        //判断界限标记
		else if (currentRead->term != nil)
		{
			// Read type #3 - read up to a terminator
			
			// Our 'done' variable was updated via the readLengthForTermWithPreBuffer:found: method
            //如果没做完，且读的最大长度大于0，去判断是否溢出
			if (!done && currentRead->maxLength > 0)
			{
				// We're not done and there's a set maxLength.
				// Have we reached that maxLength yet?
                //如果已读的大小大于最大的大小，则报溢出错误
				if (currentRead->bytesDone >= currentRead->maxLength)
				{
					error = [self readMaxedOutError];
				}
			}
		}
		else
		{
			// Read type #1 - read all available data
			// 
			// We're done as soon as
			// - we've read all available data (in prebuffer and socket)
			// - we've read the maxLength of read packet.
            // 判断已读大小和最大大小是否相同，相同则读完
			done = ((currentRead->maxLength > 0) && (currentRead->bytesDone == currentRead->maxLength));
		}
		
	}
	
	// 
	// STEP 2 - READ FROM SOCKET
	//
    // 这里是直接从 SOCKET 来读取
	
	BOOL socketEOF = (flags & kSocketHasReadEOF) ? YES : NO;  // Nothing more to read via socket (end of file)
	BOOL waiting   = !done && !error && !socketEOF && !hasBytesAvailable; // Ran out of data, waiting for more
	
    //如果没完成，且没错，没读到结尾，有可读数据
	if (!done && !error && !socketEOF && hasBytesAvailable)
	{
		NSAssert(([preBuffer availableBytes] == 0), @"Invalid logic");
		
		BOOL readIntoPreBuffer = NO;
		uint8_t *buffer = NULL;
		size_t bytesRead = 0;
		
        // 当前消息处于 ssl/tsl 加密
		if (flags & kSocketSecure)
		{
            // 如果使用的是 CFStream 方式
			if ([self usingCFStreamForTLS])
			{
//				#if TARGET_OS_IPHONE
				
				// Using CFStream, rather than SecureTransport, for TLS
				
				NSUInteger defaultReadLength = (1024 * 32);
				
                // 获取可以读区的大小，并且得知是否需要先将数据写入缓冲区
				NSUInteger bytesToRead = [currentRead optimalReadLengthWithDefault:defaultReadLength
				                                                   shouldPreBuffer:&readIntoPreBuffer];
				
				// Make sure we have enough room in the buffer for our read.
				//
				// We are either reading directly into the currentRead->buffer,
				// or we're reading into the temporary preBuffer.
				
                // 如果需要先写入缓冲区
				if (readIntoPreBuffer)
				{   // 先扩容
					[preBuffer ensureCapacityForWrite:bytesToRead];
					// 获取写入的指针地址
					buffer = [preBuffer writeBuffer];
				}
				else
				{
                    // 看看能不能塞下，塞不下也扩容
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesToRead];
					// 或许直接可以写下的指针地址
					buffer = (uint8_t *)[currentRead->buffer mutableBytes]
					       + currentRead->startOffset
					       + currentRead->bytesDone;
				}
				
				// Read data into buffer
				// 通过 CFReadStreamRead ，从 readStream 读取 bytesToRead 大小到 buffer 指针中
				CFIndex result = CFReadStreamRead(readStream, buffer, (CFIndex)bytesToRead);
				LogVerbose(@"CFReadStreamRead(): result = %i", (int)result);
				
				if (result < 0)
				{
					error = (__bridge_transfer NSError *)CFReadStreamCopyError(readStream);
				}
				else if (result == 0)
				{
					socketEOF = YES;
				}
				else
				{
					waiting = YES;
					bytesRead = (size_t)result;
				}
				
				// We only know how many decrypted bytes were read.
				// The actual number of bytes read was likely more due to the overhead of the encryption.
				// So we reset our flag, and rely on the next callback to alert us of more data.
				flags &= ~kSecureSocketHasBytesAvailable;
				
//				#endif
			}
			else
			{
				// Using SecureTransport for TLS
				//
				// We know:
				// - how many bytes are available on the socket
				// - how many encrypted bytes are sitting in the sslPreBuffer
				// - how many decypted bytes are sitting in the sslContext
				//
				// But we do NOT know:
				// - how many encypted bytes are sitting in the sslContext
				//
				// So we play the regular game of using an upper bound instead.
				
				NSUInteger defaultReadLength = (1024 * 32);
				
				if (defaultReadLength < estimatedBytesAvailable) {
					defaultReadLength = estimatedBytesAvailable + (1024 * 16);
				}
				
				NSUInteger bytesToRead = [currentRead optimalReadLengthWithDefault:defaultReadLength
				                                                   shouldPreBuffer:&readIntoPreBuffer];
				
				if (bytesToRead > SIZE_MAX) { // NSUInteger may be bigger than size_t
					bytesToRead = SIZE_MAX;
				}
				
				// Make sure we have enough room in the buffer for our read.
				//
				// We are either reading directly into the currentRead->buffer,
				// or we're reading into the temporary preBuffer.
				
				if (readIntoPreBuffer)
				{
					[preBuffer ensureCapacityForWrite:bytesToRead];
					
					buffer = [preBuffer writeBuffer];
				}
				else
				{
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesToRead];
					
					buffer = (uint8_t *)[currentRead->buffer mutableBytes]
					       + currentRead->startOffset
					       + currentRead->bytesDone;
				}
				
                // 和上面相似，
				// The documentation from Apple states:
				// 
				//     "a read operation might return errSSLWouldBlock,
				//      indicating that less data than requested was actually transferred"
				// 
				// However, starting around 10.7, the function will sometimes return noErr,
				// even if it didn't read as much data as requested. So we need to watch out for that.
				
                // 一直从 sslContext 中读取数据，指到读完为止，这里加个while 循环读取，是因为苹果说 SSLRead 返回的数据可能小于我们想要读区的数据
				OSStatus result;
				do
				{
					void *loop_buffer = buffer + bytesRead;
					size_t loop_bytesToRead = (size_t)bytesToRead - bytesRead;
					size_t loop_bytesRead = 0;
					
					result = SSLRead(sslContext, loop_buffer, loop_bytesToRead, &loop_bytesRead);
					LogVerbose(@"read from secure socket = %u", (unsigned)loop_bytesRead);
					
					bytesRead += loop_bytesRead;
					
				} while ((result == noErr) && (bytesRead < bytesToRead));
				
                
				// 读完以后的错误判断
				if (result != noErr)
				{
					if (result == errSSLWouldBlock)
						waiting = YES;
					else
					{
						if (result == errSSLClosedGraceful || result == errSSLClosedAbort)
						{
							// We've reached the end of the stream.
							// Handle this the same way we would an EOF from the socket.
							socketEOF = YES;
							sslErrCode = result;
						}
						else
						{
							error = [self sslError:result];
						}
					}
					// It's possible that bytesRead > 0, even if the result was errSSLWouldBlock.
					// This happens when the SSLRead function is able to read some data,
					// but not the entire amount we requested.
					
					if (bytesRead <= 0)
					{
						bytesRead = 0;
					}
				}
				
				// Do not modify socketFDBytesAvailable.
				// It will be updated via the SSLReadFunction().
			}
		}
		else
		{
			// Normal socket operation
			
			NSUInteger bytesToRead;
			
			// There are 3 types of read packets:
			//
			// 1) Read all available data.
			// 2) Read a specific length of data.
			// 3) Read up to a particular terminator.
			
			if (currentRead->term != nil)
			{
				// Read type #3 - read up to a terminator
				
				bytesToRead = [currentRead readLengthForTermWithHint:estimatedBytesAvailable
				                                     shouldPreBuffer:&readIntoPreBuffer];
			}
			else
			{
				// Read type #1 or #2
				
				bytesToRead = [currentRead readLengthForNonTermWithHint:estimatedBytesAvailable];
			}
			
			if (bytesToRead > SIZE_MAX) { // NSUInteger may be bigger than size_t (read param 3)
				bytesToRead = SIZE_MAX;
			}
			
			// Make sure we have enough room in the buffer for our read.
			//
			// We are either reading directly into the currentRead->buffer,
			// or we're reading into the temporary preBuffer.
			
			if (readIntoPreBuffer)
			{
				[preBuffer ensureCapacityForWrite:bytesToRead];
				
				buffer = [preBuffer writeBuffer];
			}
			else
			{
				[currentRead ensureCapacityForAdditionalDataOfLength:bytesToRead];
				
				buffer = (uint8_t *)[currentRead->buffer mutableBytes]
				       + currentRead->startOffset
				       + currentRead->bytesDone;
			}
			
			// Read data into buffer
            
            // 逻辑相同
			
			int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
            
            // 直接通过 read 从 socketFD 读取数据
			
			ssize_t result = read(socketFD, buffer, (size_t)bytesToRead);
			LogVerbose(@"read from socket = %i", (int)result);
			
			if (result < 0)
			{
				if (errno == EWOULDBLOCK)
					waiting = YES;
				else
					error = [self errorWithErrno:errno reason:@"Error in read() function"];
				
				socketFDBytesAvailable = 0;
			}
			else if (result == 0)
			{
				socketEOF = YES;
				socketFDBytesAvailable = 0;
			}
			else
			{
				bytesRead = result;
				
				if (bytesRead < bytesToRead)
				{
					// The read returned less data than requested.
					// This means socketFDBytesAvailable was a bit off due to timing,
					// because we read from the socket right when the readSource event was firing.
					socketFDBytesAvailable = 0;
				}
				else
				{
					if (socketFDBytesAvailable <= bytesRead)
						socketFDBytesAvailable = 0;
					else
						socketFDBytesAvailable -= bytesRead;
				}
				
				if (socketFDBytesAvailable == 0)
				{
					waiting = YES;
				}
			}
		}
		
		if (bytesRead > 0)
		{
			// Check to see if the read operation is done
            // 检查读取操作是否完成
			
			if (currentRead->readLength > 0)
			{
				// Read type #2 - read a specific length of data
				// 
				// Note: We should never be using a prebuffer when we're reading a specific length of data.
				
				NSAssert(readIntoPreBuffer == NO, @"Invalid logic");
				
				currentRead->bytesDone += bytesRead;
				totalBytesReadForCurrentRead += bytesRead;
                
                // 判断是否读取完成
				
				done = (currentRead->bytesDone == currentRead->readLength);
			}
			else if (currentRead->term != nil)
			{
				// Read type #3 - read up to a terminator
				
                // 需要从缓存区读取数据到 currentRead 里面
				if (readIntoPreBuffer)
				{
					// We just read a big chunk of data into the preBuffer
					// 更新已读数据
					[preBuffer didWrite:bytesRead];
                    
					LogVerbose(@"read data into preBuffer - preBuffer.length = %zu", [preBuffer availableBytes]);
					
					// Search for the terminating sequence
					// 去 preBuffer 里面找下终止符 
//                    对于设置了终止符的读取包，这段代码返回从给定的预缓冲区中可以读取的数据量，不会超过终止符或最大长度。
//                    假定终止符尚未被读取。
                    
					NSUInteger bytesToCopy = [currentRead readLengthForTermWithPreBuffer:preBuffer found:&done];
                    
                    
					LogVerbose(@"copying %lu bytes from preBuffer", (unsigned long)bytesToCopy);
					
					// Ensure there's room on the read packet's buffer
					// 扩充
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesToCopy];
					
					// Copy bytes from prebuffer into read buffer
					
                    // 获取新数据写入的指针地址
					uint8_t *readBuf = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset
					                                                                 + currentRead->bytesDone;
					// copy 过来
                    // 这里就是直接从 preBuffer 拷贝到 readBuf里了，上面的都是先拷贝到preBuffer缓冲区或者是直接拷贝到 readBuf。
                    
					memcpy(readBuf, [preBuffer readBuffer], bytesToCopy);
					
                    // 更新已读数据
					// Remove the copied bytes from the prebuffer
					[preBuffer didRead:bytesToCopy];
					LogVerbose(@"preBuffer.length = %zu", [preBuffer availableBytes]);
					
					// Update totals
					currentRead->bytesDone += bytesToCopy;
					totalBytesReadForCurrentRead += bytesToCopy;
					
					// Our 'done' variable was updated via the readLengthForTermWithPreBuffer:found: method above
				}
				else
				{
					// We just read a big chunk of data directly into the packet's buffer.
					// We need to move any overflow into the prebuffer.
					
					NSInteger overflow = [currentRead searchForTermAfterPreBuffering:bytesRead];
					
					if (overflow == 0)
					{
						// Perfect match!
						// Every byte we read stays in the read buffer,
						// and the last byte we read was the last byte of the term.
						
						currentRead->bytesDone += bytesRead;
						totalBytesReadForCurrentRead += bytesRead;
						done = YES;
					}
					else if (overflow > 0)
					{
                        // 在 currentRead 数据中找到终止符，但是后面还有数据，需要将溢出数据，转移到 preBuffer 中，
                        
						// The term was found within the data that we read,
						// and there are extra bytes that extend past the end of the term.
						// We need to move these excess bytes out of the read packet and into the prebuffer.
						
						NSInteger underflow = bytesRead - overflow;
						
						// Copy excess data into preBuffer
						
						LogVerbose(@"copying %ld overflow bytes into preBuffer", (long)overflow);
						[preBuffer ensureCapacityForWrite:overflow];
						
						uint8_t *overflowBuffer = buffer + underflow;
						memcpy([preBuffer writeBuffer], overflowBuffer, overflow);
						
						[preBuffer didWrite:overflow];
						LogVerbose(@"preBuffer.length = %zu", [preBuffer availableBytes]);
						
						// Note: The completeCurrentRead method will trim the buffer for us.
						
						currentRead->bytesDone += underflow;
						totalBytesReadForCurrentRead += underflow;
						done = YES;
					 }
					else
					{
						// The term was not found within the data that we read.
						
						currentRead->bytesDone += bytesRead;
						totalBytesReadForCurrentRead += bytesRead;
						done = NO;
					}
				}
				
				if (!done && currentRead->maxLength > 0)
				{
					// We're not done and there's a set maxLength.
					// Have we reached that maxLength yet?
					
					if (currentRead->bytesDone >= currentRead->maxLength)
					{
						error = [self readMaxedOutError];
					}
				}
			}
			else
			{
				// Read type #1 - read all available data
				
                // 处理没有特定长度或终止符的读取操作：
                
				if (readIntoPreBuffer)
				{
					// We just read a chunk of data into the preBuffer
					
					[preBuffer didWrite:bytesRead];
					
					// Now copy the data into the read packet.
					// 
					// Recall that we didn't read directly into the packet's buffer to avoid
					// over-allocating memory since we had no clue how much data was available to be read.
					// 
					// Ensure there's room on the read packet's buffer
					
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesRead];
					
					// Copy bytes from prebuffer into read buffer
					
					uint8_t *readBuf = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset
					                                                                 + currentRead->bytesDone;
					
                    // 从 preBuffer 读取到 readBuf 中
					memcpy(readBuf, [preBuffer readBuffer], bytesRead);
					
					// Remove the copied bytes from the prebuffer
					[preBuffer didRead:bytesRead];
					
					// Update totals
					currentRead->bytesDone += bytesRead;
					totalBytesReadForCurrentRead += bytesRead;
				}
				else
				{
					currentRead->bytesDone += bytesRead;
					totalBytesReadForCurrentRead += bytesRead;
				}
				
				done = YES;
			}
			
		} // if (bytesRead > 0)
		
	} // if (!done && !error && !socketEOF && hasBytesAvailable)
	
	
	if (!done && currentRead->readLength == 0 && currentRead->term == nil)
	{
		// Read type #1 - read all available data
		// 
		// We might arrive here if we read data from the prebuffer but not from the socket.
		
		done = (totalBytesReadForCurrentRead > 0);
	}
	
	// Check to see if we're done, or if we've made progress
	
    // 读取完成
	if (done)
	{
		[self completeCurrentRead];
		
		if (!error && (!socketEOF || [preBuffer availableBytes] > 0))
		{
			[self maybeDequeueRead];
		}
	}
	else if (totalBytesReadForCurrentRead > 0)
	{
		// We're not done read type #2 or #3 yet, but we have read in some bytes
		//
		// We ensure that `waiting` is set in order to resume the readSource (if it is suspended). It is
		// possible to reach this point and `waiting` not be set, if the current read's length is
		// sufficiently large. In that case, we may have read to some upperbound successfully, but
		// that upperbound could be smaller than the desired length.
		waiting = YES;

		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
		
		if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:didReadPartialDataOfLength:tag:)])
		{
			long theReadTag = currentRead->tag;
			
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socket:self didReadPartialDataOfLength:totalBytesReadForCurrentRead tag:theReadTag];
			}});
		}
	}
	
	// Check for errors
	
	if (error)
	{
		[self closeWithError:error];
	}
	else if (socketEOF)
	{
		[self doReadEOF];
	}
	else if (waiting)
	{
		if (![self usingCFStreamForTLS])
		{
			// Monitor the socket for readability (if we're not already doing so)
			[self resumeReadSource];
		}
	}
	
	// Do not add any code here without first adding return statements in the error cases above.
}

- (void)doReadEOF
{
	LogTrace();
	
	// This method may be called more than once.
	// If the EOF is read while there is still data in the preBuffer,
	// then this method may be called continually after invocations of doReadData to see if it's time to disconnect.
	
	flags |= kSocketHasReadEOF;
	
	if (flags & kSocketSecure)
	{
		// If the SSL layer has any buffered data, flush it into the preBuffer now.
		
		[self flushSSLBuffers];
	}
	
	BOOL shouldDisconnect = NO;
	NSError *error = nil;
	
	if ((flags & kStartingReadTLS) || (flags & kStartingWriteTLS))
	{
		// We received an EOF during or prior to startTLS.
		// The SSL/TLS handshake is now impossible, so this is an unrecoverable situation.
		
		shouldDisconnect = YES;
		
		if ([self usingSecureTransportForTLS])
		{
			error = [self sslError:errSSLClosedAbort];
		}
	}
	else if (flags & kReadStreamClosed)
	{
		// The preBuffer has already been drained.
		// The config allows half-duplex connections.
		// We've previously checked the socket, and it appeared writeable.
		// So we marked the read stream as closed and notified the delegate.
		// 
		// As per the half-duplex contract, the socket will be closed when a write fails,
		// or when the socket is manually closed.
		
		shouldDisconnect = NO;
	}
	else if ([preBuffer availableBytes] > 0)
	{
		LogVerbose(@"Socket reached EOF, but there is still data available in prebuffer");
		
		// Although we won't be able to read any more data from the socket,
		// there is existing data that has been prebuffered that we can read.
		
		shouldDisconnect = NO;
	}
	else if (config & kAllowHalfDuplexConnection)
	{
		// We just received an EOF (end of file) from the socket's read stream.
		// This means the remote end of the socket (the peer we're connected to)
		// has explicitly stated that it will not be sending us any more data.
		// 
		// Query the socket to see if it is still writeable. (Perhaps the peer will continue reading data from us)
		
		int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
		
		struct pollfd pfd[1];
		pfd[0].fd = socketFD;
		pfd[0].events = POLLOUT;
		pfd[0].revents = 0;
		
		poll(pfd, 1, 0);
		
		if (pfd[0].revents & POLLOUT)
		{
			// Socket appears to still be writeable
			
			shouldDisconnect = NO;
			flags |= kReadStreamClosed;
			
			// Notify the delegate that we're going half-duplex
			
			__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

			if (delegateQueue && [theDelegate respondsToSelector:@selector(socketDidCloseReadStream:)])
			{
				dispatch_async(delegateQueue, ^{ @autoreleasepool {
					
					[theDelegate socketDidCloseReadStream:self];
				}});
			}
		}
		else
		{
			shouldDisconnect = YES;
		}
	}
	else
	{
		shouldDisconnect = YES;
	}
	
	
	if (shouldDisconnect)
	{
		if (error == nil)
		{
			if ([self usingSecureTransportForTLS])
			{
				if (sslErrCode != noErr && sslErrCode != errSSLClosedGraceful)
				{
					error = [self sslError:sslErrCode];
				}
				else
				{
					error = [self connectionClosedError];
				}
			}
			else
			{
				error = [self connectionClosedError];
			}
		}
		[self closeWithError:error];
	}
	else
	{
		if (![self usingCFStreamForTLS])
		{
			// Suspend the read source (if needed)
			
			[self suspendReadSource];
		}
	}
}

- (void)completeCurrentRead
{
	LogTrace();
	
	NSAssert(currentRead, @"Trying to complete current read when there is no current read.");
	
	
	NSData *result = nil;
	
	if (currentRead->bufferOwner)
	{
		// We created the buffer on behalf of the user.
		// Trim our buffer to be the proper size.
		[currentRead->buffer setLength:currentRead->bytesDone];
		
		result = currentRead->buffer;
	}
	else
	{
		// We did NOT create the buffer.
		// The buffer is owned by the caller.
		// Only trim the buffer if we had to increase its size.
		
		if ([currentRead->buffer length] > currentRead->originalBufferLength)
		{
			NSUInteger readSize = currentRead->startOffset + currentRead->bytesDone;
			NSUInteger origSize = currentRead->originalBufferLength;
			
			NSUInteger buffSize = MAX(readSize, origSize);
			
			[currentRead->buffer setLength:buffSize];
		}
		
		uint8_t *buffer = (uint8_t *)[currentRead->buffer mutableBytes] + currentRead->startOffset;
		
		result = [NSData dataWithBytesNoCopy:buffer length:currentRead->bytesDone freeWhenDone:NO];
	}
	
	__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

	if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:didReadData:withTag:)])
	{
		GCDAsyncReadPacket *theRead = currentRead; // Ensure currentRead retained since result may not own buffer
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didReadData:result withTag:theRead->tag];
		}});
	}
	
	[self endCurrentRead];
}

- (void)endCurrentRead
{
	if (readTimer)
	{
		dispatch_source_cancel(readTimer);
		readTimer = NULL;
	}
	
	currentRead = nil;
}

- (void)setupReadTimerWithTimeout:(NSTimeInterval)timeout
{
	if (timeout >= 0.0)
	{
		readTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
		__weak GCDAsyncSocket *weakSelf = self;
		
		dispatch_source_set_event_handler(readTimer, ^{ @autoreleasepool {
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			__strong GCDAsyncSocket *strongSelf = weakSelf;
			if (strongSelf == nil) return_from_block;
			
			[strongSelf doReadTimeout];
			
		#pragma clang diagnostic pop
		}});
		
		#if !OS_OBJECT_USE_OBJC
		dispatch_source_t theReadTimer = readTimer;
		dispatch_source_set_cancel_handler(readTimer, ^{
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			LogVerbose(@"dispatch_release(readTimer)");
			dispatch_release(theReadTimer);
			
		#pragma clang diagnostic pop
		});
		#endif
		
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
		
		dispatch_source_set_timer(readTimer, tt, DISPATCH_TIME_FOREVER, 0);
		dispatch_resume(readTimer);
	}
}

- (void)doReadTimeout
{
	// This is a little bit tricky.
	// Ideally we'd like to synchronously query the delegate about a timeout extension.
	// But if we do so synchronously we risk a possible deadlock.
	// So instead we have to do so asynchronously, and callback to ourselves from within the delegate block.
	
	flags |= kReadsPaused;
	
	__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

	if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:shouldTimeoutReadWithTag:elapsed:bytesDone:)])
	{
		GCDAsyncReadPacket *theRead = currentRead;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			NSTimeInterval timeoutExtension = 0.0;
			
			timeoutExtension = [theDelegate socket:self shouldTimeoutReadWithTag:theRead->tag
			                                                             elapsed:theRead->timeout
			                                                           bytesDone:theRead->bytesDone];
			
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				[self doReadTimeoutWithExtension:timeoutExtension];
			}});
		}});
	}
	else
	{
		[self doReadTimeoutWithExtension:0.0];
	}
}

- (void)doReadTimeoutWithExtension:(NSTimeInterval)timeoutExtension
{
	if (currentRead)
	{
		if (timeoutExtension > 0.0)
		{
			currentRead->timeout += timeoutExtension;
			
			// Reschedule the timer
			dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutExtension * NSEC_PER_SEC));
			dispatch_source_set_timer(readTimer, tt, DISPATCH_TIME_FOREVER, 0);
			
			// Unpause reads, and continue
			flags &= ~kReadsPaused;
			[self doReadData];
		}
		else
		{
			LogVerbose(@"ReadTimeout");
			
			[self closeWithError:[self readTimeoutError]];
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Writing
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)writeData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	if ([data length] == 0) return;
	
	GCDAsyncWritePacket *packet = [[GCDAsyncWritePacket alloc] initWithData:data timeout:timeout tag:tag];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
		LogTrace();
		
        if ((self->flags & kSocketStarted) && !(self->flags & kForbidReadsWrites))
		{
            [self->writeQueue addObject:packet];
			[self maybeDequeueWrite];
		}
	}});
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
}

- (float)progressOfWriteReturningTag:(long *)tagPtr bytesDone:(NSUInteger *)donePtr total:(NSUInteger *)totalPtr
{
	__block float result = 0.0F;
	
	dispatch_block_t block = ^{
		
        if (!self->currentWrite || ![self->currentWrite isKindOfClass:[GCDAsyncWritePacket class]])
		{
			// We're not writing anything right now.
			
			if (tagPtr != NULL)   *tagPtr = 0;
			if (donePtr != NULL)  *donePtr = 0;
			if (totalPtr != NULL) *totalPtr = 0;
			
			result = NAN;
		}
		else
		{
            NSUInteger done = self->currentWrite->bytesDone;
            NSUInteger total = [self->currentWrite->buffer length];
			
            if (tagPtr != NULL)   *tagPtr = self->currentWrite->tag;
			if (donePtr != NULL)  *donePtr = done;
			if (totalPtr != NULL) *totalPtr = total;
			
			result = (float)done / (float)total;
		}
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}

/**
 * Conditionally starts a new write.
 * 
 * It is called when:
 * - a user requests a write
 * - after a write request has finished (to handle the next request)
 * - immediately after the socket opens to handle any pending requests
 * 
 * This method also handles auto-disconnect post read/write completion.
**/
- (void)maybeDequeueWrite
{
	LogTrace();
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	// If we're not currently processing a write AND we have an available write stream
	if ((currentWrite == nil) && (flags & kConnected))
	{
		if ([writeQueue count] > 0)
		{
			// Dequeue the next object in the write queue
			currentWrite = [writeQueue objectAtIndex:0];
			[writeQueue removeObjectAtIndex:0];
			
			
			if ([currentWrite isKindOfClass:[GCDAsyncSpecialPacket class]])
			{
				LogVerbose(@"Dequeued GCDAsyncSpecialPacket");
				
				// Attempt to start TLS
				flags |= kStartingWriteTLS;
				
				// This method won't do anything unless both kStartingReadTLS and kStartingWriteTLS are set
				[self maybeStartTLS];
			}
			else
			{
				LogVerbose(@"Dequeued GCDAsyncWritePacket");
				
				// Setup write timer (if needed)
				[self setupWriteTimerWithTimeout:currentWrite->timeout];
				
				// Immediately write, if possible
				[self doWriteData];
			}
		}
		else if (flags & kDisconnectAfterWrites)
		{
			if (flags & kDisconnectAfterReads)
			{
				if (([readQueue count] == 0) && (currentRead == nil))
				{
					[self closeWithError:nil];
				}
			}
			else
			{
				[self closeWithError:nil];
			}
		}
	}
}

- (void)doWriteData
{
	LogTrace();
	
	// This method is called by the writeSource via the socketQueue
	
	if ((currentWrite == nil) || (flags & kWritesPaused))
	{
		LogVerbose(@"No currentWrite or kWritesPaused");
		
		// Unable to write at this time
		
		if ([self usingCFStreamForTLS])
		{
			// CFWriteStream only fires once when there is available data.
			// It won't fire again until we've invoked CFWriteStreamWrite.
		}
		else
		{
			// If the writeSource is firing, we need to pause it
			// or else it will continue to fire over and over again.
			
			if (flags & kSocketCanAcceptBytes)
			{
				[self suspendWriteSource];
			}
		}
		return;
	}
	
	if (!(flags & kSocketCanAcceptBytes))
	{
		LogVerbose(@"No space available to write...");
		
		// No space available to write.
		
		if (![self usingCFStreamForTLS])
		{
			// Need to wait for writeSource to fire and notify us of
			// available space in the socket's internal write buffer.
			
			[self resumeWriteSource];
		}
		return;
	}
	
	if (flags & kStartingWriteTLS)
	{
		LogVerbose(@"Waiting for SSL/TLS handshake to complete");
		
		// The writeQueue is waiting for SSL/TLS handshake to complete.
		
		if (flags & kStartingReadTLS)
		{
			if ([self usingSecureTransportForTLS] && lastSSLHandshakeError == errSSLWouldBlock)
			{
				// We are in the process of a SSL Handshake.
				// We were waiting for available space in the socket's internal OS buffer to continue writing.
			
				[self ssl_continueSSLHandshake];
			}
		}
		else
		{
			// We are still waiting for the readQueue to drain and start the SSL/TLS process.
			// We now know we can write to the socket.
			
			if (![self usingCFStreamForTLS])
			{
				// Suspend the write source or else it will continue to fire nonstop.
				
				[self suspendWriteSource];
			}
		}
		
		return;
	}
	
	// Note: This method is not called if currentWrite is a GCDAsyncSpecialPacket (startTLS packet)
	
	BOOL waiting = NO;
	NSError *error = nil;
	size_t bytesWritten = 0;
	
	if (flags & kSocketSecure)
	{
		if ([self usingCFStreamForTLS])
		{
//			#if TARGET_OS_IPHONE
			
			// 
			// Writing data using CFStream (over internal TLS)
			// 
			
			const uint8_t *buffer = (const uint8_t *)[currentWrite->buffer bytes] + currentWrite->bytesDone;
			
			NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone;
			
			if (bytesToWrite > SIZE_MAX) // NSUInteger may be bigger than size_t (write param 3)
			{
				bytesToWrite = SIZE_MAX;
			}
		
			CFIndex result = CFWriteStreamWrite(writeStream, buffer, (CFIndex)bytesToWrite);
			LogVerbose(@"CFWriteStreamWrite(%lu) = %li", (unsigned long)bytesToWrite, result);
		
			if (result < 0)
			{
				error = (__bridge_transfer NSError *)CFWriteStreamCopyError(writeStream);
			}
			else
			{
				bytesWritten = (size_t)result;
				
				// We always set waiting to true in this scenario.
				// CFStream may have altered our underlying socket to non-blocking.
				// Thus if we attempt to write without a callback, we may end up blocking our queue.
				waiting = YES;
			}
			
//			#endif
		}
		else
		{
			// We're going to use the SSLWrite function.
			// 
			// OSStatus SSLWrite(SSLContextRef context, const void *data, size_t dataLength, size_t *processed)
			// 
			// Parameters:
			// context     - An SSL session context reference.
			// data        - A pointer to the buffer of data to write.
			// dataLength  - The amount, in bytes, of data to write.
			// processed   - On return, the length, in bytes, of the data actually written.
			// 
			// It sounds pretty straight-forward,
			// but there are a few caveats you should be aware of.
			// 
			// The SSLWrite method operates in a non-obvious (and rather annoying) manner.
			// According to the documentation:
			// 
			//   Because you may configure the underlying connection to operate in a non-blocking manner,
			//   a write operation might return errSSLWouldBlock, indicating that less data than requested
			//   was actually transferred. In this case, you should repeat the call to SSLWrite until some
			//   other result is returned.
			// 
			// This sounds perfect, but when our SSLWriteFunction returns errSSLWouldBlock,
			// then the SSLWrite method returns (with the proper errSSLWouldBlock return value),
			// but it sets processed to dataLength !!
			// 
			// In other words, if the SSLWrite function doesn't completely write all the data we tell it to,
			// then it doesn't tell us how many bytes were actually written. So, for example, if we tell it to
			// write 256 bytes then it might actually write 128 bytes, but then report 0 bytes written.
			// 
			// You might be wondering:
			// If the SSLWrite function doesn't tell us how many bytes were written,
			// then how in the world are we supposed to update our parameters (buffer & bytesToWrite)
			// for the next time we invoke SSLWrite?
			// 
			// The answer is that SSLWrite cached all the data we told it to write,
			// and it will push out that data next time we call SSLWrite.
			// If we call SSLWrite with new data, it will push out the cached data first, and then the new data.
			// If we call SSLWrite with empty data, then it will simply push out the cached data.
			// 
			// For this purpose we're going to break large writes into a series of smaller writes.
			// This allows us to report progress back to the delegate.
			
			OSStatus result;
			
			BOOL hasCachedDataToWrite = (sslWriteCachedLength > 0);
			BOOL hasNewDataToWrite = YES;
			
			if (hasCachedDataToWrite)
			{
				size_t processed = 0;
				
				result = SSLWrite(sslContext, NULL, 0, &processed);
				
				if (result == noErr)
				{
					bytesWritten = sslWriteCachedLength;
					sslWriteCachedLength = 0;
					
					if ([currentWrite->buffer length] == (currentWrite->bytesDone + bytesWritten))
					{
						// We've written all data for the current write.
						hasNewDataToWrite = NO;
					}
				}
				else
				{
					if (result == errSSLWouldBlock)
					{
						waiting = YES;
					}
					else
					{
						error = [self sslError:result];
					}
					
					// Can't write any new data since we were unable to write the cached data.
					hasNewDataToWrite = NO;
				}
			}
			
			if (hasNewDataToWrite)
			{
				const uint8_t *buffer = (const uint8_t *)[currentWrite->buffer bytes]
				                                        + currentWrite->bytesDone
				                                        + bytesWritten;
				
				NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone - bytesWritten;
				
				if (bytesToWrite > SIZE_MAX) // NSUInteger may be bigger than size_t (write param 3)
				{
					bytesToWrite = SIZE_MAX;
				}
				
				size_t bytesRemaining = bytesToWrite;
				
				BOOL keepLooping = YES;
				while (keepLooping)
				{
					const size_t sslMaxBytesToWrite = 32768;
					size_t sslBytesToWrite = MIN(bytesRemaining, sslMaxBytesToWrite);
					size_t sslBytesWritten = 0;
					
					result = SSLWrite(sslContext, buffer, sslBytesToWrite, &sslBytesWritten);
					
					if (result == noErr)
					{
						buffer += sslBytesWritten;
						bytesWritten += sslBytesWritten;
						bytesRemaining -= sslBytesWritten;
						
						keepLooping = (bytesRemaining > 0);
					}
					else
					{
						if (result == errSSLWouldBlock)
						{
							waiting = YES;
							sslWriteCachedLength = sslBytesToWrite;
						}
						else
						{
							error = [self sslError:result];
						}
						
						keepLooping = NO;
					}
					
				} // while (keepLooping)
				
			} // if (hasNewDataToWrite)
		}
	}
	else
	{
		// 
		// Writing data directly over raw socket
		// 
		
		int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
		
		const uint8_t *buffer = (const uint8_t *)[currentWrite->buffer bytes] + currentWrite->bytesDone;
		
		NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone;
		
		if (bytesToWrite > SIZE_MAX) // NSUInteger may be bigger than size_t (write param 3)
		{
			bytesToWrite = SIZE_MAX;
		}
		
		ssize_t result = write(socketFD, buffer, (size_t)bytesToWrite);
		LogVerbose(@"wrote to socket = %zd", result);
		
		// Check results
		if (result < 0)
		{
			if (errno == EWOULDBLOCK)
			{
				waiting = YES;
			}
			else
			{
				error = [self errorWithErrno:errno reason:@"Error in write() function"];
			}
		}
		else
		{
			bytesWritten = result;
		}
	}
	
	// We're done with our writing.
	// If we explictly ran into a situation where the socket told us there was no room in the buffer,
	// then we immediately resume listening for notifications.
	// 
	// We must do this before we dequeue another write,
	// as that may in turn invoke this method again.
	// 
	// Note that if CFStream is involved, it may have maliciously put our socket in blocking mode.
	
	if (waiting)
	{
		flags &= ~kSocketCanAcceptBytes;
		
		if (![self usingCFStreamForTLS])
		{
			[self resumeWriteSource];
		}
	}
	
	// Check our results
	
	BOOL done = NO;
	
	if (bytesWritten > 0)
	{
		// Update total amount read for the current write
		currentWrite->bytesDone += bytesWritten;
		LogVerbose(@"currentWrite->bytesDone = %lu", (unsigned long)currentWrite->bytesDone);
		
		// Is packet done?
		done = (currentWrite->bytesDone == [currentWrite->buffer length]);
	}
	
	if (done)
	{
		[self completeCurrentWrite];
		
		if (!error)
		{
			dispatch_async(socketQueue, ^{ @autoreleasepool{
				
				[self maybeDequeueWrite];
			}});
		}
	}
	else
	{
		// We were unable to finish writing the data,
		// so we're waiting for another callback to notify us of available space in the lower-level output buffer.
		
		if (!waiting && !error)
		{
			// This would be the case if our write was able to accept some data, but not all of it.
			
			flags &= ~kSocketCanAcceptBytes;
			
			if (![self usingCFStreamForTLS])
			{
				[self resumeWriteSource];
			}
		}
		
		if (bytesWritten > 0)
		{
			// We're not done with the entire write, but we have written some bytes
			
			__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

			if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:didWritePartialDataOfLength:tag:)])
			{
				long theWriteTag = currentWrite->tag;
				
				dispatch_async(delegateQueue, ^{ @autoreleasepool {
					
					[theDelegate socket:self didWritePartialDataOfLength:bytesWritten tag:theWriteTag];
				}});
			}
		}
	}
	
	// Check for errors
	
	if (error)
	{
		[self closeWithError:[self errorWithErrno:errno reason:@"Error in write() function"]];
	}
	
	// Do not add any code here without first adding a return statement in the error case above.
}

- (void)completeCurrentWrite
{
	LogTrace();
	
	NSAssert(currentWrite, @"Trying to complete current write when there is no current write.");
	

	__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
	
	if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:didWriteDataWithTag:)])
	{
		long theWriteTag = currentWrite->tag;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			[theDelegate socket:self didWriteDataWithTag:theWriteTag];
		}});
	}
	
	[self endCurrentWrite];
}

- (void)endCurrentWrite
{
	if (writeTimer)
	{
		dispatch_source_cancel(writeTimer);
		writeTimer = NULL;
	}
	
	currentWrite = nil;
}

- (void)setupWriteTimerWithTimeout:(NSTimeInterval)timeout
{
	if (timeout >= 0.0)
	{
		writeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
		__weak GCDAsyncSocket *weakSelf = self;
		
		dispatch_source_set_event_handler(writeTimer, ^{ @autoreleasepool {
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			__strong GCDAsyncSocket *strongSelf = weakSelf;
			if (strongSelf == nil) return_from_block;
			
			[strongSelf doWriteTimeout];
			
		#pragma clang diagnostic pop
		}});
		
		#if !OS_OBJECT_USE_OBJC
		dispatch_source_t theWriteTimer = writeTimer;
		dispatch_source_set_cancel_handler(writeTimer, ^{
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			LogVerbose(@"dispatch_release(writeTimer)");
			dispatch_release(theWriteTimer);
			
		#pragma clang diagnostic pop
		});
		#endif
		
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
		
		dispatch_source_set_timer(writeTimer, tt, DISPATCH_TIME_FOREVER, 0);
		dispatch_resume(writeTimer);
	}
}

- (void)doWriteTimeout
{
	// This is a little bit tricky.
	// Ideally we'd like to synchronously query the delegate about a timeout extension.
	// But if we do so synchronously we risk a possible deadlock.
	// So instead we have to do so asynchronously, and callback to ourselves from within the delegate block.
	
	flags |= kWritesPaused;
	
	__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

	if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:shouldTimeoutWriteWithTag:elapsed:bytesDone:)])
	{
		GCDAsyncWritePacket *theWrite = currentWrite;
		
		dispatch_async(delegateQueue, ^{ @autoreleasepool {
			
			NSTimeInterval timeoutExtension = 0.0;
			
			timeoutExtension = [theDelegate socket:self shouldTimeoutWriteWithTag:theWrite->tag
			                                                              elapsed:theWrite->timeout
			                                                            bytesDone:theWrite->bytesDone];
			
            dispatch_async(self->socketQueue, ^{ @autoreleasepool {
				
				[self doWriteTimeoutWithExtension:timeoutExtension];
			}});
		}});
	}
	else
	{
		[self doWriteTimeoutWithExtension:0.0];
	}
}

- (void)doWriteTimeoutWithExtension:(NSTimeInterval)timeoutExtension
{
	if (currentWrite)
	{
		if (timeoutExtension > 0.0)
		{
			currentWrite->timeout += timeoutExtension;
			
			// Reschedule the timer
			dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutExtension * NSEC_PER_SEC));
			dispatch_source_set_timer(writeTimer, tt, DISPATCH_TIME_FOREVER, 0);
			
			// Unpause writes, and continue
			flags &= ~kWritesPaused;
			[self doWriteData];
		}
		else
		{
			LogVerbose(@"WriteTimeout");
			
			[self closeWithError:[self writeTimeoutError]];
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Security
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)startTLS:(NSDictionary *)tlsSettings
{
	LogTrace();
	
	if (tlsSettings == nil)
    {
        // Passing nil/NULL to CFReadStreamSetProperty will appear to work the same as passing an empty dictionary,
        // but causes problems if we later try to fetch the remote host's certificate.
        // 
        // To be exact, it causes the following to return NULL instead of the normal result:
        // CFReadStreamCopyProperty(readStream, kCFStreamPropertySSLPeerCertificates)
        // 
        // So we use an empty dictionary instead, which works perfectly.
        
        tlsSettings = [NSDictionary dictionary];
    }
	
	GCDAsyncSpecialPacket *packet = [[GCDAsyncSpecialPacket alloc] initWithTLSSettings:tlsSettings];
	
	dispatch_async(socketQueue, ^{ @autoreleasepool {
		
        if ((self->flags & kSocketStarted) && !(self->flags & kQueuedTLS) && !(self->flags & kForbidReadsWrites))
		{
            [self->readQueue addObject:packet];
            [self->writeQueue addObject:packet];
			
            self->flags |= kQueuedTLS;
			
			[self maybeDequeueRead];
			[self maybeDequeueWrite];
		}
	}});
	
}

- (void)maybeStartTLS
{
	// We can't start TLS until:
	// - All queued reads prior to the user calling startTLS are complete
	// - All queued writes prior to the user calling startTLS are complete
	// 
	// We'll know these conditions are met when both kStartingReadTLS and kStartingWriteTLS are set
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		BOOL useSecureTransport = YES;
		
//		#if TARGET_OS_IPHONE
		{
			GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
            NSDictionary *tlsSettings = @{};
            if (tlsPacket) {
                tlsSettings = tlsPacket->tlsSettings;
            }
			NSNumber *value = [tlsSettings objectForKey:GCDAsyncSocketUseCFStreamForTLS];
			if (value && [value boolValue])
				useSecureTransport = NO;
		}
//		#endif
		// 使用 ssl SecureTransport
		if (useSecureTransport)
		{
			[self ssl_startTLS];
		}
		else
		{
//		#if TARGET_OS_IPHONE
            // 使用oc的 cfstream , 已经过时不建议使用
			[self cf_startTLS];
//		#endif
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Security via SecureTransport
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (OSStatus)sslReadWithBuffer:(void *)buffer length:(size_t *)bufferLength
{
	LogVerbose(@"sslReadWithBuffer:%p length:%lu", buffer, (unsigned long)*bufferLength);
	
	if ((socketFDBytesAvailable == 0) && ([sslPreBuffer availableBytes] == 0))
	{
		LogVerbose(@"%@ - No data available to read...", THIS_METHOD);
		
		// No data available to read.
		// 
		// Need to wait for readSource to fire and notify us of
		// available data in the socket's internal read buffer.
		
		[self resumeReadSource];
		
		*bufferLength = 0;
		return errSSLWouldBlock;
	}
	
	size_t totalBytesRead = 0;
	size_t totalBytesLeftToBeRead = *bufferLength;
	
	BOOL done = NO;
	BOOL socketError = NO;
	
	// 
	// STEP 1 : READ FROM SSL PRE BUFFER
	// 
	
	size_t sslPreBufferLength = [sslPreBuffer availableBytes];
	
	if (sslPreBufferLength > 0)
	{
		LogVerbose(@"%@: Reading from SSL pre buffer...", THIS_METHOD);
		
		size_t bytesToCopy;
		if (sslPreBufferLength > totalBytesLeftToBeRead)
			bytesToCopy = totalBytesLeftToBeRead;
		else
			bytesToCopy = sslPreBufferLength;
		
		LogVerbose(@"%@: Copying %zu bytes from sslPreBuffer", THIS_METHOD, bytesToCopy);
		
		memcpy(buffer, [sslPreBuffer readBuffer], bytesToCopy);
		[sslPreBuffer didRead:bytesToCopy];
		
		LogVerbose(@"%@: sslPreBuffer.length = %zu", THIS_METHOD, [sslPreBuffer availableBytes]);
		
		totalBytesRead += bytesToCopy;
		totalBytesLeftToBeRead -= bytesToCopy;
		
		done = (totalBytesLeftToBeRead == 0);
		
		if (done) LogVerbose(@"%@: Complete", THIS_METHOD);
	}
	
	// 
	// STEP 2 : READ FROM SOCKET
	// 
	
	if (!done && (socketFDBytesAvailable > 0))
	{
		LogVerbose(@"%@: Reading from socket...", THIS_METHOD);
		
		int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
		
		BOOL readIntoPreBuffer;
		size_t bytesToRead;
		uint8_t *buf;
		
		if (socketFDBytesAvailable > totalBytesLeftToBeRead)
		{
			// Read all available data from socket into sslPreBuffer.
			// Then copy requested amount into dataBuffer.
			
			LogVerbose(@"%@: Reading into sslPreBuffer...", THIS_METHOD);
			
			[sslPreBuffer ensureCapacityForWrite:socketFDBytesAvailable];
			
			readIntoPreBuffer = YES;
			bytesToRead = (size_t)socketFDBytesAvailable;
			buf = [sslPreBuffer writeBuffer];
		}
		else
		{
			// Read available data from socket directly into dataBuffer.
			
			LogVerbose(@"%@: Reading directly into dataBuffer...", THIS_METHOD);
			
			readIntoPreBuffer = NO;
			bytesToRead = totalBytesLeftToBeRead;
			buf = (uint8_t *)buffer + totalBytesRead;
		}
		
		ssize_t result = read(socketFD, buf, bytesToRead);
		LogVerbose(@"%@: read from socket = %zd", THIS_METHOD, result);
		
		if (result < 0)
		{
			LogVerbose(@"%@: read errno = %i", THIS_METHOD, errno);
			
			if (errno != EWOULDBLOCK)
			{
				socketError = YES;
			}
			
			socketFDBytesAvailable = 0;
		}
		else if (result == 0)
		{
			LogVerbose(@"%@: read EOF", THIS_METHOD);
			
			socketError = YES;
			socketFDBytesAvailable = 0;
		}
		else
		{
			size_t bytesReadFromSocket = result;
			
			if (socketFDBytesAvailable > bytesReadFromSocket)
				socketFDBytesAvailable -= bytesReadFromSocket;
			else
				socketFDBytesAvailable = 0;
			
			if (readIntoPreBuffer)
			{
				[sslPreBuffer didWrite:bytesReadFromSocket];
				
				size_t bytesToCopy = MIN(totalBytesLeftToBeRead, bytesReadFromSocket);
				
				LogVerbose(@"%@: Copying %zu bytes out of sslPreBuffer", THIS_METHOD, bytesToCopy);
				
				memcpy((uint8_t *)buffer + totalBytesRead, [sslPreBuffer readBuffer], bytesToCopy);
				[sslPreBuffer didRead:bytesToCopy];
				
				totalBytesRead += bytesToCopy;
				totalBytesLeftToBeRead -= bytesToCopy;
				
				LogVerbose(@"%@: sslPreBuffer.length = %zu", THIS_METHOD, [sslPreBuffer availableBytes]);
			}
			else
			{
				totalBytesRead += bytesReadFromSocket;
				totalBytesLeftToBeRead -= bytesReadFromSocket;
			}
			
			done = (totalBytesLeftToBeRead == 0);
			
			if (done) LogVerbose(@"%@: Complete", THIS_METHOD);
		}
	}
	
	*bufferLength = totalBytesRead;
	
	if (done)
		return noErr;
	
	if (socketError)
		return errSSLClosedAbort;
	
	return errSSLWouldBlock;
}

- (OSStatus)sslWriteWithBuffer:(const void *)buffer length:(size_t *)bufferLength
{
	if (!(flags & kSocketCanAcceptBytes))
	{
		// Unable to write.
		// 
		// Need to wait for writeSource to fire and notify us of
		// available space in the socket's internal write buffer.
		
		[self resumeWriteSource];
		
		*bufferLength = 0;
		return errSSLWouldBlock;
	}
	
	size_t bytesToWrite = *bufferLength;
	size_t bytesWritten = 0;
	
	BOOL done = NO;
	BOOL socketError = NO;
	
	int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
	
	ssize_t result = write(socketFD, buffer, bytesToWrite);
	
	if (result < 0)
	{
		if (errno != EWOULDBLOCK)
		{
			socketError = YES;
		}
		
		flags &= ~kSocketCanAcceptBytes;
	}
	else if (result == 0)
	{
		flags &= ~kSocketCanAcceptBytes;
	}
	else
	{
		bytesWritten = result;
		
		done = (bytesWritten == bytesToWrite);
	}
	
	*bufferLength = bytesWritten;
	
	if (done)
		return noErr;
	
	if (socketError)
		return errSSLClosedAbort;
	
	return errSSLWouldBlock;
}

static OSStatus SSLReadFunction(SSLConnectionRef connection, void *data, size_t *dataLength)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)connection;
	
	NSCAssert(dispatch_get_specific(asyncSocket->IsOnSocketQueueOrTargetQueueKey), @"What the deuce?");
	
	return [asyncSocket sslReadWithBuffer:data length:dataLength];
}

static OSStatus SSLWriteFunction(SSLConnectionRef connection, const void *data, size_t *dataLength)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)connection;
	
	NSCAssert(dispatch_get_specific(asyncSocket->IsOnSocketQueueOrTargetQueueKey), @"What the deuce?");
	
	return [asyncSocket sslWriteWithBuffer:data length:dataLength];
}

- (void)ssl_startTLS
{
	LogTrace();
	
	LogVerbose(@"Starting TLS (via SecureTransport)...");
	
	OSStatus status;
	
	GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
	if (tlsPacket == nil) // Code to quiet the analyzer
	{
		NSAssert(NO, @"Logic error");
		
		[self closeWithError:[self otherError:@"Logic error"]];
		return;
	}
	NSDictionary *tlsSettings = tlsPacket->tlsSettings;
	
	// Create SSLContext, and setup IO callbacks and connection ref
	
	NSNumber *isServerNumber = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLIsServer];
	BOOL isServer = [isServerNumber boolValue];
	
	#if (__MAC_OS_X_VERSION_MIN_REQUIRED >= 1080)
	{
        // 创建一个sslContext，分服务端客户端
		if (isServer)
			sslContext = SSLCreateContext(kCFAllocatorDefault, kSSLServerSide, kSSLStreamType);
		else
			sslContext = SSLCreateContext(kCFAllocatorDefault, kSSLClientSide, kSSLStreamType);
		
		if (sslContext == NULL)
		{
			[self closeWithError:[self otherError:@"Error in SSLCreateContext"]];
			return;
		}
	}
	#else // (__MAC_OS_X_VERSION_MIN_REQUIRED < 1080)
	{
		status = SSLNewContext(isServer, &sslContext);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLNewContext"]];
			return;
		}
	}
	#endif
	
    // 给 sslContext 绑定 网络io 读写的回调的回调
	status = SSLSetIOFuncs(sslContext, &SSLReadFunction, &SSLWriteFunction);
	if (status != noErr)
	{
		[self closeWithError:[self otherError:@"Error in SSLSetIOFuncs"]];
		return;
	}
	
    // 将 sslContext 与 SSLConnectionRef（连接者）管理起来
	status = SSLSetConnection(sslContext, (__bridge SSLConnectionRef)self);
	if (status != noErr)
	{
		[self closeWithError:[self otherError:@"Error in SSLSetConnection"]];
		return;
	}


	NSNumber *shouldManuallyEvaluateTrust = [tlsSettings objectForKey:GCDAsyncSocketManuallyEvaluateTrust];
	if ([shouldManuallyEvaluateTrust boolValue])
	{
		if (isServer)
		{
			[self closeWithError:[self otherError:@"Manual trust validation is not supported for server sockets"]];
			return;
		}
		// 允许中断捂手，方便自己去校验证书
		status = SSLSetSessionOption(sslContext, kSSLSessionOptionBreakOnServerAuth, true);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetSessionOption"]];
			return;
		}
		
		#if !TARGET_OS_IPHONE && (__MAC_OS_X_VERSION_MIN_REQUIRED < 1080)
		
		// Note from Apple's documentation:
		//
		// It is only necessary to call SSLSetEnableCertVerify on the Mac prior to OS X 10.8.
		// On OS X 10.8 and later setting kSSLSessionOptionBreakOnServerAuth always disables the
		// built-in trust evaluation. All versions of iOS behave like OS X 10.8 and thus
		// SSLSetEnableCertVerify is not available on that platform at all.
		
		status = SSLSetEnableCertVerify(sslContext, NO);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetEnableCertVerify"]];
			return;
		}
		
		#endif
	}

	// Configure SSLContext from given settings
	// 
	// Checklist:
	//  1. kCFStreamSSLPeerName
	//  2. kCFStreamSSLCertificates
	//  3. GCDAsyncSocketSSLPeerID
	//  4. GCDAsyncSocketSSLProtocolVersionMin
	//  5. GCDAsyncSocketSSLProtocolVersionMax
	//  6. GCDAsyncSocketSSLSessionOptionFalseStart
	//  7. GCDAsyncSocketSSLSessionOptionSendOneByteRecord
	//  8. GCDAsyncSocketSSLCipherSuites
	//  9. GCDAsyncSocketSSLDiffieHellmanParameters (Mac)
    // 10. GCDAsyncSocketSSLALPN
	//
	// Deprecated (throw error):
	// 10. kCFStreamSSLAllowsAnyRoot
	// 11. kCFStreamSSLAllowsExpiredRoots
	// 12. kCFStreamSSLAllowsExpiredCertificates
	// 13. kCFStreamSSLValidatesCertificateChain
	// 14. kCFStreamSSLLevel
	
	NSObject *value;
	
	// 1. kCFStreamSSLPeerName
	
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLPeerName];
	if ([value isKindOfClass:[NSString class]])
	{
		NSString *peerName = (NSString *)value;
		
		const char *peer = [peerName UTF8String];
		size_t peerLen = strlen(peer);
		
        // 可以指定对方的域名，名字等（用于验证对等方证书中的公共名字段）
		status = SSLSetPeerDomainName(sslContext, peer, peerLen);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetPeerDomainName"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for kCFStreamSSLPeerName. Value must be of type NSString.");
		
		[self closeWithError:[self otherError:@"Invalid value for kCFStreamSSLPeerName."]];
		return;
	}
	
	// 2. kCFStreamSSLCertificates
	
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLCertificates];
	if ([value isKindOfClass:[NSArray class]])
	{
		NSArray *certs = (NSArray *)value;
		// 指定证书，服务端是必须的，客户端可以选配
		status = SSLSetCertificate(sslContext, (__bridge CFArrayRef)certs);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetCertificate"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for kCFStreamSSLCertificates. Value must be of type NSArray.");
		
		[self closeWithError:[self otherError:@"Invalid value for kCFStreamSSLCertificates."]];
		return;
	}
	
	// 3. GCDAsyncSocketSSLPeerID
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLPeerID];
	if ([value isKindOfClass:[NSData class]])
	{
		NSData *peerIdData = (NSData *)value;
		
        // 指定一些对该库不透明的数据，这些数据足以唯一标识当前会话的对等方
		status = SSLSetPeerID(sslContext, [peerIdData bytes], [peerIdData length]);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetPeerID"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLPeerID. Value must be of type NSData."
		             @" (You can convert strings to data using a method like"
		             @" [string dataUsingEncoding:NSUTF8StringEncoding])");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLPeerID."]];
		return;
	}
	
	// 4. GCDAsyncSocketSSLProtocolVersionMin
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLProtocolVersionMin];
	if ([value isKindOfClass:[NSNumber class]])
	{
		SSLProtocol minProtocol = (SSLProtocol)[(NSNumber *)value intValue];
		if (minProtocol != kSSLProtocolUnknown)
		{
            // 执行ssl协议最低版本
			status = SSLSetProtocolVersionMin(sslContext, minProtocol);
			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetProtocolVersionMin"]];
				return;
			}
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLProtocolVersionMin. Value must be of type NSNumber.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLProtocolVersionMin."]];
		return;
	}
	
	// 5. GCDAsyncSocketSSLProtocolVersionMax
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLProtocolVersionMax];
	if ([value isKindOfClass:[NSNumber class]])
	{
		SSLProtocol maxProtocol = (SSLProtocol)[(NSNumber *)value intValue];
		if (maxProtocol != kSSLProtocolUnknown)
		{
            // 设置最高版本
			status = SSLSetProtocolVersionMax(sslContext, maxProtocol);
			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetProtocolVersionMax"]];
				return;
			}
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLProtocolVersionMax. Value must be of type NSNumber.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLProtocolVersionMax."]];
		return;
	}
	
	// 6. GCDAsyncSocketSSLSessionOptionFalseStart
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLSessionOptionFalseStart];
	if ([value isKindOfClass:[NSNumber class]])
	{
		NSNumber *falseStart = (NSNumber *)value;
        
//        kSSLSessionOptionFalseStart 是 SSLSessionOption 枚举中的一个选项，用于启用或禁用 TLS False Start。启用 False Start 可以减少握手延迟，从而提高性能。
//        TLS False Start 的概念
//        TLS False Start 是 TLS 1.2 引入的一种优化技术。它允许客户端在握手尚未完全完成之前开始发送应用数据。具体来说，在完成客户端到服务器的密钥交换之后，客户端可以立即开始发送加密的数据，而无需等待完整的握手过程结束。这可以显著减少握手延迟，从而加快连接的建立。

        
		status = SSLSetSessionOption(sslContext, kSSLSessionOptionFalseStart, [falseStart boolValue]);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetSessionOption (kSSLSessionOptionFalseStart)"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLSessionOptionFalseStart. Value must be of type NSNumber.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLSessionOptionFalseStart."]];
		return;
	}
	
	// 7. GCDAsyncSocketSSLSessionOptionSendOneByteRecord
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLSessionOptionSendOneByteRecord];
	if ([value isKindOfClass:[NSNumber class]])
	{
		NSNumber *oneByteRecord = (NSNumber *)value;
        
//        kSSLSessionOptionSendOneByteRecord 是 SSLSessionOption 枚举中的一个选项，用于控制是否启用 1/n-1 记录分割以缓解 BEAST 攻击。启用这个选项会导致 SSL/TLS 实现将数据分割成更小的记录来发送。
//        BEAST 攻击的背景
//        BEAST (Browser Exploit Against SSL/TLS) 是一种针对 SSL/TLS 协议的攻击，主要影响 TLS 1.0 及更早版本。攻击者利用了 CBC（密码块链）模式中的弱点，通过拦截和篡改加密数据块来解密敏感信息。为了缓解这种攻击，一种有效的方法是将数据分割成更小的记录来发送，这样攻击者就无法利用块之间的依赖性进行攻击。
        
        // 新的tls 协议已经没有这个安全隐患了
        
		status = SSLSetSessionOption(sslContext, kSSLSessionOptionSendOneByteRecord, [oneByteRecord boolValue]);
		if (status != noErr)
		{
			[self closeWithError:
			  [self otherError:@"Error in SSLSetSessionOption (kSSLSessionOptionSendOneByteRecord)"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLSessionOptionSendOneByteRecord."
		             @" Value must be of type NSNumber.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLSessionOptionSendOneByteRecord."]];
		return;
	}
	
	// 8. GCDAsyncSocketSSLCipherSuites
	
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLCipherSuites];
	if ([value isKindOfClass:[NSArray class]])
	{
		NSArray *cipherSuites = (NSArray *)value;
		NSUInteger numberCiphers = [cipherSuites count];
		SSLCipherSuite ciphers[numberCiphers];
		
		NSUInteger cipherIndex;
		for (cipherIndex = 0; cipherIndex < numberCiphers; cipherIndex++)
		{
			NSNumber *cipherObject = [cipherSuites objectAtIndex:cipherIndex];
			ciphers[cipherIndex] = (SSLCipherSuite)[cipherObject unsignedIntValue];
		}
        
        // SSLSetEnabledCiphers 函数用于为 SSL 会话设置一组启用的加密套件。通过指定特定的加密套件，可以控制 SSL/TLS 会话的安全性和性能。该函数必须在没有活动会话时调用，并且适用于需要特定加密套件配置的场景。
		
		status = SSLSetEnabledCiphers(sslContext, ciphers, numberCiphers);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetEnabledCiphers"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLCipherSuites. Value must be of type NSArray.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLCipherSuites."]];
		return;
	}
	
	// 9. GCDAsyncSocketSSLDiffieHellmanParameters
	
//	#if !TARGET_OS_IPHONE
	value = [tlsSettings objectForKey:GCDAsyncSocketSSLDiffieHellmanParameters];
	if ([value isKindOfClass:[NSData class]])
	{
		NSData *diffieHellmanData = (NSData *)value;
		
		status = SSLSetDiffieHellmanParams(sslContext, [diffieHellmanData bytes], [diffieHellmanData length]);
		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetDiffieHellmanParams"]];
			return;
		}
	}
	else if (value)
	{
		NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLDiffieHellmanParameters. Value must be of type NSData.");
		
		[self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLDiffieHellmanParameters."]];
		return;
	}
//	#endif

    // 10. kCFStreamSSLCertificates
    value = [tlsSettings objectForKey:GCDAsyncSocketSSLALPN];
    if ([value isKindOfClass:[NSArray class]])
    {
        if (@available(iOS 11.0, macOS 10.13, tvOS 11.0, *))
        {
            CFArrayRef protocols = (__bridge CFArrayRef)((NSArray *) value);
            // 设置支持的协议
            status = SSLSetALPNProtocols(sslContext, protocols);
            if (status != noErr)
            {
                [self closeWithError:[self otherError:@"Error in SSLSetALPNProtocols"]];
                return;
            }
        }
        else
        {
            NSAssert(NO, @"Security option unavailable - GCDAsyncSocketSSLALPN"
                     @" - iOS 11.0, macOS 10.13 required");
            [self closeWithError:[self otherError:@"Security option unavailable - GCDAsyncSocketSSLALPN"]];
        }
    }
    else if (value)
    {
        NSAssert(NO, @"Invalid value for GCDAsyncSocketSSLALPN. Value must be of type NSArray.");
        
        [self closeWithError:[self otherError:@"Invalid value for GCDAsyncSocketSSLALPN."]];
        return;
    }
    
	// DEPRECATED checks
	
	// 10. kCFStreamSSLAllowsAnyRoot
	
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLAllowsAnyRoot];
	#pragma clang diagnostic pop
	if (value)
	{
		NSAssert(NO, @"Security option unavailable - kCFStreamSSLAllowsAnyRoot"
		             @" - You must use manual trust evaluation");
		
		[self closeWithError:[self otherError:@"Security option unavailable - kCFStreamSSLAllowsAnyRoot"]];
		return;
	}
	
	// 11. kCFStreamSSLAllowsExpiredRoots
	
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLAllowsExpiredRoots];
	#pragma clang diagnostic pop
	if (value)
	{
		NSAssert(NO, @"Security option unavailable - kCFStreamSSLAllowsExpiredRoots"
		             @" - You must use manual trust evaluation");
		
		[self closeWithError:[self otherError:@"Security option unavailable - kCFStreamSSLAllowsExpiredRoots"]];
		return;
	}
	
	// 12. kCFStreamSSLValidatesCertificateChain
	
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLValidatesCertificateChain];
	#pragma clang diagnostic pop
	if (value)
	{
		NSAssert(NO, @"Security option unavailable - kCFStreamSSLValidatesCertificateChain"
		             @" - You must use manual trust evaluation");
		
		[self closeWithError:[self otherError:@"Security option unavailable - kCFStreamSSLValidatesCertificateChain"]];
		return;
	}
	
	// 13. kCFStreamSSLAllowsExpiredCertificates
	
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLAllowsExpiredCertificates];
	#pragma clang diagnostic pop
	if (value)
	{
		NSAssert(NO, @"Security option unavailable - kCFStreamSSLAllowsExpiredCertificates"
		             @" - You must use manual trust evaluation");
		
		[self closeWithError:[self otherError:@"Security option unavailable - kCFStreamSSLAllowsExpiredCertificates"]];
		return;
	}
	
	// 14. kCFStreamSSLLevel
	
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	value = [tlsSettings objectForKey:(__bridge NSString *)kCFStreamSSLLevel];
	#pragma clang diagnostic pop
	if (value)
	{
		NSAssert(NO, @"Security option unavailable - kCFStreamSSLLevel"
		             @" - You must use GCDAsyncSocketSSLProtocolVersionMin & GCDAsyncSocketSSLProtocolVersionMax");
		
		[self closeWithError:[self otherError:@"Security option unavailable - kCFStreamSSLLevel"]];
		return;
	}
	
	// Setup the sslPreBuffer
	// 
	// Any data in the preBuffer needs to be moved into the sslPreBuffer,
	// as this data is now part of the secure read stream.
	
    // 创建 sslPreBuffer 缓存包
	sslPreBuffer = [[GCDAsyncSocketPreBuffer alloc] initWithCapacity:(1024 * 4)];
	
    //获取到preBuffer可读大小
	size_t preBufferLength  = [preBuffer availableBytes];
	
	if (preBufferLength > 0)
	{
        // 校验下能不能放这么多数据，如果不可以就自己扩容
		[sslPreBuffer ensureCapacityForWrite:preBufferLength];
		// 从 preBuffer 的 readBuffer位置，读取 preBufferLength 这么长到 sslPreBuffer 的可写的下标的地方
		memcpy([sslPreBuffer writeBuffer], [preBuffer readBuffer], preBufferLength);
        // 设置已读位置
		[preBuffer didRead:preBufferLength];
        // 设置已写位置
		[sslPreBuffer didWrite:preBufferLength];
	}
	
	sslErrCode = lastSSLHandshakeError = noErr;
	
	// Start the SSL Handshake process
    //开始SSL握手过程
	[self ssl_continueSSLHandshake];
}

- (void)ssl_continueSSLHandshake
{
	LogTrace();
	
	// If the return value is noErr, the session is ready for normal secure communication.
	// If the return value is errSSLWouldBlock, the SSLHandshake function must be called again.
	// If the return value is errSSLServerAuthCompleted, we ask delegate if we should trust the
	// server and then call SSLHandshake again to resume the handshake or close the connection
	// errSSLPeerBadCert SSL error.
	// Otherwise, the return value indicates an error code.
	
    // 开始握手
	OSStatus status = SSLHandshake(sslContext);
	lastSSLHandshakeError = status;
	
	if (status == noErr)
	{
		LogVerbose(@"SSLHandshake complete");
		
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
		flags |=  kSocketSecure;
		
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

        // 握手成功，代理回调出去
		if (delegateQueue && [theDelegate respondsToSelector:@selector(socketDidSecure:)])
		{
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socketDidSecure:self];
			}});
		}
		
		[self endCurrentRead];
		[self endCurrentWrite];
		
		[self maybeDequeueRead];
		[self maybeDequeueWrite];
	}
	else if (status == errSSLPeerAuthCompleted)
	{
		LogVerbose(@"SSLHandshake peerAuthCompleted - awaiting delegate approval");
		
		__block SecTrustRef trust = NULL;
		status = SSLCopyPeerTrust(sslContext, &trust);
		if (status != noErr)
		{
			[self closeWithError:[self sslError:status]];
			return;
		}
		
		int aStateIndex = stateIndex;
		dispatch_queue_t theSocketQueue = socketQueue;
		
		__weak GCDAsyncSocket *weakSelf = self;
		
		void (^comletionHandler)(BOOL) = ^(BOOL shouldTrust){ @autoreleasepool {
		#pragma clang diagnostic push
		#pragma clang diagnostic warning "-Wimplicit-retain-self"
			
			dispatch_async(theSocketQueue, ^{ @autoreleasepool {
				
				if (trust) {
					CFRelease(trust);
					trust = NULL;
				}
				
				__strong GCDAsyncSocket *strongSelf = weakSelf;
				if (strongSelf)
				{
                    // 已经处理完了证书校验，尝试去重新握手
					[strongSelf ssl_shouldTrustPeer:shouldTrust stateIndex:aStateIndex];
				}
			}});
			
		#pragma clang diagnostic pop
		}};
		
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;
		
		if (delegateQueue && [theDelegate respondsToSelector:@selector(socket:didReceiveTrust:completionHandler:)])
		{
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
                // 代理调出去，需要信任，成功以后执行 comletionHandler 这个block，会再次进行握手
				[theDelegate socket:self didReceiveTrust:trust completionHandler:comletionHandler];
			}});
		}
		else
		{
			if (trust) {
				CFRelease(trust);
				trust = NULL;
			}
			
			NSString *msg = @"GCDAsyncSocketManuallyEvaluateTrust specified in tlsSettings,"
			                @" but delegate doesn't implement socket:shouldTrustPeer:";
			
			[self closeWithError:[self otherError:msg]];
			return;
		}
	}
	else if (status == errSSLWouldBlock)
	{
		LogVerbose(@"SSLHandshake continues...");
		
		// Handshake continues...
		// 
		// This method will be called again from doReadData or doWriteData.
	}
	else
	{
		[self closeWithError:[self sslError:status]];
	}
}

- (void)ssl_shouldTrustPeer:(BOOL)shouldTrust stateIndex:(int)aStateIndex
{
	LogTrace();
	
	if (aStateIndex != stateIndex)
	{
		LogInfo(@"Ignoring ssl_shouldTrustPeer - invalid state (maybe disconnected)");
		
		// One of the following is true
		// - the socket was disconnected
		// - the startTLS operation timed out
		// - the completionHandler was already invoked once
		
		return;
	}
	
	// Increment stateIndex to ensure completionHandler can only be called once.
	stateIndex++;
	
    // 已经被信任了，再次握手
	if (shouldTrust)
	{
        NSAssert(lastSSLHandshakeError == errSSLPeerAuthCompleted, @"ssl_shouldTrustPeer called when last error is %d and not errSSLPeerAuthCompleted", (int)lastSSLHandshakeError);
		[self ssl_continueSSLHandshake];
	}
	else
	{
		[self closeWithError:[self sslError:errSSLPeerBadCert]];
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Security via CFStream
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

//#if TARGET_OS_IPHONE

- (void)cf_finishSSLHandshake
{
	LogTrace();
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
		flags |= kSocketSecure;
		
		__strong id<GCDAsyncSocketDelegate> theDelegate = delegate;

		if (delegateQueue && [theDelegate respondsToSelector:@selector(socketDidSecure:)])
		{
			dispatch_async(delegateQueue, ^{ @autoreleasepool {
				
				[theDelegate socketDidSecure:self];
			}});
		}
		
		[self endCurrentRead];
		[self endCurrentWrite];
		
		[self maybeDequeueRead];
		[self maybeDequeueWrite];
	}
}

- (void)cf_abortSSLHandshake:(NSError *)error
{
	LogTrace();
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
		[self closeWithError:error];
	}
}

- (void)cf_startTLS
{
	LogTrace();
	
	LogVerbose(@"Starting TLS (via CFStream)...");
	
	if ([preBuffer availableBytes] > 0)
	{
		NSString *msg = @"Invalid TLS transition. Handshake has already been read from socket.";
		
		[self closeWithError:[self otherError:msg]];
		return;
	}
	// 暂停读写source
	[self suspendReadSource];
	[self suspendWriteSource];
	
	socketFDBytesAvailable = 0;
	flags &= ~kSocketCanAcceptBytes;
	flags &= ~kSecureSocketHasBytesAvailable;
	
	flags |=  kUsingCFStreamForTLS;
	
    // 重新创建读写source
	if (![self createReadAndWriteStream])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamCreatePairWithSocket"]];
		return;
	}
	// 这次要将 ReadWrite 包含进去
	if (![self registerForStreamCallbacksIncludingReadWrite:YES])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamSetClient"]];
		return;
	}
	// 重新加入到runloop中
	if (![self addStreamsToRunLoop])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamScheduleWithRunLoop"]];
		return;
	}
	
	NSAssert([currentRead isKindOfClass:[GCDAsyncSpecialPacket class]], @"Invalid read packet for startTLS");
	NSAssert([currentWrite isKindOfClass:[GCDAsyncSpecialPacket class]], @"Invalid write packet for startTLS");
	
	GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
	CFDictionaryRef tlsSettings = (__bridge CFDictionaryRef)tlsPacket->tlsSettings;
	
	// Getting an error concerning kCFStreamPropertySSLSettings ?
	// You need to add the CFNetwork framework to your iOS application.
	// 将设置设置到读写源中
    
	BOOL r1 = CFReadStreamSetProperty(readStream, kCFStreamPropertySSLSettings, tlsSettings);
	BOOL r2 = CFWriteStreamSetProperty(writeStream, kCFStreamPropertySSLSettings, tlsSettings);
	
	// For some reason, starting around the time of iOS 4.3,
	// the first call to set the kCFStreamPropertySSLSettings will return true,
	// but the second will return false.
	// 
	// Order doesn't seem to matter.
	// So you could call CFReadStreamSetProperty and then CFWriteStreamSetProperty, or you could reverse the order.
	// Either way, the first call will return true, and the second returns false.
	// 
	// Interestingly, this doesn't seem to affect anything.
	// Which is not altogether unusual, as the documentation seems to suggest that (for many settings)
	// setting it on one side of the stream automatically sets it for the other side of the stream.
	// 
	// Although there isn't anything in the documentation to suggest that the second attempt would fail.
	// 
	// Furthermore, this only seems to affect streams that are negotiating a security upgrade.
	// In other words, the socket gets connected, there is some back-and-forth communication over the unsecure
	// connection, and then a startTLS is issued.
	// So this mostly affects newer protocols (XMPP, IMAP) as opposed to older protocols (HTTPS).
	
	if (!r1 && !r2) // Yes, the && is correct - workaround for apple bug.
	{
		[self closeWithError:[self otherError:@"Error in CFStreamSetProperty"]];
		return;
	}
	// 重新打开源
	if (![self openStreams])
	{
		[self closeWithError:[self otherError:@"Error in CFStreamOpen"]];
		return;
	}
	
	LogVerbose(@"Waiting for SSL Handshake to complete...");
}

//#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark CFStream
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

//#if TARGET_OS_IPHONE

+ (void)ignore:(id)_
{}

+ (void)startCFStreamThreadIfNeeded
{
	LogTrace();
	
	static dispatch_once_t predicate;
	dispatch_once(&predicate, ^{
		
		cfstreamThreadRetainCount = 0;
		cfstreamThreadSetupQueue = dispatch_queue_create("GCDAsyncSocket-CFStreamThreadSetup", DISPATCH_QUEUE_SERIAL);
	});
	
	dispatch_sync(cfstreamThreadSetupQueue, ^{ @autoreleasepool {
		
		if (++cfstreamThreadRetainCount == 1)
		{
            // 创建子线程
            // cfstreamThread 开启runloop，使线程保活
			cfstreamThread = [[NSThread alloc] initWithTarget:self
			                                         selector:@selector(cfstreamThread:)
			                                           object:nil];
			[cfstreamThread start];
		}
	}});
}

+ (void)stopCFStreamThreadIfNeeded
{
	LogTrace();
	
	// The creation of the cfstreamThread is relatively expensive.
	// So we'd like to keep it available for recycling.
	// However, there's a tradeoff here, because it shouldn't remain alive forever.
	// So what we're going to do is use a little delay before taking it down.
	// This way it can be reused properly in situations where multiple sockets are continually in flux.
	
	int delayInSeconds = 30;
	dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
	dispatch_after(when, cfstreamThreadSetupQueue, ^{ @autoreleasepool {
	#pragma clang diagnostic push
	#pragma clang diagnostic warning "-Wimplicit-retain-self"
		
		if (cfstreamThreadRetainCount == 0)
		{
			LogWarn(@"Logic error concerning cfstreamThread start / stop");
			return_from_block;
		}
		
		if (--cfstreamThreadRetainCount == 0)
		{
			[cfstreamThread cancel]; // set isCancelled flag
			
			// wake up the thread
            [[self class] performSelector:@selector(ignore:)
                                 onThread:cfstreamThread
                               withObject:[NSNull null]
                            waitUntilDone:NO];
            
			cfstreamThread = nil;
		}
		
	#pragma clang diagnostic pop
	}});
}

+ (void)cfstreamThread:(id)unused { @autoreleasepool
{
	[[NSThread currentThread] setName:GCDAsyncSocketThreadName];
	
	LogInfo(@"CFStreamThread: Started");
	
	// We can't run the run loop unless it has an associated input source or a timer.
	// So we'll just create a timer that will never fire - unless the server runs for decades.
	[NSTimer scheduledTimerWithTimeInterval:[[NSDate distantFuture] timeIntervalSinceNow]
	                                 target:self
	                               selector:@selector(ignore:)
	                               userInfo:nil
	                                repeats:YES];
	
	NSThread *currentThread = [NSThread currentThread];
	NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];
	
	BOOL isCancelled = [currentThread isCancelled];
	
	while (!isCancelled && [currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]])
	{
		isCancelled = [currentThread isCancelled];
	}
	
	LogInfo(@"CFStreamThread: Stopped");
}}

+ (void)scheduleCFStreams:(GCDAsyncSocket *)asyncSocket
{
	LogTrace();
	NSAssert([NSThread currentThread] == cfstreamThread, @"Invoked on wrong thread");
	
    // 获取当前子线程的runloop，
	CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    
//    用于将 CFReadStream 对象与指定的运行循环（Run Loop）关联起来，并指定在运行循环的哪个模式下处理流事件。通过这样做，你可以异步地处理流事件（如数据可用、流到达末尾、错误等），而不需要阻塞主线程。
	
	if (asyncSocket->readStream)
		CFReadStreamScheduleWithRunLoop(asyncSocket->readStream, runLoop, kCFRunLoopDefaultMode);
	
	if (asyncSocket->writeStream)
		CFWriteStreamScheduleWithRunLoop(asyncSocket->writeStream, runLoop, kCFRunLoopDefaultMode);
}

+ (void)unscheduleCFStreams:(GCDAsyncSocket *)asyncSocket
{
	LogTrace();
	NSAssert([NSThread currentThread] == cfstreamThread, @"Invoked on wrong thread");
	
	CFRunLoopRef runLoop = CFRunLoopGetCurrent();
	
	if (asyncSocket->readStream)
		CFReadStreamUnscheduleFromRunLoop(asyncSocket->readStream, runLoop, kCFRunLoopDefaultMode);
	
	if (asyncSocket->writeStream)
		CFWriteStreamUnscheduleFromRunLoop(asyncSocket->writeStream, runLoop, kCFRunLoopDefaultMode);
}

static void CFReadStreamCallback (CFReadStreamRef stream, CFStreamEventType type, void *pInfo)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)pInfo;
	
	switch(type)
	{
		case kCFStreamEventHasBytesAvailable:
		{
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFReadStreamCallback - HasBytesAvailable");
				
				if (asyncSocket->readStream != stream)
					return_from_block;
				
                /*
                这行代码检查两个标志位 kStartingReadTLS 和 kStartingWriteTLS 是否都已设置。
                这些标志位表示正在开始读和写的 TLS（SSL）握手过程。即，当两个标志位都设置时，意味着套接字正处于 TLS 握手过程中。
                 */
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					// If we set kCFStreamPropertySSLSettings before we opened the streams, this might be a lie.
					// (A callback related to the tcp stream, but not to the SSL layer).
					
                    /*
                     读取的数据。
                         •    如果 readStream 中有数据可读，这意味着可以进行进一步的握手处理，因此设置标志位 kSecureSocketHasBytesAvailable，表示 TLS 连接已安全，并调用 [asyncSocket cf_finishSSLHandshake] 来完成 SSL 握手过程。
                     cf_finishSSLHandshake 是一个关键函数，负责完成 TLS 握手的最后阶段，它可能会根据当前的握手状态继续处理 SSL 证书交换、加密设置等过程，确保 SSL 连接成功建立。
                     */
					if (CFReadStreamHasBytesAvailable(asyncSocket->readStream))
					{
						asyncSocket->flags |= kSecureSocketHasBytesAvailable;
						[asyncSocket cf_finishSSLHandshake];
					}
				}
				else
				{
                    // 直接去读取
					asyncSocket->flags |= kSecureSocketHasBytesAvailable;
					[asyncSocket doReadData];
				}
			}});
			
			break;
		}
		default:
		{
			NSError *error = (__bridge_transfer  NSError *)CFReadStreamCopyError(stream);
			
			if (error == nil && type == kCFStreamEventEndEncountered)
			{
				error = [asyncSocket connectionClosedError];
			}
			
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFReadStreamCallback - Other");
				
				if (asyncSocket->readStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					[asyncSocket cf_abortSSLHandshake:error];
				}
				else
				{
					[asyncSocket closeWithError:error];
				}
			}});
			
			break;
		}
	}
	
}

static void CFWriteStreamCallback (CFWriteStreamRef stream, CFStreamEventType type, void *pInfo)
{
	GCDAsyncSocket *asyncSocket = (__bridge GCDAsyncSocket *)pInfo;
	
	switch(type)
	{
		case kCFStreamEventCanAcceptBytes:
		{
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFWriteStreamCallback - CanAcceptBytes");
				
				if (asyncSocket->writeStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					// If we set kCFStreamPropertySSLSettings before we opened the streams, this might be a lie.
					// (A callback related to the tcp stream, but not to the SSL layer).
					
					if (CFWriteStreamCanAcceptBytes(asyncSocket->writeStream))
					{
						asyncSocket->flags |= kSocketCanAcceptBytes;
						[asyncSocket cf_finishSSLHandshake];
					}
				}
				else
				{
					asyncSocket->flags |= kSocketCanAcceptBytes;
					[asyncSocket doWriteData];
				}
			}});
			
			break;
		}
		default:
		{
			NSError *error = (__bridge_transfer NSError *)CFWriteStreamCopyError(stream);
			
			if (error == nil && type == kCFStreamEventEndEncountered)
			{
				error = [asyncSocket connectionClosedError];
			}
			
			dispatch_async(asyncSocket->socketQueue, ^{ @autoreleasepool {
				
				LogCVerbose(@"CFWriteStreamCallback - Other");
				
				if (asyncSocket->writeStream != stream)
					return_from_block;
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					[asyncSocket cf_abortSSLHandshake:error];
				}
				else
				{
					[asyncSocket closeWithError:error];
				}
			}});
			
			break;
		}
	}
	
}

- (BOOL)createReadAndWriteStream
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	
	
	if (readStream || writeStream)
	{
		// Streams already created
		return YES;
	}
	
	int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : (socket6FD != SOCKET_NULL) ? socket6FD : socketUN;
	
	if (socketFD == SOCKET_NULL)
	{
		// Cannot create streams without a file descriptor
		return NO;
	}
	
	if (![self isConnected])
	{
		// Cannot create streams until file descriptor is connected
		return NO;
	}
	
	LogVerbose(@"Creating read and write stream...");
	
    // 创建一个读写流，但此方法被标记为已过期
    // CFStreamCreatePairWithSocket(NULL, (CFSocketNativeHandle)socketFD, &readStream, &writeStream) 是一个 Core Foundation API，用于创建与一个本地套接字相关联的读写流。它通常用于网络编程，通过将本地的 Socket 文件描述符与输入/输出流关联起来，方便开发者通过流来进行数据的读写操作
    // 如果没有使用 CFStream 来处理加解密的话，readStream writeStream 只起到了 kCFStreamEventErrorOccurred 与 kCFStreamEventEndEncountered 的作用，
    // 如果 是使用 CFStream 的话，还涉及数据到达的回调。
    
    
	CFStreamCreatePairWithSocket(NULL, (CFSocketNativeHandle)socketFD, &readStream, &writeStream);
	
	// The kCFStreamPropertyShouldCloseNativeSocket property should be false by default (for our case).
	// But let's not take any chances.
	
	if (readStream)
        //  设置相关属性，这里指的是关闭流的时候，不需要关闭 底层socket
		CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
	if (writeStream)
		CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
	
	if ((readStream == NULL) || (writeStream == NULL))
	{
		LogWarn(@"Unable to create read and write stream...");
		
		if (readStream)
		{
			CFReadStreamClose(readStream);
			CFRelease(readStream);
			readStream = NULL;
		}
		if (writeStream)
		{
			CFWriteStreamClose(writeStream);
			CFRelease(writeStream);
			writeStream = NULL;
		}
		
		return NO;
	}
	
	return YES;
}

- (BOOL)registerForStreamCallbacksIncludingReadWrite:(BOOL)includeReadWrite
{
	LogVerbose(@"%@ %@", THIS_METHOD, (includeReadWrite ? @"YES" : @"NO"));
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
    
    // CFStreamClientContext 是 Core Foundation 框架中用于定义流（如读流和写流）客户端上下文的结构体。它用于在注册回调函数时传递用户定义的上下文信息，通常在处理异步事件时使用。
	
	streamContext.version = 0;
	streamContext.info = (__bridge void *)(self);
	streamContext.retain = nil;
	streamContext.release = nil;
	streamContext.copyDescription = nil;
	
    // kCFStreamEventErrorOccurred 流操作过程中发生了错误
    // kCFStreamEventEndEncountered 流已经到达了文件、数据或连接的末尾
    CFOptionFlags readStreamEvents = kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered;
	if (includeReadWrite)
        // kCFStreamEventHasBytesAvailable 流中有可供读取的字节
		readStreamEvents |= kCFStreamEventHasBytesAvailable;
	
    // 为读流设置 callback
	if (!CFReadStreamSetClient(readStream, readStreamEvents, &CFReadStreamCallback, &streamContext))
	{
		return NO;
	}
	
	CFOptionFlags writeStreamEvents = kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered;
	if (includeReadWrite)
        // kCFStreamEventCanAcceptBytes 写入流（CFWriteStream）已经准备好
		writeStreamEvents |= kCFStreamEventCanAcceptBytes;
	// 为写流设置 callback
	if (!CFWriteStreamSetClient(writeStream, writeStreamEvents, &CFWriteStreamCallback, &streamContext))
	{
		return NO;
	}
	
	return YES;
}

- (BOOL)addStreamsToRunLoop
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	if (!(flags & kAddedStreamsToRunLoop))
	{
		LogVerbose(@"Adding streams to runloop...");
        // 创建子线程，并且将子线程保活，开启runloop,
		[[self class] startCFStreamThreadIfNeeded];
        // 将读写流写入到cfstreamThread线程 中的runloop中，让 runloop任何模式下都触发，将读流附加到运行循环和特定的运行模式中，使得运行循环能够监听和处理读流的事件，如数据可读、流打开完成、错误发生等。这对于异步 I/O 操作非常重要，因为它允许程序在不阻塞的情况下处理 I/O 事件。
        dispatch_sync(cfstreamThreadSetupQueue, ^{
            [[self class] performSelector:@selector(scheduleCFStreams:)
                                 onThread:cfstreamThread
                               withObject:self
                            waitUntilDone:YES];
        });
		flags |= kAddedStreamsToRunLoop;
	}
	
	return YES;
}

- (void)removeStreamsFromRunLoop
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	if (flags & kAddedStreamsToRunLoop)
	{
		LogVerbose(@"Removing streams from runloop...");
        
        dispatch_sync(cfstreamThreadSetupQueue, ^{
            [[self class] performSelector:@selector(unscheduleCFStreams:)
                                 onThread:cfstreamThread
                               withObject:self
                            waitUntilDone:YES];
        });
		[[self class] stopCFStreamThreadIfNeeded];
		
		flags &= ~kAddedStreamsToRunLoop;
	}
}

- (BOOL)openStreams
{
	LogTrace();
	
	NSAssert(dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey), @"Must be dispatched on socketQueue");
	NSAssert((readStream != NULL && writeStream != NULL), @"Read/Write stream is null");
	
	CFStreamStatus readStatus = CFReadStreamGetStatus(readStream);
	CFStreamStatus writeStatus = CFWriteStreamGetStatus(writeStream);
	
	if ((readStatus == kCFStreamStatusNotOpen) || (writeStatus == kCFStreamStatusNotOpen))
	{
		LogVerbose(@"Opening read and write stream...");
		// 开启读写流了
		BOOL r1 = CFReadStreamOpen(readStream);
		BOOL r2 = CFWriteStreamOpen(writeStream);
		
		if (!r1 || !r2)
		{
			LogError(@"Error in CFStreamOpen");
			return NO;
		}
	}
	
	return YES;
}

//#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Advanced
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * See header file for big discussion of this method.
**/
- (BOOL)autoDisconnectOnClosedReadStream
{
	// Note: YES means kAllowHalfDuplexConnection is OFF
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		return ((config & kAllowHalfDuplexConnection) == 0);
	}
	else
	{
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
            result = ((self->config & kAllowHalfDuplexConnection) == 0);
		});
		
		return result;
	}
}

/**
 * See header file for big discussion of this method.
**/
- (void)setAutoDisconnectOnClosedReadStream:(BOOL)flag
{
	// Note: YES means kAllowHalfDuplexConnection is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
            self->config &= ~kAllowHalfDuplexConnection;
		else
            self->config |= kAllowHalfDuplexConnection;
	};
	
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_async(socketQueue, block);
}


/**
 * See header file for big discussion of this method.
**/
- (void)markSocketQueueTargetQueue:(dispatch_queue_t)socketNewTargetQueue
{
	void *nonNullUnusedPointer = (__bridge void *)self;
	dispatch_queue_set_specific(socketNewTargetQueue, IsOnSocketQueueOrTargetQueueKey, nonNullUnusedPointer, NULL);
}

/**
 * See header file for big discussion of this method.
**/
- (void)unmarkSocketQueueTargetQueue:(dispatch_queue_t)socketOldTargetQueue
{
	dispatch_queue_set_specific(socketOldTargetQueue, IsOnSocketQueueOrTargetQueueKey, NULL, NULL);
}

/**
 * See header file for big discussion of this method.
**/
- (void)performBlock:(dispatch_block_t)block
{
	if (dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
		block();
	else
		dispatch_sync(socketQueue, block);
}

/**
 * Questions? Have you read the header file?
**/
- (int)socketFD
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return SOCKET_NULL;
	}
	
	if (socket4FD != SOCKET_NULL)
		return socket4FD;
	else
		return socket6FD;
}

/**
 * Questions? Have you read the header file?
**/
- (int)socket4FD
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return SOCKET_NULL;
	}
	
	return socket4FD;
}

/**
 * Questions? Have you read the header file?
**/
- (int)socket6FD
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return SOCKET_NULL;
	}
	
	return socket6FD;
}

//#if TARGET_OS_IPHONE

/**
 * Questions? Have you read the header file?
**/
- (CFReadStreamRef)readStream
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NULL;
	}
	
	if (readStream == NULL)
		[self createReadAndWriteStream];
	
	return readStream;
}

/**
 * Questions? Have you read the header file?
**/
- (CFWriteStreamRef)writeStream
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NULL;
	}
	
	if (writeStream == NULL)
		[self createReadAndWriteStream];
	
	return writeStream;
}

- (BOOL)enableBackgroundingOnSocketWithCaveat:(BOOL)caveat
{
	if (![self createReadAndWriteStream])
	{
		// Error occurred creating streams (perhaps socket isn't open)
		return NO;
	}
	
	BOOL r1, r2;
	
	LogVerbose(@"Enabling backgrouding on socket");
	
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	r1 = CFReadStreamSetProperty(readStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
	r2 = CFWriteStreamSetProperty(writeStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
#pragma clang diagnostic pop

	if (!r1 || !r2)
	{
		return NO;
	}
	
	if (!caveat)
	{
		if (![self openStreams])
		{
			return NO;
		}
	}
	
	return YES;
}

/**
 * Questions? Have you read the header file?
**/
- (BOOL)enableBackgroundingOnSocket
{
	LogTrace();
	
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NO;
	}
	
	return [self enableBackgroundingOnSocketWithCaveat:NO];
}

- (BOOL)enableBackgroundingOnSocketWithCaveat // Deprecated in iOS 4.???
{
	// This method was created as a workaround for a bug in iOS.
	// Apple has since fixed this bug.
	// I'm not entirely sure which version of iOS they fixed it in...
	
	LogTrace();
	
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NO;
	}
	
	return [self enableBackgroundingOnSocketWithCaveat:YES];
}

//#endif

- (SSLContextRef)sslContext
{
	if (!dispatch_get_specific(IsOnSocketQueueOrTargetQueueKey))
	{
		LogWarn(@"%@ - Method only available from within the context of a performBlock: invocation", THIS_METHOD);
		return NULL;
	}
	
	return sslContext;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Class Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


+ (NSMutableArray *)lookupHost:(NSString *)host port:(uint16_t)port error:(NSError **)errPtr
{
	LogTrace();
	
	NSMutableArray *addresses = nil;
	NSError *error = nil;

    // 服务器在本地
	if ([host isEqualToString:@"localhost"] || [host isEqualToString:@"loopback"])
	{
		// Use LOOPBACK address
		struct sockaddr_in nativeAddr4;
		nativeAddr4.sin_len         = sizeof(struct sockaddr_in);
		nativeAddr4.sin_family      = AF_INET;
		nativeAddr4.sin_port        = htons(port);
		nativeAddr4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		memset(&(nativeAddr4.sin_zero), 0, sizeof(nativeAddr4.sin_zero));
		
		struct sockaddr_in6 nativeAddr6;
		nativeAddr6.sin6_len        = sizeof(struct sockaddr_in6);
		nativeAddr6.sin6_family     = AF_INET6;
		nativeAddr6.sin6_port       = htons(port);
		nativeAddr6.sin6_flowinfo   = 0;
		nativeAddr6.sin6_addr       = in6addr_loopback;
		nativeAddr6.sin6_scope_id   = 0;
		
		// Wrap the native address structures
		
		NSData *address4 = [NSData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
		NSData *address6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
		
		addresses = [NSMutableArray arrayWithCapacity:2];
		[addresses addObject:address4];
		[addresses addObject:address6];
	}
	else
	{
		NSString *portStr = [NSString stringWithFormat:@"%hu", port];
		
		struct addrinfo hints, *res, *res0;
		
		memset(&hints, 0, sizeof(hints));
		hints.ai_family   = PF_UNSPEC;
		hints.ai_socktype = SOCK_STREAM;
		hints.ai_protocol = IPPROTO_TCP;
		
//        getaddrinfo 是一个用于网络编程的函数，通常用于将主机名（如域名）和服务名（如端口号）转换为套接字地址。
        // hints 是设置希望返回的 指向一个 struct addrinfo 结构，提供关于 getaddrinfo 需要执行的查询类型的提示。如果是 NULL，表示没有任何提示。
//            该结构允许指定期望的返回地址类型、套接字类型、协议等。
		int gai_error = getaddrinfo([host UTF8String], [portStr UTF8String], &hints, &res0);
		
        // 如果有错误
		if (gai_error)
		{
			error = [self gaiError:gai_error];
		}
		else
		{
			NSUInteger capacity = 0;
			for (res = res0; res; res = res->ai_next)
			{
				if (res->ai_family == AF_INET || res->ai_family == AF_INET6) {
					capacity++;
				}
			}
			
			addresses = [NSMutableArray arrayWithCapacity:capacity];
			
            // 返回的 res0 是链式结构，可能包含多个·ipv4,ipv6 ，还可能多个服务器地址
			for (res = res0; res; res = res->ai_next)
			{
				if (res->ai_family == AF_INET)
				{
					// Found IPv4 address.
					// Wrap the native address structure, and add to results.
					
					NSData *address4 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
					[addresses addObject:address4];
				}
				else if (res->ai_family == AF_INET6)
				{
					// Fixes connection issues with IPv6
					// https://github.com/robbiehanson/CocoaAsyncSocket/issues/429#issuecomment-222477158
					
					// Found IPv6 address.
					// Wrap the native address structure, and add to results.
					
                    /*
                    在给定的代码中，对于 res->ai_addr 进行强制类型转换的目的是将其转换为 struct sockaddr_in6 * 类型的指针，以便于访问和操作 IPv6 地址相关的字段。

                    res->ai_addr 实际上是一个指向通用的 struct sockaddr 结构的指针，它用于存储不同地址族（如 IPv4、IPv6）的地址信息。因为 struct sockaddr_in6 是 struct sockaddr 的一个具体子类型，它包含了额外的 IPv6 地址字段。

                    通过将 res->ai_addr 强制转换为 struct sockaddr_in6 *，我们可以将其视为 struct sockaddr_in6 类型的指针，并直接访问和操作其中的 IPv6 地址字段，如 sin6_port。

                    因此，强制类型转换允许我们将通用的地址结构指针指向的内存解释为特定类型的结构，从而方便我们对其中的字段进行读写操作。
                     */
					struct sockaddr_in6 *sockaddr = (struct sockaddr_in6 *)(void *)res->ai_addr;
					in_port_t *portPtr = &sockaddr->sin6_port;
					if ((portPtr != NULL) && (*portPtr == 0)) {
					        *portPtr = htons(port);
					}

					NSData *address6 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
					[addresses addObject:address6];
				}
			}
			freeaddrinfo(res0);
			
			if ([addresses count] == 0)
			{
				error = [self gaiError:EAI_FAIL];
			}
		}
	}
	
	if (errPtr) *errPtr = error;
	return addresses;
}

+ (NSString *)hostFromSockaddr4:(const struct sockaddr_in *)pSockaddr4
{
	char addrBuf[INET_ADDRSTRLEN];
	
	if (inet_ntop(AF_INET, &pSockaddr4->sin_addr, addrBuf, (socklen_t)sizeof(addrBuf)) == NULL)
	{
		addrBuf[0] = '\0';
	}
	
	return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}

+ (NSString *)hostFromSockaddr6:(const struct sockaddr_in6 *)pSockaddr6
{
	char addrBuf[INET6_ADDRSTRLEN];
	
	if (inet_ntop(AF_INET6, &pSockaddr6->sin6_addr, addrBuf, (socklen_t)sizeof(addrBuf)) == NULL)
	{
		addrBuf[0] = '\0';
	}
	
	return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}

+ (uint16_t)portFromSockaddr4:(const struct sockaddr_in *)pSockaddr4
{
	return ntohs(pSockaddr4->sin_port);
}

+ (uint16_t)portFromSockaddr6:(const struct sockaddr_in6 *)pSockaddr6
{
	return ntohs(pSockaddr6->sin6_port);
}

+ (NSURL *)urlFromSockaddrUN:(const struct sockaddr_un *)pSockaddr
{
	NSString *path = [NSString stringWithUTF8String:pSockaddr->sun_path];
	return [NSURL fileURLWithPath:path];
}

+ (NSString *)hostFromAddress:(NSData *)address
{
	NSString *host;
	
	if ([self getHost:&host port:NULL fromAddress:address])
		return host;
	else
		return nil;
}

+ (uint16_t)portFromAddress:(NSData *)address
{
	uint16_t port;
	
	if ([self getHost:NULL port:&port fromAddress:address])
		return port;
	else
		return 0;
}

+ (BOOL)isIPv4Address:(NSData *)address
{
	if ([address length] >= sizeof(struct sockaddr))
	{
		const struct sockaddr *sockaddrX = [address bytes];
		
		if (sockaddrX->sa_family == AF_INET) {
			return YES;
		}
	}
	
	return NO;
}

+ (BOOL)isIPv6Address:(NSData *)address
{
	if ([address length] >= sizeof(struct sockaddr))
	{
		const struct sockaddr *sockaddrX = [address bytes];
		
		if (sockaddrX->sa_family == AF_INET6) {
			return YES;
		}
	}
	
	return NO;
}

+ (BOOL)getHost:(NSString **)hostPtr port:(uint16_t *)portPtr fromAddress:(NSData *)address
{
	return [self getHost:hostPtr port:portPtr family:NULL fromAddress:address];
}

+ (BOOL)getHost:(NSString **)hostPtr port:(uint16_t *)portPtr family:(sa_family_t *)afPtr fromAddress:(NSData *)address
{
	if ([address length] >= sizeof(struct sockaddr))
	{
		const struct sockaddr *sockaddrX = [address bytes];
		
		if (sockaddrX->sa_family == AF_INET)
		{
			if ([address length] >= sizeof(struct sockaddr_in))
			{
				struct sockaddr_in sockaddr4;
				memcpy(&sockaddr4, sockaddrX, sizeof(sockaddr4));
				
				if (hostPtr) *hostPtr = [self hostFromSockaddr4:&sockaddr4];
				if (portPtr) *portPtr = [self portFromSockaddr4:&sockaddr4];
				if (afPtr)   *afPtr   = AF_INET;
				
				return YES;
			}
		}
		else if (sockaddrX->sa_family == AF_INET6)
		{
			if ([address length] >= sizeof(struct sockaddr_in6))
			{
				struct sockaddr_in6 sockaddr6;
				memcpy(&sockaddr6, sockaddrX, sizeof(sockaddr6));
				
				if (hostPtr) *hostPtr = [self hostFromSockaddr6:&sockaddr6];
				if (portPtr) *portPtr = [self portFromSockaddr6:&sockaddr6];
				if (afPtr)   *afPtr   = AF_INET6;
				
				return YES;
			}
		}
	}
	
	return NO;
}

+ (NSData *)CRLFData
{
	return [NSData dataWithBytes:"\x0D\x0A" length:2];
}

+ (NSData *)CRData
{
	return [NSData dataWithBytes:"\x0D" length:1];
}

+ (NSData *)LFData
{
	return [NSData dataWithBytes:"\x0A" length:1];
}

+ (NSData *)ZeroData
{
	return [NSData dataWithBytes:"" length:1];
}

@end	
