//
//  LKMCPBridgeServer.m
//  LookinClient
//
//  Local bridge used by the external MCP server.
//

#import "LKMCPBridgeServer.h"
#import "LKAppsManager.h"
#import "LKExportManager.h"
#import "LKHelper.h"
#import "LKStaticAsyncUpdateManager.h"
#import "LKStaticHierarchyDataSource.h"
#import "LookinDashboardBlueprint.h"
#import "LookinDisplayItem+LookinClient.h"
#import "LookinAttributeModification.h"
#import "LookinAppInfo.h"
#import "LookinDisplayItemDetail.h"
#import "LookinHierarchyInfo.h"
#import "LookinObject.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

static const uint16_t LKMCPBridgePort = 47638;
static const size_t LKMCPBridgeMaxRequestLength = 8192;
static const size_t LKMCPBridgeMaxBodyLength = 65536;

static NSSet<NSString *> *LKMCPAllowedInvokeMethods(void) {
    static NSSet<NSString *> *methods = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        methods = [NSSet setWithArray:@[
            @"setNeedsLayout",
            @"layoutIfNeeded",
            @"setNeedsDisplay",
            @"reloadData",
            @"reloadInputViews"
        ]];
    });
    return methods;
}

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

    NSData *headerEnd = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange headerEndRange = [requestData rangeOfData:headerEnd options:0 range:NSMakeRange(0, requestData.length)];
    if (headerEndRange.location == NSNotFound) {
        [self _writeJSON:@{@"error": @"Invalid HTTP request."} status:400 client:clientFD];
        return;
    }

    NSData *headerData = [requestData subdataWithRange:NSMakeRange(0, headerEndRange.location)];
    NSString *request = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    NSString *requestLine = [[request componentsSeparatedByString:@"\r\n"] firstObject];
    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    if (parts.count < 2) {
        [self _writeJSON:@{@"error": @"Invalid HTTP request line."} status:400 client:clientFD];
        return;
    }

    NSString *method = parts.firstObject;
    NSURLComponents *components = [NSURLComponents componentsWithString:parts[1]];
    NSString *path = components.path;
    NSDictionary<NSString *, NSString *> *query = [self _queryDictionaryFromItems:components.queryItems];

    if (![method isEqualToString:@"GET"] && ![method isEqualToString:@"POST"]) {
        [self _writeJSON:@{@"error": @"Only GET and POST are supported."} status:405 client:clientFD];
        return;
    }

    if ([path isEqualToString:@"/status"]) {
        if (![method isEqualToString:@"GET"]) {
            [self _writeJSON:@{@"error": @"Use GET for /status."} status:405 client:clientFD];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _handleStatusWithClient:clientFD];
        });
        return;
    }

    if ([path isEqualToString:@"/selected-item"]) {
        if (![method isEqualToString:@"GET"]) {
            [self _writeJSON:@{@"error": @"Use GET for /selected-item."} status:405 client:clientFD];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _handleSelectedItemWithClient:clientFD];
        });
        return;
    }

    if ([path isEqualToString:@"/snapshot"]) {
        if (![method isEqualToString:@"GET"]) {
            [self _writeJSON:@{@"error": @"Use GET for /snapshot."} status:405 client:clientFD];
            return;
        }
        BOOL refresh = ![query[@"refresh"] isEqualToString:@"0"];
        CGFloat compression = query[@"compression"].length ? query[@"compression"].doubleValue : 0.5;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _handleSnapshotWithRefresh:refresh compression:compression client:clientFD];
        });
        return;
    }

    if ([path isEqualToString:@"/selected-screenshot"]) {
        if (![method isEqualToString:@"GET"]) {
            [self _writeJSON:@{@"error": @"Use GET for /selected-screenshot."} status:405 client:clientFD];
            return;
        }
        NSString *type = query[@"type"] ?: @"auto";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _handleSelectedScreenshotWithType:type client:clientFD];
        });
        return;
    }

    if ([path isEqualToString:@"/invoke-method"] || [path isEqualToString:@"/selected-frame"] || [path isEqualToString:@"/set-property"] || [path isEqualToString:@"/set-constraint-property"]) {
        if (![method isEqualToString:@"POST"]) {
            [self _writeJSON:@{@"error": @"Use POST for write endpoints."} status:405 client:clientFD];
            return;
        }
        NSDictionary *body = [self _readJSONBodyWithRequestData:requestData headerString:request headerEndRange:headerEndRange client:clientFD];
        if (!body) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([path isEqualToString:@"/invoke-method"]) {
                [self _handleInvokeMethodWithBody:body client:clientFD];
            } else if ([path isEqualToString:@"/selected-frame"]) {
                [self _handleSelectedFrameWithBody:body client:clientFD];
            } else if ([path isEqualToString:@"/set-property"]) {
                [self _handleSetPropertyWithBody:body client:clientFD];
            } else {
                [self _handleSetConstraintPropertyWithBody:body client:clientFD];
            }
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

- (void)_handleSelectedItemWithClient:(int)clientFD {
    LookinDisplayItem *item = [LKStaticHierarchyDataSource sharedInstance].selectedItem;
    if (!item) {
        [self _writeJSON:@{@"error": @"No selected hierarchy item."} status:409 client:clientFD];
        return;
    }

    NSMutableDictionary *payload = [@{
        @"title": item.title ?: @"",
        @"subtitle": item.subtitle ?: @"",
        @"depth": @(item.indentLevel),
        @"child_count": @(item.subitems.count),
        @"hidden": @(item.inHiddenHierarchy),
        @"displaying": @(item.displayingInHierarchy),
        @"frame": [self _dictionaryFromRect:item.frame],
        @"bounds": [self _dictionaryFromRect:item.bounds]
    } mutableCopy];

    NSDictionary *view = [self _dictionaryFromObject:item.viewObject];
    NSDictionary *layer = [self _dictionaryFromObject:item.layerObject];
    NSDictionary *controller = [self _dictionaryFromObject:item.hostViewControllerObject];
    if (view) {
        payload[@"view"] = view;
    }
    if (layer) {
        payload[@"layer"] = layer;
    }
    if (controller) {
        payload[@"controller"] = controller;
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

- (void)_handleInvokeMethodWithBody:(NSDictionary *)body client:(int)clientFD {
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    if (!app) {
        [self _writeJSON:@{@"error": @"No connected app."} status:409 client:clientFD];
        return;
    }

    NSString *text = [body[@"method"] isKindOfClass:[NSString class]] ? body[@"method"] : body[@"text"];
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        [self _writeJSON:@{@"error": @"method is required."} status:400 client:clientFD];
        return;
    }
    if ([text containsString:@":"]) {
        [self _writeJSON:@{@"error": @"Methods with arguments are not supported."} status:400 client:clientFD];
        return;
    }
    if (![LKMCPAllowedInvokeMethods() containsObject:text]) {
        [self _writeJSON:@{@"error": @"Unsupported method. Use one of the allowed no-argument methods."} status:400 client:clientFD];
        return;
    }

    unsigned long oid = [self _oidFromBody:body];
    if (!oid) {
        [self _writeJSON:@{@"error": @"No target object found. Select a hierarchy item or pass oid."} status:409 client:clientFD];
        return;
    }

    [[app invokeMethodWithOid:oid text:text] subscribeNext:^(NSDictionary *value) {
        NSMutableDictionary *payload = [@{
            @"oid": @(oid),
            @"method": text
        } mutableCopy];
        if ([value isKindOfClass:[NSDictionary class]]) {
            [payload addEntriesFromDictionary:value];
        }
        [self _writeJSON:payload status:200 client:clientFD];
    } error:^(NSError * _Nullable error) {
        [self _writeJSON:[self _dictionaryFromError:error] status:502 client:clientFD];
    }];
}

- (void)_handleSelectedFrameWithBody:(NSDictionary *)body client:(int)clientFD {
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    if (!app) {
        [self _writeJSON:@{@"error": @"No connected app."} status:409 client:clientFD];
        return;
    }

    LookinDisplayItem *item = [LKStaticHierarchyDataSource sharedInstance].selectedItem;
    if (!item) {
        [self _writeJSON:@{@"error": @"No selected hierarchy item."} status:409 client:clientFD];
        return;
    }
    if (!item.layerObject.oid) {
        [self _writeJSON:@{@"error": @"Selected item has no layer object."} status:409 client:clientFD];
        return;
    }

    NSNumber *x = [self _numberFromBody:body key:@"x"];
    NSNumber *y = [self _numberFromBody:body key:@"y"];
    NSNumber *width = [self _numberFromBody:body key:@"width"];
    NSNumber *height = [self _numberFromBody:body key:@"height"];
    if (!x || !y || !width || !height) {
        [self _writeJSON:@{@"error": @"x, y, width and height are required numbers."} status:400 client:clientFD];
        return;
    }

    CGRect frame = CGRectMake(x.doubleValue, y.doubleValue, width.doubleValue, height.doubleValue);
    LookinAttributeModification *modification = [LookinAttributeModification new];
    modification.clientReadableVersion = [LKHelper lookinReadableVersion];
    modification.targetOid = item.layerObject.oid;
    modification.setterSelector = @selector(setFrame:);
    modification.attrType = LookinAttrTypeCGRect;
    modification.value = [NSValue valueWithRect:frame];

    [[app submitInbuiltModification:modification] subscribeNext:^(LookinDisplayItemDetail *detail) {
        [[LKStaticHierarchyDataSource sharedInstance] modifyWithDisplayItemDetail:detail];
        [[LKStaticAsyncUpdateManager sharedInstance] updateAfterModifyingDisplayItem:(LookinStaticDisplayItem *)item];
        NSDictionary *payload = @{
            @"modified": @YES,
            @"target": @"selected_layer",
            @"layerOid": @(item.layerObject.oid),
            @"frame": @{
                @"x": x,
                @"y": y,
                @"width": width,
                @"height": height
            }
        };
        [self _writeJSON:payload status:200 client:clientFD];
    } error:^(NSError * _Nullable error) {
        [self _writeJSON:[self _dictionaryFromError:error] status:502 client:clientFD];
    }];
}

- (void)_handleSetPropertyWithBody:(NSDictionary *)body client:(int)clientFD {
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    if (!app) {
        [self _writeJSON:@{@"error": @"No connected app."} status:409 client:clientFD];
        return;
    }

    NSString *property = [body[@"property"] isKindOfClass:[NSString class]] ? body[@"property"] : nil;
    NSString *attrID = [body[@"attr_id"] isKindOfClass:[NSString class]] ? body[@"attr_id"] : nil;
    NSDictionary *definition = property.length ? [self _propertyDefinitions][property] : nil;
    if (!attrID.length) {
        attrID = definition[@"attr_id"];
    }
    NSNumber *typeValue = definition[@"type"];
    NSString *setterString = [definition[@"setter"] isKindOfClass:[NSString class]] ? definition[@"setter"] : nil;
    if ((!attrID.length && !setterString.length) || !typeValue) {
        [self _writeJSON:@{@"error": @"Unsupported property. Use a supported property alias or attr_id with a known alias."} status:400 client:clientFD];
        return;
    }

    SEL setter = setterString.length ? NSSelectorFromString(setterString) : [LookinDashboardBlueprint setterWithAttrID:attrID];
    if (!setter) {
        [self _writeJSON:@{@"error": @"This property is not writable in Lookin."} status:400 client:clientFD];
        return;
    }

    LookinAttrType attrType = typeValue.integerValue;
    id value = [self _parsedValueFromBody:body attrType:attrType];
    if (!value) {
        [self _writeJSON:@{@"error": @"Invalid value for target property."} status:400 client:clientFD];
        return;
    }

    unsigned long explicitOid = [self _unsignedLongFromObject:body[@"oid"]];
    LookinDisplayItem *item = [LKStaticHierarchyDataSource sharedInstance].selectedItem;
    NSString *target = [definition[@"target"] isKindOfClass:[NSString class]] ? definition[@"target"] : nil;
    BOOL useViewObject = target.length ? ![target isEqualToString:@"layer"] : [LookinDashboardBlueprint isUIViewPropertyWithAttrID:attrID];
    unsigned long targetOid = explicitOid;
    if (!targetOid) {
        if (!item) {
            [self _writeJSON:@{@"error": @"No selected hierarchy item. Select a view or pass oid."} status:409 client:clientFD];
            return;
        }
        targetOid = useViewObject ? item.viewObject.oid : item.layerObject.oid;
    }
    if (!targetOid) {
        [self _writeJSON:@{@"error": @"No target object found for this property."} status:409 client:clientFD];
        return;
    }

    LookinAttributeModification *modification = [LookinAttributeModification new];
    modification.clientReadableVersion = [LKHelper lookinReadableVersion];
    modification.targetOid = targetOid;
    modification.setterSelector = setter;
    modification.attrType = attrType;
    modification.value = value;

    [[app submitInbuiltModification:modification] subscribeNext:^(LookinDisplayItemDetail *detail) {
        if (detail) {
        [[LKStaticHierarchyDataSource sharedInstance] modifyWithDisplayItemDetail:detail];
    }
        BOOL needsPatch = [definition[@"patch"] respondsToSelector:@selector(boolValue)] ? [definition[@"patch"] boolValue] : (attrID.length && [LookinDashboardBlueprint needPatchAfterModificationWithAttrID:attrID]);
        if (item && needsPatch) {
            [[LKStaticAsyncUpdateManager sharedInstance] updateAfterModifyingDisplayItem:(LookinStaticDisplayItem *)item];
        }
        NSMutableDictionary *payload = [@{
            @"modified": @YES,
            @"property": property ?: (attrID ?: @""),
            @"targetOid": @(targetOid),
            @"target": useViewObject ? @"view" : @"layer"
        } mutableCopy];
        if (attrID.length) {
            payload[@"attr_id"] = attrID;
        }
        [self _writeJSON:payload status:200 client:clientFD];
    } error:^(NSError * _Nullable error) {
        [self _writeJSON:[self _dictionaryFromError:error] status:502 client:clientFD];
    }];
}

- (void)_handleSetConstraintPropertyWithBody:(NSDictionary *)body client:(int)clientFD {
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    if (!app) {
        [self _writeJSON:@{@"error": @"No connected app."} status:409 client:clientFD];
        return;
    }

    unsigned long oid = [self _unsignedLongFromObject:body[@"oid"]];
    if (!oid) {
        [self _writeJSON:@{@"error": @"Explicit NSLayoutConstraint oid is required."} status:400 client:clientFD];
        return;
    }
    NSString *property = [body[@"property"] isKindOfClass:[NSString class]] ? body[@"property"] : nil;
    NSDictionary *definition = [self _constraintPropertyDefinitions][property ?: @""];
    if (!definition) {
        [self _writeJSON:@{@"error": @"Unsupported constraint property. Supported: constant, priority, active."} status:400 client:clientFD];
        return;
    }

    LookinAttrType attrType = [definition[@"type"] integerValue];
    id value = [self _parsedValueFromBody:body attrType:attrType];
    if (!value) {
        [self _writeJSON:@{@"error": @"Invalid value for target constraint property."} status:400 client:clientFD];
        return;
    }

    LookinAttributeModification *modification = [LookinAttributeModification new];
    modification.clientReadableVersion = [LKHelper lookinReadableVersion];
    modification.targetOid = oid;
    modification.setterSelector = NSSelectorFromString(definition[@"setter"]);
    modification.attrType = attrType;
    modification.value = value;

    LookinDisplayItem *item = [LKStaticHierarchyDataSource sharedInstance].selectedItem;
    [[app submitInbuiltModification:modification] subscribeNext:^(LookinDisplayItemDetail *detail) {
        if (detail) {
            [[LKStaticHierarchyDataSource sharedInstance] modifyWithDisplayItemDetail:detail];
        }
        if (item) {
            [[LKStaticAsyncUpdateManager sharedInstance] updateAfterModifyingDisplayItem:(LookinStaticDisplayItem *)item];
        }
        NSDictionary *payload = @{
            @"modified": @YES,
            @"property": property,
            @"target": @"constraint",
            @"targetOid": @(oid)
        };
        [self _writeJSON:payload status:200 client:clientFD];
    } error:^(NSError * _Nullable error) {
        [self _writeJSON:[self _dictionaryFromError:error] status:502 client:clientFD];
    }];
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

- (NSDictionary *)_readJSONBodyWithRequestData:(NSMutableData *)requestData headerString:(NSString *)headerString headerEndRange:(NSRange)headerEndRange client:(int)clientFD {
    NSUInteger contentLength = [self _contentLengthFromHeaderString:headerString];
    if (contentLength == 0) {
        [self _writeJSON:@{@"error": @"Content-Length is required."} status:400 client:clientFD];
        return nil;
    }
    if (contentLength > LKMCPBridgeMaxBodyLength) {
        [self _writeJSON:@{@"error": @"Request body is too large."} status:413 client:clientFD];
        return nil;
    }

    NSUInteger bodyStart = NSMaxRange(headerEndRange);
    NSMutableData *bodyData = [NSMutableData dataWithCapacity:contentLength];
    if (requestData.length > bodyStart) {
        NSUInteger availableLength = MIN(requestData.length - bodyStart, contentLength);
        [bodyData appendData:[requestData subdataWithRange:NSMakeRange(bodyStart, availableLength)]];
    }

    uint8_t buffer[1024];
    while (bodyData.length < contentLength) {
        ssize_t readLength = read(clientFD, buffer, MIN(sizeof(buffer), contentLength - bodyData.length));
        if (readLength <= 0) {
            break;
        }
        [bodyData appendBytes:buffer length:(NSUInteger)readLength];
    }

    if (bodyData.length < contentLength) {
        [self _writeJSON:@{@"error": @"Request body is incomplete."} status:400 client:clientFD];
        return nil;
    }

    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&error];
    if (![json isKindOfClass:[NSDictionary class]]) {
        [self _writeJSON:@{@"error": error.localizedDescription ?: @"Request body must be a JSON object."} status:400 client:clientFD];
        return nil;
    }
    return json;
}

- (NSUInteger)_contentLengthFromHeaderString:(NSString *)headerString {
    NSArray<NSString *> *lines = [headerString componentsSeparatedByString:@"\r\n"];
    for (NSString *line in lines) {
        NSRange separatorRange = [line rangeOfString:@":"];
        if (separatorRange.location == NSNotFound) {
            continue;
        }
        NSString *name = [[line substringToIndex:separatorRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![name.lowercaseString isEqualToString:@"content-length"]) {
            continue;
        }
        NSString *value = [[line substringFromIndex:NSMaxRange(separatorRange)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSScanner *scanner = [NSScanner scannerWithString:value];
        unsigned long long length = 0;
        if ([scanner scanUnsignedLongLong:&length] && scanner.isAtEnd) {
            return (NSUInteger)length;
        }
        return 0;
    }
    return 0;
}

- (unsigned long)_oidFromBody:(NSDictionary *)body {
    unsigned long explicitOid = [self _unsignedLongFromObject:body[@"oid"]];
    if (explicitOid) {
        return explicitOid;
    }

    LookinDisplayItem *item = [LKStaticHierarchyDataSource sharedInstance].selectedItem;
    if (!item) {
        return 0;
    }

    NSString *target = [body[@"target"] isKindOfClass:[NSString class]] ? body[@"target"] : @"selected_view";
    if ([target isEqualToString:@"selected_layer"] || [target isEqualToString:@"layer"]) {
        return item.layerObject.oid;
    }
    if ([target isEqualToString:@"selected_controller"] || [target isEqualToString:@"controller"]) {
        return item.hostViewControllerObject.oid;
    }
    if ([target isEqualToString:@"selected_view"] || [target isEqualToString:@"view"]) {
        return item.viewObject.oid;
    }
    return 0;
}

- (unsigned long)_unsignedLongFromObject:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value unsignedLongValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        unsigned long long number = 0;
        if ([scanner scanUnsignedLongLong:&number] && scanner.isAtEnd) {
            return (unsigned long)number;
        }
    }
    return 0;
}

- (NSNumber *)_numberFromBody:(NSDictionary *)body key:(NSString *)key {
    id value = body[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        double number = 0;
        if ([scanner scanDouble:&number] && scanner.isAtEnd) {
            return @(number);
        }
    }
    return nil;
}

- (id)_parsedValueFromBody:(NSDictionary *)body attrType:(LookinAttrType)attrType {
    id rawValue = body[@"value"];
    if (!rawValue) {
        rawValue = body;
    }

    switch (attrType) {
        case LookinAttrTypeBOOL:
            return [self _boolNumberFromObject:rawValue];
        case LookinAttrTypeChar:
        case LookinAttrTypeInt:
        case LookinAttrTypeShort:
        case LookinAttrTypeLong:
        case LookinAttrTypeLongLong:
        case LookinAttrTypeUnsignedChar:
        case LookinAttrTypeUnsignedInt:
        case LookinAttrTypeUnsignedShort:
        case LookinAttrTypeUnsignedLong:
        case LookinAttrTypeUnsignedLongLong:
        case LookinAttrTypeFloat:
        case LookinAttrTypeDouble:
        case LookinAttrTypeEnumInt:
        case LookinAttrTypeEnumLong:
            return [self _numberFromObject:rawValue];
        case LookinAttrTypeNSString:
        case LookinAttrTypeEnumString:
            return [rawValue isKindOfClass:[NSString class]] ? rawValue : nil;
        case LookinAttrTypeCGPoint:
            return [self _pointValueFromObject:rawValue];
        case LookinAttrTypeCGSize:
            return [self _sizeValueFromObject:rawValue];
        case LookinAttrTypeCGRect:
            return [self _rectValueFromObject:rawValue];
        case LookinAttrTypeUIEdgeInsets:
            return [self _edgeInsetsValueFromObject:rawValue];
        case LookinAttrTypeUIColor:
            return [self _rgbaComponentsFromObject:rawValue];
        default:
            return nil;
    }
}

- (NSNumber *)_numberFromObject:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        double number = 0;
        if ([scanner scanDouble:&number] && scanner.isAtEnd) {
            return @(number);
        }
    }
    return nil;
}

- (NSNumber *)_boolNumberFromObject:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) {
        return @([(NSNumber *)value boolValue]);
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lowercaseValue = [(NSString *)value lowercaseString];
        if ([lowercaseValue isEqualToString:@"true"] || [lowercaseValue isEqualToString:@"yes"] || [lowercaseValue isEqualToString:@"1"]) {
            return @YES;
        }
        if ([lowercaseValue isEqualToString:@"false"] || [lowercaseValue isEqualToString:@"no"] || [lowercaseValue isEqualToString:@"0"]) {
            return @NO;
        }
    }
    return nil;
}

