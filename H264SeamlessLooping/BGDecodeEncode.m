//
//  BGDecodeEncode.m
//
//  Created by Mo DeJong on 4/5/16.
//
//  See license.txt for BSD license terms.
//

#import "BGDecodeEncode.h"

@import AVFoundation;
@import UIKit;

@import CoreVideo;
@import CoreImage;
@import CoreMedia;
@import CoreGraphics;
@import VideoToolbox;

#import "H264FrameEncoder.h"

#import "CGFrameBuffer.h"

#if defined(DEBUG)
static const int dumpFramesImages = 1;
#else
static const int dumpFramesImages = 0;
#endif // DEBUG

//#define LOGGING 1

// Block API typedef, returns a BOOL

typedef BOOL (^EncodeFrameBlockT)(int, CVPixelBufferRef);

// Private API

@interface BGDecodeEncode ()
@end

@implementation BGDecodeEncode

// Return the movie decode OS type, typically kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
// but could be kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange. In any case, this value
// needs to match in both the encoder and decoder.

+ (OSType) getPixelType
{
  // Explicitly use video range color matrix
  const OSType movieEncodePixelFormatType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  //const OSType movieEncodePixelFormatType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  return movieEncodePixelFormatType;
}

+ (CVPixelBufferRef) pixelBufferFromCGImage:(CGImageRef)cgImage
                                 renderSize:(CGSize)renderSize
                                       dump:(BOOL)dump
                                      asYUV:(BOOL)asYUV
{
  NSDictionary *options = @{
                            (NSString *)kCVPixelBufferCGImageCompatibilityKey: @(YES),
                            (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @(YES)
                            };
  
  int renderWidth = (int) renderSize.width;
  int renderHeight = (int) renderSize.height;
  
  int imageWidth = (int) CGImageGetWidth(cgImage);
  int imageHeight = (int) CGImageGetHeight(cgImage);
  
  assert(imageWidth <= renderWidth);
  assert(imageHeight <= renderHeight);
  
  // FIXME: instead of creating CoreVideo buffers over and over, just create 1 and
  // then keep using it to do the render operations. Could also use a pool, but
  // not really needed either.
  
  CVPixelBufferRef buffer = NULL;
  CVPixelBufferCreate(kCFAllocatorDefault,
                      renderWidth,
                      renderHeight,
                      kCVPixelFormatType_32BGRA,
                      (__bridge CFDictionaryRef)options,
                      &buffer);
  
  size_t bytesPerRow, extraBytes;
  bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
  extraBytes = bytesPerRow - renderWidth*sizeof(uint32_t);
  //NSLog(@"bytesPerRow %d extraBytes %d", (int)bytesPerRow, (int)extraBytes);
  
  CVPixelBufferLockBaseAddress(buffer, 0);
  
  void *baseAddress                  = CVPixelBufferGetBaseAddress(buffer);
  
  //CGColorSpaceRef colorSpace = CGImageGetColorSpace(image.CGImage);
  CGColorSpaceRef colorSpace  = CGColorSpaceCreateDeviceRGB();
  
  CGContextRef context;
  
  context = CGBitmapContextCreate(baseAddress,
                                  renderWidth,
                                  renderHeight,
                                  8,
                                  CVPixelBufferGetBytesPerRow(buffer),
                                  colorSpace,
                                  kCGBitmapByteOrder32Host | kCGImageAlphaNoneSkipFirst);
  
  // Render frame into top left corner at exact size
  
  CGContextClearRect(context, CGRectMake(0.0f, 0.0f, renderWidth, renderHeight));
  
  CGContextDrawImage(context, CGRectMake(0.0f, renderHeight - imageHeight, imageWidth, imageHeight), cgImage);
  
  CGColorSpaceRelease(colorSpace);
  CGContextRelease(context);
  
  CVPixelBufferUnlockBaseAddress(buffer, 0);
  
  // Convert from BGRA to YUV representation
  
  if (asYUV) {
    CVPixelBufferRef yuv420Buffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          renderWidth,
                                          renderHeight,
                                          [self getPixelType],
                                          (__bridge CFDictionaryRef) @{
                                                                       (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
                                                                       (__bridge NSString *)kCVPixelFormatOpenGLESCompatibility : @(YES),
                                                                       },
                                          &yuv420Buffer);
    
    CIContext *context = [CIContext contextWithOptions:nil];
    NSAssert(context, @"CIContext");
    
    CIImage *inImage = [CIImage imageWithCVPixelBuffer:buffer];
    
    if (status == kCVReturnSuccess) {
      [context render:inImage toCVPixelBuffer:yuv420Buffer];
    }
    
    CVPixelBufferRelease(buffer);
    
    return yuv420Buffer;
  }
  
  return buffer;
}

// Decompress CoreMedia sample data directly from a .mov container
// without decompressing the samples.

// Given a .mov generate an array of the frames as CoreVideo buffers.
// This method returns the frames as BGRA pixels or YUV frames.

+ (BOOL) decodeCoreVideoFramesFromMOV:(NSString*)movPath
                                asYUV:(BOOL)asYUV
                     encodeFrameBlock:(EncodeFrameBlockT)encodeFrameBlock
{
  if ([[NSFileManager defaultManager] fileExistsAtPath:movPath] == FALSE) {
    return FALSE;
  }
  
  assert(encodeFrameBlock != nil);
  
  // Read H.264 frames and convert from YUV to BGRA on the read
  
  NSURL *assetURL = [NSURL fileURLWithPath:movPath];
  assert(assetURL);
  
  NSDictionary *options = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES]
                                                      forKey:AVURLAssetPreferPreciseDurationAndTimingKey];
  
  AVURLAsset *avUrlAsset = [[AVURLAsset alloc] initWithURL:assetURL options:options];
  
  if (avUrlAsset.hasProtectedContent) {
    NSAssert(FALSE, @"DRM");
  }
  
  if ([avUrlAsset tracks] == 0) {
    NSAssert(FALSE, @"not tracks");
  }
  
  NSError *assetError = nil;
  AVAssetReader *aVAssetReader = [AVAssetReader assetReaderWithAsset:avUrlAsset error:&assetError];
  
  NSAssert(aVAssetReader, @"aVAssetReader");
  
  if (assetError) {
    NSAssert(FALSE, @"AVAssetReader");
  }
  
  NSDictionary *videoSettings;
  
  if (asYUV) {
    videoSettings = [NSDictionary dictionaryWithObject:
                     [NSNumber numberWithUnsignedInt:[self getPixelType]] forKey:(id)kCVPixelBufferPixelFormatTypeKey];
  } else {
    videoSettings = [NSDictionary dictionaryWithObject:
                     [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey];
    
  }
  
  NSArray *videoTracks = [avUrlAsset tracksWithMediaType:AVMediaTypeVideo];
  
  NSAssert([videoTracks count] == 1, @"only 1 video track can be decoded");
  
  AVAssetTrack *videoTrack = [videoTracks objectAtIndex:0];
  
#if defined(LOGGING)
  NSArray *availableMetadataFormats = videoTrack.availableMetadataFormats;
  NSLog(@"availableMetadataFormats %@", availableMetadataFormats);
#endif // LOGGING
  
  NSAssert(videoTrack.isSelfContained, @"isSelfContained");
  
#if defined(LOGGING)
  CGSize uncroppedSize = videoTrack.naturalSize;
  NSLog(@"video track naturalSize w x h : %d x %d", (int)uncroppedSize.width, (int)uncroppedSize.height);
#endif // LOGGING
  
  // Track length in second, should map directly to number of frames
  
#if defined(LOGGING)
  CMTimeRange timeRange = videoTrack.timeRange;
  float duration = (float)CMTimeGetSeconds(timeRange.duration);
  NSLog(@"video track time duration %0.3f", duration);
#endif // LOGGING
  
  // Don't know how many frames at this point
  
  //int numFrames = round(duration);
  //NSLog(@"estimated number of frames %d", numFrames);
  
  AVAssetReaderTrackOutput *aVAssetReaderOutput = [[AVAssetReaderTrackOutput alloc]
                                                   initWithTrack:videoTrack outputSettings:videoSettings];
  
  NSAssert(aVAssetReaderOutput, @"AVAssetReaderVideoCompositionOutput failed");
  
  aVAssetReaderOutput.alwaysCopiesSampleData = FALSE;
  
  [aVAssetReader addOutput:aVAssetReaderOutput];
  
  aVAssetReaderOutput = aVAssetReaderOutput;
  
  // start reading
  
  NSAssert(aVAssetReader, @"aVAssetReader");
  
  BOOL worked = [aVAssetReader startReading];
  
  if (worked == FALSE) {
    AVAssetReaderStatus status = aVAssetReader.status;
    NSError *error = aVAssetReader.error;
    
    NSLog(@"status = %d", (int)status);
    NSLog(@"error = %@", [error description]);
    
    return FALSE;
  }
  
  // Read N frames as CoreVideo buffers and invoke callback
  
  BOOL allFramesEncodedSuccessfully = TRUE;
  
  // Read N frames, convert to BGRA pixels
  
  for ( int i = 0; 1; i++ ) @autoreleasepool {
    
    CMSampleBufferRef sampleBuffer = NULL;
    sampleBuffer = [aVAssetReaderOutput copyNextSampleBuffer];
    
    if (sampleBuffer == nil) {
      // Another frame could not be loaded, this is the normal
      // termination condition at the end of the file.
      break;
    }
    
    // Process BGRA data in buffer, crop and then read and combine
    
    CVImageBufferRef imageBufferRef = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBufferRef == NULL) {
      NSLog(@"CMSampleBufferGetImageBuffer() returned NULL at frame %d", i);
      allFramesEncodedSuccessfully = FALSE;
      break;
    }
    
    CVPixelBufferRef pixBuffer = imageBufferRef;
    
    BOOL worked = encodeFrameBlock(i, pixBuffer);
    
    CFRelease(sampleBuffer);
    
    if (!worked) {
      allFramesEncodedSuccessfully = FALSE;
      break;
    }
  }
  
  [aVAssetReader cancelReading];
  
  if (allFramesEncodedSuccessfully == FALSE) {
    return FALSE;
  } else {
    return TRUE;
  }
}

