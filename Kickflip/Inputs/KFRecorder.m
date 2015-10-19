//
//  KFRecorder.m
//  FFmpegEncoder
//
//  Created by Christopher Ballinger on 1/16/14.
//  Copyright (c) 2014 Christopher Ballinger. All rights reserved.
//
#define kSCRecorderRecordSessionQueueKey "SCRecorderRecordSessionQueue"
#import "KFRecorder.h"
#import "KFAACEncoder.h"
#import "KFH264Encoder.h"
#import "KFHLSMonitor.h"
#import "KFH264Encoder.h"
#import "KFHLSWriter.h"
#import "KFLog.h"
#import "KFAPIClient.h"
#import "KFS3Stream.h"
#import "KFFrame.h"
#import "KFVideoFrame.h"
#import "Kickflip.h"
#import "Endian.h"

@interface KFRecorder()
@property (nonatomic) double minBitrate;
@property (nonatomic) BOOL hasScreenshot;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic) BOOL isUsingFrontFacingCamera;
@property (nonatomic) AVCaptureDeviceInput* videoInput;
@property (nonatomic) AVCaptureDevicePosition device;
@property (readonly, nonatomic) dispatch_queue_t __nonnull sessionQueue;
@property BOOL isHasFlash;
@end

int _beginSessionConfigurationCount;


@implementation KFRecorder

- (id) init {
    if (self = [super init]) {
        
        _minBitrate = 300 * 1000;
        [self setupSession];
        [self setupEncoders];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];
        
    }
    return self;
}

- (AVCaptureDevice *)audioDevice
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
    if ([devices count] > 0)
        return [devices objectAtIndex:0];
    
    return nil;
}