- (NSValue *)_rectValueFromObject:(id)value {
    NSDictionary *dict = [value isKindOfClass:[NSDictionary class]] ? value : nil;
    NSNumber *x = [self _numberFromObject:dict[@"x"]];
    NSNumber *y = [self _numberFromObject:dict[@"y"]];
    NSNumber *width = [self _numberFromObject:dict[@"width"]];
    NSNumber *height = [self _numberFromObject:dict[@"height"]];
    if (!x || !y || !width || !height) {
        return nil;
    }
    return [NSValue valueWithRect:NSMakeRect(x.doubleValue, y.doubleValue, width.doubleValue, height.doubleValue)];
}

- (NSValue *)_pointValueFromObject:(id)value {
    NSDictionary *dict = [value isKindOfClass:[NSDictionary class]] ? value : nil;
    NSNumber *x = [self _numberFromObject:dict[@"x"]];
    NSNumber *y = [self _numberFromObject:dict[@"y"]];
    if (!x || !y) {
        return nil;
    }
    return [NSValue valueWithPoint:NSMakePoint(x.doubleValue, y.doubleValue)];
}

- (NSValue *)_sizeValueFromObject:(id)value {
    NSDictionary *dict = [value isKindOfClass:[NSDictionary class]] ? value : nil;
    NSNumber *width = [self _numberFromObject:dict[@"width"]];
    NSNumber *height = [self _numberFromObject:dict[@"height"]];
    if (!width || !height) {
        return nil;
    }
    return [NSValue valueWithSize:NSMakeSize(width.doubleValue, height.doubleValue)];
}

