#import "CDEProjectBrowserWindowController.h"
#import "CDEProjectBrowserItem.h"
#import "NSAlert-OAExtensions.h"
#import "CDEDocument.h"
#import "CDEConfiguration.h"
#import "CDEApplicationDelegate.h"
#import "NSURL+CDEAdditions.h"

#define kCDEFileModificationDateKey @"modificationDate"
#define kCDEStorePathKey @"storePath"
#define kCDEModelPathKey @"modelPath"

@interface CDEProjectBrowserWindowController ()

#pragma mark - Properties
@property (nonatomic, copy) NSURL *projectDirectoryURL;

@property (strong) IBOutlet NSProgressIndicator *reloadProgressIndicator;
@property (strong) IBOutlet NSButton *reloadButton;

@property (strong) IBOutlet NSArrayController *items;
@property (strong) IBOutlet NSTableView *tableView;

@end

@implementation CDEProjectBrowserWindowController

#pragma mark - Working with the project browser
- (void)showWithProjectDirectoryURL:(NSURL *)projectDirectoryURL {
    self.projectDirectoryURL = projectDirectoryURL;
    [self showWindow:self];
    [self updateUI];
    [self reloadProjectBrowser:self];
}

- (void)updateProjectDirectoryURL:(NSURL *)projectDirectoryURL {
    self.projectDirectoryURL = projectDirectoryURL;
    [self reloadProjectBrowser:self];
}

- (void)updateUI {
    [self.reloadButton setEnabled:(self.projectDirectoryURL != nil)];
}

#pragma mark - Actions
- (IBAction)createProject:(id)sender {
    NSInteger row = [self.tableView rowForView:sender];
    if(row == -1) {
        return;
    }
    CDEProjectBrowserItem *item = [self.items.arrangedObjects objectAtIndex:row];
    
    if(item == nil) {
        return;
    }
    CDEDocument *document = [[NSDocumentController sharedDocumentController] openUntitledDocumentAndDisplay:NO error:NULL];
    CDEConfiguration *c = [document createConfiguration];
    NSError *error = nil;
    NSURL *storeURL = [NSURL fileURLWithPath:item.storePath];
    NSURL *modelURL = [NSURL fileURLWithPath:item.modelPath];
    
    BOOL set = [c setBookmarkDataWithApplicationBundleURL:nil storeURL:storeURL modelURL:modelURL error:&error];
    if(!set) {
        NSLog(@"error: %@", error);
    }
    error = nil;
    BOOL setup = [document setupAndStartAccessingConfigurationRelatedURLsAndGetError:&error];
    if(!setup) {
        NSLog(@"error: %@", error);
    }
    [document makeWindowControllers];
    [document showWindows];
}