- (void) setupHLSWriterWithEndpoint:(KFS3Stream*)endpoint {
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    NSString *folderName = [NSString stringWithFormat:@"%@.hls", endpoint.streamID];
    NSString *hlsDirectoryPath = [basePath stringByAppendingPathComponent:folderName];
    [[NSFileManager defaultManager] createDirectoryAtPath:hlsDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    self.hlsWriter = [[KFHLSWriter alloc] initWithDirectoryPath:hlsDirectoryPath];
    [_hlsWriter addVideoStreamWithWidth:self.videoWidth height:self.videoHeight];
    [_hlsWriter addAudioStreamWithSampleRate:self.audioSampleRate];
    
}

- (void) setupEncoders {
    self.audioSampleRate = 44100;
    self.videoHeight = 1280;
    self.videoWidth = 720;
    int audioBitrate = 64 * 1000; // 64 Kbps
    int maxBitrate = [Kickflip maxBitrate];
    int videoBitrate = maxBitrate - audioBitrate;
    _h264Encoder = [[KFH264Encoder alloc] initWithBitrate:videoBitrate width:self.videoWidth height:self.videoHeight];
    _h264Encoder.delegate = self;
    
    _aacEncoder = [[KFAACEncoder alloc] initWithBitrate:audioBitrate sampleRate:self.audioSampleRate channels:1];
    _aacEncoder.delegate = self;
    _aacEncoder.addADTSHeader = YES;
}

- (void) setupAudioCapture {
    
    // create capture device with video input
    
    /*
     * Create audio connection
     */
    AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    NSError *error = nil;
    AVCaptureDeviceInput *audioInput = [[AVCaptureDeviceInput alloc] initWithDevice:audioDevice error:&error];
    if (error) {
        NSLog(@"Error getting audio input device: %@", error.description);
    }
    if ([_session canAddInput:audioInput]) {
        [_session addInput:audioInput];
    }
    
    _audioQueue = dispatch_queue_create("Audio Capture Queue", DISPATCH_QUEUE_SERIAL);
    _audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    [_audioOutput setSampleBufferDelegate:self queue:_audioQueue];
    if ([_session canAddOutput:_audioOutput]) {
        [_session addOutput:_audioOutput];
    }
    _audioConnection = [_audioOutput connectionWithMediaType:AVMediaTypeAudio];
}

- (void) setupVideoCapture {
    [self setupVideoCaptureWithCapturePosition:AVCaptureDevicePositionFront];
}

- (AVCaptureConnection*)currentVideoConnection {
    for (AVCaptureConnection * connection in _videoOutput.connections) {
        for (AVCaptureInputPort * port in connection.inputPorts) {
            if ([port.mediaType isEqual:AVMediaTypeVideo]) {
                return connection;
            }
        }
    }
    
    return nil;
}

- (void) setupVideoCaptureWithCapturePosition:(AVCaptureDevicePosition)position {
    NSError *error = nil;
    AVCaptureDevice* videoDevice = [self deviceWithMediaType:AVMediaTypeVideo preferringPosition:position];
    
    _device = AVCaptureDevicePositionFront;
    if(_videoInput){
        [_session removeInput:_videoInput];
    }
    
    _videoInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
    if (error) {
        NSLog(@"Error getting video input device: %@", error.description);
    }
    
    if ([_session canAddInput:_videoInput]) {
        [_session addInput:_videoInput];
    }
    
    NSLog(@"%@",_session.inputs);
    
    
    // create an output for YUV output with self as delegate
    _videoQueue = dispatch_queue_create("Video Capture Queue", DISPATCH_QUEUE_SERIAL);
    
    _videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    [_videoOutput setSampleBufferDelegate:self queue:_videoQueue];
    NSDictionary *captureSettings = @{(NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    _videoOutput.videoSettings = captureSettings;
    _videoOutput.alwaysDiscardsLateVideoFrames = YES;
    if ([_session canAddOutput:_videoOutput]) {
        [_session addOutput:_videoOutput];
    }
    
    NSLog(@"%@",_videoOutput);
    _videoConnection = [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
    [_videoConnection setVideoOrientation:AVCaptureVideoOrientationPortrait];
    NSLog(@"%@",[self currentVideoConnection]);
    
    
    
    
}

#pragma mark KFEncoderDelegate method
- (void) encoder:(KFEncoder*)encoder encodedFrame:(KFFrame *)frame {
    if (encoder == _h264Encoder) {
        KFVideoFrame *videoFrame = (KFVideoFrame*)frame;
        [_hlsWriter processEncodedData:videoFrame.data presentationTimestamp:videoFrame.pts streamIndex:0 isKeyFrame:videoFrame.isKeyFrame];
    } else if (encoder == _aacEncoder) {
        [_hlsWriter processEncodedData:frame.data presentationTimestamp:frame.pts streamIndex:1 isKeyFrame:NO];
    }
}

#pragma mark AVCaptureOutputDelegate method
- (void) captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if (!_isRecording) {
        return;
    }
    // pass frame to encoders
    
    
    if (connection == _audioConnection) {
        [_aacEncoder encodeSampleBuffer:sampleBuffer];
        return;
    }
    else{
        _videoConnection = connection;
        if(_videoConnection.videoOrientation != AVCaptureVideoOrientationPortrait){
            _videoConnection.videoOrientation = AVCaptureVideoOrientationPortrait;
        }
        
    }
    
    if (!_hasScreenshot) {
        UIImage *image = [self imageFromSampleBuffer:sampleBuffer];
        NSString *path = [self.hlsWriter.directoryPath stringByAppendingPathComponent:@"thumb.jpg"];
        NSData *imageData = UIImageJPEGRepresentation(image, 0.7);
        [imageData writeToFile:path atomically:NO];
        _hasScreenshot = YES;
    }
    [_h264Encoder encodeSampleBuffer:sampleBuffer];
    
    
}

// Create a UIImage from sample buffer data
- (UIImage *) imageFromSampleBuffer:(CMSampleBufferRef) sampleBuffer
{
    // Get a CMSampleBuffer's Core Video image buffer for the media data
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    // Lock the base address of the pixel buffer
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    // Get the number of bytes per row for the pixel buffer
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    
    // Get the number of bytes per row for the pixel buffer
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    // Get the pixel buffer width and height
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    // Create a device-dependent RGB color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    // Create a bitmap graphics context with the sample buffer data
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8,
                                                 bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    // Create a Quartz image from the pixel data in the bitmap graphics context
    CGImageRef quartzImage = CGBitmapContextCreateImage(context);
    // Unlock the pixel buffer
    CVPixelBufferUnlockBaseAddress(imageBuffer,0);
    
    // Free up the context and color space
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    // Create an image object from the Quartz image
    UIImage *image = [UIImage imageWithCGImage:quartzImage];
    
    // Release the Quartz image
    CGImageRelease(quartzImage);
    
    return (image);
}


- (void) setupSession {
    _session = [[AVCaptureSession alloc] init];
    [self setupVideoCapture];
    [self setupAudioCapture];
    
    // start capture and a preview layer
    dispatch_async(dispatch_get_main_queue(), ^{
        [_session startRunning];
        _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:_session];
        _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    });
    
}

- (void) startRecording {
    
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    [self.locationManager startUpdatingLocation];
    [[KFAPIClient sharedClient] startNewStream:^(KFStream *endpointResponse, NSError *error) {
        if (error) {
            if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidStartRecording:error:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate recorderDidStartRecording:self error:error];
                });
            }
            return;
        }
        self.stream = endpointResponse;
        [self setStreamStartLocation];
        if ([endpointResponse isKindOfClass:[KFS3Stream class]]) {
            KFS3Stream *s3Endpoint = (KFS3Stream*)endpointResponse;
            s3Endpoint.streamState = KFStreamStateStreaming;
            [self setupHLSWriterWithEndpoint:s3Endpoint];
            
            [[KFHLSMonitor sharedMonitor] startMonitoringFolderPath:_hlsWriter.directoryPath endpoint:s3Endpoint delegate:self];
            
            NSError *error = nil;
            [_hlsWriter prepareForWriting:&error];
            if (error) {
                DDLogError(@"Error preparing for writing: %@", error);
            }
            self.isRecording = YES;
            if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidStartRecording:error:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate recorderDidStartRecording:self error:nil];
                });
            }
        }
    }];
    
}