- (NSValue *)_edgeInsetsValueFromObject:(id)value {
    NSDictionary *dict = [value isKindOfClass:[NSDictionary class]] ? value : nil;
    NSNumber *top = [self _numberFromObject:dict[@"top"]];
    NSNumber *left = [self _numberFromObject:dict[@"left"]];
    NSNumber *bottom = [self _numberFromObject:dict[@"bottom"]];
    NSNumber *right = [self _numberFromObject:dict[@"right"]];
    if (!top || !left || !bottom || !right) {
        return nil;
    }
    return [NSValue valueWithEdgeInsets:NSEdgeInsetsMake(top.doubleValue, left.doubleValue, bottom.doubleValue, right.doubleValue)];
}

- (NSArray<NSNumber *> *)_rgbaComponentsFromObject:(id)value {
    if ([value isKindOfClass:[NSString class]]) {
        return [self _rgbaComponentsFromHexString:value];
    }
    NSArray *values = nil;
    if ([value isKindOfClass:[NSArray class]]) {
        values = value;
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = value;
        values = @[dict[@"r"] ?: dict[@"red"] ?: [NSNull null],
                   dict[@"g"] ?: dict[@"green"] ?: [NSNull null],
                   dict[@"b"] ?: dict[@"blue"] ?: [NSNull null],
                   dict[@"a"] ?: dict[@"alpha"] ?: @(1)];
    }
    if (values.count != 3 && values.count != 4) {
        return nil;
    }

    NSMutableArray<NSNumber *> *components = [NSMutableArray arrayWithCapacity:4];
    for (NSUInteger idx = 0; idx < values.count; idx++) {
        NSNumber *number = [self _numberFromObject:values[idx]];
        if (!number) {
            return nil;
        }
        double component = number.doubleValue;
        if (component > 1) {
            component = component / 255.0;
        }
        component = MAX(0, MIN(1, component));
        [components addObject:@(component)];
    }
    if (components.count == 3) {
        [components addObject:@(1)];
    }
    return components.copy;
}

