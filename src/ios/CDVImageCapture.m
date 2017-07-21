/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVImageCapture.h"
#import "CDVJpegHeaderWriter.h"
#import "AppDelegate.h"
#import "UIImage+CropScaleOrientation.h"
#import <ImageIO/CGImageProperties.h>
#import <AssetsLibrary/ALAssetRepresentation.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/CGImageSource.h>
#import <ImageIO/CGImageProperties.h>
#import <ImageIO/CGImageDestination.h>
#import <MobileCoreServices/UTCoreTypes.h>
#import <objc/message.h>

#ifndef __CORDOVA_4_0_0
    #import <Cordova/NSData+Base64.h>
#endif

#define CDV_PHOTO_PREFIX @"cdv_photo_"

static NSSet* org_apache_cordova_validArrowDirections;

static NSString* toBase64(NSData* data) {
    SEL s1 = NSSelectorFromString(@"cdv_base64EncodedString");
    SEL s2 = NSSelectorFromString(@"base64EncodedString");
    SEL s3 = NSSelectorFromString(@"base64EncodedStringWithOptions:");

    if ([data respondsToSelector:s1]) {
        NSString* (*func)(id, SEL) = (void *)[data methodForSelector:s1];
        return func(data, s1);
    } else if ([data respondsToSelector:s2]) {
        NSString* (*func)(id, SEL) = (void *)[data methodForSelector:s2];
        return func(data, s2);
    } else if ([data respondsToSelector:s3]) {
        NSString* (*func)(id, SEL, NSUInteger) = (void *)[data methodForSelector:s3];
        return func(data, s3, 0);
    } else {
        return nil;
    }
}

@implementation CDVPictureOptions

+ (instancetype) createFromTakePictureArguments:(CDVInvokedUrlCommand*)command
{
    CDVPictureOptions* pictureOptions = [[CDVPictureOptions alloc] init];

    pictureOptions.quality = [command argumentAtIndex:0 withDefault:@(50)];
    pictureOptions.destinationType = [[command argumentAtIndex:1 withDefault:@(DestinationTypeFileUri)] unsignedIntegerValue];
    pictureOptions.sourceType = [[command argumentAtIndex:2 withDefault:@(UIImagePickerControllerSourceTypeCamera)] unsignedIntegerValue];

    NSNumber* targetWidth = [command argumentAtIndex:3 withDefault:nil];
    NSNumber* targetHeight = [command argumentAtIndex:4 withDefault:nil];
    pictureOptions.targetSize = CGSizeMake(0, 0);
    if ((targetWidth != nil) && (targetHeight != nil)) {
        pictureOptions.targetSize = CGSizeMake([targetWidth floatValue], [targetHeight floatValue]);
    }

    pictureOptions.encodingType = [[command argumentAtIndex:5 withDefault:@(EncodingTypeJPEG)] unsignedIntegerValue];
    pictureOptions.mediaType = [[command argumentAtIndex:6 withDefault:@(MediaTypePicture)] unsignedIntegerValue];
    pictureOptions.allowsEditing = [[command argumentAtIndex:7 withDefault:@(NO)] boolValue];
    pictureOptions.correctOrientation = [[command argumentAtIndex:8 withDefault:@(NO)] boolValue];
    pictureOptions.saveToPhotoAlbum = [[command argumentAtIndex:9 withDefault:@(NO)] boolValue];
    pictureOptions.popoverOptions = [command argumentAtIndex:10 withDefault:nil];
    pictureOptions.cameraDirection = [[command argumentAtIndex:11 withDefault:@(UIImagePickerControllerCameraDeviceRear)] unsignedIntegerValue];

    pictureOptions.popoverSupported = NO;
    pictureOptions.usesGeolocation = NO;

    return pictureOptions;
}

@end


@interface CDVImageCapture ()

@property (readwrite, assign) BOOL hasPendingOperation;
@property (assign, nonatomic) AVCaptureDevicePosition position;
@property (nonatomic) AVCapturePhotoOutput* avCapture;
@property (nonatomic) AVCapturePhotoSettings* avSettings;
@property (nonatomic) UIView* camview;
@property (nonatomic) AVCaptureVideoPreviewLayer* previewLayer;
@property (nonatomic) AVCaptureSession* session;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, assign) CGSize targetSize;
@property (nonatomic, assign) CGSize defaultSize;
@property (readwrite, assign) BOOL redEyeReduction;
@property (assign, nonatomic) UIDeviceOrientation orientation;
@end


@implementation CDVImageCapture

+ (void)initialize
{
    org_apache_cordova_validArrowDirections = [[NSSet alloc] initWithObjects:[NSNumber numberWithInt:UIPopoverArrowDirectionUp], [NSNumber numberWithInt:UIPopoverArrowDirectionDown], [NSNumber numberWithInt:UIPopoverArrowDirectionLeft], [NSNumber numberWithInt:UIPopoverArrowDirectionRight], [NSNumber numberWithInt:UIPopoverArrowDirectionAny], nil];
}

@synthesize hasPendingOperation, pickerController, locationManager;