- (void)pause{
    
}

- (void)checkLocationPermission{
    if ([CLLocationManager locationServicesEnabled]) {
        switch ([CLLocationManager authorizationStatus]) {
            case kCLAuthorizationStatusAuthorized:
            {
                UIAlertView *alert= [[UIAlertView alloc]initWithTitle:@"OK" message:@"Can use" delegate:nil cancelButtonTitle:@"Ok" otherButtonTitles: nil];
                [alert show];
                alert= nil;
            }
                
                break;
            case kCLAuthorizationStatusDenied:
            {
                UIAlertView *alert= [[UIAlertView alloc]initWithTitle:@"Error" message:@"App level settings has been denied" delegate:nil cancelButtonTitle:@"Ok" otherButtonTitles: nil];
                [alert show];
                alert= nil;
            }
                break;
            case kCLAuthorizationStatusNotDetermined:
            {
                UIAlertView *alert= [[UIAlertView alloc]initWithTitle:@"Error" message:@"The user is yet to provide the permission" delegate:nil cancelButtonTitle:@"Ok" otherButtonTitles: nil];
                [alert show];
                alert= nil;
            }
                break;
            case kCLAuthorizationStatusRestricted:
            {
                UIAlertView *alert= [[UIAlertView alloc]initWithTitle:@"Error" message:@"The app is recstricted from using location services." delegate:nil cancelButtonTitle:@"Ok" otherButtonTitles: nil];
                [alert show];
                alert= nil;
            }
                break;
                
            default:
                break;
        }
    }
    else{
        UIAlertView *alert= [[UIAlertView alloc]initWithTitle:@"Error" message:@"The location services seems to be disabled from the settings." delegate:nil cancelButtonTitle:@"Ok" otherButtonTitles: nil];
        [alert show];
        alert= nil;
    }
}


- (void) startRecordingWithParam:(NSDictionary*)parameters{
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    if ([self.locationManager respondsToSelector:@selector(requestWhenInUseAuthorization)]) {
        [self.locationManager requestWhenInUseAuthorization];
    }
    
    [self.locationManager startUpdatingLocation];
    [[KFAPIClient sharedClient] startStreamWithParameters:parameters callbackBlock:^(KFStream *endpointResponse, NSError *error) {
        if (error) {
            if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidStartRecording:error:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate recorderDidStartRecording:self error:error];
                });
            }
            return;
        }
        self.stream = endpointResponse;
        [self setStreamStartLocation];
        if ([endpointResponse isKindOfClass:[KFS3Stream class]]) {
            KFS3Stream *s3Endpoint = (KFS3Stream*)endpointResponse;
            s3Endpoint.streamState = KFStreamStateStreaming;
            [self setupHLSWriterWithEndpoint:s3Endpoint];
            
            [[KFHLSMonitor sharedMonitor] startMonitoringFolderPath:_hlsWriter.directoryPath endpoint:s3Endpoint delegate:self];
            
            NSError *error = nil;
            [_hlsWriter prepareForWriting:&error];
            if (error) {
                DDLogError(@"Error preparing for writing: %@", error);
            }
            self.isRecording = YES;
            if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidStartRecording:error:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate recorderDidStartRecording:self error:nil];
                });
            }
        }
    }];
}