- (NSArray<NSNumber *> *)_rgbaComponentsFromHexString:(NSString *)string {
    NSString *hex = [[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([hex hasPrefix:@"#"]) {
        hex = [hex substringFromIndex:1];
    }
    if (hex.length != 6 && hex.length != 8) {
        return nil;
    }
    unsigned int rgba = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexInt:&rgba]) {
        return nil;
    }
    CGFloat red = 0;
    CGFloat green = 0;
    CGFloat blue = 0;
    CGFloat alpha = 1;
    if (hex.length == 6) {
        red = ((rgba >> 16) & 0xFF) / 255.0;
        green = ((rgba >> 8) & 0xFF) / 255.0;
        blue = (rgba & 0xFF) / 255.0;
    } else {
        red = ((rgba >> 24) & 0xFF) / 255.0;
        green = ((rgba >> 16) & 0xFF) / 255.0;
        blue = ((rgba >> 8) & 0xFF) / 255.0;
        alpha = (rgba & 0xFF) / 255.0;
    }
    return @[@(red), @(green), @(blue), @(alpha)];
}

- (NSDictionary<NSString *, NSDictionary *> *)_propertyDefinitions {
    static NSDictionary<NSString *, NSDictionary *> *definitions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#define MCPAttr(_attr, _type) @{@"attr_id": _attr, @"type": @(_type)}
        definitions = @{
            @"frame": MCPAttr(LookinAttr_Layout_Frame_Frame, LookinAttrTypeCGRect),
            @"bounds": MCPAttr(LookinAttr_Layout_Bounds_Bounds, LookinAttrTypeCGRect),
            @"position": MCPAttr(LookinAttr_Layout_Position_Position, LookinAttrTypeCGPoint),
            @"anchorPoint": MCPAttr(LookinAttr_Layout_AnchorPoint_AnchorPoint, LookinAttrTypeCGPoint),
            @"hidden": MCPAttr(LookinAttr_ViewLayer_Visibility_Hidden, LookinAttrTypeBOOL),
            @"alpha": MCPAttr(LookinAttr_ViewLayer_Visibility_Opacity, LookinAttrTypeFloat),
            @"opacity": MCPAttr(LookinAttr_ViewLayer_Visibility_Opacity, LookinAttrTypeFloat),
            @"userInteractionEnabled": MCPAttr(LookinAttr_ViewLayer_InterationAndMasks_Interaction, LookinAttrTypeBOOL),
            @"masksToBounds": MCPAttr(LookinAttr_ViewLayer_InterationAndMasks_MasksToBounds, LookinAttrTypeBOOL),
            @"clipsToBounds": MCPAttr(LookinAttr_ViewLayer_InterationAndMasks_MasksToBounds, LookinAttrTypeBOOL),
            @"cornerRadius": MCPAttr(LookinAttr_ViewLayer_Corner_Radius, LookinAttrTypeFloat),
            @"backgroundColor": MCPAttr(LookinAttr_ViewLayer_BgColor_BgColor, LookinAttrTypeUIColor),
            @"borderColor": MCPAttr(LookinAttr_ViewLayer_Border_Color, LookinAttrTypeUIColor),
            @"borderWidth": MCPAttr(LookinAttr_ViewLayer_Border_Width, LookinAttrTypeFloat),
            @"tintColor": MCPAttr(LookinAttr_ViewLayer_TintColor_Color, LookinAttrTypeUIColor),
            @"contentMode": MCPAttr(LookinAttr_ViewLayer_ContentMode_Mode, LookinAttrTypeEnumInt),
            @"tag": MCPAttr(LookinAttr_ViewLayer_Tag_Tag, LookinAttrTypeLong),
            @"huggingHorizontal": MCPAttr(LookinAttr_AutoLayout_Hugging_Hor, LookinAttrTypeFloat),
            @"huggingVertical": MCPAttr(LookinAttr_AutoLayout_Hugging_Ver, LookinAttrTypeFloat),
            @"compressionResistanceHorizontal": MCPAttr(LookinAttr_AutoLayout_Resistance_Hor, LookinAttrTypeFloat),
            @"compressionResistanceVertical": MCPAttr(LookinAttr_AutoLayout_Resistance_Ver, LookinAttrTypeFloat),
            @"text": MCPAttr(LookinAttr_UILabel_Text_Text, LookinAttrTypeNSString),
            @"labelText": MCPAttr(LookinAttr_UILabel_Text_Text, LookinAttrTypeNSString),
            @"numberOfLines": MCPAttr(LookinAttr_UILabel_NumberOfLines_NumberOfLines, LookinAttrTypeLong),
            @"fontSize": MCPAttr(LookinAttr_UILabel_Font_Size, LookinAttrTypeFloat),
            @"textColor": MCPAttr(LookinAttr_UILabel_TextColor_Color, LookinAttrTypeUIColor),
            @"textAlignment": MCPAttr(LookinAttr_UILabel_Alignment_Alignment, LookinAttrTypeEnumInt),
            @"lineBreakMode": MCPAttr(LookinAttr_UILabel_BreakMode_Mode, LookinAttrTypeEnumInt),
            @"adjustsFontSizeToFitWidth": MCPAttr(LookinAttr_UILabel_CanAdjustFont_CanAdjustFont, LookinAttrTypeBOOL),
            @"enabled": MCPAttr(LookinAttr_UIControl_EnabledSelected_Enabled, LookinAttrTypeBOOL),
            @"selected": MCPAttr(LookinAttr_UIControl_EnabledSelected_Selected, LookinAttrTypeBOOL),
            @"contentVerticalAlignment": MCPAttr(LookinAttr_UIControl_VerAlignment_Alignment, LookinAttrTypeEnumInt),
            @"contentHorizontalAlignment": MCPAttr(LookinAttr_UIControl_HorAlignment_Alignment, LookinAttrTypeEnumInt),
            @"contentEdgeInsets": MCPAttr(LookinAttr_UIButton_ContentInsets_Insets, LookinAttrTypeUIEdgeInsets),
            @"titleEdgeInsets": MCPAttr(LookinAttr_UIButton_TitleInsets_Insets, LookinAttrTypeUIEdgeInsets),
            @"imageEdgeInsets": MCPAttr(LookinAttr_UIButton_ImageInsets_Insets, LookinAttrTypeUIEdgeInsets),
            @"highlighted": @{@"setter": @"setHighlighted:", @"type": @(LookinAttrTypeBOOL), @"target": @"view", @"patch": @(YES)},
            @"cellSelected": @{@"setter": @"setSelected:", @"type": @(LookinAttrTypeBOOL), @"target": @"view", @"patch": @(YES)},
            @"selectionStyle": @{@"setter": @"setSelectionStyle:", @"type": @(LookinAttrTypeEnumInt), @"target": @"view", @"patch": @(YES)},
            @"accessoryType": @{@"setter": @"setAccessoryType:", @"type": @(LookinAttrTypeEnumInt), @"target": @"view", @"patch": @(YES)},
            @"editing": @{@"setter": @"setEditing:", @"type": @(LookinAttrTypeBOOL), @"target": @"view", @"patch": @(YES)},
            @"contentOffset": MCPAttr(LookinAttr_UIScrollView_Offset_Offset, LookinAttrTypeCGPoint),
            @"contentSize": MCPAttr(LookinAttr_UIScrollView_ContentSize_Size, LookinAttrTypeCGSize),
            @"contentInset": MCPAttr(LookinAttr_UIScrollView_ContentInset_Inset, LookinAttrTypeUIEdgeInsets),
            @"qmuiInitialContentInset": MCPAttr(LookinAttr_UIScrollView_QMUIInitialInset_Inset, LookinAttrTypeUIEdgeInsets),
            @"contentInsetAdjustmentBehavior": MCPAttr(LookinAttr_UIScrollView_Behavior_Behavior, LookinAttrTypeEnumInt),
            @"scrollIndicatorInsets": MCPAttr(LookinAttr_UIScrollView_IndicatorInset_Inset, LookinAttrTypeUIEdgeInsets),
            @"scrollEnabled": MCPAttr(LookinAttr_UIScrollView_ScrollPaging_ScrollEnabled, LookinAttrTypeBOOL),
            @"pagingEnabled": MCPAttr(LookinAttr_UIScrollView_ScrollPaging_PagingEnabled, LookinAttrTypeBOOL),
            @"alwaysBounceVertical": MCPAttr(LookinAttr_UIScrollView_Bounce_Ver, LookinAttrTypeBOOL),
            @"alwaysBounceHorizontal": MCPAttr(LookinAttr_UIScrollView_Bounce_Hor, LookinAttrTypeBOOL),
            @"showsHorizontalScrollIndicator": MCPAttr(LookinAttr_UIScrollView_ShowsIndicator_Hor, LookinAttrTypeBOOL),
            @"showsVerticalScrollIndicator": MCPAttr(LookinAttr_UIScrollView_ShowsIndicator_Ver, LookinAttrTypeBOOL),
            @"delaysContentTouches": MCPAttr(LookinAttr_UIScrollView_ContentTouches_Delay, LookinAttrTypeBOOL),
            @"canCancelContentTouches": MCPAttr(LookinAttr_UIScrollView_ContentTouches_CanCancel, LookinAttrTypeBOOL),
            @"minimumZoomScale": MCPAttr(LookinAttr_UIScrollView_Zoom_MinScale, LookinAttrTypeFloat),
            @"maximumZoomScale": MCPAttr(LookinAttr_UIScrollView_Zoom_MaxScale, LookinAttrTypeFloat),
            @"zoomScale": MCPAttr(LookinAttr_UIScrollView_Zoom_Scale, LookinAttrTypeFloat),
            @"bouncesZoom": MCPAttr(LookinAttr_UIScrollView_Zoom_Bounce, LookinAttrTypeBOOL),
            @"separatorInset": MCPAttr(LookinAttr_UITableView_SeparatorInset_Inset, LookinAttrTypeUIEdgeInsets),
            @"separatorColor": MCPAttr(LookinAttr_UITableView_SeparatorColor_Color, LookinAttrTypeUIColor),
            @"separatorStyle": MCPAttr(LookinAttr_UITableView_SeparatorStyle_Style, LookinAttrTypeEnumInt),
            @"textViewText": MCPAttr(LookinAttr_UITextView_Text_Text, LookinAttrTypeNSString),
            @"textViewFontSize": MCPAttr(LookinAttr_UITextView_Font_Size, LookinAttrTypeFloat),
            @"textViewTextColor": MCPAttr(LookinAttr_UITextView_TextColor_Color, LookinAttrTypeUIColor),
            @"textViewTextAlignment": MCPAttr(LookinAttr_UITextView_Alignment_Alignment, LookinAttrTypeEnumInt),
            @"editable": MCPAttr(LookinAttr_UITextView_Basic_Editable, LookinAttrTypeBOOL),
            @"selectable": MCPAttr(LookinAttr_UITextView_Basic_Selectable, LookinAttrTypeBOOL),
            @"textContainerInset": MCPAttr(LookinAttr_UITextView_ContainerInset_Inset, LookinAttrTypeUIEdgeInsets),
            @"textFieldText": MCPAttr(LookinAttr_UITextField_Text_Text, LookinAttrTypeNSString),
            @"placeholder": MCPAttr(LookinAttr_UITextField_Placeholder_Placeholder, LookinAttrTypeNSString),
            @"textFieldFontSize": MCPAttr(LookinAttr_UITextField_Font_Size, LookinAttrTypeFloat),
            @"textFieldTextColor": MCPAttr(LookinAttr_UITextField_TextColor_Color, LookinAttrTypeUIColor),
            @"textFieldTextAlignment": MCPAttr(LookinAttr_UITextField_Alignment_Alignment, LookinAttrTypeEnumInt),
            @"clearsOnBeginEditing": MCPAttr(LookinAttr_UITextField_Clears_ClearsOnBeginEditing, LookinAttrTypeBOOL),
            @"clearsOnInsertion": MCPAttr(LookinAttr_UITextField_Clears_ClearsOnInsertion, LookinAttrTypeBOOL),
            @"minimumFontSize": MCPAttr(LookinAttr_UITextField_CanAdjustFont_MinSize, LookinAttrTypeFloat)
        };
#undef MCPAttr
    });
    return definitions;
}

