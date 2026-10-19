#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

static char *StorageMetadataJSON(NSDictionary *value) {
 NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
 NSString *json=data?[[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]autorelease]:nil;
 return json?strdup(json.UTF8String):NULL;
}
static char *StorageMetadataError(void) {
 return StorageMetadataJSON(@{@"inspectionError":@"Application metadata could not be read safely"});
}
static int StorageOpenBundle(NSString *path) {
 if(!path.isAbsolutePath){errno=EINVAL;return -1;}
 int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
 for(NSString *component in path.pathComponents){
  if([component isEqual:@"/"])continue;
  if(fd<0)return -1;
  if([component isEqual:@"."] || [component isEqual:@".."]) {close(fd);errno=EINVAL;return -1;}
  int next=openat(fd,component.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  int error=errno;close(fd);fd=next;errno=error;
 }
 return fd;
}

// Consumes a borrowed, already-open regular file. The byte bound applies to
// the actual read, even if the file grows after fstat; no pathname is reopened.
NSDictionary *WattStorageInfoFromFD(int fd) {
 struct stat st;
 const NSUInteger limit=1024*1024;
 if(fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_size<0 || st.st_size>limit)return nil;
 NSMutableData *data=[NSMutableData data];unsigned char buffer[16384];
 while(data.length<=limit){
  size_t available=MIN(sizeof(buffer),limit+1-data.length);
  ssize_t count=read(fd,buffer,available);
  if(count<0){if(errno==EINTR)continue;return nil;}
  if(count==0)break;
  [data appendBytes:buffer length:(NSUInteger)count];
 }
 if(data.length>limit)return nil;
 id value=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
 return [value isKindOfClass:NSDictionary.class]?value:nil;
}

// Metadata-only classification. No resource walk, network permission or mutation.
// A discovered identity is not durable authorization for a later Trash request.
char *WattInspectStorageApplication(const char *path) {
 @autoreleasepool {
  if (!path) return NULL;
  NSString *p=[NSString stringWithUTF8String:path];
  if (!p) return NULL;
  int bundleFD=StorageOpenBundle(p);
  if(bundleFD<0)return StorageMetadataError();
  int contentsFD=openat(bundleFD,"Contents",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  close(bundleFD);
  if(contentsFD<0)return errno==ENOENT?NULL:StorageMetadataError();
  int infoFD=openat(contentsFD,"Info.plist",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
  if(infoFD<0){int error=errno;close(contentsFD);return error==ENOENT?NULL:StorageMetadataError();}
  NSDictionary *info=WattStorageInfoFromFD(infoFD);close(infoFD);
  if(!info){close(contentsFD);return StorageMetadataError();}
  NSString *identifier=info[@"CFBundleIdentifier"];
  NSString *executable=info[@"CFBundleExecutable"];
  if (![info[@"CFBundlePackageType"] isEqual:@"APPL"] || ![identifier isKindOfClass:NSString.class] ||
      !identifier.length || ![executable isKindOfClass:NSString.class] || !executable.length ||
      [executable containsString:@"/"] || [executable isEqual:@".."] || [executable isEqual:@"."]) {close(contentsFD);return NULL;}
  int executableDir=openat(contentsFD,"MacOS",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(contentsFD);
  if(executableDir<0)return StorageMetadataError();
  int executableFD=openat(executableDir,executable.fileSystemRepresentation,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);close(executableDir);
  struct stat executableStat;
  BOOL regular=executableFD>=0 && fstat(executableFD,&executableStat)==0 && S_ISREG(executableStat.st_mode);
  if(executableFD>=0)close(executableFD);
  if(!regular)return StorageMetadataError();
  NSString *name=info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
  if (![name isKindOfClass:NSString.class] || !name.length) name=p.lastPathComponent.stringByDeletingPathExtension;
  BOOL resolved=NO,thirdParty=NO;
  SecStaticCodeRef code=NULL; SecRequirementRef apple=NULL,trusted=NULL;
  if (SecStaticCodeCreateWithPath((CFURLRef)[NSURL fileURLWithPath:p],kSecCSDefaultFlags,&code)==errSecSuccess) {
   SecRequirementCreateWithString(CFSTR("anchor apple"),kSecCSDefaultFlags,&apple);
   SecRequirementCreateWithString(CFSTR("anchor apple generic"),kSecCSDefaultFlags,&trusted);
   BOOL appleCode=apple && SecStaticCodeCheckValidity(code,kSecCSBasicValidateOnly,apple)==errSecSuccess;
   BOOL trustedCode=trusted && SecStaticCodeCheckValidity(code,kSecCSBasicValidateOnly,trusted)==errSecSuccess;
   CFDictionaryRef signing=NULL;
   if (SecCodeCopySigningInformation(code,kSecCSSigningInformation,&signing)==errSecSuccess) {
    NSString *signedID=((NSDictionary *)signing)[(NSString *)kSecCodeInfoIdentifier];
    resolved=[identifier isEqual:signedID] && (appleCode || trustedCode);
    CFRelease(signing);
   }
   thirdParty=resolved && !appleCode && ![identifier.lowercaseString hasPrefix:@"com.apple."];
  }
  if (code) CFRelease(code);if (apple) CFRelease(apple);if (trusted) CFRelease(trusted);
  BOOL protected=[p isEqual:NSBundle.mainBundle.bundlePath] || [identifier isEqual:NSBundle.mainBundle.bundleIdentifier] ||
      [identifier isEqual:@"com.wattnook.app"] || [name isEqual:@"WattNook"];
  BOOL running=NO;
  for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
   if ([identifier isEqual:app.bundleIdentifier] || [p isEqual:app.bundleURL.path]) {running=YES;break;}
  }
  NSDictionary *result=@{@"path":p,@"bundleID":identifier,@"name":name,@"resolved":@(resolved),
      @"thirdParty":@(thirdParty),@"protected":@(protected),@"running":@(running)};
  return StorageMetadataJSON(result);
 }
}
