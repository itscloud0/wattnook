#import "native_internal.h"
#import <poll.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>

static NSNumber *SleepStatus(NSData *data) {
    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!text) return nil;
    NSNumber *result = nil;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSMutableArray *fields = [NSMutableArray array];
        for (NSString *field in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
            if (field.length) [fields addObject:field];
        if (![fields.firstObject isEqual:@"SleepDisabled"]) continue;
        if (result || fields.count != 2 || ![@[@"0",@"1"] containsObject:fields[1]]) return nil;
        result = @([fields[1] isEqual:@"1"]);
    }
    return result;
}

void WattReadSleepStatus(NSString *executable, NSArray<NSString *> *arguments, NSTimeInterval timeout,
                        void (^completion)(NSNumber *, NSString *)) {
    // Direct read-only pmset invocation, no Swift-helper process and no main-thread wait.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @autoreleasepool {
            NSTask *task = [[[NSTask alloc] init] autorelease];
            NSPipe *pipe = [NSPipe pipe];
            task.executableURL = [NSURL fileURLWithPath:executable]; task.arguments = arguments;
            task.standardOutput = pipe; task.standardError = NSFileHandle.fileHandleWithNullDevice;
            NSString *error = nil; NSNumber *status = nil;
            NSMutableData *data = [NSMutableData data];
            @try {
                [task launch];
                int fd = pipe.fileHandleForReading.fileDescriptor;
                int flags = fcntl(fd,F_GETFL);
                if (flags < 0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK) < 0)
                    error = @"Cannot read sleep status output";
                double seconds = isfinite(timeout) && timeout > 0 ? MIN(timeout,5) : 2;
                NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime+seconds;
                BOOL eof = NO;
                while (!error && !(eof && !task.running)) {
                    double remaining = deadline-NSProcessInfo.processInfo.systemUptime;
                    if (remaining <= 0) { error = @"Sleep status check timed out; retry shortly"; break; }
                    struct pollfd stream = {fd,POLLIN|POLLHUP,0};
                    int ready = poll(eof ? NULL : &stream,eof ? 0 : 1,(int)MIN(50,MAX(1,remaining*1000)));
                    if (ready < 0 && errno != EINTR) { error = @"Sleep status output failed"; break; }
                    if (ready <= 0 || eof) continue;
                    if (stream.revents & (POLLERR|POLLNVAL)) { error = @"Sleep status output failed"; break; }
                    char buffer[4096]; ssize_t length = read(fd,buffer,sizeof(buffer));
                    if (length == 0) eof = YES;
                    else if (length > 0) {
                        if (data.length+(NSUInteger)length > 16384) { error = @"Unexpected sleep status output size"; break; }
                        [data appendBytes:buffer length:(NSUInteger)length];
                    } else if (errno != EAGAIN && errno != EINTR) { error = @"Sleep status output failed"; break; }
                }
                if (!error) {
                    if (task.terminationStatus == 0) status = SleepStatus(data);
                    if (!status) error = @"Cannot read macOS sleep setting; last display guard state retained";
                }
            } @catch (NSException *exception) {
                (void)exception; error = @"Cannot start sleep status check";
            }
            // Only this read-only child is terminated; never an app or authorization helper.
            if (task.running) kill(task.processIdentifier,SIGKILL);
            [pipe.fileHandleForReading closeFile];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(status,error); });
        }
    });
}
