#import <Foundation/Foundation.h>
#import <SocketRocket/SRWebSocket.h>

@protocol ObjectiveDDPDelegate;

@interface ObjectiveDDP : NSObject <SRWebSocketDelegate>

@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, weak) id <ObjectiveDDPDelegate> delegate;
@property (nonatomic, strong) SRWebSocket *webSocket;

- (id)initWithURLString:(NSString *)urlString delegate:(id <ObjectiveDDPDelegate>)delegate;
- (void)connectWebSocket;
- (void)disconnectWebSocket;
- (void)connectWithSession:(NSString *)session version:(NSString *)version support:(NSString *)support;
- (void)subscribeWith:(NSString *)id name:(NSString *)name parameters:(NSArray *)parameters;
- (void)unsubscribeWith:(NSString *)id;
- (void)methodWithId:(NSString *)id method:(NSString *)method parameters:(NSArray *)parameters;
- (void)ping;
- (void)pong:(NSString *)id;

@end

@protocol ObjectiveDDPDelegate

- (void)didOpen;
- (void)didReceiveMessage:(NSDictionary *)message;
- (void)didReceiveConnectionError:(NSError *)error;
- (void)didReceiveConnectionClose;

@end
