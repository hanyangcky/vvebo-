//
//  vvebo_fix.m
//  VVebo 重写规则 -> 进程内 dylib（仅接口适配，不含付费绕过）
//
//  修订点（相对初版）：
//   1. 转发请求改用 defaultSessionConfiguration + 共享 Cookie 存储，
//      避免 ephemeral 把微博登录态 Cookie 丢掉导致请求未授权。
//   2. swizzle -[NSURLSessionConfiguration protocolClasses]，
//      保证 App 即便显式设了 protocolClasses，我们的协议也会被纳入。
//   3. 全程 [VVFIX] 前缀日志，便于在 Console.app 排查是否加载/拦截。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *g_uid = nil;
static id g_uidLock = nil;

#define VVLog(...) NSLog(@"[VVFIX] " __VA_ARGS__)

#pragma mark - VVTransform

@interface VVTransform : NSObject
+ (void)captureUidFromURL:(NSString *)url;
+ (NSURLRequest *)rewriteRequest:(NSMutableURLRequest *)req originalURL:(NSString *)origURLStr;
+ (BOOL)needsResponseTransform:(NSString *)url;
+ (NSData *)transformResponse:(NSData *)data forURL:(NSString *)url;
@end

@implementation VVTransform

+ (void)captureUidFromURL:(NSString *)url {
    if ([url containsString:@"remind/unread_count"] || [url containsString:@"users/show"]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"uid=([0-9]+)" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:url options:0 range:NSMakeRange(0, url.length)];
        if (m) {
            NSString *uid = [url substringWithRange:[m rangeAtIndex:1]];
            @synchronized (g_uidLock) { g_uid = uid; }
            VVLog(@"captured uid=%@", uid);
        }
    }
}

+ (NSURLRequest *)rewriteRequest:(NSMutableURLRequest *)req originalURL:(NSString *)origURLStr {
    if ([origURLStr containsString:@"statuses/user_timeline"]) {
        VVLog(@"rewrite user_timeline -> profile/statuses/tab");
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
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"uid=([0-9]+)" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:origURLStr options:0 range:NSMakeRange(0, origURLStr.length)];
        if (m) uid = [origURLStr substringWithRange:[m rangeAtIndex:1]];
        if (!uid) @synchronized (g_uidLock) { uid = g_uid; }
        if (uid) {
            [newUrl appendFormat:@"&containerid=230413%@_-_WEIBO_SECOND_PROFILE_WEIBO", uid];
            VVLog(@"using uid=%@ for containerid", uid);
        } else {
            VVLog(@"WARN: no uid available for containerid");
        }
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
        VVLog(@"transform: json parse failed, pass through");
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
                        mblog[@"label"] = @"\u7f6e\u9876";
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
        VVLog(@"transform tab: %lu statuses", (unsigned long)statuses.count);
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
            VVLog(@"transform fans: %lu -> %lu cards", (unsigned long)cards.count, (unsigned long)filtered.count);
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
    if ([request valueForHTTPHeaderField:@"X-VV-Internal"]) return NO;
    NSString *host = request.URL.host ?: @"";
    if ([host containsString:@"weibo"]) {
        BOOL intercept = [host containsString:@"api.weibo.cn"];
        VVLog(@"canInit host=%@ intercept=%d", host, intercept);
        return intercept;
    }
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
            VVLog(@"forward error: %@", error.localizedDescription);
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

#pragma mark - NSURLSessionConfiguration hook

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

static void Swizzle(Class c, SEL orig, SEL repl) {
    Method m1 = class_getInstanceMethod(c, orig);
    Method m2 = class_getInstanceMethod(c, repl);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

#pragma mark - Entry

__attribute__((constructor)) static void VVInit(void) {
    g_uidLock = [[NSObject alloc] init];
    [NSURLProtocol registerClass:[VVProtocol class]];
    Swizzle([NSURLSessionConfiguration class],
            @selector(protocolClasses),
            @selector(vv_protocolClasses));
    VVLog(@"init done (protocol registered + swizzled)");
}
