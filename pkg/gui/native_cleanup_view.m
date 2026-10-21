#import "native_internal.h"

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

@interface WattStorageView : NSView <NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate> {
 BattMenuController *_owner;
 uint64_t _generation;
 BOOL _running,_active;
}
@property(nonatomic,retain) NSView *listView,*detailView;
@property(nonatomic,retain) NSButton *scanButton,*applicationsTab,*cachesTab;
@property(nonatomic,assign) NSInteger selectedCategory;
@property(nonatomic,retain) NSSearchField *searchField;
@property(nonatomic,retain) NSTableView *table;
@property(nonatomic,retain) NSTextField *statusLabel,*emptyLabel,*pathLabel,*detailTitle,*detailSize,*detailCopy,*detailReason;
@property(nonatomic,retain) NSImageView *detailIcon;
@property(nonatomic,copy) NSArray *applications,*caches,*rows;
@property(nonatomic,copy) NSDictionary *selectedItem;
- (instancetype)initWithOwner:(BattMenuController *)owner;
- (void)setActive:(BOOL)active;
- (void)update:(NSDictionary *)snapshot;
@end

@implementation WattStorageView
- (instancetype)initWithOwner:(BattMenuController *)owner {
 if (!(self=[super initWithFrame:NSMakeRect(0,0,400,450)]))return nil;
 _owner=owner;
 self.listView=[[[NSView alloc]initWithFrame:self.bounds]autorelease];[self addSubview:_listView];
 // Same tab treatment as System's CPU / Memory / Disk sort.
 self.applicationsTab=StorageButton(_listView,NSMakeRect(16,408,180,30),@"Applications",self,@selector(selectCategory:));
 self.cachesTab=StorageButton(_listView,NSMakeRect(204,408,180,30),@"App caches",self,@selector(selectCategory:));
 WattSetButtonGrouped(_applicationsTab,YES);WattSetButtonGrouped(_cachesTab,YES);
 WattSetButtonSelected(_applicationsTab,YES);
 self.searchField=[[[NSSearchField alloc]initWithFrame:NSMakeRect(16,368,276,28)]autorelease];
 _searchField.placeholderString=@"Search applications";_searchField.delegate=self;
 [_searchField setAccessibilityLabel:@"Search applications"];[_listView addSubview:_searchField];
 self.scanButton=StorageButton(_listView,NSMakeRect(300,367,84,30),@"Scan",self,@selector(scan:));
 [_scanButton setAccessibilityIdentifier:@"storage.scan"];
 self.statusLabel=StorageLabel(_listView,NSMakeRect(32,336,336,22),@"Scan when you need a storage overview.",12,NO);
 _statusLabel.maximumNumberOfLines=1;_statusLabel.lineBreakMode=NSLineBreakByTruncatingTail;
 // The list sits on one translucent tile, like the other pages on the sky.
 NSView *tile=[[[NSView alloc]initWithFrame:NSMakeRect(16,8,368,322)]autorelease];
 tile.wantsLayer=YES;tile.layer.backgroundColor=WattTileColor(NO).CGColor;tile.layer.cornerRadius=14;
 [_listView addSubview:tile];
 NSScrollView *scroll=[[[NSScrollView alloc]initWithFrame:NSMakeRect(24,16,352,306)]autorelease];
 scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;scroll.drawsBackground=NO;scroll.borderType=NSNoBorder;
 self.table=[[[NSTableView alloc]initWithFrame:NSMakeRect(0,0,352,314)]autorelease];
 _table.delegate=self;_table.dataSource=self;_table.rowHeight=44;_table.headerView=nil;
 _table.backgroundColor=NSColor.clearColor;if(@available(macOS 11.0,*))_table.style=NSTableViewStylePlain;_table.intercellSpacing=NSMakeSize(0,0);
 _table.allowsMultipleSelection=NO;_table.allowsEmptySelection=YES;
 [_table setAccessibilityLabel:@"Applications and observed sizes"];
 NSTableColumn *column=[[[NSTableColumn alloc]initWithIdentifier:@"application"]autorelease];
 column.width=352;column.minWidth=330;[_table addTableColumn:column];
 _table.columnAutoresizingStyle=NSTableViewLastColumnOnlyAutoresizingStyle;
 _table.target=self;_table.action=@selector(review:);_table.selectionHighlightStyle=NSTableViewSelectionHighlightStyleNone;
 scroll.documentView=_table;[_listView addSubview:scroll];
 self.emptyLabel=StorageLabel(_listView,NSMakeRect(48,179,304,62),@"See your applications and their sizes.\nChoose Scan to get started.",13,NO);
 _emptyLabel.alignment=NSTextAlignmentCenter;_emptyLabel.maximumNumberOfLines=3;

 self.detailView=[[[NSView alloc]initWithFrame:self.bounds]autorelease];_detailView.hidden=YES;[self addSubview:_detailView];
 NSButton *back=WattActionButton(_detailView,NSMakeRect(14,408,90,30),@"Back",@"chevron.left",self,@selector(back:));
 WattSetButtonPlain(back,YES);
 self.detailIcon=[[[NSImageView alloc]initWithFrame:NSMakeRect(24,350,40,40)]autorelease];[_detailView addSubview:_detailIcon];
 self.detailTitle=StorageLabel(_detailView,NSMakeRect(76,360,300,20),@"",15,YES);_detailTitle.maximumNumberOfLines=1;
 _detailTitle.lineBreakMode=NSLineBreakByTruncatingTail;
 self.detailSize=StorageLabel(_detailView,NSMakeRect(24,295,352,36),@"",24,YES);
 _detailSize.font=[NSFont monospacedDigitSystemFontOfSize:24 weight:NSFontWeightMedium];
 self.detailCopy=StorageLabel(_detailView,NSMakeRect(24,224,352,56),@"",13,NO);_detailCopy.maximumNumberOfLines=3;
 StorageLabel(_detailView,NSMakeRect(24,191,352,20),@"Location",12,YES);
 self.pathLabel=StorageLabel(_detailView,NSMakeRect(24,126,352,60),@"",12,NO);
 _pathLabel.selectable=YES;_pathLabel.maximumNumberOfLines=3;_pathLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;
 self.detailReason=StorageLabel(_detailView,NSMakeRect(24,62,352,52),@"",12,NO);_detailReason.maximumNumberOfLines=3;
 WattActionButton(_detailView,NSMakeRect(24,16,352,30),@"Show in Finder",@"folder",self,@selector(reveal:));
 return self;
}
- (void)dealloc {
 [_listView release];[_detailView release];[_scanButton release];[_applicationsTab release];[_cachesTab release];
 [_searchField release];[_table release];[_statusLabel release];[_emptyLabel release];[_pathLabel release];
 [_detailTitle release];[_detailSize release];[_detailCopy release];[_detailReason release];[_detailIcon release];
 [_applications release];[_caches release];[_rows release];[_selectedItem release];[super dealloc];
}
- (void)reset {
 _running=NO;_scanButton.enabled=YES;_scanButton.title=@"Scan";_searchField.enabled=YES;
 _searchField.stringValue=@"";self.applications=@[];self.caches=@[];self.rows=@[];
 [_table deselectAll:nil];[_table reloadData];[self back:nil];
 _statusLabel.stringValue=@"Scan when you need a storage overview.";_statusLabel.toolTip=nil;
 _emptyLabel.stringValue=@"See your applications and their sizes.\nChoose Scan to get started.";_emptyLabel.hidden=NO;
}
- (void)setActive:(BOOL)active {
 if (_active==active)return;_active=active;
 if(active)_generation=++_owner.storageGeneration;else battStorageAction(_owner.handle,_generation,3);
 [self reset];
}
- (void)scan:(id)sender {
 if(!_active)return;
 if(_running){_scanButton.enabled=NO;_scanButton.title=@"Canceling…";battStorageAction(_owner.handle,_generation,2);return;}
 [self reset];_running=YES;_scanButton.title=@"Cancel";_statusLabel.stringValue=@"Measuring application sizes…";
 _emptyLabel.stringValue=@"Reading file metadata.\nLeaving Storage stops the scan.";
 battStorageAction(_owner.handle,_generation,1);
}
- (void)selectCategory:(id)sender {
 _selectedCategory=sender==_cachesTab?1:0;
 WattSetButtonSelected(_applicationsTab,_selectedCategory==0);WattSetButtonSelected(_cachesTab,_selectedCategory==1);
 [self category:nil];
}
- (void)category:(id)sender {
 [self back:nil];
 NSArray *source=_selectedCategory==0?_applications:_caches;
 NSString *query=[_searchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 NSMutableArray *filtered=[NSMutableArray array];
 for(NSDictionary *item in source){
  NSString *name=item[@"app"][@"name"] ?: @"";
  if(!query.length || [name rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound)[filtered addObject:item];
 }
 self.rows=filtered;[_table deselectAll:nil];[_table reloadData];_emptyLabel.hidden=_rows.count!=0;
 if(query.length)_emptyLabel.stringValue=@"No matching applications.\nTry another name.";
 else if(_applications.count)_emptyLabel.stringValue=_selectedCategory==0?@"No applications in this scan.":@"No verified application caches found.\nUnknown and system caches stay excluded.";
}
- (void)controlTextDidChange:(NSNotification *)notification {[self category:nil];}
- (void)update:(NSDictionary *)snapshot {
 if(!_active)return;
 NSString *state=snapshot[@"state"];
 if([state isEqual:@"running"]){_statusLabel.stringValue=[NSString stringWithFormat:@"Scanning · %@ entries",snapshot[@"visited"] ?: @0];return;}
 [self back:nil];_running=NO;_scanButton.enabled=YES;_scanButton.title=@"Rescan";
 NSMutableArray *apps=[NSMutableArray array],*caches=[NSMutableArray array];
 NSDictionary *inventory=[snapshot[@"applications"] isKindOfClass:NSDictionary.class]?snapshot[@"applications"]:@{};
 NSArray *entries=[inventory[@"entries"] isKindOfClass:NSArray.class]?inventory[@"entries"]:@[];
 for(NSDictionary *entry in entries){
  NSDictionary *app=[entry[@"identity"] isKindOfClass:NSDictionary.class]?entry[@"identity"]:@{};
  NSDictionary *size=[entry[@"size"] isKindOfClass:NSDictionary.class]?entry[@"size"]:@{};
  if(![app[@"path"] isKindOfClass:NSString.class] || ![app[@"name"] isKindOfClass:NSString.class])continue;
  [apps addObject:@{@"app":app,@"size":size,@"path":app[@"path"],@"reason":entry[@"reason"] ?: @""}];
 }
 NSArray *observations=[snapshot[@"observations"] isKindOfClass:NSArray.class]?snapshot[@"observations"]:@[];
 for(NSDictionary *observation in observations){
  NSString *path=observation[@"path"];
  if(![path isKindOfClass:NSString.class] || ![observation[@"category"] isEqual:@"Application cache"])continue;
  for(NSDictionary *item in apps)if([item[@"app"][@"bundleID"] isEqual:path.lastPathComponent]){
   [caches addObject:@{@"app":item[@"app"],@"size":observation,@"path":path,@"cache":@YES,@"reason":item[@"reason"]}];break;
  }
 }
 NSComparator bySize=^NSComparisonResult(NSDictionary *a,NSDictionary *b){
  uint64_t left=[a[@"size"][@"bytes"] unsignedLongLongValue],right=[b[@"size"][@"bytes"] unsignedLongLongValue];
  if(left!=right)return left>right?NSOrderedAscending:NSOrderedDescending;
  return [a[@"app"][@"name"] localizedCaseInsensitiveCompare:b[@"app"][@"name"]];
 };
 self.applications=[apps sortedArrayUsingComparator:bySize];self.caches=[caches sortedArrayUsingComparator:bySize];
 NSString *summary=[state isEqual:@"complete"]?@"Applications measured":[state isEqual:@"canceled"]?@"Canceled · partial results":[state isEqual:@"error"]?@"Scan unavailable":@"Partial results";
 NSString *reason=[snapshot[@"reason"] isKindOfClass:NSString.class]?snapshot[@"reason"]:@"";
 _statusLabel.stringValue=reason.length?[NSString stringWithFormat:@"%@ · %@",summary,reason]:[NSString stringWithFormat:@"%@ · %lu apps",summary,(unsigned long)apps.count];
 _statusLabel.toolTip=_statusLabel.stringValue;
 [self category:nil];
 if(!apps.count)_emptyLabel.stringValue=[state isEqual:@"error"]?@"Scan unavailable.\nCheck the message above, then try Rescan.":@"No applications were measured.\nTry Rescan; some locations may be unavailable.";
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table{return _rows.count;}
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)index {
 NSDictionary *item=_rows[index];NSDictionary *app=item[@"app"];
 NSView *cell=[[[NSView alloc]initWithFrame:NSMakeRect(0,0,column.width,44)]autorelease];
 NSImageView *icon=[[[NSImageView alloc]initWithFrame:NSMakeRect(0,6,32,32)]autorelease];
 icon.image=[NSWorkspace.sharedWorkspace iconForFile:app[@"path"]];[cell addSubview:icon];
 NSTextField *name=StorageLabel(cell,NSMakeRect(44,18,column.width-154,20),app[@"name"],13,YES);
 name.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
 // Bar length is relative to the largest row, so sizes compare at a glance.
 double largest=MAX(1,[_rows.firstObject[@"size"][@"bytes"] doubleValue]);
 double fraction=MIN(1,[item[@"size"][@"bytes"] doubleValue]/largest);
 CGFloat track=column.width-154;
 NSView *rail=[[[NSView alloc]initWithFrame:NSMakeRect(46,10,track,3)]autorelease];
 rail.wantsLayer=YES;rail.layer.cornerRadius=1.5;rail.layer.backgroundColor=[NSColor.labelColor colorWithAlphaComponent:0.10].CGColor;
 [cell addSubview:rail];
 if(fraction>0){
  NSView *fill=[[[NSView alloc]initWithFrame:NSMakeRect(46,10,MAX(3,track*fraction),3)]autorelease];
  fill.wantsLayer=YES;fill.layer.cornerRadius=1.5;fill.layer.backgroundColor=WattAccentColor().CGColor;[cell addSubview:fill];
 }
 name.maximumNumberOfLines=1;name.lineBreakMode=NSLineBreakByTruncatingTail;name.toolTip=app[@"name"];
 NSTextField *size=StorageLabel(cell,NSMakeRect(column.width-106,14,102,18),StorageSize(item[@"size"]),12,NO);
 size.maximumNumberOfLines=1;size.alignment=NSTextAlignmentRight;size.font=[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
 size.toolTip=[item[@"size"][@"complete"] boolValue]?@"Observed logical size, not guaranteed recoverable space.":@"Partial or unknown size. This item is review-only.";
 return cell;
}
- (void)review:(id)sender {
 NSInteger index=_table.selectedRow;if(_running||index<0||index>=(NSInteger)_rows.count)return;
 self.selectedItem=_rows[index];NSDictionary *app=_selectedItem[@"app"];BOOL cache=[_selectedItem[@"cache"] boolValue];
 _detailTitle.stringValue=app[@"name"];_detailTitle.toolTip=app[@"name"];
 _detailIcon.image=[NSWorkspace.sharedWorkspace iconForFile:app[@"path"]];
 _detailSize.stringValue=StorageSize(_selectedItem[@"size"]);
 _detailCopy.stringValue=cache?@"Application cache only. Caches may need rebuilding; settings and documents are not included.":@"Application bundle only. Documents, settings and databases are not included. Vendor helpers may remain.";
 _pathLabel.stringValue=_selectedItem[@"path"];_pathLabel.toolTip=_pathLabel.stringValue;
 NSString *reason=_selectedItem[@"reason"];
 _detailReason.stringValue=reason.length?[reason stringByAppendingString:@"."]:@"Sizes are observed on disk and may not all be recoverable.";
 _detailReason.toolTip=_detailReason.stringValue;
 _listView.hidden=YES;_detailView.hidden=NO;
}
- (void)back:(id)sender {
 _listView.hidden=NO;_detailView.hidden=YES;self.selectedItem=nil;
 _pathLabel.stringValue=@"";_pathLabel.toolTip=nil;_detailIcon.image=nil;
 [_table deselectAll:nil];
}
- (void)reveal:(id)sender {
 if(!_active || !_selectedItem)return;
 NSString *path=_selectedItem[@"path"];
 if([path isKindOfClass:NSString.class] && path.isAbsolutePath)
  [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
}
@end

NSView *WattCreateStorageReview(BattMenuController *controller){
 controller.storageView=[[[WattStorageView alloc]initWithOwner:controller]autorelease];return controller.storageView;
}
void WattSetStorageReviewActive(BattMenuController *controller,BOOL active){[(WattStorageView *)controller.storageView setActive:active];}
void WattShowStorageReview(BattMenuController *controller){BattShowStoragePage(controller);}
void WattUpdateStorageReview(BattMenuController *controller,uint64_t generation,NSDictionary *snapshot){
 if(generation!=controller.storageGeneration)return;[(WattStorageView *)controller.storageView update:snapshot];
}
