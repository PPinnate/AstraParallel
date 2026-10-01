//
// Copyright © 2022 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

@import simd;
@import MetalKit;
#import <TargetConditionals.h>

#import "CSMetalRenderer.h"
#import "CSRenderSource.h"
#import "CSRenderer.h"

// Header shared between C code here, which executes Metal API commands, and .metal files, which
//   uses these types as inputs to the shaders
#import "CSShaderTypes.h"

NS_ASSUME_NONNULL_BEGIN

@protocol AstraFrameTiming <NSObject>
@property (nonatomic, readonly) NSTimeInterval astraFrameReceivedAt;
@property (nonatomic, readonly) NSUInteger astraFrameSequence;
@end

/// Helper class to retain fields from a renderer source
@interface _CSRendererSourceData : NSObject<CSRenderSource>

@property (nonatomic, readonly) CGPoint offset;
@property (nonatomic, readonly) id<MTLBuffer> vertices;
@property (nonatomic, readonly) NSUInteger numVertices;
@property (nonatomic, readonly) id<MTLTexture> texture;
@property (nonatomic, readonly) BOOL hasAlpha;
@property (nonatomic, readonly) BOOL isInverted;
@property (nonatomic, readonly) BOOL isVisible;
@property (nonatomic, strong, readonly) _CSRendererSourceData *cursorSource;
@property (nonatomic, readonly) NSTimeInterval frameReceivedAt;
@property (nonatomic, readonly) NSUInteger frameSequence;

- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithRenderSource:(id<CSRenderSource>)renderSource device:(id<MTLDevice>)device;
- (nullable instancetype)initWithRenderSource:(id<CSRenderSource>)renderSource atOffset:(CGPoint)offset device:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END

@implementation _CSRendererSourceData

/// Retain a copy of the render source data
/// - Parameter renderSource: Render source to read from
- (nullable instancetype)initWithRenderSource:(id<CSRenderSource>)renderSource {
    return [self initWithRenderSource:renderSource atOffset:CGPointZero];
}

/// Retain a copy of the render source data
/// - Parameters:
///   - renderSource: Render source to read from
///   - offset: Offset to add to `viewportOrigin`, can be zero
- (nullable instancetype)initWithRenderSource:(id<CSRenderSource>)renderSource atOffset:(CGPoint)offset {
    id<CSRenderSource> cursorSource = renderSource.cursorSource;
    if (self = [super init]) {
        _offset = CGPointMake(renderSource.offset.x +
                              offset.x,
                              renderSource.offset.y +
                              offset.y);
        _vertices = renderSource.vertices;
        _numVertices = renderSource.numVertices;
        _texture = renderSource.texture;
        _hasAlpha = renderSource.hasAlpha;
        _isInverted = renderSource.isInverted;
        _isVisible = renderSource.isVisible;
        if ([(NSObject *)renderSource respondsToSelector:@selector(astraFrameReceivedAt)]) {
            _frameReceivedAt = [(id<AstraFrameTiming>)renderSource astraFrameReceivedAt];
            _frameSequence = [(id<AstraFrameTiming>)renderSource astraFrameSequence];
        }
        if (!_vertices || !_texture) {
            return nil;
        }
        if (cursorSource) {
            _cursorSource = [[_CSRendererSourceData alloc] initWithRenderSource:cursorSource
                                                                       atOffset:renderSource.offset];
        }
    }
    return self;
}

@end

@interface CSMetalRenderer ()

// Thses must only be accessed by main thread
@property (nonatomic, nullable) const _CSRendererSourceData *renderSourceData;
@property (nonatomic, assign) vector_uint2 renderViewportSize;
@property (nonatomic) id<MTLSamplerState> renderSampler;
@property (nonatomic) CGPoint renderViewportOrigin;
@property (nonatomic) CGFloat renderViewportScale;
@property (nonatomic) BOOL renderNeedsUpdate;
@property (nonatomic, readonly) NSMutableArray<completionCallback_t> *renderCompletions;