- (NSURL*) urlTransformer:(NSURL*)url
{
    NSURL* urlToTransform = url;

    // for backwards compatibility - we check if this property is there
    SEL sel = NSSelectorFromString(@"urlTransformer");
    if ([self.commandDelegate respondsToSelector:sel]) {
        // grab the block from the commandDelegate
        NSURL* (^urlTransformer)(NSURL*) = ((id(*)(id, SEL))objc_msgSend)(self.commandDelegate, sel);
        // if block is not null, we call it
        if (urlTransformer) {
            urlToTransform = urlTransformer(url);
        }
    }

    return urlToTransform;
}

- (BOOL)usesGeolocation
{
    id useGeo = [self.commandDelegate.settings objectForKey:[@"CameraUsesGeolocation" lowercaseString]];
    return [(NSNumber*)useGeo boolValue];
}

- (BOOL)popoverSupported
{
    return (NSClassFromString(@"UIPopoverController") != nil) &&
           (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
}

- (void)takePicture:(CDVInvokedUrlCommand*)command
{

    self.redEyeReduction  = command.arguments[0];
    NSNumber* imageHeight = [command argumentAtIndex:1 withDefault:nil];
    NSNumber* imageWidth = [command argumentAtIndex:2 withDefault:nil];
    _targetSize = CGSizeMake(0, 0);
    if ((imageHeight != nil) && (imageWidth != nil)) {
        _targetSize = CGSizeMake([imageWidth floatValue], [imageHeight floatValue]);
    }
    NSString *fillLightMode  = command.arguments[3];
    NSString *cameraDirection  = command.arguments[4];
    AVCaptureDevice *inputDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];

    if([cameraDirection isEqualToString:@"frontcamera"]){
        inputDevice = [self getCaptureDevice:AVCaptureDevicePositionFront];
    }
    else if([cameraDirection isEqualToString:@"rearcamera"]){
        inputDevice = [self getCaptureDevice:AVCaptureDevicePositionBack];

    }

    [inputDevice lockForConfiguration:nil];
    if([fillLightMode isEqualToString:@"flash"] && [inputDevice isFlashModeSupported:AVCaptureFlashModeOn]){
        [inputDevice setFlashMode:AVCaptureFlashModeOn];
        // [inputDevice setTorchMode:AVCaptureTorchModeOn];
    }
    else if([fillLightMode isEqualToString:@"off"] && [inputDevice isFlashModeSupported:AVCaptureFlashModeOff]){
        [inputDevice setFlashMode:AVCaptureFlashModeOff];
    }
    else if([fillLightMode isEqualToString:@"auto"] && [inputDevice isFlashModeSupported:AVCaptureFlashModeAuto]){
        [inputDevice setFlashMode:AVCaptureFlashModeAuto];
        //  [inputDevice setTorchMode:AVCaptureTorchModeAuto];
    }
    [inputDevice unlockForConfiguration];
    [self restrictToPortraitMode:YES];
    //store callback to use in delegate
    self.command = command;
    self.session = [[AVCaptureSession alloc] init];
    //[self.session setSessionPreset:AVCaptureSessionPresetHigh];

    NSError *error;
    AVCaptureDeviceInput *deviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:inputDevice error:&error];

    if ([self.session canAddInput:deviceInput]) {
        [self.session addInput:deviceInput];
    }

    _avCapture = [[AVCapturePhotoOutput alloc]init];
    _avSettings = [AVCapturePhotoSettings photoSettings];
    // self.movieOutput = [[AVCaptureMovieFileOutput alloc] init];
    [self.session addOutput:self.avCapture];
    AVCaptureConnection *connection = [self.avCapture connectionWithMediaType:AVMediaTypeVideo];
    [connection setVideoOrientation:AVCaptureVideoOrientationPortrait];
    if (connection.active)
    {
            //connection is active
        NSLog(@"active");
        _previewLayer = [[AVCaptureVideoPreviewLayer alloc ] initWithSession:self.session];
        _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        _previewLayer.frame = self.webView.bounds;
        [self.webView.layer addSublayer:self.previewLayer];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationChanged)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
        [self.session startRunning];
        _button = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.button addTarget:self action:@selector(takePhoto) forControlEvents:UIControlEventTouchUpInside];
        [self.button setTitle:@"Capture" forState:UIControlStateNormal];
        self.button.frame = CGRectMake(0,0,100,50);
        _camview = [[UIView alloc]initWithFrame:CGRectMake(0, self.webView.frame.size.height-80, self.webView.frame.size.width, 80)];
        [self.camview setBackgroundColor:[UIColor blackColor]];
        [self.webView addSubview:self.camview];
        self.button.center = _camview.center;
        [self.webView addSubview:self.button];

    }
    else
    {
        NSLog(@"Connection is not active");

    }


    //   [self.avCapture capturePhotoWithSettings:_avSettings delegate:weakSelf];


}

-(void) restrictToPortraitMode:(BOOL) orientation {
    AppDelegate* appDelegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
    appDelegate.restrictToPortrait = orientation;
}