- (IBAction)reloadProjectBrowser:(id)sender {
    NSURL *simulatorURL = self.projectDirectoryURL;
    if(simulatorURL == nil) {
        NSLog(@"simulator url is nil");
        [self displayDelayedNoSimulatorDirectoryAlert];
        return;
    }
    
    [self.items setContent:[@[] mutableCopy]];
    
    [self.reloadButton setEnabled:NO];
    [self.reloadProgressIndicator startAnimation:self];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fileManager = [NSFileManager new];
        NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:simulatorURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *url, NSError *error) {
            NSLog(@"error while enumerating contents of simulator directory: %@", error);
            return YES;
        }];
        
        NSMutableDictionary *metadataByStorePath = [NSMutableDictionary new];
        NSMutableDictionary *modelByModelPath = [NSMutableDictionary new];
        
        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        for(NSURL *URL in enumerator) {
            NSError *error = nil;
            NSString *UTI = [workspace typeOfFile:URL.path error:&error];
            if(UTI == nil) {
                NSLog(@"Failed to determine UTI: %@", error);
                continue;
            }
            BOOL isModel = [workspace type:UTI conformsToType:@"com.apple.xcode.mom"];
            if(isModel) {
                @try {
                    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:URL];
                    if(model == nil) {
                        continue;
                    }
                    NSManagedObjectModel *transformedModel = model.transformedManagedObjectModel_cde;
                    if(transformedModel == nil) {
                        continue;
                    }
                    modelByModelPath[URL.path] = transformedModel;
                }
                @catch (NSException *exception) {
                    
                }
                @finally {
                    
                }
                
                continue;
            }
            
            BOOL isData = [workspace type:UTI conformsToType:@"public.data"];
            if(isData == NO) {
                continue;
            }
            
            if([URL isSQLiteURL_cde] == NO) {
                continue;
            }
            
            error = nil;
            NSDictionary *metadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:nil URL:URL error:&error];
            if(metadata == nil) {
                continue;
            }
            metadataByStorePath[URL.path] = metadata;
        }
                
        NSMutableArray *items = [NSMutableArray new];
        NSMutableArray *itemsWithDates=[NSMutableArray new]; // Each element is dictionary with {modificationDate:, storePath:, modelPath}

        // Find compatible combinations
        [modelByModelPath enumerateKeysAndObjectsUsingBlock:^(NSString *modelPath, NSManagedObjectModel *model, BOOL *stop) {
            [metadataByStorePath enumerateKeysAndObjectsUsingBlock:^(NSString *storePath, NSDictionary *metadata, BOOL *stop) {
                BOOL isCompatible = [model isConfiguration:nil compatibleWithStoreMetadata:metadata];
                if(isCompatible) {
                    NSString *storePathAppName = [[NSURL fileURLWithPath:storePath] appFolderName_cde];
                    NSString *modelPathAppName = [[NSURL fileURLWithPath:modelPath] appFolderName_cde];
                    BOOL sameApplication = [storePathAppName isEqualToString:modelPathAppName];
                    if (sameApplication) {
                        CDEProjectBrowserItem *item = [[CDEProjectBrowserItem alloc] initWithStorePath:storePath modelPath:modelPath];
                        [items addObject:item];
                    }
                    NSDate *storeModDate;
                    NSURL *storeURL=[NSURL fileURLWithPath:storePath];
                    NSError *error;
                    [storeURL getResourceValue:&storeModDate forKey:NSURLContentModificationDateKey error:&error];
                    
                    //Also look for: .sqlite-wal (write-ahead log).  Use most recent, although the wal should be most recent if found.
                    NSString *walPath=[NSString stringWithFormat:@"%@-wal",storeURL.absoluteString];
                    NSURL *walUrl=[NSURL URLWithString:walPath];
                    NSDate *walModDate;
                    [walUrl getResourceValue:&walModDate forKey:NSURLContentModificationDateKey error:&error];
                    
                    if ([storeModDate compare:walModDate]==NSOrderedAscending) {
                        storeModDate=walModDate;
                    }

                    NSDate *modelModDate;
                    NSURL *modelURL=[NSURL fileURLWithPath:modelPath];
                    [modelURL getResourceValue:&modelModDate forKey:NSURLContentModificationDateKey error:&error];

                    //NSSortDescriptor doesn't do NSDate, so use a string. Both dates concatenated for nesting.
                    NSString *fileModDateString=[NSString stringWithFormat:@"%@ - %@",storeModDate,modelModDate];
                    
                    NSDictionary *itemWithDate=@{kCDEFileModificationDateKey: fileModDateString,
                                                 kCDEStorePathKey: storePath,
                                                 kCDEModelPathKey: modelPath};
                    
                    [itemsWithDates addObject:itemWithDate];
                }
            }];
        }];
        
        //Now sort and display
        NSSortDescriptor *descriptor = [[NSSortDescriptor alloc] initWithKey:kCDEFileModificationDateKey ascending:NO];
        NSArray *itemsSorted=[itemsWithDates sortedArrayUsingDescriptors:[NSArray arrayWithObjects:descriptor,nil]];
        
        for (NSDictionary *itemWithDate in itemsSorted) {
            NSString *storePath=itemWithDate[kCDEStorePathKey];
            NSString *modelPath=itemWithDate[kCDEModelPathKey];
            CDEProjectBrowserItem *item = [[CDEProjectBrowserItem alloc] initWithStorePath:storePath modelPath:modelPath];
            [items addObject:item];
        }
        
        double delayInSeconds = 1.0;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self.items setContent:items];
            [self.reloadButton setEnabled:YES];
            [self.reloadProgressIndicator stopAnimation:self];
        });
    });
}

#pragma mark - Helper
- (void)displayDelayedNoSimulatorDirectoryAlert {
    double delayInSeconds = 2.0;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        NSAlert *alert = [NSAlert alertWithMessageText:@"iPhone Simulator Directory not set" defaultButton:@"Open Preferences…" alternateButton:@"Close Project Browser" otherButton:nil informativeTextWithFormat:@"The Project Browser has to know where the iPhone Simulator directory is. Please go to the preferences and specify your iPhone Simulator directory in the Integration tab."];
        alert.alertStyle = NSInformationalAlertStyle;
        [alert beginSheetModalForWindow:self.window completionHandler_oa:^(NSAlert *alert, NSInteger returnCode) {
            if(returnCode ==  NSAlertDefaultReturn) {
                // show prefs.
                [(CDEApplicationDelegate *)[NSApp delegate] showPreferences:self];
            }
            [self closeWindowSoon];
        }];
    });
}

- (void)closeWindowSoon {
    double delayInSeconds = 2.0;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self.window performClose:self];
    });
}

#pragma mark - NSWindowController
- (instancetype)init {
    self = [super initWithWindowNibName:@"CDEProjectBrowserWindowController" owner:self];
    if(self) {
        
    }
    return self;
}

- (void)windowDidLoad {
    [super windowDidLoad];
}

@end