// Decompress and then recompress each frame of H264 video as keyframes that
// can be rendered directly without holding a stream decode resource open.

+ (NSArray*) recompressKeyframesOnBackgroundThread:(NSString*)resourceName
                                     frameDuration:(float)frameDuration
                                        renderSize:(CGSize)renderSize
                                        aveBitrate:(int)aveBitrate
{
#if defined(LOGGING)
  NSLog(@"recompressKeyframesOnBackgroundThread");
#endif // LOGGING
  
  NSAssert([NSThread isMainThread] == FALSE, @"isMainThread");

  NSString *resTail = [resourceName lastPathComponent];
  NSString *resNoSuffix = [[resourceName lastPathComponent] stringByDeletingPathExtension];
  
  NSString* movieFilePath = [[NSBundle mainBundle]
                             pathForResource:resTail ofType:nil];
  NSAssert(movieFilePath, @"movieFilePath is nil");
  
  // Previously, asYUV was set to TRUE on device in an attempt to get the best
  // performance by avoiding YUV->RGB->YUV conversion, but it seems to produce
  // some slightly off colors in the reencoded video. Convert the initial movie
  // data to RGB and then encode from RGB so that the defaults match whatever iOS
  // is doing with 601 and 709 automatic detection.

  BOOL asYUV = FALSE;
  
//  BOOL asYUV = TRUE;
//#if TARGET_IPHONE_SIMULATOR
//  asYUV = FALSE; // Force BGRA buffer when running in simulator
//#endif // TARGET_IPHONE_SIMULATOR
  
  // Setup frame encoder that will encode each frame
  
  H264FrameEncoder *frameEncoder = [[H264FrameEncoder alloc] init];
  
  // Hard coded to 24 FPS
  //frameEncoder.frameDuration = 1.0f/24;
  frameEncoder.frameDuration = frameDuration;
  
  // Larger than original but not too big
  
//  frameEncoder.aveBitrate = 5000000;
  frameEncoder.aveBitrate = aveBitrate;
  
  // Begin to decode frames
  
  NSMutableArray *encodedH264Buffers = [NSMutableArray array];
  
  __block int totalEncodeNumBytes = 0;
  
  EncodeFrameBlockT encodeFrameBlock =  ^ BOOL (int frameOffset, CVPixelBufferRef pixBuffer) {
    int width = (int) CVPixelBufferGetWidth(pixBuffer);
    int height = (int) CVPixelBufferGetHeight(pixBuffer);
    
    CGSize imgSize = CGSizeMake(width, height);
    
    // 1920 x 1080 is Full HD and the upper limit of H264 render size for iPad devices.
    // When the size of the input and the output exactly match, use input buffer (much faster)
    
    // 2048 x 1536 seems to work just fine on iPad Retina
    
    //CGSize renderSize = CGSizeMake(1920, 1080);
    //CGSize renderSize = CGSizeMake(2048, 1536);
    
    //int renderWidth = (int) renderSize.width;
    //int renderHeight = (int) renderSize.height;
    
    // Render CoreVideo to a NxN square so that square pixels do not distort
    
#if defined(LOGGING)
    NSLog(@"encode input dimensions %4d x %4d", width, height);
#endif // LOGGING
    
    CVPixelBufferRef largerBuffer;
    
    if (CGSizeEqualToSize(imgSize, renderSize)) {
      // No resize needed
      largerBuffer = pixBuffer;
      
      CVPixelBufferRetain(largerBuffer);
    } else {
      int srcWidth = (int) CVPixelBufferGetWidth(pixBuffer);
      int srcHeight = (int) CVPixelBufferGetHeight(pixBuffer);
      int pixBufferNumBytes = (int) CVPixelBufferGetBytesPerRow(pixBuffer) * srcHeight;
      
      {
        int status = CVPixelBufferLockBaseAddress(pixBuffer, 0);
        assert(status == kCVReturnSuccess);
      }
      void *pixelsPtr = CVPixelBufferGetBaseAddress(pixBuffer);
      assert(pixelsPtr);
      
      size_t bitsPerComponent = 8;
      size_t numComponents = 4;
      size_t bitsPerPixel = bitsPerComponent * numComponents;
      size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixBuffer);
      
      CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host | kCGImageAlphaNoneSkipFirst;
      
      CGDataProviderReleaseDataCallback releaseData = NULL;
      
      CGDataProviderRef dataProviderRef = CGDataProviderCreateWithData(
                                                                       NULL,
                                                                       pixelsPtr,
                                                                       pixBufferNumBytes,
                                                                       releaseData);

      BOOL shouldInterpolate = TRUE;
        
      CGColorRenderingIntent renderIntent = kCGRenderingIntentDefault;
        
      CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB(); // iOS sRGB
      
      CGImageRef inImageRef = CGImageCreate(srcWidth, srcHeight, bitsPerComponent, bitsPerPixel, bytesPerRow,
                                            colorSpace, bitmapInfo, dataProviderRef, NULL,
                                            shouldInterpolate, renderIntent);

      CGDataProviderRelease(dataProviderRef);
      
      CGColorSpaceRelease(colorSpace);

      assert(inImageRef);
      
      // Dump original before resize action
      
      if (dumpFramesImages)
      {
        NSString *dumpFilename = [NSString stringWithFormat:@"%@_orig_F%d.png", resNoSuffix, frameOffset];
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:dumpFilename];
        
        UIImage *rerenderedInputImg = [UIImage imageWithCGImage:inImageRef];
        NSData *pngData = UIImagePNGRepresentation(rerenderedInputImg);
        [pngData writeToFile:tmpPath atomically:TRUE];
        
        //NSLog(@"wrote \"%@\" at size %d x %d", tmpPath, (int)rerenderedInputImg.size.width, (int)rerenderedInputImg.size.height);
      }
      
      // Output image as CoreGraphics buffer
      
      CGFrameBuffer *cgFramebuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:24 width:renderSize.width height:renderSize.height];
      
      // Render the src image into a large framebuffer
      
      BOOL worked = [cgFramebuffer renderCGImage:inImageRef];
      assert(worked);
      
      CGImageRelease(inImageRef);
      
      {
        int status = CVPixelBufferUnlockBaseAddress(pixBuffer, 0);
        assert(status == kCVReturnSuccess);
      }
      
      CGImageRef resizedCgImgRef = [cgFramebuffer createCGImageRef];
      
      if (dumpFramesImages)
      {
        NSString *dumpFilename = [NSString stringWithFormat:@"%@_resized_F%d.png", resNoSuffix, frameOffset];
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:dumpFilename];
        
        UIImage *rerenderedInputImg = [UIImage imageWithCGImage:resizedCgImgRef];
        NSData *pngData = UIImagePNGRepresentation(rerenderedInputImg);
        [pngData writeToFile:tmpPath atomically:TRUE];
        
        //NSLog(@"wrote \"%@\" at size %d x %d", tmpPath, (int)rerenderedInputImg.size.width, (int)rerenderedInputImg.size.height);
      }
      
      largerBuffer = [self.class pixelBufferFromCGImage:resizedCgImgRef
                                           renderSize:renderSize
                                                 dump:FALSE
                                                asYUV:FALSE];
      
      CGImageRelease(resizedCgImgRef);
    }
    
    if (dumpFramesImages)
    {
      CIImage *largerCiImage = [CIImage imageWithCVPixelBuffer:largerBuffer];
      
      UIGraphicsBeginImageContext(renderSize);
      CGRect rect;
      rect.origin = CGPointZero;
      rect.size   = renderSize;
      UIImage *remLargerImage = [UIImage imageWithCIImage:largerCiImage];
      [remLargerImage drawInRect:rect];
      UIImage *largerRenderedImg = UIGraphicsGetImageFromCurrentImageContext();
      UIGraphicsEndImageContext();
      
      NSString *dumpFilename = [NSString stringWithFormat:@"%@_F%d.png", resNoSuffix, frameOffset];
      NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:dumpFilename];
      
      NSData *pngData = UIImagePNGRepresentation(largerRenderedImg);
      [pngData writeToFile:tmpPath atomically:TRUE];
      