- (void) orientationChanged {
    
    self.orientation = [UIDevice currentDevice].orientation;
    _previewLayer.frame = self.webView.bounds;
    
    //  approach 2
    
//    if(self.orientationSet == NO)
//        self.orientation = [UIDevice currentDevice].orientation;
//    
//    _previewLayer.frame = self.webView.bounds;
//    self.orientationSet = YES;
    
    // calls orientationChanged() event again; flag used to store previous orientation
    
//    NSNumber *value = [NSNumber numberWithInt:UIInterfaceOrientationPortrait];
//    [[UIDevice currentDevice] setValue:value forKey:@"orientation"];
//    
//    self.orientationSet = NO;
//    ------approach 2 ends------

//    if([self.session isRunning]){
//        UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
//        _previewLayer.frame = self.webView.bounds;
//        [self.camview removeFromSuperview];
//        [self.button removeFromSuperview];
//
//        // another way to achieve previewLyer Orientation
//
//        //   [ _previewLayer.connection setVideoOrientation:[[UIApplication sharedApplication] statusBarOrientation]];
//
//        if (deviceOrientation == UIDeviceOrientationPortraitUpsideDown){
//            [_previewLayer.connection setVideoOrientation:AVCaptureVideoOrientationPortraitUpsideDown];
//            //        _camview = [[UIView alloc]initWithFrame:CGRectMake(self.webView.frame.size.width-80,0,80,self.webView.frame.size.height)];
//        }
//        else if (deviceOrientation == UIDeviceOrientationPortrait){
//            [_previewLayer.connection setVideoOrientation:AVCaptureVideoOrientationPortrait];
//            _camview = [[UIView alloc]initWithFrame:CGRectMake(0, _previewLayer.frame.size.height-80, _previewLayer.frame.size.width, 80)];
//        }
//        else if (deviceOrientation == UIDeviceOrientationLandscapeLeft){
//            [_previewLayer.connection setVideoOrientation:AVCaptureVideoOrientationLandscapeRight];
//            _camview = [[UIView alloc]initWithFrame:CGRectMake(_previewLayer.frame.size.width-80,0,80,_previewLayer.frame.size.height)];
//        }
//        else if(deviceOrientation == UIDeviceOrientationLandscapeRight){
//            [_previewLayer.connection setVideoOrientation:AVCaptureVideoOrientationLandscapeLeft];
//            _camview = [[UIView alloc]initWithFrame:CGRectMake(0,0,80,_previewLayer.frame.size.height)];
//        }
//        else {
//            // TODO  - should we reject other device orientations such as UIDeviceOrientationFaceDown ,UIDeviceOrientationFaceUp,UIDeviceOrientationUnknown
//        }
//        _orientation = deviceOrientation;
//        [self.camview setBackgroundColor:[UIColor blackColor]];
//        [self.webView addSubview:self.camview];
//        self.button.center = _camview.center;
//        [self.webView addSubview:self.button];
//    }
}

- (AVCaptureDevice *)getCaptureDevice:(int)facing
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices) {
        if ([device position] == facing) {
            return device;
        }
    }
    return nil;
}

-(void)takePhoto
{
    __weak CDVImageCapture* weakSelf = self;
    [self restrictToPortraitMode:NO];
    [self.avCapture capturePhotoWithSettings:_avSettings delegate:weakSelf];

}
    // AVPhotoCaptureDelegate

-(void)captureOutput:(AVCapturePhotoOutput *)captureOutput didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)photoSampleBuffer previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings bracketSettings:(AVCaptureBracketedStillImageSettings *)bracketSettings error:(NSError *)error
{
    if (error) {
        NSLog(@"error : %@", error.localizedDescription);
    }

    if (photoSampleBuffer) {
        NSData *data = [AVCapturePhotoOutput JPEGPhotoDataRepresentationForJPEGSampleBuffer:photoSampleBuffer previewPhotoSampleBuffer:previewPhotoSampleBuffer];
        UIImage *image = [UIImage imageWithData:data];
        if(self.orientation == UIDeviceOrientationLandscapeRight){
            image = [[UIImage alloc] initWithCGImage: image.CGImage
                                               scale: 1.0
                                         orientation: UIImageOrientationDown];
        }
        else if(self.orientation == UIDeviceOrientationLandscapeLeft){
            image = [[UIImage alloc] initWithCGImage: image.CGImage
                                               scale: 1.0
                                         orientation: UIImageOrientationUp];
        }
        NSLog(@"%f", image.size.height);
        NSLog(@"%f", image.size.width);
        _defaultSize = CGSizeMake(image.size.width , image.size.height);
        NSData *imageData = UIImageJPEGRepresentation(image, 1.0);
        UIImage* scaledImage = nil;
        if((self.targetSize.width > 0) && (self.targetSize.height >0)){
            // scaledImage = [image imageByScalingNotCroppingForSize:self.targetSize];
            if (CGSizeEqualToSize(image.size, self.targetSize) == NO) {
                UIGraphicsBeginImageContext( self.targetSize);
                [image drawInRect:CGRectMake(0,0,self.targetSize.width,self.targetSize.height)];
                scaledImage = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                imageData = UIImageJPEGRepresentation(scaledImage, 1.0);
            }
        }
        NSLog(@"%f", scaledImage.size.height);
        NSLog(@"%f", scaledImage.size.width);
        //  red eye reduction -- more testing required

        //        if(self.redEyeReduction == YES){
        //        CIImage *img = [CIImage imageWithData:data];
        //        NSArray* adjustments = [img autoAdjustmentFiltersWithOptions:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:NO] forKey:kCIImageAutoAdjustEnhance]];
        //        for (CIFilter *filter in adjustments) {
        //            [filter setValue:img forKey:kCIInputImageKey];
        //            img = filter.outputImage;
        //        }
        //        UIImage *newimage = [[UIImage alloc] initWithCIImage:img];
        //        imageData = UIImageJPEGRepresentation(newimage, 1.0);
        //        }

        NSString *base64 = [imageData base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:base64];
        [self.commandDelegate sendPluginResult:result callbackId:self.command.callbackId];
        [self.session stopRunning];
        [self.previewLayer removeFromSuperlayer];
        [self.camview removeFromSuperview];
        [self.button removeFromSuperview];
    }
}

