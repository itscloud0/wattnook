#import "../../pkg/gui/native_internal.h"
#include <assert.h>
#include <sys/stat.h>
#include <unistd.h>
void battMenuWillOpen(uintptr_t h) {}
void battMenuTimerFired(uintptr_t h) {}
void battMenuAction(uintptr_t h,int i,bool b) {}
bool battMenuSetLimit(uintptr_t h,int i) {return true;}
void battMainCallback(uintptr_t h) {}
static int lastAction,actionCount;static uint64_t lastGeneration;
void battStorageAction(uintptr_t h,uint64_t g,int a){lastAction=a;lastGeneration=g;actionCount++;}
static NSButton *FindButton(NSView *v,NSString *title){
 for(NSView *child in v.subviews){
  if([child isKindOfClass:NSButton.class]&&[((NSButton *)child).title isEqual:title])return (NSButton *)child;
  NSButton *found=FindButton(child,title);if(found)return found;
 }return nil;
}
static void Capture(NSView *view,NSString *directory,NSString *name){
 if(!directory)return;
 NSBitmapImageRep *image=[view bitmapImageRepForCachingDisplayInRect:view.bounds];
 [view cacheDisplayInRect:view.bounds toBitmapImageRep:image];
 [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES];
}
int main(int argc,const char **argv){@autoreleasepool{
 [NSApplication sharedApplication];
 BattMenuController *c=[[BattMenuController alloc]init];c.handle=1;c.items=[NSMutableDictionary dictionary];
 c.powerFlowView=[[[BattPowerFlowView alloc]initWithFrame:NSMakeRect(0,0,400,220)]autorelease];BattBuildPopover(c);
 NSView *dashboard=c.popover.contentViewController.view;
 int windows=(int)NSApp.windows.count;
 [FindButton(dashboard,@"Storage") performClick:nil];assert((int)NSApp.windows.count==windows&&actionCount==0);
 NSView *v=c.storageView;
 NSTableView *table=[v valueForKey:@"table"];
 NSButton *scan=[v valueForKey:@"scanButton"];
 assert([scan.title isEqual:@"Scan"]&&table.numberOfRows==0);
 assert(table.headerView==nil&&table.rowHeight==52);
 assert(FindButton(v,@"Review")==nil);
 NSString *directory=argc==2?[NSString stringWithUTF8String:argv[1]]:nil;
 NSWindow *host=[[[NSWindow alloc]initWithContentRect:dashboard.bounds styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO]autorelease];
 host.contentView=dashboard;[host orderFront:nil];[dashboard displayIfNeeded];Capture(dashboard,directory,@"initial.png");
 assert(![[v valueForKey:@"stateView"] isHidden]);
 [scan performClick:nil];assert(lastAction==1&&lastGeneration==c.storageGeneration);
 [((NSTextField *)[v valueForKey:@"stateText"]) setStringValue:@"219,862 files checked. You can close WattNook; the scan keeps going."];
 [dashboard displayIfNeeded];Capture(dashboard,directory,@"scanning.png");
 [scan performClick:nil];assert(lastAction==2&&!scan.enabled);
 NSDictionary *identity=@{@"name":@"An application with a deliberately long but real-looking name",@"bundleID":@"test.one",@"path":@"/synthetic/Applications/One.app",@"running":@YES};
 NSDictionary *snapshot=@{@"state":@"partial",@"reason":@"Some folders were inaccessible",@"applications":@{@"entries":@[
  @{@"identity":identity,@"size":@{@"bytes":@3000000000000ULL,@"complete":@YES},@"reason":@"Quit the application normally before removing it",
   @"leftovers":@[@{@"path":@"/synthetic/Library/Caches/test.one",@"category":@"Caches",@"bytes":@1234000000,@"complete":@YES},
                  @{@"path":@"/synthetic/Library/Application Support/One",@"category":@"Application Support",@"bytes":@1000,@"complete":@YES,@"suggested":@YES}]},
  @{@"identity":@{@"name":@"Second",@"bundleID":@"test.two",@"path":@"/synthetic/Applications/Two.app"},@"size":@{@"complete":@NO}}]},
  @"observations":@[@{@"path":@"/synthetic/Library/Caches/test.one",@"displayPath":@"/synthetic/Library/Caches/test.one",@"category":@"Application cache",@"bytes":@1234000000,@"complete":@YES}]};
 WattUpdateStorageReview(c,c.storageGeneration,snapshot);
 assert(table.numberOfRows==2&&table.selectedRow==-1&&scan.enabled);
 assert(NSWidth(v.bounds)==400&&NSHeight(v.bounds)==450&&NSMaxX(scan.frame)<=384);
 [dashboard displayIfNeeded];Capture(dashboard,directory,@"applications.png");
 NSSearchField *search=[v valueForKey:@"searchField"];search.stringValue=@"second";
 [(id)v controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
 assert(table.numberOfRows==1);
 search.stringValue=@"";[(id)v controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
 [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
 // A single click on a row opens its detail; there is no separate Review button.
 assert(table.action==@selector(review:)&&table.target==v);[table sendAction:table.action to:table.target];
 NSView *detail=[v valueForKey:@"detailView"];assert(!detail.hidden);
 NSTextField *path=[v valueForKey:@"pathLabel"];assert(path.selectable&&[path.stringValue isEqual:identity[@"path"]]);
 // Uninstaller: the bundle and its exact leftovers are checked, name-only matches are not;
 // a running app cannot be moved.
 NSArray *checks=[v valueForKey:@"checks"];assert(checks.count==3);
 assert(((NSButton *)checks[0]).state==NSControlStateValueOn&&((NSButton *)checks[1]).state==NSControlStateValueOn&&((NSButton *)checks[2]).state==NSControlStateValueOff);
 NSButton *trash=FindButton(detail,@"Move to Trash");assert(trash&&!trash.enabled);
 assert(FindButton(detail,@"Show in Finder")!=nil);
 [dashboard displayIfNeeded];Capture(dashboard,directory,@"detail.png");
 [FindButton(detail,@"Back") performClick:nil];assert(detail.hidden&&table.selectedRow==-1);
 WattUpdateStorageReview(c,c.storageGeneration,@{@"state":@"error",@"reason":@"Permission denied"});
 assert(detail.hidden&&table.numberOfRows==0);
 assert([((NSTextField *)[v valueForKey:@"stateText"]).stringValue containsString:@"Permission denied"]);
 [dashboard displayIfNeeded];Capture(dashboard,directory,@"error.png");
 // Switching tabs or closing the popover neither cancels a scan nor drops results.
 int before=actionCount;uint64_t generation=c.storageGeneration;
 [FindButton(dashboard,@"Battery") performClick:nil];assert(actionCount==before&&v.hidden);
 [FindButton(dashboard,@"Storage") performClick:nil];assert(c.storageGeneration==generation);
 [scan performClick:nil];assert(lastAction==1);int started=actionCount;
 [c popoverDidClose:[NSNotification notificationWithName:NSPopoverDidCloseNotification object:c.popover]];
 assert(actionCount==started);
 WattUpdateStorageReview(c,c.storageGeneration,snapshot);assert(table.numberOfRows==2);
 // README capture: real app icons and names from this Mac, illustrative sizes.
 if(directory){
  NSArray *names=@[@"Cursor",@"Discord",@"Spotify",@"Telegram",@"Notion",@"Linear",@"Zed"];
  NSArray *bytes=@[@1460000000,@820000000,@640000000,@510000000,@470000000,@380000000,@290000000];
  NSMutableArray *entries=[NSMutableArray array];
  for(NSUInteger i=0;i<names.count;i++){
   NSString *id=[@"com.example." stringByAppendingString:[names[i] lowercaseString]];
   NSString *lib=[NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
   [entries addObject:@{@"identity":@{@"name":names[i],@"bundleID":id,@"path":[NSString stringWithFormat:@"/Applications/%@.app",names[i]]},
    @"size":@{@"bytes":bytes[i],@"complete":@YES},
    @"leftovers":@[@{@"path":[lib stringByAppendingFormat:@"/Application Support/%@",names[i]],@"category":@"Application Support",@"bytes":@([bytes[i] doubleValue]*0.6),@"complete":@YES},
                   @{@"path":[lib stringByAppendingFormat:@"/Caches/%@",id],@"category":@"Caches",@"bytes":@([bytes[i] doubleValue]*0.3),@"complete":@YES},
                   @{@"path":[lib stringByAppendingFormat:@"/Preferences/%@.plist",id],@"category":@"Preferences",@"bytes":@12000,@"complete":@YES},
                   @{@"path":[lib stringByAppendingFormat:@"/Saved Application State/%@.savedState",id],@"category":@"Saved state",@"bytes":@48000,@"complete":@YES}]}];
  }
  WattUpdateStorageReview(c,c.storageGeneration,@{@"state":@"complete",@"applications":@{@"entries":entries}});
  [dashboard displayIfNeeded];Capture(dashboard,directory,@"readme-storage.png");
  [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];[table sendAction:table.action to:table.target];
  [dashboard displayIfNeeded];Capture(dashboard,directory,@"readme-uninstall.png");
  [FindButton(detail,@"Back") performClick:nil];
 }
 // End to end: a throwaway bundle goes to the Trash through the real path
 // (revalidation, then NSWorkspace recycle), and leaves the list.
 NSString *tmp=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"wattnook-trash-%d",getpid()]];
 NSString *bundle=[tmp stringByAppendingPathComponent:@"WattNook Trash Test.app"];
 [NSFileManager.defaultManager createDirectoryAtPath:[bundle stringByAppendingPathComponent:@"Contents/MacOS"] withIntermediateDirectories:YES attributes:nil error:NULL];
 struct stat st;assert(lstat(bundle.fileSystemRepresentation,&st)==0);
 NSDictionary *dummy=@{@"name":@"WattNook Trash Test",@"bundleID":@"io.wattnook.trash-test",@"path":bundle,
  @"device":@((uint64_t)st.st_dev),@"inode":@((uint64_t)st.st_ino)};
 WattUpdateStorageReview(c,c.storageGeneration,@{@"state":@"complete",@"applications":@{@"entries":@[
  @{@"identity":dummy,@"size":@{@"bytes":@4096,@"complete":@YES}}]}});
 assert(table.numberOfRows==1);
 [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];[table sendAction:table.action to:table.target];
 NSButton *move=FindButton(detail,@"Move to Trash");assert(move.enabled);
 [move performClick:nil];assert([move.title isEqual:@"Move 1 item"]);[move performClick:nil];
 for(int i=0;i<100&&[NSFileManager.defaultManager fileExistsAtPath:bundle];i++)
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
 [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
 assert(![NSFileManager.defaultManager fileExistsAtPath:bundle]&&table.numberOfRows==0);
 [NSFileManager.defaultManager removeItemAtPath:tmp error:NULL];
 [host orderOut:nil];[c release];NSLog(@"Application-first Storage checks passed");
}return 0;}
