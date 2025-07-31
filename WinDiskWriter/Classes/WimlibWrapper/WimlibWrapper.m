//
//  WimlibWrapper.m
//  windiskwriter
//
//  Created by Macintosh on 12.02.2023.
//  Copyright © 2023 TechUnRestricted. All rights reserved.
//

#import "WimlibWrapper.h"
#import "CChar2DArray.h"
#import "WimlibSplitInfo.h"
#import "HelperFunctions.h"
#import "Constants.h"
#import "wimlib.h"
#import "wim.h"
#import "xml.h"

@implementation WimlibWrapper {
    WIMStruct *currentWIM;
}

- (instancetype)initWithWimPath: (NSString *)wimPath {
    self = [super self];
    
    enum wimlib_error_code wimOpenStatus = wimlib_open_wim([wimPath UTF8String], NULL, &currentWIM);
    _wimPath = wimPath;
    
    return self;
}

- (UInt32)imagesCount {
    if (currentWIM == NULL) {
        return 0;
    }
    
    return currentWIM->hdr.image_count;
}

- (WimLibWrapperCPUArch)CPUArchitectureForImageIndex: (UInt32)imageIndex {
    if (currentWIM == NULL) {
        return NULL;
    }
    
    NSString *stringValue = [self propertyValueForKey: @"WINDOWS/ARCH"
                                           imageIndex: imageIndex];
    
    if (stringValue == NULL) {
        return WimLibWrapperCPUArchUnknown;
    }
    
    NSInteger convertedIntegerValue = [stringValue integerValue];
    
    switch (convertedIntegerValue) {
        case WimLibWrapperCPUArchIntel:
        case WimLibWrapperCPUArchMIPS:
        case WimLibWrapperCPUArchAlpha:
        case WimLibWrapperCPUArchPPC:
        case WimLibWrapperCPUArchSHX:
        case WimLibWrapperCPUArchARM:
        case WimLibWrapperCPUArchIA64:
        case WimLibWrapperCPUArchAlpha64:
        case WimLibWrapperCPUArchMSIL:
        case WimLibWrapperCPUArchAMD64:
        case WimLibWrapperCPUArchIA32OnWin64:
        case WimLibWrapperCPUArchARM64:
            return convertedIntegerValue;
        default:
            return WimLibWrapperCPUArchUnknown;
    }
}

- (NSString *_Nullable)propertyValueForKey: (NSString *)key
                                imageIndex: (NSUInteger)imageIndex {
    if (currentWIM == NULL) {
        return NULL;
    }
    
    char *value = wimlib_get_image_property(currentWIM, imageIndex, key.UTF8String);
    
    if (value == NULL) {
        return NULL;
    }
    
    return [NSString stringWithCString: value
                              encoding: NSUTF8StringEncoding];
}

- (WimlibWrapperResult)setPropertyValue: (NSString *)value
                                 forKey: (NSString *)key
                             imageIndex: (UInt32)imageIndex {
    if (currentWIM == NULL) {
        return NO;
    }
    
    NSString *currentValue = [self propertyValueForKey: key
                                            imageIndex: imageIndex];
    
    if (currentValue == NULL) {
        return WimlibWrapperResultSkipped;
    }
    
    if ([value isEqualToString:currentValue]) {
        return WimlibWrapperResultSkipped;
    }
    
    enum wimlib_error_code result = wimlib_set_image_property(currentWIM,
                                                              imageIndex,
                                                              [key cStringUsingEncoding: NSUTF8StringEncoding],
                                                              [value cStringUsingEncoding: NSUTF8StringEncoding]);
    
    if (result != WIMLIB_ERR_SUCCESS) {
        return WimlibWrapperResultFailure;
    }
    
    return WimlibWrapperResultSuccess;
}

