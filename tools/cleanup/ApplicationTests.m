#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <fcntl.h>
#include <unistd.h>
extern char *WattInspectStorageApplication(const char *path);
extern NSDictionary *WattStorageInfoFromFD(int fd);
int main(void) {@autoreleasepool {
 char *temporaryRoot=realpath(NSTemporaryDirectory().fileSystemRepresentation,NULL);assert(temporaryRoot);
 NSString *root=[[NSString stringWithUTF8String:temporaryRoot] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];free(temporaryRoot);
 NSString *app=[root stringByAppendingPathComponent:@"Fixture.app"];
 NSFileManager *fm=NSFileManager.defaultManager;
 [fm createDirectoryAtPath:[app stringByAppendingPathComponent:@"Contents/MacOS"] withIntermediateDirectories:YES attributes:nil error:nil];
 // A suffix alone must not yield an application identity.
 char *raw=WattInspectStorageApplication(app.fileSystemRepresentation);
 assert(raw==NULL);
 NSDictionary *info=@{@"CFBundleIdentifier":@"test.fixture",@"CFBundleName":@"Fixture",@"CFBundlePackageType":@"APPL",@"CFBundleExecutable":@"fixture"};
 [info writeToFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES];
 [@"not signed executable" writeToFile:[app stringByAppendingPathComponent:@"Contents/MacOS/fixture"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
 raw=WattInspectStorageApplication(app.fileSystemRepresentation);assert(raw!=NULL);
 NSDictionary *result=[NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];free(raw);
 assert([result[@"bundleID"] isEqual:@"test.fixture"]);
 assert(![result[@"resolved"] boolValue]&&![result[@"thirdParty"] boolValue]);
 assert([fm fileExistsAtPath:app]); // Inspection never mutates bundles.
 NSString *linkApp=[root stringByAppendingPathComponent:@"Linked.app"];
 [fm createDirectoryAtPath:linkApp withIntermediateDirectories:YES attributes:nil error:nil];
 [fm createSymbolicLinkAtPath:[linkApp stringByAppendingPathComponent:@"Contents"] withDestinationPath:[app stringByAppendingPathComponent:@"Contents"] error:nil];
 raw=WattInspectStorageApplication(linkApp.fileSystemRepresentation);
 if(raw){
  NSDictionary *rejected=[NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];free(raw);
  assert(rejected[@"inspectionError"]!=nil&&rejected[@"bundleID"]==nil);
 }
#ifndef WATT_STORAGE_BOUNDARY_ONLY
 // Pin the opened file, replace the pathname, then read. A pathname re-open
 // would pick the replacement instead of the original test.fixture identity.
 NSString *plist=[app stringByAppendingPathComponent:@"Contents/Info.plist"];
 int fd=open(plist.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);assert(fd>=0);
 [fm moveItemAtPath:plist toPath:[plist stringByAppendingString:@".old"] error:nil];
 [@{@"CFBundleIdentifier":@"test.replacement"} writeToFile:plist atomically:YES];
 NSDictionary *pinned=WattStorageInfoFromFD(fd);close(fd);
 assert([pinned[@"CFBundleIdentifier"] isEqual:@"test.fixture"]);
 NSMutableData *large=[NSMutableData dataWithLength:1024*1024+1];
 [large writeToFile:plist atomically:YES];fd=open(plist.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);assert(fd>=0);
 assert(WattStorageInfoFromFD(fd)==nil);close(fd);
#endif
 [fm removeItemAtPath:root error:nil]; // Only this synthetic fixture, never a real app.
 NSLog(@"Application identity checks passed");
}return 0;}
