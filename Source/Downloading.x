#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "FFMpegDownloader.h"
#import "Headers/YTUIResources.h"
#import "Headers/YTMActionSheetController.h"
#import "Headers/YTMActionRowView.h"
#import "Headers/YTIPlayerOverlayRenderer.h"
#import "Headers/YTIPlayerOverlayActionSupportedRenderers.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerView.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"
#import "Headers/YTIFormatStream.h"
#import "Headers/YTAlertView.h"
#import "Headers/ELMNodeController.h"

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

static id YTMUDownloadSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static YTPlayerViewController *YTMUDownloadPlayerFromObject(id candidate, NSUInteger depth);

static YTPlayerViewController *YTMUDownloadPlayerFromKnownKeys(id candidate, NSUInteger depth) {
    NSArray<NSString *> *keys = @[
        @"playerViewController",
        @"_playerViewController",
        @"playerViewDelegate",
        @"_playerViewDelegate",
        @"playerController",
        @"_playerController",
        @"player",
        @"_player"
    ];
    for (NSString *key in keys) {
        id value = YTMUDownloadSafeValueForKey(candidate, key);
        if (!value || value == candidate) continue;
        YTPlayerViewController *player = YTMUDownloadPlayerFromObject(value, depth + 1);
        if (player) return player;
    }
    return nil;
}

static YTPlayerViewController *YTMUDownloadPlayerFromObject(id candidate, NSUInteger depth) {
    if (!candidate || depth > 10) return nil;

    Class playerClass = NSClassFromString(@"YTPlayerViewController");
    if (playerClass && [candidate isKindOfClass:playerClass]) return candidate;

    YTPlayerViewController *keyPlayer = YTMUDownloadPlayerFromKnownKeys(candidate, depth);
    if (keyPlayer) return keyPlayer;

    id parent = YTMUDownloadSafeValueForKey(candidate, @"parentViewController");
    if (parent && parent != candidate) {
        YTPlayerViewController *parentPlayer = YTMUDownloadPlayerFromObject(parent, depth + 1);
        if (parentPlayer) return parentPlayer;
    }

    if ([candidate isKindOfClass:[UIViewController class]]) {
        UIViewController *viewController = (UIViewController *)candidate;
        YTPlayerViewController *viewPlayer = YTMUDownloadPlayerFromObject(viewController.view, depth + 1);
        if (viewPlayer) return viewPlayer;

        for (UIViewController *child in viewController.childViewControllers) {
            YTPlayerViewController *childPlayer = YTMUDownloadPlayerFromObject(child, depth + 1);
            if (childPlayer) return childPlayer;
        }
    }

    return nil;
}

static YTPlayerViewController *YTMUDownloadPlayerFromViewHierarchy(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        YTPlayerViewController *player = YTMUDownloadPlayerFromObject(ancestor, 0);
        if (player) return player;
    }
    return nil;
}

static YTPlayerViewController *YTMUDownloadPlayerInSubviews(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return nil;

    YTPlayerViewController *player = YTMUDownloadPlayerFromObject(view, 0);
    if (player) return player;

    for (UIView *subview in view.subviews) {
        YTPlayerViewController *subviewPlayer = YTMUDownloadPlayerInSubviews(subview, depth + 1);
        if (subviewPlayer) return subviewPlayer;
    }
    return nil;
}

static id YTMUDownloadPlayerResponseFromObject(id candidate, NSUInteger depth) {
    if (!candidate || depth > 10) return nil;

    id response = YTMUDownloadSafeValueForKey(candidate, @"playerResponse") ?: YTMUDownloadSafeValueForKey(candidate, @"_playerResponse");
    if (response) return response;

    id parentResponder = YTMUDownloadSafeValueForKey(candidate, @"parentResponder") ?: YTMUDownloadSafeValueForKey(candidate, @"_parentResponder");
    if (parentResponder && parentResponder != candidate) {
        id parentResponse = YTMUDownloadPlayerResponseFromObject(parentResponder, depth + 1);
        if (parentResponse) return parentResponse;
    }

    id delegate = YTMUDownloadSafeValueForKey(candidate, @"delegate") ?: YTMUDownloadSafeValueForKey(candidate, @"_delegate");
    if (delegate && delegate != candidate) {
        id delegateResponse = YTMUDownloadPlayerResponseFromObject(delegate, depth + 1);
        if (delegateResponse) return delegateResponse;
    }

    if ([candidate isKindOfClass:[UIViewController class]]) {
        UIViewController *viewController = (UIViewController *)candidate;
        for (UIViewController *child in viewController.childViewControllers) {
            id childResponse = YTMUDownloadPlayerResponseFromObject(child, depth + 1);
            if (childResponse) return childResponse;
        }
    }

    return nil;
}

static id YTMUDownloadObjectForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    if ([object isKindOfClass:[NSDictionary class]]) return ((NSDictionary *)object)[key];
    return YTMUDownloadSafeValueForKey(object, key);
}

static NSString *YTMUDownloadStringForKey(id object, NSString *key) {
    id value = YTMUDownloadObjectForKey(object, key);
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return @"";
}

