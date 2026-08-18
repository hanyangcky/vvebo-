//
//  vvebo_fix.m  v3
//  VVebo 重写规则 -> 进程内 dylib（仅接口适配，不含付费绕过）
//
//  v3 修订点：
//   1. 关键修复：hook NSURLSession 的 sessionWithConfiguration: 工厂方法，
//      在创建 session 前强制把 VVProtocol 写入 configuration.protocolClasses，
//      解决 “NSURLSession 内部不读取 getter swizzle 的 protocolClasses”
//      导致 canInit 永远不被调用的问题。
//   2. 新增“探针”：hook NSURLSession dataTaskWithRequest: 等，记录 App 发出的
//      每一个请求 URL，用于在无 Mac 情况下确认 vVebo 真实流量与所用网络栈。
//   3. canInit 对每一个 weibo 域请求无条件记录，确认协议是否被咨询。
//   4. 仅拦截规则涉及的接口（user_timeline / profile tab / cardlist /
//      unread_count / users/show），其余请求原样放行，降低风险。
//   5. 文件日志落到 App 沙盒 Documents/vvfix.log（Filza 可导出）。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *g_uid = nil;
static id g_uidLock = nil;

#pragma mark - File logging

static NSString *VVLogPath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask, YES) firstObject];
        p = [docs stringByAppendingPathComponent:@"vvfix.log"];
    });
    return p;
}

static void VVFileLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *line = [NSString stringWithFormat:@"[%@] [VVFIX] %@\n",
                      [[NSDate date] description], msg];
    NSLog(@"[VVFIX] %@", msg);

    @try {
        NSString *path = VVLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {
        NSLog(@"[VVFIX] log write failed: %@", e);
    }
}

#pragma mark - VVTransform

@interface VVTransform : NSObject
+ (BOOL)vv_shouldIntercept:(NSString *)url;
+ (void)captureUidFromURL:(NSString *)url;
+ (NSURLRequest *)rewriteRequest:(NSMutableURLRequest *)req originalURL:(NSString *)origURLStr;
+ (BOOL)needsResponseTransform:(NSString *)url;
+ (NSData *)transformResponse:(NSData *)data forURL:(NSString *)url;
@end

@implementation VVTransform

+ (BOOL)vv_shouldIntercept:(NSString *)url {
    if ([url containsString:@"statuses/user_timeline"]) return YES;
    if ([url containsString:@"profile/statuses/tab"]) return YES;
    if ([url containsString:@"cardlist"]) return YES;
    if ([url containsString:@"remind/unread_count"]) return YES;
    if ([url containsString:@"users/show"]) return YES;
    return NO;
}

+ (void)captureUidFromURL:(NSString *)url {
    if ([url containsString:@"remind/unread_count"] || [url containsString:@"users/show"]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"uid=([0-9]+)"
                                                                            options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:url options:0 range:NSMakeRange(0, url.length)];
        if (m) {
            NSString *uid = [url substringWithRange:[m rangeAtIndex:1]];
            @synchronized (g_uidLock) { g_uid = uid; }
            VVFileLog(@"captured uid=%@", uid);
        }
    }
}

+ (NSURLRequest *)rewriteRequest:(NSMutableURLRequest *)req originalURL:(NSString *)origURLStr {
    if ([origURLStr containsString:@"statuses/user_timeline"]) {
        NSMutableString *newUrl = [origURLStr mutableCopy];
        [newUrl replaceOccurrencesOfString:@"statuses/user_timeline"
                                withString:@"profile/statuses/tab"
                                   options:NSLiteralSearch
                                     range:NSMakeRange(0, newUrl.length)];
        [newUrl replaceOccurrencesOfString:@"max_id"
                                withString:@"since_id"
                                   options:NSLiteralSearch
                                     range:NSMakeRange(0, newUrl.length)];
        NSString *uid = nil;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"uid=([0-9]+)"
                                                                            options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:origURLStr
                                                 options:0
                                                   range:NSMakeRange(0, origURLStr.length)];
        if (m) uid = [origURLStr substringWithRange:[m rangeAtIndex:1]];
        if (!uid) @synchronized (g_uidLock) { uid = g_uid; }
        if (uid) {
            [newUrl appendFormat:@"&containerid=230413%@_-_WEIBO_SECOND_PROFILE_WEIBO", uid];
            VVFileLog(@"rewrite user_timeline -> tab (uid=%@)", uid);
        } else {
            VVFileLog(@"WARN: no uid available when rewriting user_timeline");
        }
        VVFileLog(@"final url: %@", newUrl);
        req.URL = [NSURL URLWithString:newUrl];
    }
    return req;
}

