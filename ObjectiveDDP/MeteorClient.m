#import "DependencyProvider.h"
#import "MeteorClient.h"
#import "MeteorClient+Private.h"
#import "BSONIdGenerator.h"
#import "NSData+DDPHex.h"

NSString * const MeteorClientDidConnectNotification = @"boundsj.objectiveddp.connected";
NSString * const MeteorClientDidDisconnectNotification = @"boundsj.objectiveddp.disconnected";
NSString * const MeteorClientTransportErrorDomain = @"boundsj.objectiveddp.transport";

@interface MeteorClient ()

@property (nonatomic, copy, readwrite) NSString *ddpVersion;

@end

@implementation MeteorClient
- (void)dealloc
{
    self.ddp = nil;
}
- (id)init
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (id)initWithDDPVersion:(NSString *)ddpVersion {
    self = [super init];
    if (self) {
        _collections = [NSMutableDictionary dictionary];
        _subscriptions = [NSMutableDictionary dictionary];
        _subscriptionsParameters = [NSMutableDictionary dictionary];
        _methodIds = [NSMutableSet set];
        _retryAttempts = 0;
        _responseCallbacks = [NSMutableDictionary dictionary];
        _ddpVersion = ddpVersion;
        if ([ddpVersion isEqualToString:@"pre2"]) {
            _supportedVersions = @[@"pre2", @"pre1"];
        } else {
            _supportedVersions = @[@"pre2", @"pre1"];
        }
    }
    return self;
}

#pragma mark MeteorClient public API

- (void)resetCollections {
    [self.collections removeAllObjects];
}

- (void)sendWithMethodName:(NSString *)methodName parameters:(NSArray *)parameters {
    [self sendWithMethodName:methodName parameters:parameters notifyOnResponse:NO];
}

-(NSString *)sendWithMethodName:(NSString *)methodName parameters:(NSArray *)parameters notifyOnResponse:(BOOL)notify {
    if (![self okToSend]) {
        return nil;
    }
    return [self _send:notify parameters:parameters methodName:methodName];
}

- (void)ping {
    if (!([self okToSend] && self.websocketReady)) {
        return;
    }
    [self.ddp ping];
}

- (NSString *)callMethodName:(NSString *)methodName parameters:(NSArray *)parameters responseCallback:(MeteorClientMethodCallback)responseCallback {
    if ([self _rejectIfNotConnected:responseCallback]) {
        return nil;
    };
    NSString *methodId = [self _send:YES parameters:parameters methodName:methodName];
    if (responseCallback) {
        _responseCallbacks[methodId] = [responseCallback copy];
    }
    return methodId;
}

- (void)addSubscription:(NSString *)subscriptionName {
    [self addSubscription:subscriptionName withParameters:nil];
}

- (void)addSubscription:(NSString *)subscriptionName withParameters:(NSArray *)parameters {
    NSString *uid = [BSONIdGenerator generate];
    [_subscriptions setObject:uid forKey:subscriptionName];
    if (parameters) {
        [_subscriptionsParameters setObject:parameters forKey:subscriptionName];
    }
    if (![self okToSend]) {
        return;
    }
    [self.ddp subscribeWith:uid name:subscriptionName parameters:parameters];
}

- (void)removeSubscription:(NSString *)subscriptionName {
    if (![self okToSend]) {
        return;
    }
    NSString *uid = [_subscriptions objectForKey:subscriptionName];
    if (uid) {
        [self.ddp unsubscribeWith:uid];
        // XXX: Should we really remove sub until we hear back from sever?
        [_subscriptions removeObjectForKey:subscriptionName];
    }
}

static NSString *randomId(int length) {
	static NSArray *characters;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		characters = [NSMutableArray new];
		for(char c = 'A'; c < 'Z'; c++)
			[(NSMutableArray*)characters addObject:[[NSString alloc] initWithBytes:&c length:1 encoding:NSUTF8StringEncoding]];
		for(char c = 'a'; c < 'z'; c++)
			[(NSMutableArray*)characters addObject:[[NSString alloc] initWithBytes:&c length:1 encoding:NSUTF8StringEncoding]];
		for(char c = '0'; c < '9'; c++)
			[(NSMutableArray*)characters addObject:[[NSString alloc] initWithBytes:&c length:1 encoding:NSUTF8StringEncoding]];
	});
	NSMutableString *salt = [NSMutableString new];
	for(int i = 0; i < length; i++)
		[salt appendString:characters[arc4random_uniform(characters.count)]];
	return salt;
}

