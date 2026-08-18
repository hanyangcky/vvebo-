//
//  vvebo_fix.m
//  ---------------------------------------------------------------------------
//  把 Shadowrocket / Stash 的「VVebo 重写规则」搬进 App 进程内执行，
//  通过 NSURLProtocol 拦截 api.weibo.cn 的流量，做请求改写 + 响应改写，
//  从而实现：不依赖 VPN / MITM 代理也能打开博主主页、时间线、粉丝列表。
//
//  本文件仅实现接口适配，不涉及任何付费 / 订阅 / Pro 相关的绕过。
//  编译环境：macOS + Xcode (clang, iphoneos SDK)，目标架构 arm64。
//  ---------------------------------------------------------------------------
//

#import <Foundation/Foundation.h>

// ---------------------------------------------------------------------------
//  转换逻辑：忠实复刻 suiyuran/stash 的两个脚本
// ---------------------------------------------------------------------------
static NSString *g_uid = nil;
static id g_uidLock = nil;

@interface VVTransform : NSObject
+ (void)captureUidFromURL:(NSString *)url;
+ (NSURLRequest *)rewriteRequest:(NSMutableURLRequest *)req originalURL:(NSString *)origURLStr;
+ (BOOL)needsResponseTransform:(NSString *)url;
+ (NSData *)transformResponse:(NSData *)data forURL:(NSString *)url;
@end

@implementation VVTransform

+ (void)captureUidFromURL:(NSString *)url {
    if ([url containsString:@"remind/unread_count"] || [url containsString:@"users/show"]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"uid=(\\d+)" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:url options:0 range:NSMakeRange(0, url.length)];
        if (m) {
            NSString *uid = [url substringWithRange:[m rangeAtIndex:1]];
            @synchronized (g_uidLock) { g_uid = uid; }
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
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"uid=(\\d+)" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:origURLStr options:0 range:NSMakeRange(0, origURLStr.length)];
        if (m) uid = [origURLStr substringWithRange:[m rangeAtIndex:1]];
        if (!uid) @synchronized (g_uidLock) { uid = g_uid; }
        if (uid) [newUrl appendFormat:@"&containerid=230413%@_-_WEIBO_SECOND_PROFILE_WEIBO", uid];

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
    if (err || !json) return data;

    // profile/statuses/tab -> 压平成 vVebo 认识的 statuses 数组
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
        return outData ?: data;
    }

    // cardlist?...selffans -> 过滤掉 INTEREST_PEOPLE2 推荐卡
    if ([url containsString:@"cardlist"] && [url containsString:@"selffans"]) {
        NSMutableDictionary *outObj = [json mutableCopy];
        NSArray *cards = json[@"cards"];
        if ([cards isKindOfClass:[NSArray class]]) {
            NSArray *filtered = [cards filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(id card, NSDictionary *bindings) {
                    return ![@"INTEREST_PEOPLE2" isEqualToString:card[@"itemid"]];
                }]];
            outObj[@"cards"] = filtered;
        }
        NSData *outData = [NSJSONSerialization dataWithJSONObject:outObj options:0 error:nil];
        return outData ?: data;
    }

    return data;
}

@end

// ---------------------------------------------------------------------------
//  内部转发 session（带 X-VV-Internal 标记，避免被本协议递归拦截）
// ---------------------------------------------------------------------------
static NSURLSession *ForwardSession(void) {
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

// ---------------------------------------------------------------------------
//  NSURLProtocol 子类：拦截 api.weibo.cn 流量并改写
// ---------------------------------------------------------------------------
@interface VVProtocol : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation VVProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([request valueForHTTPHeaderField:@"X-VV-Internal"]) return NO;
    NSString *host = request.URL.host ?: @"";
    return [host containsString:@"api.weibo.cn"];
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
    self.task = [[ForwardSession() dataTaskWithRequest:finalReq
                                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            [strongSelf.client URLProtocol:strongSelf didFailWithError:error];
            return;
        }

        NSData *outData = data;
        if (needTransform && data) {
            outData = [VVTransform transformResponse:data forURL:finalURLStr];
        }

        // 重写响应头里的 Content-Length，否则部分解析会截断
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
    }] resume];
}

- (void)stopLoading {
    [self.task cancel];
    self.task = nil;
}

@end

// ---------------------------------------------------------------------------
//  构造函数：加载时注册协议（早于 App 任何网络请求）
// ---------------------------------------------------------------------------
__attribute__((constructor)) static void VVInit(void) {
    g_uidLock = [[NSObject alloc] init];
    [NSURLProtocol registerClass:[VVProtocol class]];
}
