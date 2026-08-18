//
//  vvebo_fix.m  v5  (无日志版：VVFileLog 已置空，不再向 Documents/vvfix.log 写盘)
//  VVebo 重写规则 -> 进程内 dylib（仅接口适配，不含付费绕过）
//
//  v4 修订点（关键架构变更）：
//   v3 证明 NSURLSession 内部不咨询我们注入的 NSURLProtocol（protocolClasses 被绕过），
//   因此 canInitWithRequest 永远不被调用。v4 彻底放弃 NSURLProtocol，改为直接在
//   NSURLSession 的 dataTaskWithRequest: 这一层拦截：
//     * 请求侧：把 statuses/user_timeline 改写成 profile/statuses/tab（拼 containerid）。
//     * 响应侧：把 tab / cardlist(selffans) 返回的 cards JSON 变形回
//       {statuses:[...], since_id, total_number} 形状（与 user_timeline 一致）。
//   - completionHandler 型任务：直接在 hook 内包一层 handler 做响应变形。
//   - delegate 型任务（AFNetworking/vVebo 实际用法）：hook 该 session 的
//     dataDelegate 的 didReceiveData:/didCompleteWithError:，按 task 缓冲并变形后回灌。
//   仅针对规则涉及的接口生效，其余请求原样放行。
//   日志落到 App 沙盒 Documents/vvfix.log（Filza 可导出）。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *g_uid = nil;
static id g_uidLock = nil;

#pragma mark - Logging (disabled: kept as no-op so call sites stay valid but nothing is written to disk)

static void VVFileLog(NSString *fmt, ...) { (void)fmt; }

#pragma mark - VVTransform

@interface VVTransform : NSObject
+ (void)captureUid:(NSString *)url;
+ (NSString *)rewriteUserTimeline:(NSString *)url;
+ (NSData *)transformTab:(NSData *)data;
+ (NSData *)transformFans:(NSData *)data;
@end

@implementation VVTransform

+ (void)captureUid:(NSString *)url {
    // 仅从 unread_count 抓取登录用户 uid（与原始脚本一致）。
    // 注意：users/show 触发时 uid 是被查看者的 uid，绝不能用来覆盖登录用户 uid。
    if ([url containsString:@"remind/unread_count"]) {
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

+ (NSString *)rewriteUserTimeline:(NSString *)url {
    NSMutableString *s = [url mutableCopy];
    [s replaceOccurrencesOfString:@"statuses/user_timeline"
                        withString:@"profile/statuses/tab"
                           options:NSLiteralSearch
                             range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"max_id"
                        withString:@"since_id"
                           options:NSLiteralSearch
                             range:NSMakeRange(0, s.length)];
    NSString *uid = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"uid=([0-9]+)"
                                                                        options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:url options:0 range:NSMakeRange(0, url.length)];
    if (m) uid = [url substringWithRange:[m rangeAtIndex:1]];
    if (!uid) @synchronized (g_uidLock) { uid = g_uid; }
    if (uid) {
        [s appendFormat:@"&containerid=230413%@_-_WEIBO_SECOND_PROFILE_WEIBO", uid];
        VVFileLog(@"rewrite user_timeline -> tab (uid=%@)", uid);
    } else {
        VVFileLog(@"WARN: no uid available when rewriting user_timeline");
    }
    VVFileLog(@"final url: %@", s);
    return s;
}

+ (NSData *)transformTab:(NSData *)data {
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || !json) {
        VVFileLog(@"transformTab: json parse failed, pass through");
        return data;
    }
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
    VVFileLog(@"transformTab: %lu statuses (since_id=%@)", (unsigned long)statuses.count, sinceId);
    return outData ?: data;
}

+ (NSData *)transformFans:(NSData *)data {
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || !json) return data;
    NSMutableDictionary *outObj = [json mutableCopy];
    NSArray *cards = json[@"cards"];
    if ([cards isKindOfClass:[NSArray class]]) {
        NSArray *filtered = [cards filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(id card, NSDictionary *bindings) {
                return ![@"INTEREST_PEOPLE2" isEqualToString:card[@"itemid"]];
            }]];
        outObj[@"cards"] = filtered;
        VVFileLog(@"transformFans: %lu -> %lu cards", (unsigned long)cards.count, (unsigned long)filtered.count);
    }
    NSData *outData = [NSJSONSerialization dataWithJSONObject:outObj options:0 error:nil];
    return outData ?: data;
}

@end

#pragma mark - associated object keys

static const void *kTransform = &kTransform;
static const void *kBuffer    = &kBuffer;

#pragma mark - delegate (data) hook state

static NSMutableSet *gDelegateHookedClasses = nil;

@interface NSObject (VVDelegateHook)
- (void)vv_Session:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data;
- (void)vv_Session:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error;
@end

@implementation NSObject (VVDelegateHook)

- (void)vv_Session:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (objc_getAssociatedObject(dataTask, kTransform)) {
        NSMutableData *buf = objc_getAssociatedObject(dataTask, kBuffer);
        if (!buf) {
            buf = [NSMutableData data];
            objc_setAssociatedObject(dataTask, kBuffer, buf, OBJC_ASSOCIATION_RETAIN);
        }
        [buf appendData:data];
        return; // buffer only; deliver at completion
    }
    [self vv_Session:session dataTask:dataTask didReceiveData:data];
}

