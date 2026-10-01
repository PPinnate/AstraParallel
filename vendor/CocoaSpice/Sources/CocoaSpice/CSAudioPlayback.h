#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Playback only. SPICE decodes its stream; AudioQueue sends PCM to macOS output.
@interface CSAudioPlayback : NSObject
- (void)startWithChannels:(NSUInteger)channels sampleRate:(NSUInteger)sampleRate;
- (void)enqueueBytes:(const void *)bytes length:(NSUInteger)length;
- (void)stop;
- (void)setMasterVolume:(float)volume muted:(BOOL)muted;
- (void)setGuestVolumeLeft:(float)left right:(float)right muted:(BOOL)muted;
@property (nonatomic, readonly) NSUInteger delayMilliseconds;
/// Counts/state only; never records PCM data or device identifiers.
@property (nonatomic, readonly) NSDictionary<NSString *, id> *statistics;
@end
NS_ASSUME_NONNULL_END