@end

// Main class performing the rendering
@implementation CSMetalRenderer
{
    // The device (aka GPU) we're using to render
    id<MTLDevice> _device;

    // Our render pipeline composed of our vertex and fragment shaders in the .metal shader file
    id<MTLRenderPipelineState> _pipelineState;

    // The command Queue from which we'll obtain command buffers
    id<MTLCommandQueue> _commandQueue;
    __weak MTKView *_astraView;
    BOOL _astraDrawScheduled;
    NSMutableArray<NSNumber *> *_astraPresentationLatencies;
    NSMutableArray<NSNumber *> *_astraPresentationTimes;
    NSUInteger _astraPresentedFrames;
    NSUInteger _astraLastFrameSequence;
}

@synthesize device = _device;
@synthesize commandQueue = _commandQueue;
@synthesize viewportOrigin = _viewportOrigin;
@synthesize viewportScale = _viewportScale;

/// Initialize with the MetalKit view from which we'll obtain our Metal device
- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
    self = [super init];
    if(self)
    {
        NSError *error = NULL;
        
        _device = mtkView.device;
        _astraView = mtkView;
        [self _setViewportCGSize:mtkView.drawableSize];
        _renderCompletions = [NSMutableArray array];
        _viewportScale = 1.0f;
        _renderViewportScale = 1.0f;
        _astraPresentationLatencies = [NSMutableArray array];
        _astraPresentationTimes = [NSMutableArray array];

        /// Create our render pipeline
        
        // Load all the shader files with a .metal file extension in the project
        // FIXME: on Swift we have `Bundle.module` generated by SPM but it doesn't appear to be the case for Obj-C
        NSURL *modulePath = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"CocoaSpice_CocoaSpiceRenderer.bundle"];
        NSBundle *bundle = [NSBundle bundleWithURL:modulePath];
        id<MTLLibrary> defaultLibrary = [_device newDefaultLibraryWithBundle:bundle error:&error];
        NSAssert(defaultLibrary, @"Failed to get library from bundle: %@", error);

        // Load the vertex function from the library
        id<MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"vertexShader"];

        // Load the fragment function from the library
        id<MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"samplingShader"];

        // Set up a descriptor for creating a pipeline state object
        MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        pipelineStateDescriptor.label = @"Renderer Pipeline";
        pipelineStateDescriptor.vertexFunction = vertexFunction;
        pipelineStateDescriptor.fragmentFunction = fragmentFunction;
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat;
        pipelineStateDescriptor.colorAttachments[0].blendingEnabled = YES;
        pipelineStateDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipelineStateDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipelineStateDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineStateDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineStateDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipelineStateDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
        pipelineStateDescriptor.depthAttachmentPixelFormat = mtkView.depthStencilPixelFormat;
        pipelineStateDescriptor.vertexBuffers[CSRenderVertexInputIndexVertices].mutability = MTLMutabilityImmutable;

        _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                                                 error:&error];
        NSAssert(_pipelineState, @"Failed to create pipeline state to render to texture: %@", error);

        // Create the command queue
        _commandQueue = [_device newCommandQueue];

        // Sampler
        [self _initializeUpscaler:MTLSamplerMinMagFilterLinear downscaler:MTLSamplerMinMagFilterLinear];
    }

    return self;
}

- (void)_initializeUpscaler:(MTLSamplerMinMagFilter)upscaler downscaler:(MTLSamplerMinMagFilter)downscaler {
    MTLSamplerDescriptor *samplerDescriptor = [MTLSamplerDescriptor new];
    samplerDescriptor.minFilter = downscaler;
    samplerDescriptor.magFilter = upscaler;

    _renderSampler = [_device newSamplerStateWithDescriptor:samplerDescriptor];
}

