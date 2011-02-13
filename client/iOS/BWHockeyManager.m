//
//  BWHockeyController.m
//
//  Created by Andreas Linde on 8/17/10.
//  Copyright 2010 Andreas Linde. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "BWHockeyManager.h"
#import "NSString+HockeyAdditions.h"
#import <sys/sysctl.h>
#import <Foundation/Foundation.h>

// API defines - do not change
#define BETA_DOWNLOAD_TYPE_PROFILE	@"profile"
#define BETA_UPDATE_RESULT          @"result"
#define BETA_UPDATE_TITLE           @"title"
#define BETA_UPDATE_SUBTITLE        @"subtitle"
#define BETA_UPDATE_NOTES           @"notes"
#define BETA_UPDATE_VERSION         @"version"
#define BETA_UPDATE_TIMESTAMP       @"timestamp"
#define BETA_UPDATE_APPSIZE         @"appsize"

@interface BWHockeyManager ()
- (NSString *)getDevicePlatform_;
- (void)connectionOpened_;
- (void)connectionClosed_;
- (void)reachabilityChanged:(NSNotification *)notification;
- (void)startUsage;
- (void)stopUsage;
- (NSString *)currentUsageString;
- (NSString *)installationDateString;

@property (nonatomic, assign, getter=isUpdateURLOffline) BOOL updateURLOffline;
@property (nonatomic, assign, getter=isUpdateAvailable) BOOL updateAvailable;
@property (nonatomic, assign, getter=isCheckInProgress) BOOL checkInProgress;
@property (nonatomic, retain) NSMutableData *receivedData;
@property (nonatomic, copy) NSDate *lastCheck;
@property (nonatomic, copy) NSArray *apps;
@property (nonatomic, retain) NSURLConnection *urlConnection;
@property (nonatomic, copy) NSDate *usageStartTimestamp;
@end

// hockey api error domain
typedef enum {
    HockeyErrorUnknown,
    HockeyAPIServerReturnedInvalidStatus,
    HockeyAPIServerReturnedInvalidData,
    HockeyAPIServerReturnedEmptyResponse,
    HockeyAPIClientCannotCreateConnection
} HockeyErrorReason;
static NSString *kHockeyErrorDomain = @"HockeyErrorDomain";

@implementation BWHockeyManager

@synthesize delegate = delegate_;
@synthesize updateURL = updateURL_;
@synthesize urlConnection = urlConnection_;
@synthesize updateURLOffline = updateURLOffline_;
@synthesize checkInProgress = checkInProgress_;
@synthesize receivedData = receivedData_;
@synthesize sendUserData = sendUserData_;
@synthesize sendUsageTime = sendUsageTime_;
@synthesize alwaysShowUpdateReminder = showUpdateReminder_;
@synthesize checkForUpdateOnLaunch = checkForUpdateOnLaunch_;
@synthesize compareVersionType = compareVersionType_;
@synthesize lastCheck = lastCheck_;
@synthesize showUserSettings = showUserSettings_;
@synthesize updateSetting = updateSetting_;
@synthesize apps = apps_;
@synthesize updateAvailable = updateAvailable_;
@synthesize usageStartTimestamp = usageStartTimestamp_;
@synthesize currentHockeyViewController = currentHockeyViewController_;

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark static

+ (BWHockeyManager *)sharedHockeyManager {
	static BWHockeyManager *hockeyManager = nil;
    
	if (hockeyManager == nil) {
		hockeyManager = [[BWHockeyManager alloc] init];
	}
    
	return hockeyManager;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark private

- (void)reportError_:(NSError *)error {
    BWLog(@"Error: %@", [error localizedDescription]);
    
    // only show error if we enable that
    if (showFeedback_) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:BWLocalize(@"HockeyError") message:[error localizedDescription] delegate:nil cancelButtonTitle:BWLocalize(@"OK") otherButtonTitles:nil];
        [alert show];
        [alert release];
        showFeedback_ = NO;
    }
}

