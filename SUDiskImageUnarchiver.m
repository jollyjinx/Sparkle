//
//  SUDiskImageUnarchiver.m
//  Sparkle
//
//  Created by Andy Matuschak on 6/16/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUDiskImageUnarchiver.h"
#import "SUUnarchiver_Private.h"
#import "NTSynchronousTask.h"
#import "SULog.h"
#import <CoreServices/CoreServices.h>


@implementation SUDiskImageUnarchiver

+ (BOOL)_canUnarchivePath:(NSString *)path
{
	return [[path pathExtension] isEqualToString:@"dmg"];
}

- (void)start
{
	[NSThread detachNewThreadSelector:@selector(_extractDMG) toTarget:self withObject:nil];
}

- (void)_extractDMG
{		
	// GETS CALLED ON NON-MAIN THREAD!!!
	
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	BOOL mountedSuccessfully = NO;
	
	SULog(@"Extracting %@ as a DMG", archivePath);
	
	// get a unique mount point path
	NSString *mountPointName = nil;
	NSString *mountPoint = nil;
	FSRef tmpRef;
	do
	{
		CFUUIDRef uuid = CFUUIDCreate(NULL);
		mountPointName = (NSString *)CFUUIDCreateString(NULL, uuid);
		CFRelease(uuid);
#if MAC_OS_X_VERSION_MAX_ALLOWED > MAC_OS_X_VERSION_10_4
		[NSMakeCollectable((CFStringRef)mountPointName) autorelease];
#else
		[mountPointName autorelease];
#endif
		mountPoint = [@"/Volumes" stringByAppendingPathComponent:mountPointName];
	}
	while (noErr == FSPathMakeRefWithOptions((UInt8 *)[mountPoint fileSystemRepresentation], kFSPathMakeRefDoNotFollowLeafSymlink, &tmpRef, NULL));
	
	NSArray* arguments = [NSArray arrayWithObjects:@"attach", archivePath, @"-mountpoint", mountPoint, /*@"-noverify",*/ @"-nobrowse", @"-noautoopen", nil];
	// set up a pipe and push "yes" (y works too), this will accept any license agreement crap
	// not every .dmg needs this, but this will make sure it works with everyone
	NSData* yesData = [[[NSData alloc] initWithBytes:"yes\n" length:4] autorelease];
	
	NSData *output = nil;
	int	returnCode = [NTSynchronousTask task:@"/usr/bin/hdiutil" directory:@"/" withArgs:arguments input:yesData output: &output];
	if ( returnCode != 0 )
	{
		NSString*	resultStr = output ? [[[NSString alloc] initWithData: output encoding: NSUTF8StringEncoding] autorelease] : nil;
		SULog( @"hdiutil failed with code: %d data: <<%@>>", returnCode, resultStr );
		goto reportError;
	}
	mountedSuccessfully = YES;
	
	// Now that we've mounted it, we need to copy out its contents.
	FSRef srcRef, dstRef;
	OSErr err;
	err = FSPathMakeRef((UInt8 *)[mountPoint fileSystemRepresentation], &srcRef, NULL);
	if (err != noErr) goto reportError;
	err = FSPathMakeRef((UInt8 *)[[archivePath stringByDeletingLastPathComponent] fileSystemRepresentation], &dstRef, NULL);
	if (err != noErr) goto reportError;
	
	err = FSCopyObjectSync(&srcRef, &dstRef, (CFStringRef)mountPointName, NULL, kFSFileOperationSkipSourcePermissionErrors);
	if (err != noErr) goto reportError;
	
	// DMG's created on 10.6 do always have a .HFS+\ Private\ Directory\ Data^M file which is immutable -changing the immutable flag now.
	NSString	*hiddenSpecialFilenameString = [[[archivePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:mountPointName] stringByAppendingPathComponent:@".HFS+ Private Directory Data\r"];
	[[NSTask launchedTaskWithLaunchPath:@"/usr/bin/chflags" arguments:[NSArray arrayWithObjects:@"-R",@"nouchg",hiddenSpecialFilenameString, nil]] waitUntilExit];
	
	[self performSelectorOnMainThread:@selector(_notifyDelegateOfSuccess) withObject:nil waitUntilDone:NO];
	goto finally;
	
reportError:
	[self performSelectorOnMainThread:@selector(_notifyDelegateOfFailure) withObject:nil waitUntilDone:NO];

finally:
	if (mountedSuccessfully)
		[NSTask launchedTaskWithLaunchPath:@"/usr/bin/hdiutil" arguments:[NSArray arrayWithObjects:@"detach", mountPoint, @"-force", nil]];
	else
		SULog(@"Can't mount DMG %@",archivePath);
	[pool drain];
}

+ (void)load
{
	[self _registerImplementation:self];
}

@end
