#import <Foundation/Foundation.h>
#import "CSAudioPlayback.h"
#include <math.h>
#include <unistd.h>

static void require(BOOL pass, NSString *message) {
    if (!pass) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

int main(void) {
    @autoreleasepool {
        CSAudioPlayback *audio = [CSAudioPlayback new];
        [audio setMasterVolume:0.37f muted:YES];
        [audio startWithChannels:2 sampleRate:48000];
        NSDictionary *initial = audio.statistics;
        require([initial[@"configured"] boolValue], @"AudioQueue opens");
        require([initial[@"applied_volume"] floatValue] == 0, @"initial mute reaches AudioQueue");
        // Exercise actual macOS output/callbacks using silence, never a mic.
        int16_t samples[960] = {0};
        for (int n = 0; n < 60; n++) {
            [audio enqueueBytes:samples length:sizeof(samples)];
            usleep(10000);
        }
        usleep(200000);
        NSDictionary *playing = audio.statistics;
        require([playing[@"started"] boolValue], @"output starts");
        require([playing[@"completed_buffers"] unsignedLongLongValue] > 0, @"output consumes PCM buffers");
        require([playing[@"error_count"] unsignedLongLongValue] == 0, @"no AudioQueue errors");
        require([playing[@"dropped_packets"] unsignedLongLongValue] == 0, @"normal paced stream loses no packets");
        [audio setMasterVolume:0.37f muted:NO];
        require(fabsf([audio.statistics[@"applied_volume"] floatValue] - 0.37f) < 0.0001f,
                @"unmute restores selected volume");
        [audio setMasterVolume:2 muted:NO];
        require([audio.statistics[@"applied_volume"] floatValue] == 1, @"gain clamps to unity");
        [audio setMasterVolume:NAN muted:NO];
        require([audio.statistics[@"applied_volume"] floatValue] == 0, @"invalid gain is silent");
        [audio enqueueBytes:samples length:3];
        require([audio.statistics[@"dropped_packets"] unsignedLongLongValue] == 1,
                @"reject partial PCM frames");
        [audio stop];
        require(![audio.statistics[@"configured"] boolValue], @"stop disposes output");
        for (int i = 0; i < 8; i++) {
            [audio startWithChannels:(i % 2) + 1 sampleRate:44100];
            [audio enqueueBytes:samples length:sizeof(samples)];
            [audio stop];
            require([audio.statistics[@"queued_buffers"] integerValue] == 0,
                    @"restart retires all buffers");
        }
        NSDictionary *final = audio.statistics;
        require([final[@"error_count"] unsignedLongLongValue] == 0, @"lifecycle has no AudioQueue errors");
        NSDictionary *report = @{@"result": @"PASS", @"output": @"silent PCM; actual AudioQueue callbacks",
            @"hearing_confirmed": @NO, @"guest_stream_tested": @NO,
            @"during_playback": playing, @"after_stop_restart": final};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    }
    return 0;
}
