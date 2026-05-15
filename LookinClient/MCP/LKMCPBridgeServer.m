//
//  LKMCPBridgeServer.m
//  LookinClient
//
//  Local read-only bridge used by the external MCP server.
//

#import "LKMCPBridgeServer.h"
#import "LKAppsManager.h"
#import "LKExportManager.h"
#import "LKStaticHierarchyDataSource.h"
#import "LookinDisplayItem+LookinClient.h"
#import "LookinAppInfo.h"
#import "LookinHierarchyInfo.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

static const uint16_t LKMCPBridgePort = 47638;
static const size_t LKMCPBridgeMaxRequestLength = 8192;

@interface LKMCPBridgeServer ()

@property(nonatomic, assign) int serverSocket;
@property(nonatomic, strong) dispatch_queue_t serverQueue;
@property(nonatomic, assign) BOOL running;

@end

@implementation LKMCPBridgeServer

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static LKMCPBridgeServer *instance = nil;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _serverSocket = -1;
        _serverQueue = dispatch_queue_create("work.lookin.mcp.bridge", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (self.running) {
        return;
    }
    
    int socketFD = socket(AF_INET, SOCK_STREAM, 0);
    if (socketFD < 0) {
        NSLog(@"Lookin MCP bridge failed to create socket: %d", errno);
        return;
    }
    
    int reuse = 1;
    setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(LKMCPBridgePort);
    
    if (bind(socketFD, (struct sockaddr *)&address, sizeof(address)) < 0) {
        NSLog(@"Lookin MCP bridge failed to bind 127.0.0.1:%d: %d", LKMCPBridgePort, errno);
        close(socketFD);
        return;
    }
    
    if (listen(socketFD, 8) < 0) {
        NSLog(@"Lookin MCP bridge failed to listen: %d", errno);
        close(socketFD);
        return;
    }
    
    self.serverSocket = socketFD;
    self.running = YES;
    
    dispatch_async(self.serverQueue, ^{
        [self _acceptLoop];
    });
}

- (void)stop {
    self.running = NO;
    if (self.serverSocket >= 0) {
        close(self.serverSocket);
        self.serverSocket = -1;
    }
}

#pragma mark - Socket

- (void)_acceptLoop {
    while (self.running) {
        int clientFD = accept(self.serverSocket, NULL, NULL);
        if (clientFD < 0) {
            if (self.running) {
                NSLog(@"Lookin MCP bridge accept failed: %d", errno);
            }
            continue;
        }
        int noSigPipe = 1;
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        [self _handleClient:clientFD];
    }
}

- (void)_handleClient:(int)clientFD {
    NSMutableData *requestData = [NSMutableData data];
    uint8_t buffer[1024];
    
    while (requestData.length < LKMCPBridgeMaxRequestLength) {
        ssize_t readLength = read(clientFD, buffer, sizeof(buffer));
        if (readLength <= 0) {
            break;
        }
        [requestData appendBytes:buffer length:(NSUInteger)readLength];
        NSData *headerEnd = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        if ([requestData rangeOfData:headerEnd options:0 range:NSMakeRange(0, requestData.length)].location != NSNotFound) {
            break;
        }
    }
    
    NSString *request = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
    NSString *requestLine = [[request componentsSeparatedByString:@"\r\n"] firstObject];
    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    if (parts.count < 2 || ![parts.firstObject isEqualToString:@"GET"]) {
        [self _writeJSON:@{@"error": @"Only GET is supported."} status:405 client:clientFD];
        return;
    }
    
    NSURLComponents *components = [NSURLComponents componentsWithString:parts[1]];
    NSString *path = components.path;
    NSDictionary<NSString *, NSString *> *query = [self _queryDictionaryFromItems:components.queryItems];
    
    if ([path isEqualToString:@"/status"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _handleStatusWithClient:clientFD];
        });
        return;
    }
    
    if ([path isEqualToString:@"/snapshot"]) {
        BOOL refresh = ![query[@"refresh"] isEqualToString:@"0"];
        CGFloat compression = query[@"compression"].length ? query[@"compression"].doubleValue : 0.5;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _handleSnapshotWithRefresh:refresh compression:compression client:clientFD];
        });
        return;
    }
    
    if ([path isEqualToString:@"/selected-screenshot"]) {
        NSString *type = query[@"type"] ?: @"auto";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _handleSelectedScreenshotWithType:type client:clientFD];
        });
        return;
    }
    
    [self _writeJSON:@{@"error": @"Unknown endpoint."} status:404 client:clientFD];
}