+ (BOOL)needsResponseTransform:(NSString *)url {
    if ([url containsString:@"profile/statuses/tab"]) return YES;
    if ([url containsString:@"cardlist"] && [url containsString:@"selffans"]) return YES;
    return NO;
}

+ (NSData *)transformResponse:(NSData *)data forURL:(NSString *)url {
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || !json) {
        VVFileLog(@"transform: json parse failed, pass through");
        return data;
    }

    if ([url containsString:@"profile/statuses/tab"]) {
        NSArray *cards = json[@"cards"];
        NSMutableArray *statuses = [NSMutableArray array];
        for (id card in cards) {
            NSArray *group = card[@"card_group"] ?: @[card];
            for (id c in group) {
                if ([c[@"card_type"] integerValue] == 9) {
                    NSMutableDictionary *mblog = [c[@"mblog"] mutableCopy];
                    if ([mblog[@"isTop"] boolValue]) {
                        mblog[@"label"] = @"置顶";
                    }
                    [statuses addObject:mblog];
                }
            }
        }
        NSString *sinceId = json[@"cardlistInfo"][@"since_id"] ?: @"";
        NSDictionary *outObj = @{
            @"statuses": statuses,
            @"since_id": sinceId,
            @"total_number": @(100)
        };
        NSData *outData = [NSJSONSerialization dataWithJSONObject:outObj options:0 error:nil];
        VVFileLog(@"transform tab: %lu statuses (since_id=%@)", (unsigned long)statuses.count, sinceId);
        return outData ?: data;
    }

    if ([url containsString:@"cardlist"] && [url containsString:@"selffans"]) {
        NSMutableDictionary *outObj = [json mutableCopy];
        NSArray *cards = json[@"cards"];
        if ([cards isKindOfClass:[NSArray class]]) {
            NSArray *filtered = [cards filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(id card, NSDictionary *bindings) {
                    return ![@"INTEREST_PEOPLE2" isEqualToString:card[@"itemid"]];
                }]];
            outObj[@"cards"] = filtered;
            VVFileLog(@"transform fans: %lu -> %lu cards", (unsigned long)cards.count, (unsigned long)filtered.count);
        }
        NSData *outData = [NSJSONSerialization dataWithJSONObject:outObj options:0 error:nil];
        return outData ?: data;
    }

    return data;
}

@end

#pragma mark - Forward session (shared cookie storage)

static NSURLSession *ForwardSession(void) {
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        cfg.HTTPShouldSetCookies = YES;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

#pragma mark - VVProtocol

@interface VVProtocol : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation VVProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([request valueForHTTPHeaderField:@"X-VV-Internal"] != nil) return NO;
    NSString *host = request.URL.host ?: @"";
    NSString *abs = request.URL.absoluteString ?: @"";
    if (![host containsString:@"weibo"]) return NO;
    VVFileLog(@"canInit: host=%@ path=%@", host, request.URL.path);
    if ([VVTransform vv_shouldIntercept:abs]) return YES;
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [req setValue:@"1" forHTTPHeaderField:@"X-VV-Internal"];

    NSString *origURLStr = self.request.URL.absoluteString;
    [VVTransform captureUidFromURL:origURLStr];

    NSURLRequest *finalReq = [VVTransform rewriteRequest:req originalURL:origURLStr];
    NSString *finalURLStr = finalReq.URL.absoluteString;
    BOOL needTransform = [VVTransform needsResponseTransform:finalURLStr];

    __weak typeof(self) weakSelf = self;
    void (^handler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            VVFileLog(@"forward error: %@", error.localizedDescription);
            [strongSelf.client URLProtocol:strongSelf didFailWithError:error];
            return;
        }
        NSData *outData = data;
        if (needTransform && data) {
            outData = [VVTransform transformResponse:data forURL:finalURLStr];
        }
        NSURLResponse *outResp = response;
        if ([response isKindOfClass:[NSHTTPURLResponse class]] && outData) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSMutableDictionary *headers = [http.allHeaderFields mutableCopy];
            headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)outData.length];
            outResp = [[NSHTTPURLResponse alloc] initWithURL:http.URL
                                                   statusCode:http.statusCode
                                                  HTTPVersion:@"HTTP/1.1"
                                                 headerFields:headers];
        }
        [strongSelf.client URLProtocol:strongSelf
                    didReceiveResponse:outResp
                    cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        if (outData) [strongSelf.client URLProtocol:strongSelf didLoadData:outData];
        [strongSelf.client URLProtocolDidFinishLoading:strongSelf];
    };
    NSURLSessionDataTask *task = [ForwardSession() dataTaskWithRequest:finalReq completionHandler:handler];
    self.task = task;
    [task resume];
}