- (NSString *)encodedAppIdentifier_ {
    return [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}

- (NSString *)getDevicePlatform_ {
	size_t size;
	sysctlbyname("hw.machine", NULL, &size, NULL, 0);
	char *answer = malloc(size);
	sysctlbyname("hw.machine", answer, &size, NULL, 0);
	NSString *platform = [NSString stringWithCString:answer encoding: NSUTF8StringEncoding];
	free(answer);
	return platform;
}

- (void)connectionOpened_ {
    if ([self.delegate respondsToSelector:@selector(connectionOpened)])
		[(id)self.delegate connectionOpened];
}

- (void)connectionClosed_ {
    if ([self.delegate respondsToSelector:@selector(connectionClosed)])
		[(id)self.delegate connectionClosed];
}

// weak-linked reachability
- (void)setupReachability {
    if (reachability_) {
        [reachability_ performSelector:NSSelectorFromString(@"stopNotifier")];    
        [reachability_ release];
        reachability_ = nil;
    }
    
    Class reachabilityClass = NSClassFromString(@"Reachability");
    if (reachabilityClass) {
        NSString *hostName = [[NSURL URLWithString:self.updateURL] host];
        BWLog(@"setting up reachability for %@", hostName);
        reachability_ = [[reachabilityClass performSelector:NSSelectorFromString(@"reachabilityWithHostName:") withObject:hostName] retain];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:@"kNetworkReachabilityChangedNotification" object:reachability_];
        [reachability_ performSelector:NSSelectorFromString(@"startNotifier")];
    }
}

- (void)startUsage {
    self.usageStartTimestamp = [NSDate date];
    
    BOOL newVersion = NO;
    
    if (![[NSUserDefaults standardUserDefaults] valueForKey:kUsageTimeForVersionString]) {
        newVersion = YES;
    } else {
        if ([[[NSUserDefaults standardUserDefaults] valueForKey:kUsageTimeForVersionString] compare:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]] != NSOrderedSame) {
            newVersion = YES;
        }
    }
    
    if (newVersion) {
        [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithDouble:[[NSDate date] timeIntervalSinceReferenceDate]] forKey:kDateOfVersionInstallation];
        [[NSUserDefaults standardUserDefaults] setObject:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] forKey:kUsageTimeForVersionString];
        [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithDouble:0] forKey:kUsageTimeOfCurrentVersion];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }    
}

- (void)stopUsage {
    double timeDifference = [[NSDate date] timeIntervalSinceReferenceDate] - [usageStartTimestamp_ timeIntervalSinceReferenceDate];
    double previousTimeDifference = [(NSNumber *)[[NSUserDefaults standardUserDefaults] valueForKey:kUsageTimeOfCurrentVersion] doubleValue];
    
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithDouble:previousTimeDifference + timeDifference] forKey:kUsageTimeOfCurrentVersion];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSString *)currentUsageString {
    double currentUsageTime = [(NSNumber *)[[NSUserDefaults standardUserDefaults] valueForKey:kUsageTimeOfCurrentVersion] doubleValue];
    
    if (currentUsageTime > 0 && self.shouldSendUsageTime) {
        double days = trunc(currentUsageTime / (60 * 60 * 24));
        double hours = trunc((currentUsageTime - (days * 60 * 60 * 24)) / (60 * 60));
        double minutes = trunc((currentUsageTime - (hours * 60 * 60)) / 60);
        
        if (minutes <= 15) minutes = 15;
        else if (minutes <= 30) minutes = 30;
        else if (minutes <= 45) minutes = 45;
        else if (minutes < 60) { minutes = 0; hours+=1; }
        else minutes = 0;
        
        return [NSString stringWithFormat:@"%.0fd %.0fh %.0fm", days, hours, minutes];
    } else {
        return @"";
    }
}

- (NSString *)installationDateString {
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    [formatter setDateFormat:@"MM/dd/yyyy"];
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:[(NSNumber *)[[NSUserDefaults standardUserDefaults] valueForKey:kDateOfVersionInstallation] doubleValue]]];
}

- (void)checkUpdateAvailable_ {
    // check if there is an update available
    if (self.compareVersionType == HockeyComparisonResultGreater) {
        self.updateAvailable = ([self.app.version compare:self.currentAppVersion options:NSNumericSearch] == NSOrderedDescending);
    } else {
        self.updateAvailable = ([self.app.version compare:self.currentAppVersion] != NSOrderedSame);
    }
}

