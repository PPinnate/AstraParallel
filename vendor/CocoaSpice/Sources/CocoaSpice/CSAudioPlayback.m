#import "CSAudioPlayback.h"
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>

@interface CSAudioPlayback () {
    dispatch_queue_t _work;
    AudioQueueRef _audioQueue;
    NSUInteger _pendingBytes;
    NSUInteger _queuedBytes;
    NSUInteger _queuedBuffers;
    NSUInteger _bytesPerSecond;
    NSUInteger _channels;
    NSUInteger _sampleRate;
    uint64_t _receivedPackets;
    uint64_t _completedBuffers;
    uint64_t _droppedPackets;
    uint64_t _errorCount;
    OSStatus _lastError;
    float _masterVolume;
    float _guestLeft;
    float _guestRight;
    BOOL _masterMuted;
    BOOL _guestMuted;
    BOOL _started;
    BOOL _loggedFirstData;
}
- (void)completedBuffer:(AudioQueueBufferRef)buffer queue:(AudioQueueRef)queue;
- (void)stopOnQueue;
- (void)recordError:(OSStatus)result operation:(NSString *)operation;
@end

static void cs_audio_buffer_done(void *context, AudioQueueRef queue,
                                 AudioQueueBufferRef buffer) {
    [(__bridge CSAudioPlayback *)context completedBuffer:buffer queue:queue];
}