static NSString *YTMUDownloadSanitizeFileComponent(NSString *string) {
    NSString *safe = string.length ? string : @"Unknown";
    NSArray<NSString *> *bad = @[@"/", @":", @"\n", @"\r"];
    for (NSString *part in bad) {
        safe = [safe stringByReplacingOccurrencesOfString:part withString:@""];
    }
    return safe;
}

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)downloadAudio:(YTPlayerViewController *)playerResponse;
- (void)downloadCoverImage:(YTPlayerViewController *)playerResponse;
- (NSString *)getURLFromManifest:(NSURL *)manifest;
@end

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {

    if (class_getInstanceVariable([self class], "_controller") == NULL) {
        return %orig;
    }


    if (class_getInstanceVariable([self class], "_tapRecognizer") == NULL) {
        return %orig;
    }

    ELMNodeController *node = [self valueForKey:@"_controller"];
    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];

    if (![node.key isEqualToString:@"music_download_badge_1"]) {
        return %orig;
    }

    if (![tapRecognizer.view._viewControllerForAncestor isKindOfClass:%c(YTMNowPlayingViewController)]) {
        return %orig;
    }

    YTMNowPlayingViewController *playingVC = (YTMNowPlayingViewController *)tapRecognizer.view._viewControllerForAncestor;
    YTPlayerViewController *playerVC = YTMUDownloadPlayerFromViewHierarchy(tapRecognizer.view);
    if (!playerVC) playerVC = YTMUDownloadPlayerFromObject(playingVC, 0);
    if (!playerVC) playerVC = YTMUDownloadPlayerInSubviews(playingVC.view, 0);
    if (!playerVC) playerVC = YTMUDownloadPlayerFromObject([UIApplication sharedApplication].keyWindow.rootViewController, 0);
    id playerResponse = YTMUDownloadPlayerResponseFromObject(playerVC, 0);

    if (playerVC && playerResponse) {
        YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
        sheetController.sourceView = tapRecognizer.view;
        [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^ {
            [self downloadAudio:playerVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
            [self downloadCoverImage:playerVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
            return %orig;
        }]];

        if (YTMU(@"downloadAudio") && YTMU(@"downloadCoverImage")) {
            [sheetController presentFromViewController:playingVC animated:YES completion:nil];
        } else if (YTMU(@"downloadAudio")) {
            [self downloadAudio:playerVC];
        } else if (YTMU(@"downloadCoverImage")) {
            [self downloadCoverImage:playerVC];
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
    }
}

%new
- (void)downloadAudio:(YTPlayerViewController *)playerVC {
    id playerResponse = YTMUDownloadPlayerResponseFromObject(playerVC, 0);
    if (!playerResponse) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
        return;
    }

    id playerData = YTMUDownloadObjectForKey(playerResponse, @"playerData");
    id videoDetails = YTMUDownloadObjectForKey(playerData, @"videoDetails");
    id streamingData = YTMUDownloadObjectForKey(playerData, @"streamingData");
    NSString *title = YTMUDownloadSanitizeFileComponent(YTMUDownloadStringForKey(videoDetails, @"title"));
    NSString *author = YTMUDownloadSanitizeFileComponent(YTMUDownloadStringForKey(videoDetails, @"author"));
    NSString *urlStr = YTMUDownloadStringForKey(streamingData, @"hlsManifestURL");

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    ffmpeg.tempName = YTMUDownloadStringForKey(playerVC, @"contentVideoID");
    ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
    id durationValue = YTMUDownloadObjectForKey(playerVC, @"currentVideoTotalMediaTime");
    ffmpeg.duration = [durationValue respondsToSelector:@selector(doubleValue)] ? round([durationValue doubleValue]) : 0;

    
    NSString *extractedURL = [self getURLFromManifest:[NSURL URLWithString:urlStr]];
    
    if (extractedURL.length > 0) {
        [ffmpeg downloadAudio:extractedURL];

        id thumbnailDetails = YTMUDownloadObjectForKey(videoDetails, @"thumbnail");
        NSMutableArray *thumbnailsArray = YTMUDownloadObjectForKey(thumbnailDetails, @"thumbnailsArray");
        YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnail.URL]];

        if (imageData) {
            NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
            NSURL *coverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@ - %@.png", author, title]];
            [imageData writeToURL:coverURL atomically:YES];
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
    }
}

%new
- (NSString *)getURLFromManifest:(NSURL *)manifest {
    NSData *manifestData = [NSData dataWithContentsOfURL:manifest];
    NSString *manifestString = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    NSArray *manifestLines = [manifestString componentsSeparatedByString:@"\n"];

    NSArray *groupIDS = @[@"234", @"233"]; // Our priority to find group id 234
    for (NSString *groupID in groupIDS) {
        for (NSString *line in manifestLines) {
            NSString *searchString = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
            if ([line containsString:searchString]) {
                NSRange startRange = [line rangeOfString:@"https://"];
                NSRange endRange = [line rangeOfString:@"index.m3u8"];

                if (startRange.location != NSNotFound && endRange.location != NSNotFound) {
                    NSRange targetRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
                    return [line substringWithRange:targetRange];
                }
            }
        }
    }

    return nil;
}

%new
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC {
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        hud.mode = MBProgressHUDModeIndeterminate;
    });

    id playerResponse = YTMUDownloadPlayerResponseFromObject(playerVC, 0);
    if (!playerResponse) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [hud hideAnimated:YES];
        });
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
        return;
    }

    id playerData = YTMUDownloadObjectForKey(playerResponse, @"playerData");
    id videoDetails = YTMUDownloadObjectForKey(playerData, @"videoDetails");
    id thumbnailDetails = YTMUDownloadObjectForKey(videoDetails, @"thumbnail");
    NSMutableArray *thumbnailsArray = YTMUDownloadObjectForKey(thumbnailDetails, @"thumbnailsArray");
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
    NSString *thumbnailURL = [thumbnail.URL stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"w%u-h%u-", thumbnail.width, thumbnail.width] withString:@"w2048-h2048-"];

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    [ffmpeg downloadImage:[NSURL URLWithString:thumbnailURL]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [hud hideAnimated:YES];
    });
}
%end
