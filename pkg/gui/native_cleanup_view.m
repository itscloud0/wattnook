#import "native_internal.h"
#include <sys/stat.h>

static NSTextField *StorageLabel(NSView *parent,NSRect frame,NSString *text,CGFloat size,BOOL prominent) {
 NSTextField *label=[NSTextField wrappingLabelWithString:text];label.frame=frame;
 label.font=[NSFont systemFontOfSize:size weight:prominent?NSFontWeightSemibold:NSFontWeightRegular];
 label.textColor=prominent?NSColor.labelColor:NSColor.secondaryLabelColor;
 label.maximumNumberOfLines=2;[parent addSubview:label];return label;
}
// Storage uses the dashboard's own controls, not stock AppKit bezels.
static NSButton *StorageButton(NSView *parent,NSRect frame,NSString *title,id target,SEL action) {
 return WattActionButton(parent,frame,title,@"",target,action);
}
static NSString *StorageSize(NSDictionary *observation) {
 if (![observation[@"complete"] boolValue]) return [observation[@"bytes"] doubleValue]>0?
  [NSString stringWithFormat:@"%@+",WattCompactBytes([observation[@"bytes"] doubleValue],NO)]:@"Not measured";
 return WattCompactBytes([observation[@"bytes"] doubleValue],NO);
}
static uint64_t StorageBytes(NSDictionary *observation) {return [observation[@"bytes"] unsignedLongLongValue];}
static NSView *StorageTile(NSView *parent,NSRect frame) {
 NSView *tile=[[[NSView alloc]initWithFrame:frame]autorelease];
 tile.wantsLayer=YES;tile.layer.backgroundColor=WattTileColor(NO).CGColor;tile.layer.cornerRadius=14;
 [parent addSubview:tile];return tile;
}
@interface WattFlippedView : NSView
@end
@implementation WattFlippedView
- (BOOL)isFlipped {return YES;}
@end

// Applications with everything that belongs to them, sized together, and an
// uninstaller that moves the selected parts to the Trash after revalidating
// them. Nothing is removed permanently.
@interface WattStorageView : NSView <NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate> {
 BattMenuController *_owner;
 uint64_t _generation;
 BOOL _running,_active,_confirming;
}
@property(nonatomic,retain) NSView *listView,*detailView,*componentsView,*stateView;
@property(nonatomic,retain) NSButton *scanButton,*trashButton,*stateButton;
@property(nonatomic,retain) NSSearchField *searchField;
@property(nonatomic,retain) NSTableView *table;
@property(nonatomic,retain) NSProgressIndicator *progressBar;
@property(nonatomic,retain) NSImageView *stateIcon;
@property(nonatomic,retain) NSTextField *stateTitle,*stateText;
@property(nonatomic,retain) NSTextField *totalLabel,*statusLabel,*emptyLabel,*pathLabel,*detailTitle,*detailSize,*detailReason;
@property(nonatomic,retain) NSImageView *detailIcon;
@property(nonatomic,copy) NSArray *applications,*rows,*components;
@property(nonatomic,retain) NSMutableArray *checks;
@property(nonatomic,copy) NSDictionary *selectedItem;
- (instancetype)initWithOwner:(BattMenuController *)owner;
- (void)setActive:(BOOL)active;
- (void)shutdown;
- (void)update:(NSDictionary *)snapshot;
@end