@implementation CSAudioPlayback
- (instancetype)init {
    if ((self = [super init])) {
        _work = dispatch_queue_create("local.astra.audio-playback", DISPATCH_QUEUE_SERIAL);
        _masterVolume = _guestLeft = _guestRight = 1.0f;
    }
    return self;
}
- (void)dealloc {
    // Pending work retains self. AudioQueueDispose waits for C callbacks before
    // this object's storage is released; never hold the callback lock here.
    [self stopOnQueue];
}
- (void)stopOnQueue {
    AudioQueueRef queue;
    @synchronized (self) {
        queue = _audioQueue;
        _audioQueue = NULL;
        _queuedBytes = _queuedBuffers = _bytesPerSecond = 0;
    }
    _started = NO;
    _channels = _sampleRate = 0;
    if (queue) [self recordError:AudioQueueDispose(queue, true) operation:@"dispose"];
}
- (void)recordError:(OSStatus)result operation:(NSString *)operation {
    if (result == noErr) return;
    _errorCount++;
    if (_lastError != result) NSLog(@"Astra audio: %@ failed %d", operation, (int)result);
    _lastError = result;
}
- (void)stop {
    dispatch_async(_work, ^{ [self stopOnQueue]; });
}
- (void)startWithChannels:(NSUInteger)channels sampleRate:(NSUInteger)sampleRate {
    dispatch_async(_work, ^{
        [self stopOnQueue];
        if ((channels != 1 && channels != 2) || sampleRate < 8000 || sampleRate > 192000) {
            [self recordError:kAudio_ParamError operation:@"unsupported PCM format"];
            return;
        }
        AudioStreamBasicDescription format = {0};
        format.mSampleRate = sampleRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        format.mBitsPerChannel = 16;
        format.mChannelsPerFrame = (UInt32)channels;
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = format.mBytesPerPacket = (UInt32)(channels * 2);
        AudioQueueRef queue = NULL;
        OSStatus result = AudioQueueNewOutput(&format, cs_audio_buffer_done,
            (__bridge void *)self, NULL, NULL, 0, &queue);
        if (result != noErr) {
            [self recordError:result operation:@"create output"];
            return;
        }
        @synchronized (self) {
            self->_audioQueue = queue;
            self->_bytesPerSecond = sampleRate * channels * 2;
        }
        self->_channels = channels;
        self->_sampleRate = sampleRate;
        self->_lastError = noErr;
        self->_loggedFirstData = NO;
        [self recordError:AudioQueueSetParameter(queue, kAudioQueueParam_Volume,
            self->_masterMuted ? 0.0f : self->_masterVolume) operation:@"set output volume"];
        NSLog(@"Astra audio: playback configured S16LE %lu Hz %lu channel(s)", sampleRate, channels);
    });
}
- (void)setMasterVolume:(float)volume muted:(BOOL)muted {
    const float safeVolume = isfinite(volume) ? fminf(1.0f, fmaxf(0.0f, volume)) : 0.0f;
    dispatch_async(_work, ^{
        self->_masterVolume = safeVolume;
        self->_masterMuted = muted;
        if (self->_audioQueue)
            [self recordError:AudioQueueSetParameter(self->_audioQueue, kAudioQueueParam_Volume,
                muted ? 0.0f : safeVolume) operation:@"set output volume"];
    });
}
- (void)setGuestVolumeLeft:(float)left right:(float)right muted:(BOOL)muted {
    dispatch_async(_work, ^{
        self->_guestLeft = fminf(1.0f, fmaxf(0.0f, left));
        self->_guestRight = fminf(1.0f, fmaxf(0.0f, right));
        self->_guestMuted = muted;
    });
}
- (void)enqueueBytes:(const void *)bytes length:(NSUInteger)length {
    // Bound both the pending dispatch work and the actual output buffers.
    @synchronized (self) {
        _receivedPackets++;
        if (!bytes || !length || length > 262144 || _pendingBytes > 262144 - length) {
            _droppedPackets++;
            return;
        }
        _pendingBytes += length;
    }
    NSData *copy = [NSData dataWithBytes:bytes length:length];
    dispatch_async(_work, ^{
        @synchronized (self) { self->_pendingBytes -= length; }
        AudioQueueRef queue = self->_audioQueue;
        @synchronized (self) {
            if (!queue || !self->_channels || length % (self->_channels * 2) ||
                self->_queuedBuffers >= 64 || self->_queuedBytes + length > self->_bytesPerSecond / 2) {
                self->_droppedPackets++;
                return;
            }
        }
        AudioQueueBufferRef buffer = NULL;
        OSStatus result = AudioQueueAllocateBuffer(queue, (UInt32)length, &buffer);
        if (result != noErr) { [self recordError:result operation:@"allocate buffer"]; return; }
        memcpy(buffer->mAudioData, copy.bytes, length);
        buffer->mAudioDataByteSize = (UInt32)length;
        if (self->_guestMuted) {
            memset(buffer->mAudioData, 0, length);
        } else if (self->_guestLeft != 1.0f || self->_guestRight != 1.0f) {
            int16_t *samples = buffer->mAudioData;
            for (NSUInteger i = 0; i < length / 2; i++) {
                const float gain = (self->_channels == 2 && (i & 1)) ? self->_guestRight : self->_guestLeft;
                samples[i] = (int16_t)(samples[i] * gain);
            }
        }
        @synchronized (self) {
            self->_queuedBytes += length;
            self->_queuedBuffers++;
        }
        result = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
        if (result != noErr) {
            @synchronized (self) { self->_queuedBytes -= length; self->_queuedBuffers--; }
            [self recordError:result operation:@"enqueue buffer"];
            AudioQueueFreeBuffer(queue, buffer);
            return;
        }
        if (!self->_started) {
            result = AudioQueueStart(queue, NULL);
            if (result != noErr) {
                [self recordError:result operation:@"start output"];
                [self stopOnQueue];
                return;
            }
            self->_started = YES;
        }
        if (!self->_loggedFirstData) {
            NSLog(@"Astra audio: PCM received and output started");
            self->_loggedFirstData = YES;
        }
    });
}
- (void)completedBuffer:(AudioQueueBufferRef)buffer queue:(AudioQueueRef)queue {
    @synchronized (self) {
        if (queue != _audioQueue) return; // Dispose owns retired buffers.
        _queuedBytes -= MIN(_queuedBytes, (NSUInteger)buffer->mAudioDataByteSize);
        if (_queuedBuffers) _queuedBuffers--;
        _completedBuffers++;
    }
    AudioQueueFreeBuffer(queue, buffer);
}
- (NSUInteger)delayMilliseconds {
    @synchronized (self) {
        return _bytesPerSecond ? _queuedBytes * 1000 / _bytesPerSecond : 0;
    }
}
- (NSDictionary<NSString *, id> *)statistics {
    // All AudioQueue control calls stay on _work. The callback shares only
    // counters under the short lock, so disposal cannot deadlock with it.
    __block NSDictionary *result;
    dispatch_sync(_work, ^{
        AudioQueueParameterValue appliedVolume = 0;
        OSStatus volumeStatus = self->_audioQueue
            ? AudioQueueGetParameter(self->_audioQueue, kAudioQueueParam_Volume, &appliedVolume) : noErr;
        @synchronized (self) {
            result = @{@"configured": @(self->_audioQueue != NULL), @"started": @(self->_started),
                @"sample_rate": @(self->_sampleRate), @"channels": @(self->_channels),
                @"received_packets": @(self->_receivedPackets), @"completed_buffers": @(self->_completedBuffers),
                @"dropped_packets": @(self->_droppedPackets), @"pending_bytes": @(self->_pendingBytes),
                @"queued_bytes": @(self->_queuedBytes), @"queued_buffers": @(self->_queuedBuffers),
                @"queue_delay_ms": @(self->_bytesPerSecond ? self->_queuedBytes * 1000 / self->_bytesPerSecond : 0),
                @"master_volume": @(self->_masterVolume), @"master_muted": @(self->_masterMuted),
                @"guest_muted": @(self->_guestMuted), @"applied_volume": @(appliedVolume),
                @"volume_read_status": @(volumeStatus), @"error_count": @(self->_errorCount),
                @"last_error": @(self->_lastError)};
        }
    });
    return result;
}
@end