// Delegate for camera permission UIAlertView
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    // If Settings button (on iOS 8), open the settings app
    if (buttonIndex == 1) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
        if (&UIApplicationOpenSettingsURLString != NULL) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
        }
#pragma clang diagnostic pop
    }

    // Dismiss the view
    [[self.pickerController presentingViewController] dismissViewControllerAnimated:YES completion:nil];

    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"has no access to camera"];   // error callback expects string ATM

    [self.commandDelegate sendPluginResult:result callbackId:self.pickerController.callbackId];

    self.hasPendingOperation = NO;
    self.pickerController = nil;
}

- (void)repositionPopover:(CDVInvokedUrlCommand*)command
{
    if (([[self pickerController] pickerPopoverController] != nil) && [[[self pickerController] pickerPopoverController] isPopoverVisible]) {

        [[[self pickerController] pickerPopoverController] dismissPopoverAnimated:NO];

        NSDictionary* options = [command argumentAtIndex:0 withDefault:nil];
        [self displayPopover:options];
    }
}
- (void)getPhotoCapabilities:(CDVInvokedUrlCommand*)command
{
    NSString *desc  = command.arguments[0];


    if([desc isEqualToString:@"frontcamera"]){
        _position = AVCaptureDevicePositionFront;
    }
    else if([desc isEqualToString:@"rearcamera"]){
        _position = AVCaptureDevicePositionBack;
    }

    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    NSMutableArray *flashMode = [[NSMutableArray alloc] initWithCapacity:10];
    NSMutableDictionary *photocapabilities = [NSMutableDictionary dictionaryWithCapacity:10];
    for (AVCaptureDevice *device in devices){
        if(device.position == _position){
            if([device isFlashModeSupported:AVCaptureFlashModeOn]){
                [flashMode addObject:@"flash"];
            }
            if([device isFlashModeSupported:AVCaptureFlashModeOff]){
                [flashMode addObject:@"off"];
            }
            if([device isFlashModeSupported:AVCaptureFlashModeAuto]){
                [flashMode addObject:@"auto"];
            }
            if([device isTorchModeSupported:AVCaptureTorchModeOn]){
                [flashMode addObject:@"torch"];
            }
            if([device hasFlash] == NO){
                [flashMode addObject:@"unavailable"];
            }
            [photocapabilities setObject:flashMode forKey:@"fillLightMode"];

            int max_w = 0;
            int min_w = INT_MAX;
            int max_h = 0;
            int min_h = INT_MAX;

            NSArray* availFormats=device.formats;
            for (AVCaptureDeviceFormat* format in availFormats) {
                CMVideoDimensions resolution = format.highResolutionStillImageDimensions;
                int w = resolution.width;
                int h = resolution.height;
                NSLog(@"width=%d height=%d", w, h);

                if (w > max_w) {
                    max_w = w;
                }
                if (w < min_w) {
                    min_w = w;
                }
                if (h > max_h) {
                    max_h = h;
                }
                if (h < min_h) {
                    min_h = h;
                }
            }

            NSDictionary *imageHeight = @{
                @"max": [NSNumber numberWithInteger:max_h],
                @"min": [NSNumber numberWithInteger:min_h],
                @"step": [NSNumber numberWithInteger:0]
            };
            [photocapabilities setObject:imageHeight forKey:@"imageHeight"];

            NSDictionary *imageWidth = @{
                @"max": [NSNumber numberWithInteger:max_w],
                @"min": [NSNumber numberWithInteger:min_w],
                @"step": [NSNumber numberWithInteger:0]
            };
            [photocapabilities setObject:imageWidth forKey:@"imageWidth"];

            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:photocapabilities];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }
    }

}