@implementation WattStorageView
- (instancetype)initWithOwner:(BattMenuController *)owner {
 if (!(self=[super initWithFrame:NSMakeRect(0,0,400,450)]))return nil;
 _owner=owner;self.checks=[NSMutableArray array];
 self.listView=[[[NSView alloc]initWithFrame:self.bounds]autorelease];[self addSubview:_listView];
 self.searchField=[[[NSSearchField alloc]initWithFrame:NSMakeRect(16,412,276,28)]autorelease];
 _searchField.placeholderString=@"Search applications";_searchField.delegate=self;
 [_searchField setAccessibilityLabel:@"Search applications"];[_listView addSubview:_searchField];
 self.scanButton=StorageButton(_listView,NSMakeRect(300,411,84,30),@"Scan",self,@selector(scan:));
 [_scanButton setAccessibilityIdentifier:@"storage.scan"];
 self.totalLabel=StorageLabel(_listView,NSMakeRect(32,368,336,30),@"",24,YES);_totalLabel.maximumNumberOfLines=1;
 self.statusLabel=StorageLabel(_listView,NSMakeRect(32,348,336,18),@"Scan to see what each app takes, leftovers included.",12,NO);
 _statusLabel.maximumNumberOfLines=1;_statusLabel.lineBreakMode=NSLineBreakByTruncatingTail;
 StorageTile(_listView,NSMakeRect(16,8,368,332));
 NSScrollView *scroll=[[[NSScrollView alloc]initWithFrame:NSMakeRect(24,14,352,320)]autorelease];
 scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;scroll.drawsBackground=NO;scroll.borderType=NSNoBorder;
 self.table=[[[NSTableView alloc]initWithFrame:NSMakeRect(0,0,352,320)]autorelease];
 _table.delegate=self;_table.dataSource=self;_table.rowHeight=52;_table.headerView=nil;
 _table.backgroundColor=NSColor.clearColor;if(@available(macOS 11.0,*))_table.style=NSTableViewStylePlain;_table.intercellSpacing=NSMakeSize(0,0);
 _table.allowsMultipleSelection=NO;_table.allowsEmptySelection=YES;
 [_table setAccessibilityLabel:@"Applications and their sizes"];
 NSTableColumn *column=[[[NSTableColumn alloc]initWithIdentifier:@"application"]autorelease];
 column.width=352;column.minWidth=330;[_table addTableColumn:column];
 _table.columnAutoresizingStyle=NSTableViewLastColumnOnlyAutoresizingStyle;
 _table.target=self;_table.action=@selector(review:);_table.selectionHighlightStyle=NSTableViewSelectionHighlightStyleNone;
 scroll.documentView=_table;[_listView addSubview:scroll];
 self.emptyLabel=StorageLabel(_listView,NSMakeRect(48,170,304,40),@"No matching applications.\nTry another name.",13,NO);
 _emptyLabel.alignment=NSTextAlignmentCenter;_emptyLabel.maximumNumberOfLines=2;_emptyLabel.hidden=YES;

 // Before the first result (and while a scan runs) one tile owns the page:
 // what Storage does, the live count, and the one action.
 self.stateView=StorageTile(self,NSMakeRect(16,8,368,432));
 self.stateIcon=[[[NSImageView alloc]initWithFrame:NSMakeRect(152,262,64,56)]autorelease];
 _stateIcon.symbolConfiguration=[NSImageSymbolConfiguration configurationWithPointSize:44 weight:NSFontWeightLight];
 _stateIcon.contentTintColor=NSColor.secondaryLabelColor;[_stateView addSubview:_stateIcon];
 self.stateTitle=StorageLabel(_stateView,NSMakeRect(24,222,320,24),@"",17,YES);
 _stateTitle.alignment=NSTextAlignmentCenter;_stateTitle.maximumNumberOfLines=1;
 self.stateText=StorageLabel(_stateView,NSMakeRect(40,170,288,44),@"",13,NO);
 _stateText.alignment=NSTextAlignmentCenter;_stateText.maximumNumberOfLines=3;
 self.progressBar=[[[NSProgressIndicator alloc]initWithFrame:NSMakeRect(84,148,200,8)]autorelease];
 _progressBar.style=NSProgressIndicatorStyleBar;_progressBar.indeterminate=YES;_progressBar.displayedWhenStopped=NO;
 [_stateView addSubview:_progressBar];
 self.stateButton=StorageButton(_stateView,NSMakeRect(114,96,140,32),@"Scan",self,@selector(scan:));

 self.detailView=[[[NSView alloc]initWithFrame:self.bounds]autorelease];_detailView.hidden=YES;[self addSubview:_detailView];
 NSButton *back=WattActionButton(_detailView,NSMakeRect(12,412,84,28),@"Back",@"chevron.left",self,@selector(back:));
 WattSetButtonPlain(back,YES);
 self.detailIcon=[[[NSImageView alloc]initWithFrame:NSMakeRect(32,346,48,48)]autorelease];[_detailView addSubview:_detailIcon];
 self.detailTitle=StorageLabel(_detailView,NSMakeRect(92,372,276,22),@"",17,YES);_detailTitle.maximumNumberOfLines=1;
 _detailTitle.lineBreakMode=NSLineBreakByTruncatingTail;
 self.pathLabel=StorageLabel(_detailView,NSMakeRect(92,350,276,18),@"",11,NO);
 _pathLabel.selectable=YES;_pathLabel.maximumNumberOfLines=1;_pathLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;
 self.detailSize=StorageLabel(_detailView,NSMakeRect(32,308,336,26),@"",20,YES);_detailSize.maximumNumberOfLines=1;
 _detailSize.font=[NSFont monospacedDigitSystemFontOfSize:20 weight:NSFontWeightSemibold];
 StorageTile(_detailView,NSMakeRect(16,74,368,226));
 NSScrollView *parts=[[[NSScrollView alloc]initWithFrame:NSMakeRect(20,78,360,218)]autorelease];
 parts.hasVerticalScroller=YES;parts.autohidesScrollers=YES;parts.drawsBackground=NO;parts.borderType=NSNoBorder;
 self.componentsView=[[[WattFlippedView alloc]initWithFrame:NSMakeRect(0,0,344,218)]autorelease];
 parts.documentView=_componentsView;[_detailView addSubview:parts];
 self.detailReason=StorageLabel(_detailView,NSMakeRect(32,48,336,18),@"",11,NO);_detailReason.maximumNumberOfLines=1;
 _detailReason.lineBreakMode=NSLineBreakByTruncatingTail;
 WattActionButton(_detailView,NSMakeRect(16,10,176,30),@"Show in Finder",@"folder",self,@selector(reveal:));
 self.trashButton=WattActionButton(_detailView,NSMakeRect(200,10,184,30),@"Move to Trash",@"trash",self,@selector(trash:));
 [self reset];
 return self;
}
- (void)dealloc {
 [_listView release];[_detailView release];[_componentsView release];[_scanButton release];[_trashButton release];
 [_stateView release];[_stateButton release];[_progressBar release];[_stateIcon release];[_stateTitle release];[_stateText release];
 [_searchField release];[_table release];[_totalLabel release];[_statusLabel release];[_emptyLabel release];
 [_pathLabel release];[_detailTitle release];[_detailSize release];[_detailReason release];[_detailIcon release];
 [_applications release];[_rows release];[_components release];[_checks release];[_selectedItem release];[super dealloc];
}
- (void)showState:(NSString *)symbol title:(NSString *)title text:(NSString *)text action:(NSString *)action busy:(BOOL)busy {
 _stateIcon.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
 _stateTitle.stringValue=title;_stateText.stringValue=text;_stateButton.title=action;_stateButton.enabled=YES;
 // Scan is the one filled action on the page; Cancel stays a quiet text button.
 WattSetButtonPlain(_stateButton,busy);WattSetButtonSelected(_stateButton,!busy);
 if(busy)[_progressBar startAnimation:nil];else [_progressBar stopAnimation:nil];
 _stateView.hidden=NO;_listView.hidden=YES;_detailView.hidden=YES;
}
- (void)showList {[_progressBar stopAnimation:nil];_stateView.hidden=YES;_listView.hidden=NO;}
- (void)reset {
 _running=NO;_scanButton.enabled=YES;_scanButton.title=@"Scan";_searchField.enabled=YES;
 _searchField.stringValue=@"";self.applications=@[];self.rows=@[];
 [_table deselectAll:nil];[_table reloadData];[self back:nil];
 _totalLabel.stringValue=@"";_statusLabel.stringValue=@"";_statusLabel.toolTip=nil;
 [self showState:@"internaldrive" title:@"See what your apps take up"
  text:@"Each app with its caches, settings and other leftovers, ready to move to the Trash." action:@"Scan" busy:NO];
}
// Visibility no longer drives the scan: closing the popover or switching tabs
// keeps it running and keeps the results. Only Cancel or quitting stops it.
- (void)setActive:(BOOL)active {
 _active=active;
 if(active && !_generation)_generation=++_owner.storageGeneration;
}
- (void)shutdown {if(_generation)battStorageAction(_owner.handle,_generation,3);}
- (void)scan:(id)sender {
 if(!_generation)_generation=++_owner.storageGeneration;
 if(_running){
  _scanButton.enabled=_stateButton.enabled=NO;_scanButton.title=_stateButton.title=@"Canceling…";
  battStorageAction(_owner.handle,_generation,2);return;
 }
 [self reset];_running=YES;_scanButton.title=@"Cancel";
 [self showState:@"internaldrive" title:@"Scanning applications"
  text:@"Measuring each app and its leftovers. You can close WattNook; the scan keeps going." action:@"Cancel" busy:YES];
 battStorageAction(_owner.handle,_generation,1);
}
- (void)filter {
 [self back:nil];
 NSString *query=[_searchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 NSMutableArray *filtered=[NSMutableArray array];
 for(NSDictionary *item in _applications){
  NSString *name=item[@"app"][@"name"] ?: @"";
  if(!query.length || [name rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound)[filtered addObject:item];
 }
 self.rows=filtered;[_table deselectAll:nil];[_table reloadData];_emptyLabel.hidden=_rows.count!=0||!query.length;
}
- (void)controlTextDidChange:(NSNotification *)notification {[self filter];}
- (void)showTotals {
 uint64_t total=0;for(NSDictionary *item in _applications)total+=[item[@"total"] unsignedLongLongValue];
 NSMutableAttributedString *line=[[[NSMutableAttributedString alloc]initWithString:WattCompactBytes(total,NO)
  attributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:24 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:NSColor.labelColor}]autorelease];
 [line appendAttributedString:[[[NSAttributedString alloc]initWithString:[NSString stringWithFormat:@"  in %lu apps",(unsigned long)_applications.count]
  attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:NSColor.secondaryLabelColor}]autorelease]];
 _totalLabel.attributedStringValue=_applications.count?line:[[[NSAttributedString alloc]initWithString:@""]autorelease];
}
- (void)update:(NSDictionary *)snapshot {
 NSString *state=snapshot[@"state"];
 if([state isEqual:@"running"]){
  _stateText.stringValue=[NSString stringWithFormat:@"%@ files checked. You can close WattNook; the scan keeps going.",
   [NSNumberFormatter localizedStringFromNumber:snapshot[@"visited"] ?: @0 numberStyle:NSNumberFormatterDecimalStyle]];
  return;
 }
 [self back:nil];_running=NO;_scanButton.enabled=YES;_scanButton.title=@"Rescan";
 NSMutableArray *apps=[NSMutableArray array];
 NSDictionary *inventory=[snapshot[@"applications"] isKindOfClass:NSDictionary.class]?snapshot[@"applications"]:@{};
 NSArray *entries=[inventory[@"entries"] isKindOfClass:NSArray.class]?inventory[@"entries"]:@[];
 for(NSDictionary *entry in entries){
  NSDictionary *app=[entry[@"identity"] isKindOfClass:NSDictionary.class]?entry[@"identity"]:@{};
  NSDictionary *size=[entry[@"size"] isKindOfClass:NSDictionary.class]?entry[@"size"]:@{};
  if(![app[@"path"] isKindOfClass:NSString.class] || ![app[@"name"] isKindOfClass:NSString.class])continue;
  NSArray *leftovers=[entry[@"leftovers"] isKindOfClass:NSArray.class]?entry[@"leftovers"]:@[];
  uint64_t extra=0;for(NSDictionary *o in leftovers)if(![o[@"suggested"] boolValue])extra+=StorageBytes(o);
  [apps addObject:@{@"app":app,@"size":size,@"path":app[@"path"],@"reason":entry[@"reason"] ?: @"",
   @"leftovers":leftovers,@"extra":@(extra),@"total":@(StorageBytes(size)+extra)}];
 }
 self.applications=[apps sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
  uint64_t left=[a[@"total"] unsignedLongLongValue],right=[b[@"total"] unsignedLongLongValue];
  if(left!=right)return left>right?NSOrderedAscending:NSOrderedDescending;
  return [a[@"app"][@"name"] localizedCaseInsensitiveCompare:b[@"app"][@"name"]];
 }];
 NSString *reason=[snapshot[@"reason"] isKindOfClass:NSString.class]?snapshot[@"reason"]:@"";
 _statusLabel.stringValue=[state isEqual:@"complete"]?@"Includes caches, settings and other leftovers.":
  [state isEqual:@"canceled"]?@"Scan canceled; the list may be incomplete.":
  [state isEqual:@"error"]?[NSString stringWithFormat:@"Scan unavailable: %@",reason]:
  [NSString stringWithFormat:@"Some items could not be measured: %@",reason];
 _statusLabel.toolTip=_statusLabel.stringValue;
 [self showTotals];[self filter];
 if(apps.count)[self showList];
 else if([state isEqual:@"error"])[self showState:@"exclamationmark.triangle" title:@"Scan unavailable" text:reason action:@"Try Again" busy:NO];
 else [self showState:@"internaldrive" title:[state isEqual:@"canceled"]?@"Scan canceled":@"No applications found"
  text:@"Nothing was measured this time." action:@"Scan" busy:NO];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table{return _rows.count;}
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)index {
 NSDictionary *item=_rows[index];NSDictionary *app=item[@"app"];
 NSView *cell=[[[NSView alloc]initWithFrame:NSMakeRect(0,0,column.width,52)]autorelease];
 NSImageView *icon=[[[NSImageView alloc]initWithFrame:NSMakeRect(0,10,32,32)]autorelease];
 icon.image=[NSWorkspace.sharedWorkspace iconForFile:app[@"path"]];[cell addSubview:icon];
 NSTextField *name=StorageLabel(cell,NSMakeRect(44,27,column.width-150,18),app[@"name"],13,YES);
 name.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
 name.maximumNumberOfLines=1;name.lineBreakMode=NSLineBreakByTruncatingTail;name.toolTip=app[@"name"];
 uint64_t extra=[item[@"extra"] unsignedLongLongValue];
 NSString *detail=[item[@"reason"] length]?item[@"reason"]:
  (extra?[NSString stringWithFormat:@"App %@, leftovers %@",StorageSize(item[@"size"]),WattCompactBytes(extra,NO)]:@"No leftovers found");
 NSTextField *sub=StorageLabel(cell,NSMakeRect(44,9,column.width-150,16),detail,11,NO);
 sub.maximumNumberOfLines=1;sub.lineBreakMode=NSLineBreakByTruncatingTail;sub.toolTip=detail;
 NSTextField *size=StorageLabel(cell,NSMakeRect(column.width-100,17,96,18),
  [item[@"size"][@"complete"] boolValue]?WattCompactBytes([item[@"total"] doubleValue],NO):StorageSize(item[@"size"]),13,NO);
 size.maximumNumberOfLines=1;size.alignment=NSTextAlignmentRight;size.textColor=NSColor.labelColor;
 size.font=[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
 return cell;
}
// One checkbox row per part: the app bundle first, then each leftover.
- (void)buildComponents {
 for(NSView *v in _componentsView.subviews.copy)[v removeFromSuperview];
 [_checks removeAllObjects];
 NSMutableArray *parts=[NSMutableArray arrayWithObject:@{@"path":_selectedItem[@"path"],@"category":@"Application",
  @"bytes":_selectedItem[@"size"][@"bytes"] ?: @0,@"complete":_selectedItem[@"size"][@"complete"] ?: @NO,@"bundle":@YES}];
 [parts addObjectsFromArray:_selectedItem[@"leftovers"]];
 self.components=parts;
 CGFloat y=6,width=NSWidth(_componentsView.frame);
 for(NSUInteger i=0;i<parts.count;i++){
  NSDictionary *part=parts[i];BOOL suggested=[part[@"suggested"] boolValue];
  NSString *title=part[@"category"];
  NSButton *check=[NSButton checkboxWithTitle:title target:self action:@selector(toggle:)];
  check.frame=NSMakeRect(12,y,width-120,20);check.tag=(NSInteger)i;check.font=[NSFont systemFontOfSize:13];
  check.state=suggested?NSControlStateValueOff:NSControlStateValueOn;
  check.toolTip=part[@"path"];[_componentsView addSubview:check];[_checks addObject:check];
  NSTextField *path=StorageLabel(_componentsView,NSMakeRect(32,y+20,width-140,14),
   suggested?[@"Same name, check before removing: " stringByAppendingString:[part[@"path"] stringByAbbreviatingWithTildeInPath]]:
    [part[@"path"] stringByAbbreviatingWithTildeInPath],10,NO);
  path.maximumNumberOfLines=1;path.lineBreakMode=NSLineBreakByTruncatingMiddle;path.toolTip=part[@"path"];
  NSTextField *size=StorageLabel(_componentsView,NSMakeRect(width-104,y+1,92,18),StorageSize(part),12,NO);
  size.maximumNumberOfLines=1;size.alignment=NSTextAlignmentRight;size.textColor=NSColor.labelColor;
  size.font=[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
  y+=42;
 }
 [_componentsView setFrameSize:NSMakeSize(width,MAX(218,y))];
 [self toggle:nil];
}
- (NSArray *)selectedParts {
 NSMutableArray *selected=[NSMutableArray array];
 for(NSButton *check in _checks)if(check.state==NSControlStateValueOn)[selected addObject:_components[(NSUInteger)check.tag]];
 return selected;
}
- (void)toggle:(id)sender {
 [self disarm];
 uint64_t bytes=0;NSArray *selected=[self selectedParts];
 for(NSDictionary *part in selected)bytes+=StorageBytes(part);
 _detailSize.stringValue=selected.count?[NSString stringWithFormat:@"%@ selected",WattCompactBytes(bytes,NO)]:@"Nothing selected";
 NSString *reason=_selectedItem[@"reason"];
 _trashButton.enabled=selected.count>0 && !reason.length;
 _detailReason.stringValue=reason.length?[reason stringByAppendingString:@"."]:@"Items go to the Trash. Empty it to free the space.";
}
- (void)review:(id)sender {
 NSInteger index=_table.selectedRow;if(_running||index<0||index>=(NSInteger)_rows.count)return;
 self.selectedItem=_rows[index];NSDictionary *app=_selectedItem[@"app"];
 _detailTitle.stringValue=app[@"name"];_detailTitle.toolTip=app[@"name"];
 _detailIcon.image=[NSWorkspace.sharedWorkspace iconForFile:app[@"path"]];
 _pathLabel.stringValue=_selectedItem[@"path"];_pathLabel.toolTip=_pathLabel.stringValue;
 [self buildComponents];
 _listView.hidden=YES;_detailView.hidden=NO;
}
- (void)back:(id)sender {
 [self disarm];
 _listView.hidden=NO;_detailView.hidden=YES;self.selectedItem=nil;
 _pathLabel.stringValue=@"";_pathLabel.toolTip=nil;_detailIcon.image=nil;
 [_table deselectAll:nil];
}
- (void)reveal:(id)sender {
 if(!_selectedItem)return;
 NSString *path=_selectedItem[@"path"];
 if([path isKindOfClass:NSString.class] && path.isAbsolutePath)
  [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
}
- (void)disarm {
 if(!_confirming)return;_confirming=NO;
 _trashButton.title=@"Move to Trash";WattSetButtonSelected(_trashButton,NO);
}
// Revalidates each selected part against what the scan observed: the bundle
// must be the same file (device and inode) and not running; leftovers must
// still be plain files or folders inside ~/Library. Links are never followed.
- (NSString *)validate:(NSArray *)parts urls:(NSMutableArray *)urls {
 NSDictionary *app=_selectedItem[@"app"];
 NSString *library=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/"];
 if([app[@"bundleID"] length] && [NSRunningApplication runningApplicationsWithBundleIdentifier:app[@"bundleID"]].count)
  return [NSString stringWithFormat:@"Quit %@ first.",app[@"name"]];
 for(NSDictionary *part in parts){
  NSString *path=part[@"path"];struct stat st;
  if(![path isKindOfClass:NSString.class] || !path.isAbsolutePath || lstat(path.fileSystemRepresentation,&st)!=0 || S_ISLNK(st.st_mode))
   return [NSString stringWithFormat:@"%@ changed since the scan. Rescan first.",path.lastPathComponent];
  if([part[@"bundle"] boolValue]){
   if(![path isEqual:app[@"path"]] || (uint64_t)st.st_dev!=[app[@"device"] unsignedLongLongValue] || (uint64_t)st.st_ino!=[app[@"inode"] unsignedLongLongValue])
    return @"The application changed since the scan. Rescan first.";
  } else if(![path hasPrefix:[library stringByAppendingString:@"/"]]){
   return @"A leftover is outside your Library folder.";
  }
  [urls addObject:[NSURL fileURLWithPath:path]];
 }
 return nil;
}
// Asks Finder to move the items; Finder requests administrator rights itself.
// Returns nil on success, or a short reason (including the user canceling).
- (NSString *)finderTrash:(NSArray *)urls {
 NSMutableArray *files=[NSMutableArray array];
 for(NSURL *url in urls){
  NSString *path=[[url.path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
   stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  [files addObject:[NSString stringWithFormat:@"POSIX file \"%@\"",path]];
 }
 NSString *source=[NSString stringWithFormat:@"tell application \"Finder\" to delete {%@}",[files componentsJoinedByString:@", "]];
 NSDictionary *error=nil;
 NSAppleScript *script=[[[NSAppleScript alloc]initWithSource:source]autorelease];
 if([script executeAndReturnError:&error])return nil;
 NSInteger code=[error[NSAppleScriptErrorNumber] integerValue];
 if(code==-128)return @"canceled";
 if(code==-1743)return @"allow WattNook to control Finder in System Settings, Privacy & Security, Automation";
 return error[NSAppleScriptErrorMessage] ?: @"Finder could not move it";
}
- (void)trash:(id)sender {
 if(!_selectedItem)return;
 NSArray *parts=[self selectedParts];if(!parts.count)return;
 if(!_confirming){
  // A second click confirms; the button says exactly what it will do.
  _confirming=YES;WattSetButtonSelected(_trashButton,YES);
  _trashButton.title=[NSString stringWithFormat:@"Move %lu item%@",(unsigned long)parts.count,parts.count==1?@"":@"s"];
  [self performSelector:@selector(disarm) withObject:nil afterDelay:5];
  return;
 }
 [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(disarm) object:nil];
 [self disarm];
 NSMutableArray *urls=[NSMutableArray array];
 NSString *problem=[self validate:parts urls:urls];
 if(problem){_detailReason.stringValue=problem;return;}
 _trashButton.enabled=NO;_detailReason.stringValue=@"Moving to the Trash…";
 BOOL bundle=NO;for(NSDictionary *part in parts)bundle|=[part[@"bundle"] boolValue];
 NSDictionary *item=[[_selectedItem copy]autorelease];
 // Finder performs the move and asks for an administrator password when an
 // app was installed by another user; everything stays recoverable.
 [NSWorkspace.sharedWorkspace recycleURLs:urls completionHandler:^(NSDictionary *moved,NSError *error){
  dispatch_async(dispatch_get_main_queue(),^{
   NSUInteger count=moved.count;
   if(error && moved.count<urls.count){
    // Items installed by another user (often root, e.g. Adobe apps) need an
    // administrator: Finder performs the same move and shows the password
    // prompt. Anything else keeps its error.
    NSMutableArray *left=[NSMutableArray array];
    for(NSURL *url in urls)if(!moved[url])[left addObject:url];
    NSString *failure=error.localizedDescription;
    if([error.domain isEqual:NSCocoaErrorDomain] && error.code==NSFileWriteNoPermissionError){
     NSString *finderError=[self finderTrash:left];
     if(!finderError){count+=left.count;failure=nil;}
     else failure=finderError;
    }
    if(failure){self.detailReason.stringValue=[NSString stringWithFormat:@"Not moved: %@",failure];self.trashButton.enabled=YES;return;}
   }
   NSMutableArray *remaining=[[self.applications mutableCopy]autorelease];
   if(bundle)[remaining removeObject:item];
   self.applications=remaining;[self showTotals];[self filter];[self back:nil];
   self.statusLabel.stringValue=[NSString stringWithFormat:@"Moved %lu item%@ of %@ to the Trash.",(unsigned long)count,
    count==1?@"":@"s",item[@"app"][@"name"]];
  });
 }];
}
@end

NSView *WattCreateStorageReview(BattMenuController *controller){
 controller.storageView=[[[WattStorageView alloc]initWithOwner:controller]autorelease];return controller.storageView;
}
void WattSetStorageReviewActive(BattMenuController *controller,BOOL active){[(WattStorageView *)controller.storageView setActive:active];}
void WattCloseStorageReview(BattMenuController *controller){[(WattStorageView *)controller.storageView shutdown];}
void WattShowStorageReview(BattMenuController *controller){BattShowStoragePage(controller);}
void WattUpdateStorageReview(BattMenuController *controller,uint64_t generation,NSDictionary *snapshot){
 if(generation!=controller.storageGeneration)return;[(WattStorageView *)controller.storageView update:snapshot];
}