- (void)loadAppCache_ {
    NSData *savedHockeyData = [[NSUserDefaults standardUserDefaults] objectForKey:kArrayOfLastHockeyCheck];
    NSArray *savedHockeyCheck = nil;
    if (savedHockeyData) {
        [NSKeyedUnarchiver unarchiveObjectWithData:savedHockeyData];
    }
    if (savedHockeyCheck) {
        self.apps = [NSArray arrayWithArray:savedHockeyCheck];
        [self checkUpdateAvailable_];
    } else {
        self.apps = nil;
    }
}

- (void)saveAppCache_ {
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self.apps];
    [[NSUserDefaults standardUserDefaults] setObject:data forKey:kArrayOfLastHockeyCheck];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark NSObject

- (id)init {
	if ((self = [super init])) {
        updateURL_ = nil;
        checkInProgress_ = NO;
        dataFound = NO;
        updateAvailable_ = NO;
        updateURLOffline_ = NO;
        currentAppVersion_ = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
        
        // set defaults
        self.sendUserData = YES;
        self.sendUsageTime = YES;
        self.alwaysShowUpdateReminder = NO;
        self.checkForUpdateOnLaunch = YES;
        self.showUserSettings = YES;
        self.compareVersionType = HockeyComparisonResultDifferent;
        
        // load update setting from user defaults and check value
        self.updateSetting = [[NSUserDefaults standardUserDefaults] integerForKey:kHockeyAutoUpdateSetting];
        
        [self loadAppCache_];
        
        [self startUsage];
    }
    return self;
}