- (NSDictionary<NSString *, NSDictionary *> *)_constraintPropertyDefinitions {
    static NSDictionary<NSString *, NSDictionary *> *definitions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        definitions = @{
            @"constant": @{@"setter": @"setConstant:", @"type": @(LookinAttrTypeFloat)},
            @"priority": @{@"setter": @"setPriority:", @"type": @(LookinAttrTypeFloat)},
            @"active": @{@"setter": @"setActive:", @"type": @(LookinAttrTypeBOOL)}
        };
    });
    return definitions;
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

- (NSDictionary *)_dictionaryFromObject:(LookinObject *)object {
    if (!object) {
        return nil;
    }
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (object.oid) {
        dict[@"oid"] = @(object.oid);
    }
    NSString *rawClassName = [object rawClassName];
    if (rawClassName.length) {
        dict[@"rawClassName"] = rawClassName;
    }
    if (object.classChainList.count) {
        dict[@"classChainList"] = object.classChainList;
    }
    if (object.memoryAddress.length) {
        dict[@"memoryAddress"] = object.memoryAddress;
    }
    if (object.specialTrace.length) {
        dict[@"specialTrace"] = object.specialTrace;
    }
    return dict.copy;
}

- (NSDictionary *)_dictionaryFromRect:(CGRect)rect {
    return @{
        @"x": @(CGRectGetMinX(rect)),
        @"y": @(CGRectGetMinY(rect)),
        @"width": @(CGRectGetWidth(rect)),
        @"height": @(CGRectGetHeight(rect))
    };
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
        case 400:
            return @"Bad Request";
        case 404:
            return @"Not Found";
        case 405:
            return @"Method Not Allowed";
        case 409:
            return @"Conflict";
        case 413:
            return @"Payload Too Large";
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