- (void)signupWithUsername:(NSString *)username password:(NSString *)password responseCallback:(MeteorClientMethodCallback)responseCallback {
    if ([self _rejectIfNotConnected:responseCallback]) {
        return;
    }
    //[self _setAuthStateToLoggingIn];
    NSData *passwordData = [password dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes_s, *bytes_v;
    int len_s, len_v;
    NSString *identity = randomId(16);
    NSString *salt = randomId(16);
    bytes_s = (void *)[salt UTF8String];
    len_s = strlen([salt UTF8String]);
    srp_create_salted_verification_key(SRP_SHA256, SRP_NG_1024, [identity UTF8String], passwordData.bytes, passwordData.length, &bytes_s, &len_s, &bytes_v, &len_v, NULL, NULL, true);
    NSString *verifier = [[NSData dataWithBytesNoCopy:(void*)bytes_v length:len_v freeWhenDone:YES] ddp_toHex];
    NSArray *parameters = @[@{@"email": username,
                                 @"srp": @{@"identity": identity,
                                           @"salt": salt,
                                           @"verifier": verifier}}];
    [self callMethodName:@"createUser" parameters:parameters responseCallback:^(NSDictionary *response, NSError *error) {
        if (error) {
            responseCallback(nil, error);
            return;
        }
        [self logonWithUsername:username password:password responseCallback:responseCallback];
    }];
}

- (void)logonWithUsername:(NSString *)username password:(NSString *)password {
    [self logonWithUserParameters:_logonParams username:username password:password responseCallback:nil];
}

- (void)logonWithUsername:(NSString *)username password:(NSString *)password responseCallback:(MeteorClientMethodCallback)responseCallback {
    [self logonWithUserParameters:_logonParams username:username password:password responseCallback:responseCallback];
}

- (void)logonWithUserParameters:(NSDictionary *)userParameters username:(NSString *)username password:(NSString *)password responseCallback:(MeteorClientMethodCallback)responseCallback {
    if (self.authState == AuthStateLoggingIn) {
        NSString *errorDesc = [NSString stringWithFormat:@"You must wait for the current logon request to finish before sending another."];
        NSError *logonError = [NSError errorWithDomain:MeteorClientTransportErrorDomain code:MeteorClientErrorLogonRejected userInfo:@{NSLocalizedDescriptionKey: errorDesc}];
        if (responseCallback) {
            responseCallback(nil, logonError);
        }
        return;
    }
    [self _setAuthStateToLoggingIn];
    
    if ([self _rejectIfNotConnected:responseCallback]) {
        return;
    }
    
    if (!userParameters) {
        userParameters = @{@"user": @{@"username": username}};
    }
   
    NSMutableDictionary *mutableUserParameters = [userParameters mutableCopy];
    mutableUserParameters[@"A"] = [self generateAuthVerificationKeyWithUsername:username password:password];
    
    [self _setAuthStateToLoggingIn];
    
    [self callMethodName:@"beginPasswordExchange" parameters:@[mutableUserParameters] responseCallback:nil];
    _logonParams = userParameters;
    _logonMethodCallback = responseCallback;
}

- (void)logout {
    [self.ddp methodWithId:[BSONIdGenerator generate]
                    method:@"logout"
                parameters:nil];
    [self _setAuthStatetoLoggedOut];
}

- (void)disconnect {
    _disconnecting = YES;
    [self.ddp disconnectWebSocket];
    self.ddp = nil;
    self.connected = NO;
}

#pragma mark <ObjectiveDDPDelegate>

- (void)didReceiveMessage:(NSDictionary *)message {
    NSString *msg = [message objectForKey:@"msg"];
    if (!msg) return;
    NSString *messageId = message[@"id"];
    
    [self _handleMethodResultMessageWithMessageId:messageId message:message msg:msg];
    [self _handleLoginChallengeResponse:message msg:msg];
    [self _handleLoginError:message msg:msg];    
    [self _handleHAMKVerification:message msg:msg];
    [self _handleAddedMessage:message msg:msg];
    [self _handleRemovedMessage:message msg:msg];
    [self _handleChangedMessage:message msg:msg];
    
    if (msg && [msg isEqualToString:@"ping"]) {
        [self.ddp pong:messageId];
    }
    
    if (msg && [msg isEqualToString:@"failed"]) {
        NSString *version = [message objectForKey:@"version"];
        if (version) {
            self.ddpVersion = version;
        }
    }
    
    if (msg && [msg isEqualToString:@"connected"]) {
        self.connected = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"connected" object:nil];
        if (_sessionToken) {
            [self.ddp methodWithId:[BSONIdGenerator generate]
                            method:@"login"
                        parameters:@[@{@"resume": _sessionToken}]];
        }
        [self _makeMeteorDataSubscriptions];
    }
    
    if (msg && [msg isEqualToString:@"ready"]) {
        NSArray *subs = message[@"subs"];
        for(NSString *readySubscription in subs) {
            for(NSString *subscriptionName in _subscriptions) {
                NSString *curSubId = _subscriptions[subscriptionName];
                if([curSubId isEqualToString:readySubscription]) {
                    NSString *notificationName = [NSString stringWithFormat:@"%@_ready", subscriptionName];
                    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:self];
                    break;
                }
            }
        }
    }
}