- (void)getPhotoSettings:(CDVInvokedUrlCommand*)command
{
    NSString *desc  = command.arguments[0];
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSMutableDictionary *photoSettings = [NSMutableDictionary dictionaryWithCapacity:4];
    if([desc isEqualToString:@"frontcamera"]){
        device = [self getCaptureDevice:AVCaptureDevicePositionFront];
    }
    else if([desc isEqualToString:@"rearcamera"]){
        device = [self getCaptureDevice:AVCaptureDevicePositionBack];;
    }

    if([device flashMode] == AVCaptureFlashModeOff){
        [photoSettings setObject:@"off" forKey:@"fillLightMode"];
    }
    else if([device flashMode] == AVCaptureFlashModeOn){
        [photoSettings setObject:@"flash" forKey:@"fillLightMode"];
    }
    else if([device flashMode] == AVCaptureFlashModeAuto){
        [photoSettings setObject:@"auto" forKey:@"fillLightMode"];
    }
    if((self.defaultSize.width > 0) && (self.defaultSize.height >0)){
        [photoSettings setObject:[NSNumber numberWithFloat:self.defaultSize.width] forKey:@"imageWidth"];
        [photoSettings setObject:[NSNumber numberWithFloat:self.defaultSize.height] forKey:@"imageHeight"];

    }

    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:photoSettings];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];

}

- (NSInteger)integerValueForKey:(NSDictionary*)dict key:(NSString*)key defaultValue:(NSInteger)defaultValue
{
    NSInteger value = defaultValue;

    NSNumber* val = [dict valueForKey:key];  // value is an NSNumber

    if (val != nil) {
        value = [val integerValue];
    }
    return value;
}

- (void)displayPopover:(NSDictionary*)options
{
    NSInteger x = 0;
    NSInteger y = 32;
    NSInteger width = 320;
    NSInteger height = 480;
    UIPopoverArrowDirection arrowDirection = UIPopoverArrowDirectionAny;

    if (options) {
        x = [self integerValueForKey:options key:@"x" defaultValue:0];
        y = [self integerValueForKey:options key:@"y" defaultValue:32];
        width = [self integerValueForKey:options key:@"width" defaultValue:320];
        height = [self integerValueForKey:options key:@"height" defaultValue:480];
        arrowDirection = [self integerValueForKey:options key:@"arrowDir" defaultValue:UIPopoverArrowDirectionAny];
        if (![org_apache_cordova_validArrowDirections containsObject:[NSNumber numberWithUnsignedInteger:arrowDirection]]) {
            arrowDirection = UIPopoverArrowDirectionAny;
        }
    }

    [[[self pickerController] pickerPopoverController] setDelegate:self];
    [[[self pickerController] pickerPopoverController] presentPopoverFromRect:CGRectMake(x, y, width, height)
                                                                 inView:[self.webView superview]
                                               permittedArrowDirections:arrowDirection
                                                               animated:YES];
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
    if([navigationController isKindOfClass:[UIImagePickerController class]]){
        UIImagePickerController* cameraPicker = (UIImagePickerController*)navigationController;

        if(![cameraPicker.mediaTypes containsObject:(NSString*)kUTTypeImage]){
            [viewController.navigationItem setTitle:NSLocalizedString(@"Videos", nil)];
        }
    }
}

