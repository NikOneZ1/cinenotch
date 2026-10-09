// macOS's Now Playing, for CineNotch. Since macOS 15.4 the private MediaRemote framework only
// answers Apple's own processes, so CineNotch loads this library into /usr/bin/perl, which it
// still answers.
//
// Out (stdout): one JSON object per line whenever Now Playing changes:
//   {"pid":123,"title":"…","duration":19.0,"elapsed":6.9,"rate":1,"timestamp":1760000000.5}
// `elapsed` is the position at `timestamp`; while `rate` is 1 the video moves on from there.
// In (stdin): "play", "pause" or "seek <seconds>", one per line. Exits when stdin closes.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include "NowPlayingBridge.h"

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, NSDictionary *);
typedef void (*SetElapsedFn)(double);

enum { MRCommandPlay = 0, MRCommandPause = 1 };

static GetInfoFn getInfo;
static GetPIDFn getPID;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;
static dispatch_queue_t queue;
static NSData *lastLine;

/// Reads Now Playing and prints it if it changed since the last line.
static void emit(void) {
    getPID(queue, ^(int pid) {
        getInfo(queue, ^(NSDictionary *info) {
            NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:@(pid) forKey:@"pid"];
            NSDictionary *keys = @{
                @"title": @"kMRMediaRemoteNowPlayingInfoTitle",
                @"duration": @"kMRMediaRemoteNowPlayingInfoDuration",
                @"elapsed": @"kMRMediaRemoteNowPlayingInfoElapsedTime",
                @"rate": @"kMRMediaRemoteNowPlayingInfoPlaybackRate",
            };
            for (NSString *key in keys) {
                id value = info[keys[key]];
                if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) out[key] = value;
            }
            id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([timestamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @([timestamp timeIntervalSince1970]);
            NSData *line = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
            if (!line || [line isEqualToData:lastLine]) return;
            lastLine = line;
            fwrite(line.bytes, 1, line.length, stdout);
            fputc('\n', stdout);
            fflush(stdout);
        });
    });
}

static void handle(NSString *command) {
    if ([command isEqualToString:@"play"]) {
        sendCommand(MRCommandPlay, nil);
    } else if ([command isEqualToString:@"pause"]) {
        sendCommand(MRCommandPause, nil);
    } else if ([command hasPrefix:@"seek "]) {
        setElapsed([[command substringFromIndex:5] doubleValue]);
    } else {
        return;
    }
    // The player reports its new state a moment later.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), queue, ^{ emit(); });
}

void cinenotch_now_playing_main(void *perl, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (GetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPID = (GetPIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCommand = (SendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (SetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    RegisterFn registerForNotifications = (RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getPID || !sendCommand || !setElapsed || !registerForNotifications) {
        fprintf(stderr, "MediaRemote is missing functions\n");
        exit(1);
    }
    queue = dispatch_queue_create("com.cinenotch.now-playing", DISPATCH_QUEUE_SERIAL);

    registerForNotifications(queue);
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(queue, ^{ emit(); });
        }];
    }
    // Notifications don't cover everything (a seek from the page itself), so also look every second.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ emit(); });
    dispatch_resume(timer);

    [NSThread detachNewThreadWithBlock:^{
        char buffer[256];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *command = [[NSString stringWithUTF8String:buffer]
                                 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(queue, ^{ handle(command); });
        }
        // CineNotch quit or stopped the bridge.
        exit(0);
    }];
    CFRunLoopRun();
}
