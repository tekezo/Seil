#import "AppDelegate.h"
#import "ClientForKernelspace.h"
#import "MigrationUtilities.h"
#import "PreferencesKeys.h"
#import "PreferencesManager.h"
#import "PreferencesModel.h"
#import "Relauncher.h"
#import "ServerController.h"
#import "ServerForUserspace.h"
#import "SessionObserver.h"
#import "SharedKeys.h"
#import "StartAtLoginUtilities.h"
#import "Updater.h"
#include "bridge.h"

@interface AppDelegate ()

@property(weak) IBOutlet ClientForKernelspace* clientForKernelspace;
@property(weak) IBOutlet PreferencesManager* preferencesManager;
@property(weak) IBOutlet PreferencesModel* preferencesModel;
@property(weak) IBOutlet ServerController* serverController;
@property(weak) IBOutlet ServerForUserspace* serverForUserspace;
@property(weak) IBOutlet Updater* updater;

// for IONotification
@property IONotificationPortRef notifyport;
@property CFRunLoopSourceRef loopsource;

@property SessionObserver* sessionObserver;

@end

@implementation AppDelegate

// ------------------------------------------------------------
static void observer_IONotification(void* refcon, io_iterator_t iterator) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"observer_IONotification");

    AppDelegate* self = (__bridge AppDelegate*)(refcon);
    if (!self) {
      NSLog(@"[ERROR] observer_IONotification refcon == nil\n");
      return;
    }

    for (;;) {
      io_object_t obj = IOIteratorNext(iterator);
      if (!obj) break;

      IOObjectRelease(obj);
    }
    // Do not release iterator.

    // = Documentation of IOKit =
    // - Introduction to Accessing Hardware From Applications
    //   - Finding and Accessing Devices
    //
    // In the case of IOServiceAddMatchingNotification, make sure you release the iterator only if you’re also ready to stop receiving notifications:
    // When you release the iterator you receive from IOServiceAddMatchingNotification, you also disable the notification.

    // ------------------------------------------------------------
    [self.clientForKernelspace refresh_connection_with_retry];
    [self.clientForKernelspace send_config_to_kext];
  });
}

- (void)unregisterIONotification {
  if (self.notifyport) {
    if (self.loopsource) {
      CFRunLoopSourceInvalidate(self.loopsource);
      self.loopsource = nil;
    }
    IONotificationPortDestroy(self.notifyport);
    self.notifyport = nil;
  }
}

- (void)registerIONotification {
  [self unregisterIONotification];

  self.notifyport = IONotificationPortCreate(kIOMasterPortDefault);
  if (!self.notifyport) {
    NSLog(@"[ERROR] IONotificationPortCreate failed\n");
    return;
  }

  // ----------------------------------------------------------------------
  io_iterator_t it;
  kern_return_t kernResult;

  kernResult = IOServiceAddMatchingNotification(self.notifyport,
                                                kIOMatchedNotification,
                                                IOServiceNameMatching("org_pqrs_driver_Seil"),
                                                &observer_IONotification,
                                                (__bridge void*)(self),
                                                &it);
  if (kernResult != kIOReturnSuccess) {
    NSLog(@"[ERROR] IOServiceAddMatchingNotification failed");
    return;
  }
  observer_IONotification((__bridge void*)(self), it);

  // ----------------------------------------------------------------------
  self.loopsource = IONotificationPortGetRunLoopSource(self.notifyport);
  if (!self.loopsource) {
    NSLog(@"[ERROR] IONotificationPortGetRunLoopSource failed");
    return;
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), self.loopsource, kCFRunLoopDefaultMode);
}

// ------------------------------------------------------------
- (void)applicationDidFinishLaunching:(NSNotification*)aNotification {
  [[NSApplication sharedApplication] disableRelaunchOnLogin];

  // ------------------------------------------------------------
  NSInteger relaunchedCount = [Relauncher getRelaunchedCount];

  // ------------------------------------------------------------
  if ([MigrationUtilities migrate:@[ @"org.pqrs.PCKeyboardHack" ]
           oldApplicationSupports:@[]
                         oldPaths:@[ @"/Applications/PCKeyboardHack.app" ]]) {
    [Relauncher relaunch];
  }

  // ------------------------------------------------------------
  if (![self.serverForUserspace registerService]) {
    // Relaunch when registerService is failed.
    NSLog(@"[ServerForUserspace registerService] is failed. Restarting process.");
    [NSThread sleepForTimeInterval:2];
    [Relauncher relaunch];
  }
  [Relauncher resetRelaunchedCount];

  // ------------------------------------------------------------
  [self.preferencesManager loadPreferencesModel:self.preferencesModel];
  [self.serverForUserspace setup];

  self.sessionObserver = [[SessionObserver alloc] init:1
      active:^{
        [self registerIONotification];
      }
      inactive:^{
        [self unregisterIONotification];
        [self.clientForKernelspace disconnect_from_kext];
      }];

  // ------------------------------------------------------------
  if (relaunchedCount == 0) {
    [self.updater checkForUpdatesInBackground];
  } else {
    NSLog(@"Skip checkForUpdatesInBackground in the relaunched process.");
  }

  // ------------------------------------------------------------
  [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kSeilServerDidLaunchNotification
                                                                 object:nil
                                                               userInfo:nil
                                                     deliverImmediately:YES];

  // ------------------------------------------------------------
  // Open Preferences if Seil was launched by hand.
  if (![StartAtLoginUtilities isStartAtLogin] &&
      self.preferencesModel.resumeAtLogin) {
    if (relaunchedCount == 0) {
      [self openPreferences];
    }
  }
  [self.serverController updateStartAtLogin:YES];

  {
    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    if (![bundlePath isEqualToString:@"/Applications/Seil.app"]) {
      if (relaunchedCount == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          NSAlert* alert = [NSAlert new];
          [alert setMessageText:@"Seil Alert"];
          [alert addButtonWithTitle:@"Close"];
          [alert setInformativeText:@"Seil.app should be located in /Applications/Seil.app.\nDo not move Seil.app into other folders."];
          [alert runModal];
        });
      }
    }
  }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)theApplication hasVisibleWindows:(BOOL)flag {
  [self openPreferences];
  return YES;
}

- (void)openPreferences {
  NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
  if ([bundlePath length] > 0) {
    [[NSWorkspace sharedWorkspace] openFile:[NSString stringWithFormat:@"%@/Contents/Applications/Seil Preferences.app", bundlePath]];
  }
}

@end
