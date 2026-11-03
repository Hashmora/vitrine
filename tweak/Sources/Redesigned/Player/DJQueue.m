// The AI DJ's queue. Spotify's own queue page shows only the track playing under the DJ, but the player has
// the tracks that follow it up to the DJ's next change: SPTPlayerState.future, nearest first. This sheet lists
// them, follows the player as they change, and a tap skips ahead to that track (skipToNextTrackWithOptions:track:).
// It is what the DJ footer's Queue button opens (DJPlayer.x).
#import "Core/SGCore.h"
#import "Core/SGGlass.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Player/PlayerState.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "DJQueue.h"

static const CGFloat kSide = 24, kTop = 28, kRowHeight = 64;
static char kDJQueueGlassKey;

static NSArray<SPTPlayerTrack *> *tracksToCome(SPTPlayerState *state) {
    NSMutableArray<SPTPlayerTrack *> *out = [NSMutableArray array];
    Class track = NSClassFromString(@"SPTPlayerTrack");
    for (id item in state.future) {
        if ([item isKindOfClass:track]) [out addObject:item];
    }
    return out;
}

@interface SGRDJQueueSheet : UIViewController <UITableViewDataSource, UITableViewDelegate, SGPlayerStateObserver>
@end

@implementation SGRDJQueueSheet {
    NSArray<SPTPlayerTrack *> *_tracks;
    UILabel *_title, *_empty;
    UITableView *_table;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    self.modalPresentationStyle = UIModalPresentationPageSheet;
    SGPresentDark(self);
    UISheetPresentationController *sheet = self.sheetPresentationController;
    sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    sheet.prefersGrabberVisible = YES;
    if (SGBelowiOS26()) sheet.preferredCornerRadius = SGRSheetCornerRadius();
    sheet.prefersEdgeAttachedInCompactHeight = YES;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // From iOS 26 the system draws the sheet's glass; below it the sheet gets the mod's (as the Genius sheet does).
    if (@available(iOS 26.0, *)) {
    } else {
        self.view.backgroundColor = UIColor.clearColor;
        UIView *glass = SGGlassFor(self.view, &kDJQueueGlassKey);
        glass.frame = self.view.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        SGShapeGlass(glass, SGRSheetCornerRadius(), NO);
        SGRThickenSheetGlass(glass, SGRSheetCornerRadius());
    }
    _title = [UILabel new];
    _title.text = @"Up next";
    _title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _title.textColor = SGRPrimary();
    [self.view addSubview:_title];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.rowHeight = kRowHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [_table registerClass:UITableViewCell.class forCellReuseIdentifier:@"track"];
    [self.view addSubview:_table];

    _empty = [UILabel new];
    _empty.text = @"Nothing is lined up yet";
    _empty.font = [UIFont systemFontOfSize:15];
    _empty.textColor = SGRTertiary();
    _empty.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_empty];

    SGAddPlayerStateObserver(self);
    [self reload];
}

- (void)reload {
    _tracks = tracksToCome(SGPlayerState());
    _empty.hidden = _tracks.count > 0;
    [_table reloadData];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self reload];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat left = kSide + safe.left, width = self.view.bounds.size.width - left - kSide - safe.right;
    _title.frame = CGRectMake(left, kTop, width, 26);
    CGFloat top = CGRectGetMaxY(_title.frame) + 12;
    _table.frame = CGRectMake(0, top, self.view.bounds.size.width, self.view.bounds.size.height - top);
    _table.contentInset = UIEdgeInsetsMake(0, 0, safe.bottom, 0);
    _empty.frame = CGRectMake(left, top + 40, width, 24);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
    SPTPlayerTrack *track = _tracks[indexPath.row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = track.trackTitle;
    content.secondaryText = track.artistName;
    content.textProperties.color = SGRPrimary();
    content.secondaryTextProperties.color = SGRSecondary();
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, kSide, 0, kSide);
    cell.contentConfiguration = content;
    cell.backgroundColor = UIColor.clearColor;
    UIView *pressed = [UIView new];
    pressed.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    cell.selectedBackgroundView = pressed;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [(id<SPTPlayer>)SGPlayer() skipToNextTrackWithOptions:nil track:_tracks[indexPath.row]];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

void SGRShowDJQueue(void) {
    UIViewController *top = SGTopController();
    if (!top || [top isKindOfClass:SGRDJQueueSheet.class]) return;
    // What the player says is to come, for the phone's log: whether the DJ's tracks are in it.
    SPTPlayerState *state = SGPlayerState();
    NSMutableArray<NSString *> *seen = [NSMutableArray array];
    for (SPTPlayerTrack *track in tracksToCome(state)) [seen addObject:[NSString stringWithFormat:@"%@ (provider %@)", track.trackTitle, track.provider]];
    SGLog(@"AI DJ queue: context %@, playing %@, %lu to come: %@", SGURIString(state.contextURI), state.track.trackTitle,
          (unsigned long)seen.count, [seen componentsJoinedByString:@"; "]);
    [top presentViewController:[SGRDJQueueSheet new] animated:YES completion:nil];
}
