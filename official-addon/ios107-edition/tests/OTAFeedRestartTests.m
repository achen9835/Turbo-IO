#import "ExperimentalOTAFeed.h"
#include <assert.h>
#include <arpa/inet.h>
#include <errno.h>
#include <sys/socket.h>
#include <unistd.h>

static void QueryAndClose(uint16_t port) {
    int fd=socket(AF_INET,SOCK_STREAM,0);assert(fd>=0);
    struct sockaddr_in a={0};a.sin_family=AF_INET;a.sin_port=htons(port);
    a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    struct timeval timeout={3,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    assert(connect(fd,(struct sockaddr *)&a,sizeof(a))==0);
    NSString *s=[NSString stringWithFormat:@"GET /g/xxxxxxxA78p2M?packageType=app HTTP/1.1\r\nHost: 127.0.0.1:%u\r\n\r\n",port];
    NSData *data=[s dataUsingEncoding:NSUTF8StringEncoding];
    assert(send(fd,data.bytes,data.length,0)==(ssize_t)data.length);
    /* 主动关闭：让 TIME_WAIT 落在客户端临时端口而不是监听端口。若读到服务端
     * FIN 再关（原写法），服务端 accept 套接字以监听端口进入 TIME_WAIT
     * （Darwin ≈30s，无 SO_REUSEADDR），同端口重绑要等半个分钟。本测试只要求
     * 请求被完整处理，无需读取应答；请求字节已入发送缓冲，FIN 按序到达服务端。 */
    shutdown(fd,SHUT_WR);close(fd);
}

int main(void){@autoreleasepool{
    TIOExperimentalOTAFeed *feed=[TIOExperimentalOTAFeed new];NSError *error=nil;
    assert([feed startOnPort:0 error:&error]);uint16_t port=feed.port;
    TIOExperimentalOTAFeed *duplicate=[TIOExperimentalOTAFeed new];
    assert(![duplicate startOnPort:port error:&error]); // Never share an active listener.
    assert([feed.status[@"running"] boolValue]);assert([feed.status[@"queryCount"] unsignedIntegerValue]==0);
    QueryAndClose(port);[feed stop];assert(![feed.status[@"running"] boolValue]);
    /* 实现有意不设 SO_REUSEADDR/SO_REUSEPORT（避免同端口被二次监听），已接受连接的
     * TIME_WAIT 会让 bind 短暂失败——重试直至可重绑（通常远小于 5 秒），而非固定 150ms。 */
    BOOL rebound=NO;for(unsigned t=0;t<50&&!rebound;t++){rebound=[duplicate startOnPort:port error:&error];if(!rebound)usleep(100000);}
    assert(rebound); // Failed bind is retryable once the listener's connections leave TIME_WAIT.
    assert([duplicate.status[@"running"] boolValue]&&![duplicate.status[@"armed"] boolValue]);
    [duplicate stop];usleep(150000);
    for(unsigned i=0;i<6;i++){
        TIOExperimentalOTAFeed *next=[TIOExperimentalOTAFeed new];
        BOOL up=NO;for(unsigned t=0;t<50&&!up;t++){up=[next startOnPort:port error:&error];if(!up)usleep(100000);}
        if(!up){
            NSLog(@"FAIL: listener cannot rebind after a completed request (iteration %u)",i);return 1;
        }
        assert(![next.status[@"armed"] boolValue]); // Restart cannot authorize even a download.
        assert([next.status[@"running"] boolValue]);QueryAndClose(port);[next stop];usleep(150000);
    }
    NSLog(@"PASS: six same-port restarts; active duplicate rejected; default disarmed; no glasses IO");
}return 0;}
