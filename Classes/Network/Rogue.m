//
//  Rogue.m
//  RogueHTTP
//
//  Created by Courtney Holmes on 7/6/11.
//  Copyright 2011 Unemployed. All rights reserved.
//

#import "Rogue.h"

static NSDictionary *mimeTypes = nil;

@implementation Rogue

/*	Take a BSD socket handle and use it to initialize a Rogue server. */

- (id)initWithNativeSocket:(CFSocketNativeHandle)nativeSocket {
	CFReadStreamRef	readStream = nil;
	CFWriteStreamRef writeStream = nil;
	
	self = [super init];
	if (self) {
		state = RogueStateStartup;
		
		request = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, TRUE);
		
		/*	NSStream doesn't support creation from sockets.  But CFStream does, and you get
			toll-free bridging between the CFStream classes and their NSStream counterparts.
		 */
		CFStreamCreatePairWithSocket (kCFAllocatorDefault, nativeSocket, &readStream, &writeStream);
		if (readStream && writeStream) {
			netInStream = (NSInputStream*) readStream;
			[netInStream setProperty:NSStreamNetworkServiceTypeVoIP forKey:NSStreamNetworkServiceType];
			[netInStream setDelegate:self];
			[netInStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
			[netInStream open];
			
			netOutStream = (NSOutputStream*) writeStream;
			[netOutStream setProperty:NSStreamNetworkServiceTypeVoIP forKey:NSStreamNetworkServiceType];
			[netOutStream setDelegate:self];
			[netOutStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
			[netOutStream open];
			
			state = RogueStateReceiveRequestHeader;
		} else {
			state = RogueStateShutDown;
		}
		
		[self retain];
	}
	
	if (!mimeTypes)
		mimeTypes  = [[NSDictionary dictionaryWithObjectsAndKeys:
					   @"audio/mpeg", @"mp3",
					   @"audio/vnd.wave", @"wav",
					   @"application/javascript", @"js",
					   @"application/pdf", @"pdf",
					   @"text/plain", @"txt",
					   @"text/html", @"html",
					   @"text/html", @"htm",
					   @"text/xml", @"xml",
					   @"image/jpeg", @"jpg",
					   @"image/jpeg", @"jpeg",
					   @"image/gif", @"gif",
					   @"image/tiff", @"tiff",
					   @"image/png", @"png",
						nil
						] retain];

	return self;
}

- (void)dealloc {
	if (request)
		CFRelease(request);
	
	[netInStream close];
	[netInStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	[netInStream release];
	
	[netOutStream close];
	[netOutStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	[netOutStream release];
	
	[super dealloc];
}

/*	All of our async IO events end up here.  We'll fill up our buffers, and then call
	processRequest.
 */
- (void)stream:(NSStream *)theStream handleEvent:(NSStreamEvent)theEvent {
	if (theEvent &  NSStreamEventOpenCompleted) {
		NSLog(@"Unexpected connection event");
	}
	
	if (theEvent & NSStreamEventHasBytesAvailable) {
		if (theStream == netInStream) {
			netInReady = YES;
		} else if (theStream == fileInStream) {
			fileInReady = YES;
		}
	}
	
	if (theEvent & NSStreamEventHasSpaceAvailable) {
		if (theStream == netOutStream)
			netOutReady = YES;
	}
	
	if (theEvent & NSStreamEventErrorOccurred) {
		state = RogueStateStreamError;
	}
	
	if (theEvent & NSStreamEventEndEncountered) {
		if (theStream == netInStream) {
			[netInStream close];
			[netInStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
			[netInStream release];
			netInStream = nil;
		}
		// we actually deal with this in our process loop
	}
	
	[self advanceState];
}

/*	Each time we go through this function, we get as far as we can with the data we have, and then
	we return.
 */
- (void) advanceState {
	BOOL keepGoing;
	uint8_t buffer[ROGUE_BUFFER_SIZE];
	NSUInteger length;
	int streamStatus;
	
	do {
		keepGoing = NO;
		
		/*	Consume everything in the buffer and put it into our HTTP message object.
			When the object says it has a complete header, we can transition to a new state.
		 */
		if (state == RogueStateReceiveRequestHeader) {	
			if (netInStream) {
				if ([netInStream hasBytesAvailable]) {
					uint8_t *tempBuf;
					NSUInteger tempBufLength;
					
					if ( [netInStream getBuffer:&tempBuf length:&tempBufLength]) {
						if (tempBufLength > ROGUE_BUFFER_SIZE) 
							tempBufLength = ROGUE_BUFFER_SIZE;
						while ( (length = [netInStream read:buffer maxLength:tempBufLength]) > 0) {
							if (CFHTTPMessageAppendBytes(request, buffer, length)) {
								if (CFHTTPMessageIsHeaderComplete(request))
									state = RogueStateProcessRequest;
							} else
								state = RogueStateShutDown;
						}
					}
				} else {
					streamStatus = [netInStream streamStatus];
					switch ([netInStream streamStatus]) {
						case NSStreamStatusClosed:
						case NSStreamStatusError:
							state = RogueStateShutDown;
					}			
				}
			} else
				state = RogueStateShutDown;			
		}
		
		if (state == RogueStateReceiveRequestBody) {
			/*	We're not enabling this yet.  Doing so will require a different parser,
				implementation of chunked-encoding, and a probably a bunch of other stuff.
			 */
		}
		
		/*	This state requires a completed request.  We fill out all the particulars,
			generate output streams for the header and body, then change the state
		 */
		if (state == RogueStateProcessRequest) {
			[self processRequest];
			state = RogueStateSendResponseHeader;
		}
		
		/*	This state requires the headerInStream be present and available. */
		if (state == RogueStateSendResponseHeader) {
			if ([netOutStream hasSpaceAvailable] && [headerInStream hasBytesAvailable]) {
				if ( (length = [headerInStream read:buffer maxLength:length]) > 0) {
					length = [netOutStream write:buffer maxLength:length];
				} else {
					state = RogueStateSendResponseBody;
				}
			} else {
				/*	We got an event, but apparently we aren't ready.  Check the status of our
					header and network streams.  If the header stream is missing, closed, or err'ed out,
					then we'll just proceed to handling the body.
				 
					If the output stream is missing or err'ed out, then we're going to shut down.
				 */
				if (headerInStream) {
					streamStatus = [headerInStream streamStatus];
					if (streamStatus == NSStreamStatusClosed || streamStatus == NSStreamStatusError)
						state = RogueStateSendResponseBody;
				} else
					state = RogueStateSendResponseBody;

				if (netOutStream) {
					streamStatus = [netOutStream streamStatus];
					if (streamStatus == NSStreamStatusClosed || streamStatus == NSStreamStatusError)
						state = RogueStateShutDown;					
				} else
					state = RogueStateShutDown;
			}
			
		}
		
		/*	This is pretty much just like sending the response header, but with a different stream. */
		if (state == RogueStateSendResponseBody) {
			if (netOutStream && [netOutStream hasSpaceAvailable]
				&& fileInStream && [fileInStream hasBytesAvailable]) {
			
				if ( (length = [fileInStream read:buffer maxLength:length]) > 0) {
					length = [netOutStream write:buffer maxLength:length];
				}
			} else {
				// I know this looks like a call-after-check error, but messages sent to nil return 0.
				streamStatus = [fileInStream streamStatus];
				if (!fileInStream || streamStatus==NSStreamStatusClosed || streamStatus==NSStreamStatusError)
					state = RogueStateShutDown;
				
				streamStatus = [netOutStream streamStatus];
				if (!netOutStream || streamStatus==NSStreamStatusClosed || streamStatus==NSStreamStatusError)
					state = RogueStateShutDown;
			}
		}
		
		if (state == RogueStateStreamError) {
			NSLog(@"Stream error");
			state = RogueStateShutDown;
		}
		
		if (state == RogueStateShutDown) {
			[self autorelease];
			state = RogueStatePostShutdown;
		}
		
		if (state == RogueStatePostShutdown) {
			// do nothing.  The event will just pass us on by.
			// At this point, we're waiting for the event loop to empty the autorelease pool, which
			// will cause deallocation, which in turn will remove the stream events from the run loop.
		}
		
	} while(keepGoing);
}

/*	Assumes we have a valid request header.
 
	Produces a response header output buffer, and optionally a body output buffer.
 */
- (void)processRequest {
	NSFileManager *fileManager = [[[NSFileManager alloc] init] autorelease];
	NSString *filePath;
	NSString *contentType;
	int contentLength;
	int responseCode = 200;
	NSString *respText;

	NSString *method = (NSString*) CFHTTPMessageCopyRequestMethod (request);
	NSURL *url = (NSURL*) CFHTTPMessageCopyRequestURL (request);

	if (! ([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"]) ) {
		responseCode = 405;
		respText = @"MethodNotSupported";
		contentType = @"text/plain";
		fileInStream = [[NSInputStream alloc] initWithData:[NSData dataWithBytes:"Method not supported" length:20]];;
		contentLength = 20;
	}
	
	// Find the file corresponding to the URL
	if (responseCode/200 == 2) {
		BOOL isDir;

		NSArray *searchPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		filePath = [[searchPaths objectAtIndex:0] stringByAppendingPathComponent:[url path]];
		
		if ([fileManager fileExistsAtPath:filePath isDirectory:&isDir] && isDir)
			filePath = [filePath stringByAppendingPathComponent:@"index.html"];
		
		if ( (fileInStream = [[NSInputStream alloc] initWithFileAtPath:filePath]) ) {
			respText = @"OK";
			contentType = [mimeTypes valueForKey:[filePath pathExtension]];
			[[[fileManager attributesOfItemAtPath:filePath error:nil] valueForKey:NSFileSize] integerValue];
		} else {
			responseCode = 404;
			respText = @"FileNotFound";
			contentType = @"text/plain";
			fileInStream = [[NSInputStream alloc] initWithData:[NSData dataWithBytes:"File not found" length:14]];
			contentLength = 14;
		}
	}
	
	// Check lastmod date.  (Not Implemented)
	if (responseCode/200 == 2) {
		NSString *imsDate = (NSString*) CFHTTPMessageCopyHeaderFieldValue(request, (CFStringRef)@"if-modified-since");
		
		[imsDate release];
	}
	
	// create the response
	CFHTTPMessageRef response = CFHTTPMessageCreateResponse (kCFAllocatorDefault, responseCode, (CFStringRef)respText, kCFHTTPVersion1_0);
	CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Type", (CFStringRef) contentType);
	CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Content-Length", (CFStringRef)[NSString stringWithFormat:@"%ld",contentLength]);
	CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Location", (CFStringRef) [url path]);
	
	// Sun, 06 Nov 1994 08:49:37 GMT
	time_t now = time(NULL);
	struct tm timeptr;
	char rawstring[64];
	gmtime_r(&now, &timeptr);
	long len = strftime(rawstring, 64, "%a, %d %b %Y %H:%M:%S %Z", &timeptr);
	if (len>0)
		CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Date", 
										 (CFStringRef)[NSString stringWithCString:rawstring encoding:NSASCIIStringEncoding]);
	
	CFHTTPMessageSetHeaderFieldValue(response, (CFStringRef)@"Server", (CFStringRef)@"RogueHTTP/0.1");
	
	NSData *outputData = (NSData*) CFHTTPMessageCopySerializedMessage (response);
	if (outputData) {
		headerInStream = [[NSInputStream alloc] initWithData:outputData];
		state = RogueStateSendResponseHeader;
	} else {
		NSLog(@"Unable to build header.");
		state = RogueStateShutDown;
	}
	
	if (headerInStream) {
		[headerInStream setDelegate:self];
		[headerInStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
		[headerInStream open];
	}
	
	if (fileInStream) {
		[fileInStream setDelegate:self];
		[fileInStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
		[fileInStream open];
	}		
}

@end
