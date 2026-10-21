#import "../../pkg/gui/native_internal.h"
#include <assert.h>
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
 [scan performClick:nil];assert(lastAction==1&&lastGeneration==c.storageGeneration);
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
 assert([((NSTextField *)[v valueForKey:@"statusLabel"]).stringValue containsString:@"Permission denied"]);
 [dashboard displayIfNeeded];Capture(dashboard,directory,@"error.png");
 uint64_t old=c.storageGeneration;[FindButton(dashboard,@"Battery") performClick:nil];assert(lastAction==3&&v.hidden);
 [FindButton(dashboard,@"Storage") performClick:nil];assert(c.storageGeneration!=old);
 WattUpdateStorageReview(c,old,snapshot);assert(table.numberOfRows==0);
 [scan performClick:nil];[c popoverDidClose:[NSNotification notificationWithName:NSPopoverDidCloseNotification object:c.popover]];
 assert(lastAction==3&&table.numberOfRows==0);
 [host orderOut:nil];[c release];NSLog(@"Application-first Storage checks passed");
}return 0;}