#pragma mark - Handlers

- (void)_handleStatusWithClient:(int)clientFD {
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    LookinHierarchyInfo *cachedInfo = [LKStaticHierarchyDataSource sharedInstance].rawHierarchyInfo;
    NSMutableDictionary *payload = [@{
        @"bridge": @"lookin-mcp",
        @"port": @(LKMCPBridgePort),
        @"connected": @(app != nil),
        @"hasCachedHierarchy": @(cachedInfo != nil)
    } mutableCopy];
    
    NSDictionary *appInfo = [self _dictionaryFromAppInfo:app.appInfo ?: cachedInfo.appInfo];
    if (appInfo) {
        payload[@"app"] = appInfo;
    }
    
    [self _writeJSON:payload status:200 client:clientFD];
}

- (void)_handleSnapshotWithRefresh:(BOOL)refresh compression:(CGFloat)compression client:(int)clientFD {
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    
    if (refresh && app) {
        [[[app fetchHierarchyData] deliverOnMainThread] subscribeNext:^(LookinHierarchyInfo *info) {
            [self _writeSnapshotWithHierarchyInfo:info compression:compression source:@"refreshed" client:clientFD];
        } error:^(NSError * _Nullable error) {
            [self _writeJSON:[self _dictionaryFromError:error] status:502 client:clientFD];
        }];
        return;
    }
    
    LookinHierarchyInfo *cachedInfo = [LKStaticHierarchyDataSource sharedInstance].rawHierarchyInfo;
    if (cachedInfo) {
        [self _writeSnapshotWithHierarchyInfo:cachedInfo compression:compression source:@"cached" client:clientFD];
        return;
    }
    
    [self _writeJSON:@{@"error": @"No connected app or cached hierarchy."} status:409 client:clientFD];
}

- (void)_writeSnapshotWithHierarchyInfo:(LookinHierarchyInfo *)info compression:(CGFloat)compression source:(NSString *)source client:(int)clientFD {
    if (!info) {
        [self _writeJSON:@{@"error": @"Hierarchy info is empty."} status:500 client:clientFD];
        return;
    }
    
    NSString *fileName = nil;
    NSData *data = [[LKExportManager sharedInstance] dataFromHierarchyInfo:info imageCompression:compression fileName:&fileName];
    if (!data) {
        [self _writeJSON:@{@"error": @"Failed to export hierarchy snapshot."} status:500 client:clientFD];
        return;
    }
    
    NSMutableDictionary<NSString *, NSString *> *headers = [@{
        @"Content-Type": @"application/octet-stream",
        @"X-Lookin-Live-Source": source
    } mutableCopy];
    if (fileName.length) {
        headers[@"X-Lookin-File-Name"] = fileName;
    }
    [self _writeBody:data status:200 headers:headers client:clientFD];
}

- (void)_handleSelectedScreenshotWithType:(NSString *)type client:(int)clientFD {
    LookinDisplayItem *item = [LKStaticHierarchyDataSource sharedInstance].selectedItem;
    if (!item) {
        [self _writeJSON:@{@"error": @"No selected hierarchy item."} status:409 client:clientFD];
        return;
    }
    
    NSImage *image = nil;
    NSString *resolvedType = type;
    if ([type isEqualToString:@"solo"]) {
        image = item.soloScreenshot;
    } else if ([type isEqualToString:@"group"]) {
        image = item.groupScreenshot;
    } else {
        image = item.appropriateScreenshot;
        resolvedType = (item.isExpandable && item.isExpanded) ? @"solo" : @"group";
    }
    
    if (!image) {
        [self _writeJSON:@{@"error": @"Selected item has no screenshot. Try refreshing details in Lookin first."} status:409 client:clientFD];
        return;
    }
    
    NSData *imageData = [image TIFFRepresentationUsingCompression:NSTIFFCompressionLZW factor:1];
    if (!imageData) {
        [self _writeJSON:@{@"error": @"Failed to encode selected item screenshot."} status:500 client:clientFD];
        return;
    }
    
    NSMutableDictionary<NSString *, NSString *> *headers = [@{
        @"Content-Type": @"image/tiff",
        @"X-Lookin-Screenshot-Type": resolvedType
    } mutableCopy];
    NSString *title = [self _httpHeaderSafeString:item.title];
    if (title.length) {
        headers[@"X-Lookin-Item-Title"] = title;
    }
    if (item.layerObject.oid) {
        headers[@"X-Lookin-Layer-Oid"] = [NSString stringWithFormat:@"%@", @(item.layerObject.oid)];
    }
    [self _writeBody:imageData status:200 headers:headers client:clientFD];
}