- (WimlibWrapperResult)setPropertyValueForAllImages: (NSString *)value
                                             forKey: (NSString *)key {
    
    UInt32 imagesCount = [self imagesCount];
    
    BOOL requiresOverwriting = NO;
    
    for (UInt32 currentImageIndex = 1; currentImageIndex <= imagesCount; currentImageIndex++) {
        WimlibWrapperResult setPropertyResult = [self setPropertyValue: value
                                                                forKey: key
                                                            imageIndex: currentImageIndex];
        
        switch (setPropertyResult) {
            case WimlibWrapperResultSuccess:
                requiresOverwriting = YES;
                break;
            case WimlibWrapperResultFailure:
                return WimlibWrapperResultFailure;
            case WimlibWrapperResultSkipped:
                break;
        }
    }
    
    return requiresOverwriting ? WimlibWrapperResultSuccess : WimlibWrapperResultSkipped;
}

- (BOOL)applyChanges {
    if (currentWIM == NULL) {
        return NO;
    }
    
    enum wimlib_error_code overwriteReturnCode = wimlib_overwrite(currentWIM, 0, 1);
    
    return overwriteReturnCode == WIMLIB_ERR_SUCCESS;
}

- (enum wimlib_error_code)splitWithDestinationDirectoryPath: (NSString *)destinationDirectoryPath
                                        maxSliceSizeInBytes: (UInt64 *)maxSliceSizeInBytes
                                            progressHandler: (wimlib_progress_func_t _Nullable)progressHandler
                                                    context: (void *_Nullable)context {
    if (currentWIM == NULL) {
        return WIMLIB_ERR_ABORTED_BY_PROGRESS;
    }
    
    if (progressHandler != NULL) {
        wimlib_register_progress_function(currentWIM, progressHandler, context);
    }
    
    NSString *destinationFileName = [[[_wimPath lastPathComponent] stringByDeletingPathExtension] stringByAppendingPathExtension:@"swm"];
    
    return wimlib_split(currentWIM,
                        [[destinationDirectoryPath stringByAppendingPathComponent:destinationFileName] UTF8String],
                        maxSliceSizeInBytes,
                        NULL
                        );
}

enum wimlib_progress_status defaultSplitProgress(enum wimlib_progress_msg msg, union wimlib_progress_info *info, void *context) {
    WimlibSplitInfo *contextWimlibSplitStatus = (__bridge WimlibSplitInfo *)(context);

    switch (msg) {
        case WIMLIB_PROGRESS_MSG_WRITE_STREAMS: {
            UInt64 bytesTotal = contextWimlibSplitStatus.lastSplittedPartInfo.total_bytes;
            UInt64 bytesWritten = info->write_streams.completed_compressed_bytes + contextWimlibSplitStatus.lastSplittedPartInfo.completed_bytes;

            UInt32 totalPartsCount = contextWimlibSplitStatus.lastSplittedPartInfo.total_parts;
            UInt32 currentPartNumber = contextWimlibSplitStatus.lastSplittedPartInfo.cur_part_number;
            
            BOOL shouldContinue = contextWimlibSplitStatus.callback(totalPartsCount, currentPartNumber, bytesWritten, bytesTotal);
            
            if (!shouldContinue) {
                return WIMLIB_PROGRESS_STATUS_ABORT;
            }
        }
            
            break;
        case WIMLIB_PROGRESS_MSG_SPLIT_BEGIN_PART:
        case WIMLIB_PROGRESS_MSG_SPLIT_END_PART:
            [contextWimlibSplitStatus setLastSplittedPartInfo: info->split];
            break;
    }
        
    return WIMLIB_PROGRESS_STATUS_CONTINUE;
}