- (void)cleanup:(CDVInvokedUrlCommand*)command
{
    // empty the tmp directory
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSError* err = nil;
    BOOL hasErrors = NO;

    // clear contents of NSTemporaryDirectory
    NSString* tempDirectoryPath = NSTemporaryDirectory();
    NSDirectoryEnumerator* directoryEnumerator = [fileMgr enumeratorAtPath:tempDirectoryPath];
    NSString* fileName = nil;
    BOOL result;

    while ((fileName = [directoryEnumerator nextObject])) {
        // only delete the files we created
        if (![fileName hasPrefix:CDV_PHOTO_PREFIX]) {
            continue;
        }
        NSString* filePath = [tempDirectoryPath stringByAppendingPathComponent:fileName];
        result = [fileMgr removeItemAtPath:filePath error:&err];
        if (!result && err) {
            NSLog(@"Failed to delete: %@ (error: %@)", filePath, err);
            hasErrors = YES;
        }
    }

    CDVPluginResult* pluginResult;
    if (hasErrors) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:@"One or more files failed to be deleted."];
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)popoverControllerDidDismissPopover:(id)popoverController
{
    UIPopoverController* pc = (UIPopoverController*)popoverController;

    [pc dismissPopoverAnimated:YES];
    pc.delegate = nil;
    if (self.pickerController && self.pickerController.callbackId && self.pickerController.pickerPopoverController) {
        self.pickerController.pickerPopoverController = nil;
        NSString* callbackId = self.pickerController.callbackId;
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no image selected"];   // error callback expects string ATM
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
    self.hasPendingOperation = NO;
}

- (NSData*)processImage:(UIImage*)image info:(NSDictionary*)info options:(CDVPictureOptions*)options
{
    NSData* data = nil;

    switch (options.encodingType) {
        case EncodingTypePNG:
            data = UIImagePNGRepresentation(image);
            break;
        case EncodingTypeJPEG:
        {
            if ((options.allowsEditing == NO) && (options.targetSize.width <= 0) && (options.targetSize.height <= 0) && (options.correctOrientation == NO) && (([options.quality integerValue] == 100) || (options.sourceType != UIImagePickerControllerSourceTypeCamera))){
                // use image unedited as requested , don't resize
                data = UIImageJPEGRepresentation(image, 1.0);
            } else {
                data = UIImageJPEGRepresentation(image, [options.quality floatValue] / 100.0f);
            }

            if (options.usesGeolocation) {
                NSDictionary* controllerMetadata = [info objectForKey:@"UIImagePickerControllerMediaMetadata"];
                if (controllerMetadata) {
                    self.data = data;
                    self.metadata = [[NSMutableDictionary alloc] init];

                    NSMutableDictionary* EXIFDictionary = [[controllerMetadata objectForKey:(NSString*)kCGImagePropertyExifDictionary]mutableCopy];
                    if (EXIFDictionary)	{
                        [self.metadata setObject:EXIFDictionary forKey:(NSString*)kCGImagePropertyExifDictionary];
                    }

                    if (IsAtLeastiOSVersion(@"8.0")) {
                        [[self locationManager] performSelector:NSSelectorFromString(@"requestWhenInUseAuthorization") withObject:nil afterDelay:0];
                    }
                    [[self locationManager] startUpdatingLocation];
                }
            }
        }
            break;
        default:
            break;
    };

    return data;
}

- (NSString*)tempFilePath:(NSString*)extension
{
    NSString* docsPath = [NSTemporaryDirectory()stringByStandardizingPath];
    NSFileManager* fileMgr = [[NSFileManager alloc] init]; // recommended by Apple (vs [NSFileManager defaultManager]) to be threadsafe
    NSString* filePath;

    // generate unique file name
    int i = 1;
    do {
        filePath = [NSString stringWithFormat:@"%@/%@%03d.%@", docsPath, CDV_PHOTO_PREFIX, i++, extension];
    } while ([fileMgr fileExistsAtPath:filePath]);

    return filePath;
}

- (UIImage*)retrieveImage:(NSDictionary*)info options:(CDVPictureOptions*)options
{
    // get the image
    UIImage* image = nil;
    if (options.allowsEditing && [info objectForKey:UIImagePickerControllerEditedImage]) {
        image = [info objectForKey:UIImagePickerControllerEditedImage];
    } else {
        image = [info objectForKey:UIImagePickerControllerOriginalImage];
    }

    if (options.correctOrientation) {
        image = [image imageCorrectedForCaptureOrientation];
    }

    UIImage* scaledImage = nil;

    if ((options.targetSize.width > 0) && (options.targetSize.height > 0)) {
        // if cropToSize, resize image and crop to target size, otherwise resize to fit target without cropping
        if (options.cropToSize) {
            scaledImage = [image imageByScalingAndCroppingForSize:options.targetSize];
        } else {
            scaledImage = [image imageByScalingNotCroppingForSize:options.targetSize];
        }
    }

    return (scaledImage == nil ? image : scaledImage);
}

- (void)resultForImage:(CDVPictureOptions*)options info:(NSDictionary*)info completion:(void (^)(CDVPluginResult* res))completion
{
    CDVPluginResult* result = nil;
    BOOL saveToPhotoAlbum = options.saveToPhotoAlbum;
    UIImage* image = nil;

    switch (options.destinationType) {
        case DestinationTypeNativeUri:
        {
            NSURL* url = [info objectForKey:UIImagePickerControllerReferenceURL];
            saveToPhotoAlbum = NO;
            // If, for example, we use sourceType = Camera, URL might be nil because image is stored in memory.
            // In this case we must save image to device before obtaining an URI.
            if (url == nil) {
                image = [self retrieveImage:info options:options];
                ALAssetsLibrary* library = [ALAssetsLibrary new];
                [library writeImageToSavedPhotosAlbum:image.CGImage orientation:(ALAssetOrientation)(image.imageOrientation) completionBlock:^(NSURL *assetURL, NSError *error) {
                    CDVPluginResult* resultToReturn = nil;
                    if (error) {
                        resultToReturn = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[error localizedDescription]];
                    } else {
                        NSString* nativeUri = [[self urlTransformer:assetURL] absoluteString];
                        resultToReturn = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:nativeUri];
                    }
                    completion(resultToReturn);
                }];
                return;
            } else {
                NSString* nativeUri = [[self urlTransformer:url] absoluteString];
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:nativeUri];
            }
        }
            break;
        case DestinationTypeFileUri:
        {
            image = [self retrieveImage:info options:options];
            NSData* data = [self processImage:image info:info options:options];
            if (data) {

                NSString* extension = options.encodingType == EncodingTypePNG? @"png" : @"jpg";
                NSString* filePath = [self tempFilePath:extension];
                NSError* err = nil;

                // save file
                if (![data writeToFile:filePath options:NSAtomicWrite error:&err]) {
                    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[err localizedDescription]];
                } else {
                    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[[self urlTransformer:[NSURL fileURLWithPath:filePath]] absoluteString]];
                }
            }
        }
            break;
        case DestinationTypeDataUrl:
        {
            image = [self retrieveImage:info options:options];
            NSData* data = [self processImage:image info:info options:options];
            if (data)  {
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:toBase64(data)];
            }
        }
            break;
        default:
            break;
    };

    if (saveToPhotoAlbum && image) {
        ALAssetsLibrary* library = [ALAssetsLibrary new];
        [library writeImageToSavedPhotosAlbum:image.CGImage orientation:(ALAssetOrientation)(image.imageOrientation) completionBlock:nil];
    }

    completion(result);
}