- (void)dealloc {
    IF_IOS4_OR_GREATER(
                       [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
                       [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
                       )
    [reachability_ performSelector:NSSelectorFromString(@"stopNotifier")];    
    [reachability_ release];
    self.delegate = nil;
    
    [urlConnection_ cancel];
    self.urlConnection = nil;
    
    [currentHockeyViewController_ release];
    [updateURL_ release];
    [apps_ release];
    [receivedData_ release];
    [lastCheck_ release];
    [usageStartTimestamp_ release];
    
    [super dealloc];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark BetaUpdateUI

- (BWHockeyViewController *)hockeyViewController:(BOOL)modal {
    return [[[BWHockeyViewController alloc] init:self modal:modal] autorelease];
}

- (void)showUpdateView {
    UIViewController *parentViewController = nil;
    
    if ([[self delegate] respondsToSelector:@selector(viewControllerForHockeyController:)]) {
        parentViewController = [[self delegate] viewControllerForHockeyController:self];
    }
    
    UIWindow *visibleWindow = nil;
	if (parentViewController == nil && [UIWindow instancesRespondToSelector:@selector(rootViewController)]) {
        // if the rootViewController property (available >= iOS 4.0) of the main window is set, we present the modal view controller on top of the rootViewController
        NSArray *windows = [[UIApplication sharedApplication] windows];
        for (UIWindow *window in windows) {
            if (!window.hidden && !visibleWindow) {
                visibleWindow = window;
            }
            if ([window rootViewController]) {
                parentViewController = [window rootViewController];
                visibleWindow = window;
                BWLog(@"UIWindow with rootViewController found: %@", visibleWindow);
                break;
            }
        }
	}
    // special addition to get rootViewController from three20 which has it's own controller handling
    if (NSClassFromString(@"TTNavigator")) {
        parentViewController = [[NSClassFromString(@"TTNavigator") performSelector:(NSSelectorFromString(@"navigator"))] visibleViewController];
    }
    
    BWHockeyViewController *hockeyViewController = [self hockeyViewController:YES];
    UINavigationController *navController = [[[UINavigationController alloc] initWithRootViewController:hockeyViewController] autorelease];
    
    if (parentViewController) {
        if ([navController respondsToSelector:@selector(setModalTransitionStyle:)]) {
            navController.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
        }
        
        // page sheet for the iPad
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad && [navController respondsToSelector:@selector(setModalPresentationStyle:)]) {
            navController.modalPresentationStyle = UIModalPresentationFormSheet;
        }
        
        [parentViewController presentModalViewController:navController animated:YES];
    } else {
		// if not, we add a subview to the window. A bit hacky but should work in most circumstances.
		// Also, we don't get a nice animation for free, but hey, this is for beta not production users ;)
        BWLog(@"No rootViewController found, using UIWindow-approach: %@", visibleWindow);
        [visibleWindow addSubview:navController.view];
        
		// we don't release the navController here, that'll be done when it's dismissed in [BWHockeyViewController -onAction:]
        [navController retain];
	}
}


- (void)showCheckForBetaAlert_ {
    UIAlertView *alertView = [[[UIAlertView alloc] initWithTitle:BWLocalize(@"HockeyUpdateAvailable")
                                                         message:[NSString stringWithFormat:BWLocalize(@"HockeyUpdateAlertTextWithAppVersion"), [self.app nameAndVersionString]]
                                                        delegate:self
                                               cancelButtonTitle:BWLocalize(@"HockeyIgnore")
                                               otherButtonTitles:BWLocalize(@"HockeyShowUpdate"), nil
                               ] autorelease];
    [alertView show];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark RequestComments

- (BOOL)shouldCheckForUpdates {
    BOOL checkForUpdate = NO;
    switch (self.updateSetting) {
        case HockeyUpdateCheckStartup:
            checkForUpdate = YES;
            break;
        case HockeyUpdateCheckDaily:
            checkForUpdate = [[[self.lastCheck description] substringToIndex:10] compare:[[[NSDate date] description] substringToIndex:10]] != NSOrderedSame;
            break;
        case HockeyUpdateCheckManually:
            checkForUpdate = NO;
            break;
        default:
            break;
    }
    return checkForUpdate;
}

- (void)checkForUpdate {
    [self checkForUpdateShowFeedback:NO]; 
}

- (void)checkForUpdateShowFeedback:(BOOL)feedback {
    if (self.isCheckInProgress) return;
    
    showFeedback_ = feedback;
    self.checkInProgress = YES;
    
    // do we need to update?
    BOOL updatePending = self.alwaysShowUpdateReminder && [[self currentAppVersion] compare:[self app].version] != NSOrderedSame;
    if (!updatePending && ![self shouldCheckForUpdates] && !currentHockeyViewController_) {
        BWLog(@"update not needed right now");
        self.checkInProgress = NO;
        return;
    }
    
    NSMutableString *parameter = [NSMutableString stringWithFormat:@"api/2/apps/%@", [self encodedAppIdentifier_]];
    
    // build request & send
    NSString *url = [NSString stringWithFormat:@"%@%@", self.updateURL, parameter];
    BWLog(@"sending api request to %@", url);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:1 timeoutInterval:10.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"Hockey/iOS" forHTTPHeaderField:@"User-Agent"];
    
    // add additional statistics if user didn't disable flag
    if (self.shouldSendUserData) {
        NSString *postDataString = [NSString stringWithFormat:@"format=json&app_version=%@&os=iOS&os_version=%@&device=%@&udid=%@&lang=%@&usage_time=%@&first_start_at=%@",
                                    [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding],
                                    [[UIDevice currentDevice] systemVersion],
                                    [self getDevicePlatform_],
                                    [[UIDevice currentDevice] uniqueIdentifier],
                                    [[NSLocale preferredLanguages] objectAtIndex:0],
                                    [[self currentUsageString] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding],
                                    [[self installationDateString] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]
                                    ];
        BWLog(@"posting additional data: %@", postDataString);
        NSData *requestData = [NSData dataWithBytes:[postDataString UTF8String] length:[postDataString length]];
        NSString *postLength = [NSString stringWithFormat:@"%d", [postDataString length]];
        [request setValue:postLength forHTTPHeaderField:@"Content-Length"];
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"content-type"];
        [request setHTTPBody:requestData];
    }
    
    self.urlConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
    if (!urlConnection_) {
        self.checkInProgress = NO;
        [self reportError_:[NSError errorWithDomain:kHockeyErrorDomain code:HockeyAPIClientCannotCreateConnection userInfo:
                            [NSDictionary dictionaryWithObjectsAndKeys:@"Url Connection could not be created.", NSLocalizedDescriptionKey, nil]]];
    }
}

- (BOOL)initiateAppDownload {
    if (!self.isUpdateAvailable) {
        BWLog(@"Warning: No update available. Aborting.");
        return NO;
    }
    
    IF_PRE_IOS4
    (
     NSString *message = [NSString stringWithFormat:BWLocalize(@"HockeyiOS3Message"), self.updateURL];
     UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:BWLocalize(@"HockeyWarning") message:message delegate:nil cancelButtonTitle:BWLocalize(@"HockeyOK") otherButtonTitles:nil] autorelease];
     [alert show];
     return NO;
     )
    