- (WimlibWrapperResult)splitWithDestinationDirectoryPath: (NSString *)destinationDirectoryPath
                                     maxSliceSizeInBytes: (UInt64 *)maxSliceSizeInBytes
                                                callback: (WimLibWrapperSplitImageCallback)callback {
    
    WimlibSplitInfo *wimlibSplitInfo = [[WimlibSplitInfo alloc] initWithCallback: callback];
    
    enum wimlib_error_code wimlibSplitStatus = [self splitWithDestinationDirectoryPath: destinationDirectoryPath
                                                                   maxSliceSizeInBytes: maxSliceSizeInBytes
                                                                       progressHandler: defaultSplitProgress
                                                                               context: (__bridge void * _Nullable)(wimlibSplitInfo)];
        
    switch (wimlibSplitStatus) {
        case WIMLIB_ERR_SUCCESS:
            return WimlibWrapperResultSuccess;
        case WIMLIB_ERR_ABORTED_BY_PROGRESS:
            return WimlibWrapperResultSkipped;
        default:
            return WimlibWrapperResultFailure;
    }

}


- (BOOL)extractFiles: (NSArray *)files
destinationDirectory: (NSString *)destinationDirectory
      fromImageIndex: (UInt32)imageIndex {
    
    if (currentWIM == NULL) {
        return NULL;
    }
    
    CChar2DArray *filesArrayCCharEncoded = [[CChar2DArray alloc] initWithNSArray:files];
    
    enum wimlib_error_code extractionResult = wimlib_extract_paths(currentWIM,
                                                                   imageIndex,
                                                                   [destinationDirectory UTF8String],
                                                                   [filesArrayCCharEncoded getArray],
                                                                   [files count],
                                                                   WIMLIB_EXTRACT_FLAG_NO_PRESERVE_DIR_STRUCTURE
                                                                   );
    
    return extractionResult == WIMLIB_ERR_SUCCESS;
}

- (WimlibWrapperResult)extractWindowsEFIBootloaderForDestinationDirectory: (NSString *)destinationDirectory {
    UInt32 imagesCount = [self imagesCount];
    
    if (imagesCount == 0) {
        return WimlibWrapperResultSkipped;
    }
    
    for (UInt32 currentImageIndex = 1; currentImageIndex <= imagesCount; currentImageIndex++) {
        if ([self CPUArchitectureForImageIndex:currentImageIndex] != WimLibWrapperCPUArchAMD64) {
            continue;
        }
        
        BOOL bootloaderExtractionResult = [self extractFiles: @[@"/Windows/Boot/EFI/bootmgfw.efi"]
                                        destinationDirectory: destinationDirectory
                                              fromImageIndex: currentImageIndex];
        
        if (!bootloaderExtractionResult) {
            return WimlibWrapperResultFailure;
        }
        
        BOOL bootloaderRanamingSuccess = [NSFileManager.defaultManager moveItemAtPath: [destinationDirectory stringByAppendingPathComponent: @"bootmgfw.efi"]
                                                                               toPath: [destinationDirectory stringByAppendingPathComponent: @"bootx64.efi"]
                                                                                error: NULL];
        if (!bootloaderRanamingSuccess) {
            return NO;
        }
        
        return WimlibWrapperResultSuccess;
    }
    
    return WimlibWrapperResultSkipped;
}

- (WimlibWrapperResult)patchWindowsRequirementsChecks {
    if (currentWIM == NULL) {
        return WimlibWrapperResultFailure;
    }
    
    WimlibWrapperResult setPropertyResult = [self setPropertyValueForAllImages: @"Server"
                                                                        forKey: @"WINDOWS/INSTALLATIONTYPE"];
    
    switch (setPropertyResult) {
        case WimlibWrapperResultSkipped:
        case WimlibWrapperResultFailure:
            return setPropertyResult;
        default:
            break;
    }
    
    BOOL applyChangesResult = [self applyChanges];
    
    return applyChangesResult ? WimlibWrapperResultSuccess : WimlibWrapperResultFailure;
}