- (CDVPluginResult*)resultForVideo:(NSDictionary*)info
{
    NSString* moviePath = [[info objectForKey:UIImagePickerControllerMediaURL] absoluteString];
    return [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:moviePath];
}

- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingMediaWithInfo:(NSDictionary*)info
{
    __weak CDVCameraPicker* cameraPicker = (CDVCameraPicker*)picker;
    __weak CDVImageCapture* weakSelf = self;

    dispatch_block_t invoke = ^(void) {
        __block CDVPluginResult* result = nil;

        NSString* mediaType = [info objectForKey:UIImagePickerControllerMediaType];
        if ([mediaType isEqualToString:(NSString*)kUTTypeImage]) {
            [weakSelf resultForImage:cameraPicker.pictureOptions info:info completion:^(CDVPluginResult* res) {
                if (![self usesGeolocation] || picker.sourceType != UIImagePickerControllerSourceTypeCamera) {
                    [weakSelf.commandDelegate sendPluginResult:res callbackId:cameraPicker.callbackId];
                    weakSelf.hasPendingOperation = NO;
                    weakSelf.pickerController = nil;
                }
            }];
        }
        else {
            result = [weakSelf resultForVideo:info];
            [weakSelf.commandDelegate sendPluginResult:result callbackId:cameraPicker.callbackId];
            weakSelf.hasPendingOperation = NO;
            weakSelf.pickerController = nil;
        }
    };

    if (cameraPicker.pictureOptions.popoverSupported && (cameraPicker.pickerPopoverController != nil)) {
        [cameraPicker.pickerPopoverController dismissPopoverAnimated:YES];
        cameraPicker.pickerPopoverController.delegate = nil;
        cameraPicker.pickerPopoverController = nil;
        invoke();
    } else {
        [[cameraPicker presentingViewController] dismissViewControllerAnimated:YES completion:invoke];
    }
}

// older api calls newer didFinishPickingMediaWithInfo
- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingImage:(UIImage*)image editingInfo:(NSDictionary*)editingInfo
{
    NSDictionary* imageInfo = [NSDictionary dictionaryWithObject:image forKey:UIImagePickerControllerOriginalImage];

    [self imagePickerController:picker didFinishPickingMediaWithInfo:imageInfo];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker
{
    __weak CDVCameraPicker* cameraPicker = (CDVCameraPicker*)picker;
    __weak CDVImageCapture* weakSelf = self;

    dispatch_block_t invoke = ^ (void) {
        CDVPluginResult* result;
        if (picker.sourceType == UIImagePickerControllerSourceTypeCamera && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != ALAuthorizationStatusAuthorized) {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"has no access to camera"];
        } else if (picker.sourceType != UIImagePickerControllerSourceTypeCamera && [ALAssetsLibrary authorizationStatus] != ALAuthorizationStatusAuthorized) {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"has no access to assets"];
        } else {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No Image Selected"];
        }


        [weakSelf.commandDelegate sendPluginResult:result callbackId:cameraPicker.callbackId];

        weakSelf.hasPendingOperation = NO;
        weakSelf.pickerController = nil;
    };

    [[cameraPicker presentingViewController] dismissViewControllerAnimated:YES completion:invoke];
}

- (CLLocationManager*)locationManager
{
	if (locationManager != nil) {
		return locationManager;
	}

	locationManager = [[CLLocationManager alloc] init];
	[locationManager setDesiredAccuracy:kCLLocationAccuracyNearestTenMeters];
	[locationManager setDelegate:self];

	return locationManager;
}

- (void)locationManager:(CLLocationManager*)manager didUpdateToLocation:(CLLocation*)newLocation fromLocation:(CLLocation*)oldLocation
{
    if (locationManager == nil) {
        return;
    }

    [self.locationManager stopUpdatingLocation];
    self.locationManager = nil;

    NSMutableDictionary *GPSDictionary = [[NSMutableDictionary dictionary] init];

    CLLocationDegrees latitude  = newLocation.coordinate.latitude;
    CLLocationDegrees longitude = newLocation.coordinate.longitude;

    // latitude
    if (latitude < 0.0) {
        latitude = latitude * -1.0f;
        [GPSDictionary setObject:@"S" forKey:(NSString*)kCGImagePropertyGPSLatitudeRef];
    } else {
        [GPSDictionary setObject:@"N" forKey:(NSString*)kCGImagePropertyGPSLatitudeRef];
    }
    [GPSDictionary setObject:[NSNumber numberWithFloat:latitude] forKey:(NSString*)kCGImagePropertyGPSLatitude];

    // longitude
    if (longitude < 0.0) {
        longitude = longitude * -1.0f;
        [GPSDictionary setObject:@"W" forKey:(NSString*)kCGImagePropertyGPSLongitudeRef];
    }
    else {
        [GPSDictionary setObject:@"E" forKey:(NSString*)kCGImagePropertyGPSLongitudeRef];
    }
    [GPSDictionary setObject:[NSNumber numberWithFloat:longitude] forKey:(NSString*)kCGImagePropertyGPSLongitude];

    // altitude
    CGFloat altitude = newLocation.altitude;
    if (!isnan(altitude)){
        if (altitude < 0) {
            altitude = -altitude;
            [GPSDictionary setObject:@"1" forKey:(NSString *)kCGImagePropertyGPSAltitudeRef];
        } else {
            [GPSDictionary setObject:@"0" forKey:(NSString *)kCGImagePropertyGPSAltitudeRef];
        }
        [GPSDictionary setObject:[NSNumber numberWithFloat:altitude] forKey:(NSString *)kCGImagePropertyGPSAltitude];
    }

    // Time and date
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss.SSSSSS"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    [GPSDictionary setObject:[formatter stringFromDate:newLocation.timestamp] forKey:(NSString *)kCGImagePropertyGPSTimeStamp];
    [formatter setDateFormat:@"yyyy:MM:dd"];
    [GPSDictionary setObject:[formatter stringFromDate:newLocation.timestamp] forKey:(NSString *)kCGImagePropertyGPSDateStamp];

    [self.metadata setObject:GPSDictionary forKey:(NSString *)kCGImagePropertyGPSDictionary];
    [self imagePickerControllerReturnImageResult];
}