- (void)setRenderNeedsUpdate:(BOOL)value {
    _renderNeedsUpdate = value;
    if (value && _astraView.paused && !_astraDrawScheduled) {
        _astraDrawScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_astraDrawScheduled = NO;
            if (self.renderNeedsUpdate) [self->_astraView draw];
        });
    }
}

- (void)resetTimingStatistics {
    @synchronized (self) {
        [_astraPresentationLatencies removeAllObjects];
        [_astraPresentationTimes removeAllObjects];
        _astraPresentedFrames = 0;
    }
}

/// Scalers from VM settings
- (void)changeUpscaler:(MTLSamplerMinMagFilter)upscaler downscaler:(MTLSamplerMinMagFilter)downscaler {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _initializeUpscaler:upscaler downscaler:downscaler];
    });
}

- (void)_setViewportCGSize:(CGSize)size {
    vector_uint2 viewportSize;

    viewportSize.x = size.width;
    viewportSize.y = size.height;
    _renderViewportSize = viewportSize;
}

/// Called whenever view changes orientation or is resized
- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
    // Save the size of the drawable as we'll pass these
    //   values to our vertex shader when we draw
    [self _setViewportCGSize:size];
}

- (void)setViewportOrigin:(CGPoint)viewportOrigin {
    if (!CGPointEqualToPoint(_viewportOrigin, viewportOrigin)) {
        _viewportOrigin = viewportOrigin;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.renderViewportOrigin = viewportOrigin;
            self.renderNeedsUpdate = YES;
        });
    }
}

- (void)setViewportScale:(CGFloat)viewportScale {
    if (_viewportScale != viewportScale) {
        _viewportScale = viewportScale;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.renderViewportScale = viewportScale;
            self.renderNeedsUpdate = YES;
        });
    }
}

/// Must be called from main thread
- (void)_addDrawCompletion:(completionCallback_t)completion {
    [self.renderCompletions addObject:completion];
}

/// Must be called from main thread
- (void)_completeDraw {
    for (completionCallback_t completion in _renderCompletions) {
        completion();
    }
    [self.renderCompletions removeAllObjects];
}

/// Create a translation+scale matrix
static matrix_float4x4 matrix_scale_translate(CGFloat scale, CGPoint translate)
{
    matrix_float4x4 m = {
        .columns[0] = {
            scale,
            0,
            0,
            0
        },
        .columns[1] = {
            0,
            scale,
            0,
            0
        },
        .columns[2] = {
            0,
            0,
            1,
            0
        },
        .columns[3] = {
            translate.x,
            -translate.y, // y flipped
            0,
            1
        }
        
    };
    return m;
}

/// Called whenever the view needs to render a frame
- (void)drawInMTKView:(nonnull MTKView *)view
{
    const _CSRendererSourceData *sourceData = self.renderSourceData;
    if (!self.renderNeedsUpdate || !sourceData.isVisible) {
        [self _completeDraw];
        return;
    }
    // Obtain a renderPassDescriptor generated from the view's drawable textures
    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> currentDrawable = view.currentDrawable;

    if (renderPassDescriptor == nil || currentDrawable == nil) {
        return;
    }

    // Consume the flag: every content change re-sets it via
    // invalidateRenderSource:, so without this the view keeps re-rendering
    // an unchanged frame on every vsync forever.
    self.renderNeedsUpdate = NO;

    // synchronize with rendererQueue in order to access currentCommandBuffer
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"Draw Frame";

    [self _renderCommand:commandBuffer
              drawSource:sourceData
          viewportOrigin:self.renderViewportOrigin
           viewportScale:self.renderViewportScale
            viewportSize:self.renderViewportSize
                 sampler:self.renderSampler
    renderPassDescriptor:renderPassDescriptor];

    [commandBuffer presentDrawable:currentDrawable];

    NSTimeInterval received = sourceData.frameReceivedAt;
    NSUInteger sequence = sourceData.frameSequence;
    if (received > 0 && sequence != _astraLastFrameSequence) {
        _astraLastFrameSequence = sequence;
        [currentDrawable addPresentedHandler:^(id<MTLDrawable> drawable) {
            NSTimeInterval presented = drawable.presentedTime;
            if (presented <= received) return;
            @synchronized (self) {
                self->_astraPresentedFrames += 1;
                [self->_astraPresentationLatencies addObject:@((presented - received) * 1000)];
                [self->_astraPresentationTimes addObject:@(presented)];
                if (self->_astraPresentationLatencies.count > 512) {
                    [self->_astraPresentationLatencies removeObjectAtIndex:0];
                    [self->_astraPresentationTimes removeObjectAtIndex:0];
                }
            }
        }];
    }

    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _completeDraw];
        });
    }];

    // Finalize rendering here & push the command buffer to the GPU
    [commandBuffer commit];
}