- (WimlibWrapperResult)patchWindowsRegistryChecks {
    if (currentWIM == NULL) {
        return WimlibWrapperResultFailure;
    }
    
    NSURL *fileURL = [NSURL fileURLWithPath:_wimPath];
    NSURL *containingDirectory = [fileURL URLByDeletingLastPathComponent];
    NSError *directoryCreateError = NULL;
    NSFileManager *localFileManager = [NSFileManager defaultManager];
    NSString *randomFolderName = [NSString stringWithFormat:@"bi-%@", [HelperFunctions randomStringWithLength:10]];
    NSString *tempDirectory = [containingDirectory.path stringByAppendingPathComponent: randomFolderName];
    BOOL directoryCreatedSuccessfully = [localFileManager createDirectoryAtPath: tempDirectory
                                                    withIntermediateDirectories: YES
                                                                     attributes: NULL
                                                                          error: &directoryCreateError];
    
    if (!directoryCreatedSuccessfully) {
        return WimlibWrapperResultFailure;
    }
    NSArray *registryFiles = [NSArray arrayWithObjects:@"/Windows/System32/config/SYSTEM", nil ];
    
    BOOL extracted = [self extractFiles:registryFiles destinationDirectory:tempDirectory fromImageIndex:1];
    if (!extracted) {
        return WimlibWrapperResultFailure;
    }
    NSString *disableCommandsFilePath = [tempDirectory stringByAppendingPathComponent:@"disable.tpm.commands"];

    NSError *error;
    [HIVEXSH_BYPASS_TPM_CHECK_COMMANDS writeToFile:disableCommandsFilePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    NSString *systemRegistryFile = [tempDirectory stringByAppendingPathComponent:@"SYSTEM"];
    
    NSArray *argumenst = [NSArray arrayWithObjects:@"-w", @"-f", disableCommandsFilePath, systemRegistryFile, nil ];
    NSError *hivexshErrors;
    BOOL updated = [HelperFunctions runCommand:@"/opt/homebrew/bin/hivexsh" workingPath:tempDirectory arguments:argumenst error:&hivexshErrors];
    
    if (!updated) {
        NSLog([NSString stringWithFormat:@"Failed to run hivexsh on boot index 1: %@", hivexshErrors]);
        return WimlibWrapperResultFailure;
    }
    struct wimlib_add_command addCommand = {0};
    addCommand.fs_source_path = (const tchar *) [systemRegistryFile cString];
    addCommand.wim_target_path = [@"/Windows/System32/config/SYSTEM" cString];
    
    struct wimlib_update_command update_cmd = {0};
    update_cmd.op = WIMLIB_UPDATE_OP_ADD;
    update_cmd.add = addCommand;
    
    int res = wimlib_update_image(currentWIM, 1, &update_cmd, 1, NULL);
    
    if (res != 0) {
        const tchar *rawUpdateError = wimlib_get_error_string(res);
        NSString *updateError = [[NSString alloc] initWithCString:rawUpdateError];
        NSLog(@"%@", updateError);
        return WimlibWrapperResultFailure;
    }
    
    extracted = [self extractFiles:registryFiles destinationDirectory:tempDirectory fromImageIndex:2];
    if (!extracted) {
        return WimlibWrapperResultFailure;
    }

    updated = [HelperFunctions runCommand:@"/opt/homebrew/bin/hivexsh" workingPath:tempDirectory arguments:argumenst error:&hivexshErrors];
    
    if (!updated) {
        NSLog([NSString stringWithFormat:@"Failed to run hivexsh on boot index 2: %@", hivexshErrors]);
        return WimlibWrapperResultFailure;
    }
    res = wimlib_update_image(currentWIM, 1, &update_cmd, 1, NULL);
   
    if (res != 0) {
        const tchar *rawUpdateError = wimlib_get_error_string(res);
        NSString *updateError = [[NSString alloc] initWithCString:rawUpdateError];
        NSLog(@"%@", updateError);
        return WimlibWrapperResultFailure;
    }
    
    BOOL applyChangesResult = [self applyChanges];
    
    return applyChangesResult ? WimlibWrapperResultSuccess : WimlibWrapperResultFailure;
}

- (WimlibWrapperResult)removeChecks {
    if (currentWIM == NULL) {
        return WimlibWrapperResultFailure;
    }
    
    
}

- (void)dealloc {
    if (currentWIM != NULL) {
        wimlib_free(currentWIM);
    }
}

@end