//      NSLog(@"wrote \"%@\" at size %d x %d", tmpPath, (int)largerRenderedImg.size.width, (int)largerRenderedImg.size.height);
    }
    
    // Render CoreVideo to a NxN square so that square pixels do not distort
    
#if defined(LOGGING)
    int largerWidth = (int) CVPixelBufferGetWidth(largerBuffer);
    int largerHeight = (int) CVPixelBufferGetHeight(largerBuffer);
    NSLog(@"encode output dimensions %4d x %4d", largerWidth, largerHeight);
#endif // LOGGING
    
    //NSLog(@"CVPixelBufferRef: %@", pixBuffer);
      
    __block BOOL encodeFrameErrorCondition = FALSE;
    
    frameEncoder.sampleBufferBlock = ^(CMSampleBufferRef sampleBuffer) {
      // If sampleBuffer is NULL, then the frame could not be encoded.
      
      if (sampleBuffer == NULL) {
        //NSAssert(sampleBuffer, @"sampleBuffer argument to H264FrameEncoder.sampleBufferBlock is NULL");
        encodeFrameErrorCondition = TRUE;
        return;
      }
      
      [encodedH264Buffers addObject:(__bridge id)sampleBuffer];
      
      int numBytes = (int) CMSampleBufferGetSampleSize(sampleBuffer, 0);
      
#if defined(LOGGING)
      NSLog(@"encoded buffer as %6d H264 bytes", numBytes);
#endif // LOGGING
      
      totalEncodeNumBytes += numBytes;
    };
    