- (NSDictionary<NSString *, id> *)timingStatistics {
    NSArray<NSNumber *> *latencies, *times;
    NSUInteger total;
    @synchronized (self) {
        latencies = [_astraPresentationLatencies copy];
        times = [_astraPresentationTimes copy];
        total = _astraPresentedFrames;
    }
    NSArray<NSNumber *> *sorted = [latencies sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSNumber *> *recent = [NSMutableArray array];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    for (NSNumber *time in times) if (time.doubleValue >= now - 5) [recent addObject:time];
    id rate = NSNull.null;
    if (recent.count > 1) {
        double elapsed = recent.lastObject.doubleValue - recent.firstObject.doubleValue;
        if (elapsed > 0) rate = @((recent.count - 1) / elapsed);
    }
    NSMutableDictionary *result = [@{@"presented_scanout_frames": @(total), @"recent_scanout_updates_hz": rate,
        @"latency_scope": @"SPICE frame receipt to Metal drawable presentation; excludes guest rendering, hardware input and display processing"} mutableCopy];
    if (sorted.count) {
        result[@"samples"] = @(sorted.count);
        result[@"p50_ms"] = sorted[(sorted.count - 1) / 2];
        result[@"p95_ms"] = sorted[(NSUInteger)((sorted.count - 1) * 0.95)];
        result[@"max_ms"] = sorted.lastObject;
    }
    return result;
}

- (void)renderSouce:(id<CSRenderSource>)renderSource
         copyBuffer:(id<MTLBuffer>)sourceBuffer
             region:(MTLRegion)region
       sourceOffset:(NSUInteger)sourceOffset
  sourceBytesPerRow:(NSUInteger)sourceBytesPerRow
         completion:(nullable completionCallback_t)completion {

    _CSRendererSourceData *sourceData = [[_CSRendererSourceData alloc] initWithRenderSource:renderSource];

    if (!sourceData) {
        if (completion) {
            completion();
        }
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"Blit Command Buffer";
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    blitEncoder.label = @"Renderer Canvas Updates";

    [blitEncoder copyFromBuffer:sourceBuffer
                   sourceOffset:sourceOffset
              sourceBytesPerRow:sourceBytesPerRow
            sourceBytesPerImage:0
                     sourceSize:region.size
                      toTexture:sourceData.texture
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:region.origin];

    [blitEncoder endEncoding];

    [commandBuffer commit];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) {
            [self _addDrawCompletion:completion];
        }
        self.renderSourceData = sourceData;
        self.renderNeedsUpdate = YES;
    });
}

- (void)invalidateRenderSource:(id<CSRenderSource>)renderSource
                withCompletion:(nullable completionCallback_t)completion {
    _CSRendererSourceData *sourceData = [[_CSRendererSourceData alloc] initWithRenderSource:renderSource];
    if (!sourceData || !sourceData.isVisible) {
        if (completion) {
            completion();
        }
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) {
            [self _addDrawCompletion:completion];
        }
        self.renderSourceData = sourceData;
        self.renderNeedsUpdate = YES;
    });
}

- (void)disableRender {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.renderSourceData = nil;
        self.renderNeedsUpdate = NO;
    });
}