- (void)stopLoading {
    [self.task cancel];
    self.task = nil;
}

@end

#pragma mark - Force protocol into every NSURLSessionConfiguration

static void VVForceAddProtocol(NSURLSessionConfiguration *cfg) {
    if (!cfg) return;
    NSMutableArray *pc = [[cfg protocolClasses] mutableCopy];
    if (!pc) pc = [NSMutableArray array];
    Class vp = [VVProtocol class];
    if (![pc containsObject:vp]) {
        [pc addObject:vp];
        [cfg setProtocolClasses:pc];
    }
}

@interface NSURLSessionConfiguration (VVAdditions)
- (NSArray *)vv_protocolClasses;
@end

@implementation NSURLSessionConfiguration (VVAdditions)
- (NSArray *)vv_protocolClasses {
    NSMutableArray *arr = [[self vv_protocolClasses] mutableCopy];
    if (!arr) arr = [NSMutableArray array];
    Class vp = [VVProtocol class];
    if (![arr containsObject:vp]) [arr addObject:vp];
    return arr;
}
@end

#pragma mark - NSURLSession factory + task probe

@interface NSURLSession (VVHook)
+ (NSURLSession *)vv_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration;
+ (NSURLSession *)vv_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                     delegate:(id)delegate
                                delegateQueue:(NSOperationQueue *)queue;
- (NSURLSessionDataTask *)vv_dataTaskWithRequest:(NSURLRequest *)request
                               completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
- (NSURLSessionDataTask *)vv_dataTaskWithRequest:(NSURLRequest *)request;
@end

@implementation NSURLSession (VVHook)

+ (NSURLSession *)vv_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    VVForceAddProtocol(configuration);
    VVFileLog(@"factory: protocolClasses=%@", [configuration protocolClasses]);
    return [self vv_sessionWithConfiguration:configuration];
}

+ (NSURLSession *)vv_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                     delegate:(id)delegate
                                delegateQueue:(NSOperationQueue *)queue {
    VVForceAddProtocol(configuration);
    VVFileLog(@"factory(delegate): protocolClasses=%@", [configuration protocolClasses]);
    return [self vv_sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
}

- (NSURLSessionDataTask *)vv_dataTaskWithRequest:(NSURLRequest *)request
                               completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if ([request valueForHTTPHeaderField:@"X-VV-Internal"] == nil) {
        NSURL *u = request.URL;
        if (u) VVFileLog(@"PROBE task: %@://%@%@", u.scheme, u.host, u.path);
    }
    return [self vv_dataTaskWithRequest:request completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)vv_dataTaskWithRequest:(NSURLRequest *)request {
    if ([request valueForHTTPHeaderField:@"X-VV-Internal"] == nil) {
        NSURL *u = request.URL;
        if (u) VVFileLog(@"PROBE task: %@://%@%@", u.scheme, u.host, u.path);
    }
    return [self vv_dataTaskWithRequest:request];
}

@end

#pragma mark - Swizzle helper

static void Swizzle(Class c, SEL orig, SEL repl) {
    Method m1 = class_getInstanceMethod(c, orig);
    Method m2 = class_getInstanceMethod(c, repl);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}
static void SwizzleClass(Class c, SEL orig, SEL repl) {
    Method m1 = class_getClassMethod(c, orig);
    Method m2 = class_getClassMethod(c, repl);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

#pragma mark - Entry

__attribute__((constructor)) static void VVInit(void) {
    g_uidLock = [[NSObject alloc] init];
    VVFileLog(@"==== VVFIX init start (bundle=%@) ====",
              [[NSBundle mainBundle] bundleIdentifier]);

    [NSURLProtocol registerClass:[VVProtocol class]];

    // getter swizzle (belt)
    Swizzle([NSURLSessionConfiguration class],
            @selector(protocolClasses), @selector(vv_protocolClasses));

    // factory hook (suspenders) — force protocol into every session
    SwizzleClass([NSURLSession class],
                 @selector(sessionWithConfiguration:),
                 @selector(vv_sessionWithConfiguration:));
    SwizzleClass([NSURLSession class],
                 @selector(sessionWithConfiguration:delegate:delegateQueue:),
                 @selector(vv_sessionWithConfiguration:delegate:delegateQueue:));

    // probe: log every request the app makes
    Swizzle([NSURLSession class],
            @selector(dataTaskWithRequest:completionHandler:),
            @selector(vv_dataTaskWithRequest:completionHandler:));
    Swizzle([NSURLSession class],
            @selector(dataTaskWithRequest:),
            @selector(vv_dataTaskWithRequest:));

    VVFileLog(@"==== VVFIX init done ====");
}