#if TARGET_IPHONE_SIMULATOR
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:BWLocalize(@"HockeyWarning") message:BWLocalize(@"HockeySimulatorMessage") delegate:nil cancelButtonTitle:BWLocalize(@"HockeyOK") otherButtonTitles:nil] autorelease];
    [alert show];
    return NO;
#endif
    
    NSString *extraParameter = [NSString string];
    if (self.shouldSendUserData) {
        extraParameter = [NSString stringWithFormat:@"&udid=%@", [[UIDevice currentDevice] uniqueIdentifier]];
    }
    
    NSString *hockeyAPIURL = [NSString stringWithFormat:@"%@api/2/apps/%@?format=plist%@", self.updateURL, [self encodedAppIdentifier_], extraParameter];
    NSString *iOSUpdateURL = [NSString stringWithFormat:@"itms-services://?action=download-manifest&url=%@", [hockeyAPIURL bw_URLEncodedString]];
    
    BWLog(@"API Server Call: %@, calling iOS with %@", hockeyAPIURL, iOSUpdateURL);
    BOOL success = [[UIApplication sharedApplication] openURL:[NSURL URLWithString:iOSUpdateURL]];
    BWLog(@"System returned: %d", success);
    return success;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark NSURLRequest

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse {
    [self connectionOpened_];
	NSURLRequest *newRequest = request;
	if (redirectResponse) {
		newRequest = nil;
	}
	return newRequest;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if ([response respondsToSelector:@selector(statusCode)]) {
        int statusCode = [((NSHTTPURLResponse *)response) statusCode];
        if (statusCode == 404) {
            [connection cancel];  // stop connecting; no more delegate messages
            NSString *errorStr = [NSString stringWithFormat:@"Hockey API received HTTP Status Code %d", statusCode];
            [self connectionClosed_];
            [self reportError_:[NSError errorWithDomain:kHockeyErrorDomain code:HockeyAPIServerReturnedInvalidStatus userInfo:
                                [NSDictionary dictionaryWithObjectsAndKeys:errorStr, NSLocalizedDescriptionKey, nil]]];
            return;
        }
    }
    
	self.receivedData = [NSMutableData data];
	[receivedData_ setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [receivedData_ appendData:data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [self connectionClosed_];
    self.receivedData = nil;
    self.urlConnection = nil;
    self.checkInProgress = NO;
    [self reportError_:error];
}

// api call returned, parsing
- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [self connectionClosed_];
    self.checkInProgress = NO;
    
	if ([self.receivedData length]) {
        NSString *responseString = [[[NSString alloc] initWithBytes:[receivedData_ bytes] length:[receivedData_ length] encoding: NSUTF8StringEncoding] autorelease];
        BWLog(@"Received API response: %@", responseString);
        
        NSError *error = nil;
        NSArray *feedArray;
        
        // equivalent to feedArray = [responseString objectFromJSONStringWithParseOptions:0 error:&error];
        SEL jsonKitSelector = NSSelectorFromString(@"objectFromJSONStringWithParseOptions:error:");
        if (jsonKitSelector && [responseString respondsToSelector:jsonKitSelector]) {
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[responseString methodSignatureForSelector:jsonKitSelector]];
            invocation.target = responseString;
            invocation.selector = jsonKitSelector;
            int parseOptions = 0;
            [invocation setArgument:&parseOptions atIndex:2]; // arguments 0 and 1 are self and _cmd respectively, automatically set by NSInvocation
            [invocation setArgument:&error atIndex:3];
            [invocation invoke];
            [invocation getReturnValue:&feedArray];
        }else {
            BWLog(@"Error: You need a JSON Framework in your runtime!");
            [self doesNotRecognizeSelector:_cmd];
        }    
        if (error) {
            BWLog(@"Error while parsing response feed: %@", [error localizedDescription]);
            [self reportError_:error];
            return;
        }
        
        self.receivedData = nil;
        self.urlConnection = nil;
        
        // remember that we just checked the server
        self.lastCheck = [NSDate date];
        
        // server returned empty response?
        if (![feedArray count]) {
            [self reportError_:[NSError errorWithDomain:kHockeyErrorDomain code:HockeyAPIServerReturnedEmptyResponse userInfo:
                                [NSDictionary dictionaryWithObjectsAndKeys:@"Server returned empty response.", NSLocalizedDescriptionKey, nil]]];
            return;
		}
        
        NSString *currentAppCacheVersion = [[[self app].version copy] autorelease];
        
        // clear cache and reload with new data
        NSMutableArray *tmpApps = [NSMutableArray arrayWithCapacity:[feedArray count]];
        for (NSDictionary *dict in feedArray) {
            BWApp *app = [BWApp appFromDict:dict];
            if ([app isValid]) {
                [tmpApps addObject:app];
            }else {
                [self reportError_:[NSError errorWithDomain:kHockeyErrorDomain code:HockeyAPIServerReturnedInvalidData userInfo:
                                    [NSDictionary dictionaryWithObjectsAndKeys:@"Invalid data received from server.", NSLocalizedDescriptionKey, nil]]];
            }
        }
        // only set if different!
        if (![self.apps isEqualToArray:tmpApps]) {
            self.apps = [[tmpApps copy] autorelease];
        }
        [self saveAppCache_];
        
        [self checkUpdateAvailable_];
        BOOL newVersionDiffersFromCachedVersion = ![self.app.version isEqualToString:currentAppCacheVersion];
        
        // show alert if we are on the latest & greatest
        if (showFeedback_ && !self.isUpdateAvailable) {
            // use currentVersionString, as version still may differ (e.g. server: 1.2, client: 1.3)
            NSString *currentVersionString = [NSString stringWithFormat:@"%@ %@ %@", self.app.name, BWLocalize(@"HockeyVersion"), [self currentAppVersion]];
            NSString *alertMsg = [NSString stringWithFormat:BWLocalize(@"HockeyNoUpdateNeededMessage"), currentVersionString];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:BWLocalize(@"HockeyNoUpdateNeededTitle") message:alertMsg delegate:nil cancelButtonTitle:BWLocalize(@"HockeyOK") otherButtonTitles:nil];
            [alert show];
            [alert release];
        }
        
        if (self.isUpdateAvailable && self.alwaysShowUpdateReminder || newVersionDiffersFromCachedVersion) {
            if (updateAvailable_ && !currentHockeyViewController_) {
                [self showCheckForBetaAlert_];
            }
        }
        showFeedback_ = NO;
    }else {
        [self reportError_:[NSError errorWithDomain:kHockeyErrorDomain code:HockeyAPIServerReturnedEmptyResponse userInfo:
                            [NSDictionary dictionaryWithObjectsAndKeys:@"Server returned an empty response.", NSLocalizedDescriptionKey, nil]]];
    }
}