- (void)locationManager:(CLLocationManager*)manager didFailWithError:(NSError*)error
{
    if (locationManager == nil) {
        return;
    }

    [self.locationManager stopUpdatingLocation];
    self.locationManager = nil;

    [self imagePickerControllerReturnImageResult];
}

- (void)imagePickerControllerReturnImageResult
{
    CDVPictureOptions* options = self.pickerController.pictureOptions;
    CDVPluginResult* result = nil;

    if (self.metadata) {
        CGImageSourceRef sourceImage = CGImageSourceCreateWithData((__bridge CFDataRef)self.data, NULL);
        CFStringRef sourceType = CGImageSourceGetType(sourceImage);

        CGImageDestinationRef destinationImage = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)self.data, sourceType, 1, NULL);
        CGImageDestinationAddImageFromSource(destinationImage, sourceImage, 0, (__bridge CFDictionaryRef)self.metadata);
        CGImageDestinationFinalize(destinationImage);

        CFRelease(sourceImage);
        CFRelease(destinationImage);
    }

    switch (options.destinationType) {
        case DestinationTypeFileUri:
        {
            NSError* err = nil;
            NSString* extension = self.pickerController.pictureOptions.encodingType == EncodingTypePNG ? @"png":@"jpg";
            NSString* filePath = [self tempFilePath:extension];

            // save file
            if (![self.data writeToFile:filePath options:NSAtomicWrite error:&err]) {
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[err localizedDescription]];
            }
            else {
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[[self urlTransformer:[NSURL fileURLWithPath:filePath]] absoluteString]];
            }
        }
            break;
        case DestinationTypeDataUrl:
        {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:toBase64(self.data)];
        }
            break;
        case DestinationTypeNativeUri:
        default:
            break;
    };

    if (result) {
        [self.commandDelegate sendPluginResult:result callbackId:self.pickerController.callbackId];
    }

    self.hasPendingOperation = NO;
    self.pickerController = nil;
    self.data = nil;
    self.metadata = nil;

    if (options.saveToPhotoAlbum) {
        ALAssetsLibrary *library = [ALAssetsLibrary new];
        [library writeImageDataToSavedPhotosAlbum:self.data metadata:self.metadata completionBlock:nil];
    }
}

@end

@implementation CDVCameraPicker

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (UIViewController*)childViewControllerForStatusBarHidden
{
    return nil;
}

- (void)viewWillAppear:(BOOL)animated
{
    SEL sel = NSSelectorFromString(@"setNeedsStatusBarAppearanceUpdate");
    if ([self respondsToSelector:sel]) {
        [self performSelector:sel withObject:nil afterDelay:0];
    }

    [super viewWillAppear:animated];
}

+ (instancetype) createFromPictureOptions:(CDVPictureOptions*)pictureOptions;
{
    CDVCameraPicker* cameraPicker = [[CDVCameraPicker alloc] init];
    cameraPicker.pictureOptions = pictureOptions;
    cameraPicker.sourceType = pictureOptions.sourceType;
    cameraPicker.allowsEditing = pictureOptions.allowsEditing;

    if (cameraPicker.sourceType == UIImagePickerControllerSourceTypeCamera) {
        // We only allow taking pictures (no video) in this API.
        cameraPicker.mediaTypes = @[(NSString*)kUTTypeImage];
        // We can only set the camera device if we're actually using the camera.
        cameraPicker.cameraDevice = pictureOptions.cameraDirection;
    } else if (pictureOptions.mediaType == MediaTypeAll) {
        cameraPicker.mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:cameraPicker.sourceType];
    } else {
        NSArray* mediaArray = @[(NSString*)(pictureOptions.mediaType == MediaTypeVideo ? kUTTypeMovie : kUTTypeImage)];
        cameraPicker.mediaTypes = mediaArray;
    }

    return cameraPicker;
}

@end