- (void) reverseGeocodeStream:(KFStream*)stream {
    CLLocation *location = nil;
    CLLocation *endLocation = stream.endLocation;
    CLLocation *startLocation = stream.startLocation;
    if (startLocation) {
        location = startLocation;
    }
    if (endLocation) {
        location = endLocation;
    }
    if (!location) {
        return;
    }
    CLGeocoder *geocoder = [[CLGeocoder alloc] init];
    [geocoder reverseGeocodeLocation:location completionHandler:^(NSArray *placemarks, NSError *error) {
        if (error) {
            DDLogError(@"Error geocoding stream: %@", error);
            return;
        }
        if (placemarks.count == 0) {
            return;
        }
        CLPlacemark *placemark = [placemarks firstObject];
        stream.city = placemark.locality;
        stream.state = placemark.administrativeArea;
        stream.country = placemark.country;
        [self.delegate updateLocation:self];
        [[KFAPIClient sharedClient] updateMetadataForStream:stream callbackBlock:^(KFStream *updatedStream, NSError *error) {
            if (error) {
                DDLogError(@"Error updating stream geocoder info: %@", error);
            }
        }];
    }];
}

- (void) stopRecording {
    [self.locationManager stopUpdatingLocation];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self.lastLocation) {
            self.stream.endLocation = self.lastLocation;
            [[KFAPIClient sharedClient] updateMetadataForStream:self.stream callbackBlock:^(KFStream *updatedStream, NSError *error) {
                if (error) {
                    DDLogError(@"Error updating stream endLocation: %@", error);
                }
            }];
        }
        [_session stopRunning];
        self.isRecording = NO;
        NSError *error = nil;
        [_hlsWriter finishWriting:&error];
        if (error) {
            DDLogError(@"Error stop recording: %@", error);
        }
        [[KFAPIClient sharedClient] stopStream:self.stream callbackBlock:^(BOOL success, NSError *error) {
            if (!success) {
                DDLogError(@"Error stopping stream: %@", error);
            } else {
                DDLogVerbose(@"Stream stopped: %@", self.stream.streamID);
            }
        }];
        if ([self.stream isKindOfClass:[KFS3Stream class]]) {
            [[KFHLSMonitor sharedMonitor] finishUploadingContentsAtFolderPath:_hlsWriter.directoryPath endpoint:(KFS3Stream*)self.stream];
        }
        if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidFinishRecording:error:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate recorderDidFinishRecording:self error:error];
            });
        }
    });
}

-(void)stopSession{
    [_session stopRunning];
    //    self.isRecording = NO;
    //    NSError *error = nil;
    //    [_hlsWriter finishWriting:&error];
}

-(void)startSession{
    [self setupVideoCaptureWithCapturePosition:_device];
    [self setupAudioCapture];
    dispatch_async(dispatch_get_main_queue(), ^{
        [_session startRunning];
        //        KFStream * endpointResponse = self.stream;
        //        if ([endpointResponse isKindOfClass:[KFS3Stream class]]) {
        //            KFS3Stream *s3Endpoint = (KFS3Stream*)endpointResponse;
        //            s3Endpoint.streamState = KFStreamStateStreaming;
        //            [self setupHLSWriterWithEndpoint:s3Endpoint];
        //
        //            [[KFHLSMonitor sharedMonitor] startMonitoringFolderPath:_hlsWriter.directoryPath endpoint:s3Endpoint delegate:self];
        //
        //            NSError *error = nil;
        //            [_hlsWriter prepareForWriting:&error];
        //            if (error) {
        //                DDLogError(@"Error preparing for writing: %@", error);
        //            }
        //            self.isRecording = YES;
        //        }
    });
}