#pragma mark - Response

- (void)_writeJSON:(NSDictionary *)payload status:(NSUInteger)status client:(int)clientFD {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil] ?: [NSData data];
    [self _writeBody:data status:status headers:@{@"Content-Type": @"application/json; charset=utf-8"} client:clientFD];
}

- (void)_writeBody:(NSData *)body status:(NSUInteger)status headers:(NSDictionary<NSString *, NSString *> *)headers client:(int)clientFD {
    NSString *reason = [self _reasonForStatus:status];
    NSMutableString *header = [NSMutableString stringWithFormat:@"HTTP/1.1 %lu %@\r\n", (unsigned long)status, reason];
    [header appendString:@"Connection: close\r\n"];
    [header appendFormat:@"Content-Length: %@\r\n", @(body.length)];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [header appendFormat:@"%@: %@\r\n", key, value];
    }];
    [header appendString:@"\r\n"];
    
    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
    [self _writeData:headerData client:clientFD];
    [self _writeData:body client:clientFD];
    close(clientFD);
}

- (void)_writeData:(NSData *)data client:(int)clientFD {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(clientFD, bytes, remaining);
        if (written <= 0) {
            break;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
}

#pragma mark - Helpers

- (NSDictionary<NSString *, NSString *> *)_queryDictionaryFromItems:(NSArray<NSURLQueryItem *> *)items {
    NSMutableDictionary<NSString *, NSString *> *dict = [NSMutableDictionary dictionary];
    [items enumerateObjectsUsingBlock:^(NSURLQueryItem *item, NSUInteger idx, BOOL *stop) {
        if (item.name.length) {
            dict[item.name] = item.value ?: @"";
        }
    }];
    return dict;
}

- (NSDictionary *)_dictionaryFromAppInfo:(LookinAppInfo *)appInfo {
    if (!appInfo) {
        return nil;
    }
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (appInfo.appName.length) {
        dict[@"appName"] = appInfo.appName;
    }
    if (appInfo.osDescription.length) {
        dict[@"osDescription"] = appInfo.osDescription;
    }
    if (appInfo.serverReadableVersion.length) {
        dict[@"serverReadableVersion"] = appInfo.serverReadableVersion;
    }
    return dict.copy;
}

- (NSDictionary *)_dictionaryFromError:(NSError *)error {
    if (!error) {
        return @{@"error": @"Unknown error."};
    }
    NSMutableDictionary *dict = [@{
        @"error": error.localizedDescription ?: @"Request failed.",
        @"code": @(error.code)
    } mutableCopy];
    if (error.localizedRecoverySuggestion.length) {
        dict[@"recoverySuggestion"] = error.localizedRecoverySuggestion;
    }
    return dict.copy;
}

- (NSString *)_reasonForStatus:(NSUInteger)status {
    switch (status) {
        case 200:
            return @"OK";
        case 404:
            return @"Not Found";
        case 405:
            return @"Method Not Allowed";
        case 409:
            return @"Conflict";
        case 502:
            return @"Bad Gateway";
        default:
            return @"Internal Server Error";
    }
}

- (NSString *)_httpHeaderSafeString:(NSString *)string {
    if (!string.length) {
        return nil;
    }
    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    NSArray<NSString *> *parts = [string componentsSeparatedByCharactersInSet:newlines];
    return [parts componentsJoinedByString:@" "];
}

@end
