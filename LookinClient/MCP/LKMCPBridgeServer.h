//
//  LKMCPBridgeServer.h
//  LookinClient
//
//  Local read-only bridge used by the external MCP server.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LKMCPBridgeServer : NSObject

+ (instancetype)sharedInstance;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