- (void)vv_Session:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSString *type = objc_getAssociatedObject(task, kTransform);
    if (type) {
        NSMutableData *buf = objc_getAssociatedObject(task, kBuffer);
        NSData *orig = buf ? [buf copy] : nil;
        NSData *out = orig;
        if (orig) {
            if ([type isEqualToString:@"tab"]) out = [VVTransform transformTab:orig];
            else out = [VVTransform transformFans:orig];
        }
        if (out && out != orig) {
            [self vv_Session:session dataTask:(NSURLSessionDataTask *)task didReceiveData:out];
        }
        objc_setAssociatedObject(task, kTransform, nil, OBJC_ASSOCIATION_COPY);
        objc_setAssociatedObject(task, kBuffer, nil, OBJC_ASSOCIATION_RETAIN);
        [self vv_Session:session task:task didCompleteWithError:error];
        return;
    }
    [self vv_Session:session task:task didCompleteWithError:error];
}

@end

#pragma mark - NSURLSession dataTask hook

@interface NSURLSession (VVHook)
- (NSURLSessionDataTask *)vv_dataTaskWithRequest:(NSURLRequest *)request
                               completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
- (NSURLSessionDataTask *)vv_dataTaskWithRequest:(NSURLRequest *)request;
- (void)vv_ensureDelegateHook;
@end

@implementation NSURLSession (VVHook)

- (void)vv_ensureDelegateHook {
    id del = [self delegate];
    if (!del) return;
    Class dc = [del class];
    @synchronized (gDelegateHookedClasses) {
        if ([gDelegateHookedClasses containsObject:dc]) return;
        Method m1 = class_getInstanceMethod(dc, @selector(URLSession:dataTask:didReceiveData:));
        Method m2 = class_getInstanceMethod(dc, @selector(URLSession:task:didCompleteWithError:));
        if (m1) method_exchangeImplementations(m1,
                class_getInstanceMethod([NSObject class], @selector(vv_Session:dataTask:didReceiveData:)));
        if (m2) method_exchangeImplementations(m2,
                class_getInstanceMethod([NSObject class], @selector(vv_Session:task:didCompleteWithError:)));
        [gDelegateHookedClasses addObject:dc];
        VVFileLog(@"delegate hook installed on %@", NSStringFromClass(dc));
    }
}

- (NSURLSessionDataTask *)vv_dataTaskWithRequest:(NSURLRequest *)request
                               completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if ([request valueForHTTPHeaderField:@"X-VV-Internal"] != nil) {
        return [self vv_dataTaskWithRequest:request completionHandler:completionHandler];
    }
    NSString *url = request.URL.absoluteString ?: @"";
    [VVTransform captureUid:url];

    BOOL isTab  = [url containsString:@"statuses/user_timeline"];
    BOOL isFans = ([url containsString:@"cardlist"] && [url containsString:@"selffans"]);
    if (!isTab && !isFans) {
        if ([url containsString:@"weibo"]) VVFileLog(@"PROBE(comp): %@", request.URL.path);
        return [self vv_dataTaskWithRequest:request completionHandler:completionHandler];
    }

    NSMutableURLRequest *m = [request mutableCopy];
    [m setValue:@"1" forHTTPHeaderField:@"X-VV-Internal"];
    if (isTab) {
        NSString *newUrl = [VVTransform rewriteUserTimeline:url];
        [m setURL:[NSURL URLWithString:newUrl]];
    } else {
        VVFileLog(@"FANS(comp) task marked");
    }

    NSString *type = isTab ? @"tab" : @"fans";
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *out = data;
            if (!error && data) {
                out = isTab ? [VVTransform transformTab:data] : [VVTransform transformFans:data];
            }
            if (completionHandler) completionHandler(out, response, error);
        };
    return [self vv_dataTaskWithRequest:m completionHandler:wrapped];
}

- (NSURLSessionDataTask *)vv_dataTaskWithRequest:(NSURLRequest *)request {
    if ([request valueForHTTPHeaderField:@"X-VV-Internal"] != nil) {
        return [self vv_dataTaskWithRequest:request];
    }
    NSString *url = request.URL.absoluteString ?: @"";
    [VVTransform captureUid:url];

    BOOL isTab  = [url containsString:@"statuses/user_timeline"];
    BOOL isFans = ([url containsString:@"cardlist"] && [url containsString:@"selffans"]);
    if (!isTab && !isFans) {
        if ([url containsString:@"weibo"]) VVFileLog(@"PROBE(del): %@", request.URL.path);
        return [self vv_dataTaskWithRequest:request];
    }

    [self vv_ensureDelegateHook];

    NSMutableURLRequest *m = [request mutableCopy];
    [m setValue:@"1" forHTTPHeaderField:@"X-VV-Internal"];
    if (isTab) {
        NSString *newUrl = [VVTransform rewriteUserTimeline:url];
        [m setURL:[NSURL URLWithString:newUrl]];
    } else {
        VVFileLog(@"FANS(del) task marked");
    }
    NSURLSessionDataTask *task = [self vv_dataTaskWithRequest:m];
    objc_setAssociatedObject(task, kTransform, isTab ? @"tab" : @"fans", OBJC_ASSOCIATION_COPY);
    return task;
}

@end

#pragma mark - Swizzle helper

static void Swizzle(Class c, SEL orig, SEL repl) {
    Method m1 = class_getInstanceMethod(c, orig);
    Method m2 = class_getInstanceMethod(c, repl);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

#pragma mark - Entry

__attribute__((constructor)) static void VVInit(void) {
    g_uidLock = [[NSObject alloc] init];
    gDelegateHookedClasses = [NSMutableSet set];
    VVFileLog(@"==== VVFIX v4 init start (bundle=%@) ====",
              [[NSBundle mainBundle] bundleIdentifier]);
    Swizzle([NSURLSession class],
            @selector(dataTaskWithRequest:completionHandler:),
            @selector(vv_dataTaskWithRequest:completionHandler:));
    Swizzle([NSURLSession class],
            @selector(dataTaskWithRequest:),
            @selector(vv_dataTaskWithRequest:));
    VVFileLog(@"==== VVFIX v4 init done ====");
}