#if TARGET_IPHONE_SIMULATOR
    // No-op
#else
    OSType bufferPixelType = CVPixelBufferGetPixelFormatType(largerBuffer);
    if (bufferPixelType == kCVPixelFormatType_32BGRA) {
      // Already converted from YUV to BGRA
    } else {
      assert([self getPixelType] == bufferPixelType);
    }
#endif // TARGET_IPHONE_SIMULATOR
    
    BOOL worked = [frameEncoder encodeH264CoreMediaFrame:largerBuffer];

    if (worked) {
      [frameEncoder waitForFrame];
    }
    
    CVPixelBufferRelease(largerBuffer);
    
    if (encodeFrameErrorCondition == TRUE) {
      return FALSE;
    }
      
    if (worked == FALSE) {
      return FALSE;
    } else {
      return TRUE;
    }
  };

  // Encode each frame, one at a time, so that totaly memory used is minimized
  
  BOOL worked = [self.class decodeCoreVideoFramesFromMOV:movieFilePath
                                                   asYUV:asYUV
                                        encodeFrameBlock:encodeFrameBlock];

  if (worked == FALSE) {
    NSLog(@"decodeCoreVideoFramesFromMOV failed for %@", movieFilePath);
  }
  
  [frameEncoder endSession];
  
#if defined(LOGGING)
  NSLog(@"total encoded num bytes %d", totalEncodeNumBytes);
#endif // LOGGING
  
  if (worked == FALSE) {
    return nil;
  } else {
    return [NSArray arrayWithArray:encodedH264Buffers];
  }
}

@end