- (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
    AVCaptureDevice *captureDevice = [devices firstObject];
    
    for (AVCaptureDevice *device in devices)
    {
        if ([device position] == position)
        {
            captureDevice = device;
            break;
        }
    }
    
    return captureDevice;
}



//


- (void)setTorchMode:(UIButton *)btn{
    
    
    AVCaptureTorchMode torchMode = [self videoDevices].torchMode;
    AVCaptureDevice *device  = [self videoDevices];
    NSError *error = nil;
    if ([device lockForConfiguration:&error]){
        if (torchMode == AVCaptureTorchModeOn) {
            
            [device setTorchMode:AVCaptureTorchModeOff];
            
        }
        else{
            
            [device setTorchMode:AVCaptureTorchModeOn];
            
        }
        [device unlockForConfiguration];
    }
}


- (AVCaptureDeviceInput*)currentDeviceInputForMediaType:(NSString*)mediaType {
    for (AVCaptureDeviceInput* deviceInput in [self session].inputs) {
        if ([deviceInput.device hasMediaType:mediaType]) {
            return deviceInput;
        }
    }
    
    return nil;
}


- (AVCaptureDevice *)videoDeviceForPosition:(AVCaptureDevicePosition)position {
    NSArray *videoDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    
    for (AVCaptureDevice *device in videoDevices) {
        if (device.position == (AVCaptureDevicePosition)position) {
            return device;
        }
    }
    
    return nil;
}

- (AVCaptureDevice*)videoDevices {
    
    
    return [self videoDeviceForPosition:_device];
}



- (void)reconfigureVideoInput:(BOOL)shouldConfigureVideo audioInput:(BOOL)shouldConfigureAudio {
}


- (BOOL)switchCameraWithButton:(UIButton *)btn
{
    //    [self stopSession];
    switch (_device)
    {
        case AVCaptureDevicePositionUnspecified:
            _device = AVCaptureDevicePositionBack;
            _isHasFlash = true;
            break;
        case AVCaptureDevicePositionBack:
            _device = AVCaptureDevicePositionFront;
            _isHasFlash = false;
            break;
        case AVCaptureDevicePositionFront:
            _device = AVCaptureDevicePositionBack;
            _isHasFlash = true;
            break;
    }
    
    
    [self beginConfiguration];
    NSError *videoError = nil;
    [self configureDevice:[self videoDevices] mediaType:AVMediaTypeVideo error:&videoError];
    [self commitConfiguration];
    
    
    //    [self startSession];
    
    
    return _isHasFlash;
    
}






// Find a camera with the specificed AVCaptureDevicePosition, returning nil if one is not found
- (AVCaptureDevice *) cameraWithPosition:(AVCaptureDevicePosition) position
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices) {
        if ([device position] == position) {
            return device;
        }
    }
    return nil;
}

// Find a front facing camera, returning nil if one is not found
- (AVCaptureDevice *) frontFacingCamera
{
    return [self cameraWithPosition:AVCaptureDevicePositionFront];
}



- (AVCaptureConnection *)_currentCaptureConnection
{
    AVCaptureConnection *videoConnection = nil;
    
    for (AVCaptureConnection *connection in self.videoOutput.connections) {
        for (AVCaptureInputPort *port in [connection inputPorts]) {
            if ([[port mediaType] isEqual:AVMediaTypeVideo]) {
                videoConnection = connection;
                break;
            }
        }
        
        if (videoConnection) {
            break;
        }
    }
    
    return videoConnection;
}





- (void) uploader:(KFHLSUploader *)uploader didUploadSegmentAtURL:(NSURL *)segmentURL uploadSpeed:(double)uploadSpeed numberOfQueuedSegments:(NSUInteger)numberOfQueuedSegments {
    DDLogInfo(@"Uploaded segment %@ @ %f KB/s, numberOfQueuedSegments %d", segmentURL, uploadSpeed, numberOfQueuedSegments);
    if ([Kickflip useAdaptiveBitrate]) {
        double currentUploadBitrate = uploadSpeed * 8 * 1024; // bps
        double maxBitrate = [Kickflip maxBitrate];
        
        double newBitrate = currentUploadBitrate * 0.5;
        if (newBitrate > maxBitrate) {
            newBitrate = maxBitrate;
        }
        if (newBitrate < _minBitrate) {
            newBitrate = _minBitrate;
        }
        double newVideoBitrate = newBitrate - self.aacEncoder.bitrate;
        self.h264Encoder.bitrate = newVideoBitrate;
    }
}