- (void)reachabilityChanged:(NSNotification *)notification {
    id reachability = reachability_;
    if ([notification.object isKindOfClass:NSClassFromString(@"Reachability")]) {
        reachability = notification.object;
    }
    if (reachability) {
        NSInteger networkStatus;
        SEL currentReachabilityStatusSelector = NSSelectorFromString(@"currentReachabilityStatus");
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[reachability methodSignatureForSelector:currentReachabilityStatusSelector]];
        invocation.target = reachability;
        invocation.selector = currentReachabilityStatusSelector;
        [invocation invoke];
        [invocation getReturnValue:&networkStatus];
        
        // 0 = NotReachable
        BOOL isOffline = networkStatus == 0;
        self.updateURLOffline = isOffline;
        if (!isOffline) {
            [self checkForUpdate];
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark Properties

- (void)setCurrentHockeyViewController:(BWHockeyViewController *)aCurrentHockeyViewController {
    if (currentHockeyViewController_ != aCurrentHockeyViewController) {
        [currentHockeyViewController_ release];
        currentHockeyViewController_ = [aCurrentHockeyViewController retain];
        //BWLog(@"active hockey view controller: %@", aCurrentHockeyViewController);
    }
}

- (void)setUpdateURL:(NSString *)anUpdateURL {
    // ensure url ends with a trailing slash
    if (![anUpdateURL hasSuffix:@"/"]) {
        anUpdateURL = [NSString stringWithFormat:@"%@/", anUpdateURL];
    }
    
    IF_IOS4_OR_GREATER(
                       // register/deregister logic
                       NSNotificationCenter *dnc = [NSNotificationCenter defaultCenter];
                       if (!updateURL_ && anUpdateURL) {
                           [dnc addObserver:self selector:@selector(startUsage) name:UIApplicationDidBecomeActiveNotification object:nil];
                           [dnc addObserver:self selector:@selector(stopUsage) name:UIApplicationDidEnterBackgroundNotification object:nil];
                       } else if (updateURL_ && !anUpdateURL) {
                           [dnc removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
                           [dnc removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
                       }
                       )
    
    if (updateURL_ != anUpdateURL) {
        [updateURL_ release];
        updateURL_ = [anUpdateURL copy];
        [self setupReachability];
    }
}

- (void)setCheckForUpdateOnLaunch:(BOOL)flag {
    if (checkForUpdateOnLaunch_ != flag) {
        checkForUpdateOnLaunch_ = flag;
        IF_IOS4_OR_GREATER(
                           NSNotificationCenter *dnc = [NSNotificationCenter defaultCenter];
                           if (flag) {
                               [dnc addObserver:self selector:@selector(checkForUpdate) name:UIApplicationDidBecomeActiveNotification object:nil];
                           } else {
                               [dnc removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
                           }
                           )
    }
}

- (NSString *)currentAppVersion {
    return currentAppVersion_;
}

- (void)setUpdateSetting:(HockeyUpdateSetting)anUpdateSetting {
    if (anUpdateSetting > HockeyUpdateCheckManually) {
        updateSetting_ = HockeyUpdateCheckStartup;
    }
    
    updateSetting_ = anUpdateSetting;
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithInteger:updateSetting_] forKey:kHockeyAutoUpdateSetting];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)setLastCheck:(NSDate *)aLastCheck {
    if (lastCheck_ != aLastCheck) {
        [lastCheck_ release];
        lastCheck_ = [aLastCheck copy];
        
		[[NSUserDefaults standardUserDefaults] setObject:[[lastCheck_ description] substringToIndex:10] forKey:kDateOfLastHockeyCheck];
		[[NSUserDefaults standardUserDefaults] synchronize];
    }
}

- (void)setApps:(NSArray *)anApps {
    if (apps_ != anApps || !apps_) {
        [apps_ release];
        [self willChangeValueForKey:@"apps"];
        
        // populate with default values (if empty)
        if (![anApps count]) {
            BWApp *defaultApp = [[[BWApp alloc] init] autorelease];
            defaultApp.name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
            defaultApp.version = currentAppVersion_;
            apps_ = [[NSArray arrayWithObject:defaultApp] retain];
        }else {
            apps_ = [anApps copy]; 
        }      
        [self didChangeValueForKey:@"apps"];
    }
}

- (BWApp *)app {
    BWApp *app = [apps_ objectAtIndex:0];
    return app;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark UIAlertViewDelegate

// invoke the selected action from the actionsheet for a location element
- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (buttonIndex == [alertView firstOtherButtonIndex]) {
        // YES button has been clicked
        [self showUpdateView];
    }
}

@end
