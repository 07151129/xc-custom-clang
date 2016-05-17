#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#include <objc/runtime.h>
#include <mach/kern_return.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

#include "rd_route.h"


__attribute__((unused))
char* c = "Built with "__clang_version__; // Should match custom clang version after preprocessing or building

// Derived from kattrali/Xcode-Plugin-Template

@interface PBSClangCustomPlugin : NSObject
+(instancetype)sharedPlugin;
@property (nonatomic, strong, readonly) NSBundle* bundle;
@end

static PBSClangCustomPlugin* sharedPlugin;

NSString* (*org__dg_get_string)(id, NSString*) = nil;

static NSString* _dg_get_string(id __unsafe_unretained scope, NSString* __unsafe_unretained s) {
	if ([s isEqualToString:@"DEFAULT_COMPILER"])
		return @"com.pb.compiler.clang-custom";
	return org__dg_get_string(scope, s);
}

void* libclangHandle = nil;

#define CLANG_PREFIX "/usr/local"

#include "libclang_imports.h"

/**
 * FIXME: This is executed before clang queue is scheduled,
 * but it would still be nice to obtain the corresponding lock
 * to ensure no race
 **/
/* FIXME: Patching GOT is probably a better idea */
/* FIXME: Instead of dlopen'ing libclang, link it so that we don't waste time on dlsym */
static kern_return_t replaceLib() {
	libclangHandle = dlopen(CLANG_PREFIX"/lib/libclang.dylib", RTLD_LAZY | RTLD_LOCAL);
	
	if (!libclangHandle) {
		fprintf(stderr, "Failed to dlopen libclang, err: %s\n", dlerror());
		return KERN_FAILURE;
	}
	
	for (size_t i = 0; i < sizeof(libclangImports) / sizeof(char*); i++) {
		void* repl = dlsym(libclangHandle, libclangImports[i] + 1);
		if (!repl) {
			fprintf(stderr, "Failed to find %s in provided libclang, err: %s\n", libclangImports[i], dlerror());
			return KERN_FAILURE;
		}
		void* dst = dlsym(RTLD_DEFAULT, libclangImports[i] + 1);
		if (rd_route(dst, repl, nil) != KERN_SUCCESS) {
			fprintf(stderr, "Failed to reroute %s\n", libclangImports[i]);
			return false;
		}
//		fprintf(stderr, "replaced %s at 0x%x\n", libclangImports[i], dst);
	}
	
	return KERN_SUCCESS;
}

@implementation PBSClangCustomPlugin

+(void)pluginDidLoad:(NSBundle *)plugin {
	NSString* loader = [[NSBundle mainBundle] bundleIdentifier];
	if (![loader isEqualToString:@"com.apple.dt.Xcode"] &&
		![loader isEqualToString:@"com.apple.dt.xcodebuild"] &&
		![[[NSString stringWithUTF8String:_dyld_get_image_name(0)] lastPathComponent] isEqualToString:@"xcodebuild"]) /* Xcodebuild doesn't always have bundle id? */
		return;
	sharedPlugin = [[self alloc] initWithBundle:plugin];
}

+(instancetype)sharedPlugin {
	return sharedPlugin;
}

-(id)initWithBundle:(NSBundle *)bundle {
	if (self = [super init]) {
		// reference to plugin's bundle, for resource access
		_bundle = bundle;
		// NSApp may be nil if the plugin is loaded from the xcodebuild command line tool
		if (NSApp && !((NSApplication*)NSApp).mainMenu) {
			[[NSNotificationCenter defaultCenter] addObserver:self
													 selector:@selector(applicationDidFinishLaunching:)
														 name:NSApplicationDidFinishLaunchingNotification
													   object:nil];
		} else {
			[self initializeAndLog];
		}
	}
	return self;
}

-(void)applicationDidFinishLaunching:(NSNotification *)notification {
	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidFinishLaunchingNotification object:nil];
	[self initializeAndLog];
}

-(void)initializeAndLog {
	NSString *name = [self.bundle objectForInfoDictionaryKey:@"CFBundleName"];
	NSString *version = [self.bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	NSString *status = [self initialize] ? @"loaded successfully" : @"failed to load";
	NSLog(@"Plugin %@ %@ %@", name, version, status);
}

-(BOOL)initialize {
	BOOL replace = [[[self bundle] objectForInfoDictionaryKey:@"PBSReplaceDefault"] boolValue];
	if (replace && rd_route_byname("_dg_get_string", "DevToolsCore", _dg_get_string, (void**)&org__dg_get_string) != KERN_SUCCESS)
		return false;
	
	replace = [[[self bundle] objectForInfoDictionaryKey:@"PBSReplaceLibclang"] boolValue];
	if (replace && replaceLib() != KERN_SUCCESS) {
		if (libclangHandle)
			dlclose(libclangHandle);
		return false;
	}
	return true;
}

@end