- (BOOL)_renderCommand:(id<MTLCommandBuffer>)commandBuffer
            drawSource:(id<CSRenderSource>)source
        viewportOrigin:(CGPoint)viewportOrigin
         viewportScale:(CGFloat)viewportScale
          viewportSize:(vector_uint2)viewportSize
               sampler:(id<MTLSamplerState>)sampler
  renderPassDescriptor:(MTLRenderPassDescriptor *)renderPassDescriptor {
    id<MTLRenderCommandEncoder> renderEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    renderEncoder.label = @"View Presentation";

    [renderEncoder setRenderPipelineState:_pipelineState];

    NSAssert(source.isVisible, @"Screen should be visible at this point!");

    CGPoint origin = CGPointMake(viewportOrigin.x + source.offset.x * viewportScale,
                                 viewportOrigin.y + source.offset.y * viewportScale);

    [self _renderEncoder:renderEncoder
            drawAtOrigin:origin
                   scale:viewportScale
                vertices:source.vertices
            numVerticies:source.numVertices
                hasAlpha:source.hasAlpha
              isInverted:source.isInverted
                 texture:source.texture
            viewportSize:viewportSize
                 sampler:sampler];

    // Draw cursor
    if (source.cursorSource.isVisible) {
        CGPoint cursorOrigin = CGPointMake(viewportOrigin.x + (source.offset.x + source.cursorSource.offset.x) * viewportScale,
                                           viewportOrigin.y + (source.offset.y + source.cursorSource.offset.y) * viewportScale);
        // Next render the cursor
        [self _renderEncoder:renderEncoder
                drawAtOrigin:cursorOrigin
                       scale:viewportScale
                    vertices:source.cursorSource.vertices
                numVerticies:source.cursorSource.numVertices
                    hasAlpha:source.cursorSource.hasAlpha
                  isInverted:source.cursorSource.isInverted
                     texture:source.cursorSource.texture
                viewportSize:viewportSize
                     sampler:sampler];
    }

    [renderEncoder endEncoding];
}

- (void)_renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
          drawAtOrigin:(CGPoint)origin
                 scale:(CGFloat)scale
              vertices:(id<MTLBuffer>)vertices
          numVerticies:(NSUInteger)numVerticies
              hasAlpha:(BOOL)hasAlpha
            isInverted:(BOOL)isInverted
               texture:(id<MTLTexture>)texture
          viewportSize:(vector_uint2)viewportSize
               sampler:(id<MTLSamplerState>)sampler {
    matrix_float4x4 transform = matrix_scale_translate(scale,
                                                       origin);

    [renderEncoder setVertexBuffer:vertices
                            offset:0
                          atIndex:CSRenderVertexInputIndexVertices];

    [renderEncoder setVertexBytes:&viewportSize
                           length:sizeof(viewportSize)
                          atIndex:CSRenderVertexInputIndexViewportSize];

    [renderEncoder setVertexBytes:&transform
                           length:sizeof(transform)
                          atIndex:CSRenderVertexInputIndexTransform];

    [renderEncoder setVertexBytes:&hasAlpha
                           length:sizeof(hasAlpha)
                          atIndex:CSRenderVertexInputIndexHasAlpha];
    
    // Set the texture object.  The CSRenderTextureIndexBaseColor enum value corresponds
    ///  to the 'colorMap' argument in our 'samplingShader' function because its
    //   texture attribute qualifier also uses CSRenderTextureIndexBaseColor for its index
    [renderEncoder setFragmentTexture:texture
                              atIndex:CSRenderTextureIndexBaseColor];
    
    [renderEncoder setFragmentSamplerState:sampler
                                   atIndex:CSRenderSamplerIndexTexture];
    
    [renderEncoder setFragmentBytes:&isInverted
                             length:sizeof(isInverted)
                            atIndex:CSRenderFragmentBufferIndexIsInverted];

    // Draw the vertices of our triangles
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                      vertexStart:0
                      vertexCount:numVerticies];
}

@end