- (void) uploader:(KFHLSUploader *)uploader liveManifestReadyAtURL:(NSURL *)manifestURL {
    if (self.delegate && [self.delegate respondsToSelector:@selector(recorder:streamReadyAtURL:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate recorder:self streamReadyAtURL:manifestURL];
        });
    }
    DDLogVerbose(@"Manifest ready at URL: %@", manifestURL);
}

- (void) locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    self.lastLocation = [locations lastObject];
    [self setStreamStartLocation];
}

- (void) setStreamStartLocation {
    if (!self.lastLocation) {
        return;
    }
    if (self.stream && !self.stream.startLocation) {
        self.stream.startLocation = self.lastLocation;
        [[KFAPIClient sharedClient] updateMetadataForStream:self.stream callbackBlock:^(KFStream *updatedStream, NSError *error) {
            
            if (error) {
                DDLogError(@"Error updating stream startLocation: %@", error);
            }
        }];
        [self reverseGeocodeStream:self.stream];
    }
}


- (void)beginConfiguration {
    if (_session != nil) {
        _beginSessionConfigurationCount++;
        if (_beginSessionConfigurationCount == 1) {
            [_session beginConfiguration];
        }
    }
}

- (void)commitConfiguration {
    if (_session != nil) {
        _beginSessionConfigurationCount--;
        if (_beginSessionConfigurationCount == 0) {
            [_session commitConfiguration];
        }
    }
}



- (void)configureDevice:(AVCaptureDevice*)newDevice mediaType:(NSString*)mediaType error:(NSError**)error {
    AVCaptureDeviceInput *currentInput = [self currentDeviceInputForMediaType:mediaType];
    AVCaptureDevice *currentUsedDevice = currentInput.device;
    
    if (currentUsedDevice != newDevice) {
        if ([mediaType isEqualToString:AVMediaTypeVideo]) {
            NSError *error;
            if ([newDevice lockForConfiguration:&error]) {
                if (newDevice.isSmoothAutoFocusSupported) {
                    newDevice.smoothAutoFocusEnabled = YES;
                }
                newDevice.subjectAreaChangeMonitoringEnabled = true;
                
                if (newDevice.isLowLightBoostSupported) {
                    newDevice.automaticallyEnablesLowLightBoostWhenAvailable = YES;
                }
                [newDevice unlockForConfiguration];
            } else {
                NSLog(@"Failed to configure device: %@", error);
            }
            //            _videoInputAdded = NO;
        } else {
            //            _audioInputAdded = NO;
        }
        
        AVCaptureDeviceInput *newInput = nil;
        
        if (newDevice != nil) {
            newInput = [[AVCaptureDeviceInput alloc] initWithDevice:newDevice error:error];
        }
        
        if (*error == nil) {
            if (currentInput != nil) {
                [_session removeInput:currentInput];
                if ([currentInput.device hasMediaType:AVMediaTypeVideo]) {
                    
                }
            }
            
            if (newInput != nil) {
                if ([_session canAddInput:newInput]) {
                    [_session addInput:newInput];
                    if ([newInput.device hasMediaType:AVMediaTypeVideo]) {
                        _videoConnection.videoOrientation = AVCaptureVideoOrientationPortrait;
                        
                        //                        AVCaptureConnection *videoConnection = [self videoConnection];
                        //                        if ([_videoConnection isVideoStabilizationSupported]) {
                        //                            if ([_videoConnection respondsToSelector:@selector(setPreferredVideoStabilizationMode:)]) {
                        //                                _videoConnection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
                        //                            } else {
                        //#pragma clang diagnostic push
                        //#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        //                                _videoConnection.enablesVideoStabilizationWhenAvailable = YES;
                        //#pragma clang diagnostic pop
                        //                            }
                        //                        }
                    } else {
                        //                        _audioInputAdded = YES;
                    }
                } else {
                    //                    *error = [SCRecorder createError:@"Failed to add input to capture session"];
                }
            }
        }
    }
    
}


@end