- (void)didOpen {
    self.websocketReady = YES;
    [self resetCollections];
    [self.ddp connectWithSession:nil version:self.ddpVersion support:self.supportedVersions];
    [[NSNotificationCenter defaultCenter] postNotificationName:MeteorClientDidConnectNotification object:self];
}

- (void)didReceiveConnectionError:(NSError *)error {
    [self _handleConnectionError:error];
}

- (void)didReceiveConnectionClose {
    [self _handleConnectionError:nil];
}

#pragma mark - Internal

- (NSString *)_send:(BOOL)notify parameters:(NSArray *)parameters methodName:(NSString *)methodName {
    NSString *methodId = [BSONIdGenerator generate];
    if(notify == YES) {
        [_methodIds addObject:methodId];
    }
    [self.ddp methodWithId:methodId
                    method:methodName
                parameters:parameters];
    return methodId;
}

- (void)_handleConnectionError:(NSError *)error {
    self.websocketReady = NO;
    self.connected = NO;
    [self _invalidateUnresolvedMethods];
    [[NSNotificationCenter defaultCenter] postNotificationName:MeteorClientDidDisconnectNotification object:error];
    if (_disconnecting) {
        _disconnecting = NO;
        return;
    }
    [self performSelector:@selector(_reconnect) withObject:self afterDelay:5.0];
}

- (void)_invalidateUnresolvedMethods {
    for (NSString *methodId in _methodIds) {
        MeteorClientMethodCallback callback = _responseCallbacks[methodId];
        if(callback) {
            callback(nil, [NSError errorWithDomain:MeteorClientTransportErrorDomain code:MeteorClientErrorDisconnectedBeforeCallbackComplete userInfo:@{NSLocalizedDescriptionKey: @"You were disconnected"}]);
        }
    }
    [_methodIds removeAllObjects];
    [_responseCallbacks removeAllObjects];
}

- (BOOL)okToSend {
    if (!self.connected) {
        return NO;
    }
    return YES;
}

- (void)_reconnect {
    if (self.ddp.webSocket.readyState == SR_OPEN) {
        return;
    }
    [self.ddp connectWebSocket];
}

- (void)_makeMeteorDataSubscriptions {
    for (NSString *key in [_subscriptions allKeys]) {
        NSString *uid = [BSONIdGenerator generate];
        [_subscriptions setObject:uid forKey:key];
        NSArray *params = _subscriptionsParameters[key];
        [self.ddp subscribeWith:uid name:key parameters:params];
    }
}

- (BOOL)_rejectIfNotConnected:(MeteorClientMethodCallback)responseCallback {
    if (![self okToSend]) {
        NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"You are not connected"};
        NSError *notConnectedError = [NSError errorWithDomain:MeteorClientTransportErrorDomain code:MeteorClientErrorNotConnected userInfo:userInfo];
        if (responseCallback) {
            responseCallback(nil, notConnectedError);
        }
        return YES;
    }
    return NO;
}

- (void)_setAuthStateToLoggingIn {
    self.authState = AuthStateLoggingIn;
}

- (void)_setAuthStateToLoggedIn {
    self.authState = AuthStateLoggedIn;
}

- (void)_setAuthStatetoLoggedOut {
    _logonParams = nil;
    _sessionToken = nil;
    self.authState = AuthStateNoAuth;
}

# pragma mark - SRP Auth Internal

- (NSString *)generateAuthVerificationKeyWithUsername:(NSString *)username password:(NSString *)password {
    _userName = username;
    _password = password;
    const char *username_str = [username cStringUsingEncoding:NSASCIIStringEncoding];
    const char *password_str = [password cStringUsingEncoding:NSASCIIStringEncoding];
    _srpUser = srp_user_new(SRP_SHA256, SRP_NG_1024, username_str, password_str, NULL, NULL);
    srp_user_start_authentication(_srpUser);
    return [NSString stringWithCString:_srpUser->Astr encoding:NSASCIIStringEncoding];
}

@end
