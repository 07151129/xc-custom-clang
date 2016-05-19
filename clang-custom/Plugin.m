#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#include <objc/runtime.h>
#include <mach/kern_return.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <assert.h>

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

struct libclangImporter {
	char* imgName;
	uint32_t nimports;
	struct importedSym {
		char* name;
		void* addr;
	} importedSyms[256];
};

extern inline
uint32_t ulebDec(const uint8_t* at, uint32_t* dec) {
	uint32_t shamt = 0;
	while (true) {
		*dec |= (*at & 0x7f) << shamt;
		if ((*at & 0x80) == 0)
			break;
		at++;
		shamt += 7;
	}
	return shamt / 7;
}

static kern_return_t findLibclangImports(struct libclangImporter** importers, uint32_t* nfound, uint32_t sz) {
	uint32_t found = 0;
	
	for (uint32_t i = 0; i < _dyld_image_count() && found < sz; i++) {
		const char* imgName = _dyld_get_image_name(i);
		assert(imgName);
		char* slash = strrchr(imgName, '/');
		if (!slash)
			slash = (char*)imgName;
		
		if (!strcmp(slash, "/clang-custom")) /* Ignore ourselves */
			continue;
		
		struct mach_header* mh = (void*)_dyld_get_image_header(i);
		assert(mh);
//		intptr_t slide = _dyld_get_image_vmaddr_slide(i);
		uint64_t lazyBindOffs = 0;
		uint64_t lazyBindSz = 0;
		uint64_t dataOffs = 0;
		uint32_t dataIdx = 0;
		uint32_t nsegs = 0;
		uint32_t nimports = 0;
		uint32_t libclangOrdinal = 0;
		
		if (mh->magic != MH_MAGIC_64 && mh->magic != MH_MAGIC) {
			fprintf(stderr, "Skipping fat image at 0x%lx\n", (uintptr_t)mh);
			continue;
		}
		
		struct load_command* lc = (void*)mh + sizeof(*mh) + (mh->magic == MH_MAGIC_64 ? sizeof(struct mach_header_64) - sizeof(struct mach_header) : 0);
		
		for (uint32_t i = 0; i < mh->ncmds; i++) {
			if (lc->cmd == LC_DYLD_INFO_ONLY) {
				struct dyld_info_command* cmd = (void*)lc;
				
				lazyBindOffs += cmd->lazy_bind_off;
				lazyBindSz = cmd->lazy_bind_size;
			} else if (lc->cmd == LC_SEGMENT || lc->cmd == LC_SEGMENT_64) {
				struct segment_command* cmd = (void*)lc;
				struct segment_command_64* cmd64 = (void*)lc;
				
				if (!strcmp(cmd->segname, SEG_DATA)) {
					dataIdx = nsegs;
					dataOffs = lc->cmd == LC_SEGMENT ? cmd->vmaddr : cmd64->vmaddr;
				} else if (!strcmp(cmd->segname, SEG_LINKEDIT)) {
					lazyBindOffs += lc->cmd == LC_SEGMENT ? cmd->vmaddr - cmd->fileoff : cmd64->vmaddr - cmd64->fileoff;
				}
				nsegs++;
			} else if ((lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) && libclangOrdinal == 0) {
				struct dylib_command* cmd = (struct dylib_command*)lc;
				
				const char* dylibName = (void*)cmd + cmd->dylib.name.offset;
				char* slash = strrchr(dylibName, '/');
				if (!slash)
					slash = (char*)dylibName;
				if (!strcmp(slash, "/libclang.dylib"))
					libclangOrdinal = nimports + 1;
				nimports++;
			}
			lc = (void*)((char*)lc + lc->cmdsize);
		}
		
		if (!lazyBindOffs || !lazyBindSz || libclangOrdinal == 0)
			continue;
		
		struct libclangImporter* importer = calloc(1, sizeof(struct libclangImporter));
		
		importer->imgName = calloc(strlen(imgName) + 1, sizeof(char));
		strcpy(importer->imgName, imgName);
		
		struct {
			uint32_t seg;
			uint32_t offs;
			uint32_t dylibOrdinal;
			const char* symName;
		} bindOp = {0};
		
		for (uint8_t* op = (uint8_t*)mh + lazyBindOffs; op < (uint8_t*)mh + lazyBindOffs + lazyBindSz; ) {
			uint8_t opcode = *op & BIND_OPCODE_MASK;
			if (opcode == BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB) {
				bindOp.seg = *op & BIND_IMMEDIATE_MASK;
				op++;
				bindOp.offs = 0;
				op += ulebDec(op, &bindOp.offs);
				continue;
			} else if (opcode == BIND_OPCODE_SET_DYLIB_ORDINAL_IMM) {
				bindOp.dylibOrdinal = *op & BIND_IMMEDIATE_MASK;
			} else if (opcode == BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM) {
				op++;
				bindOp.symName = (const char*)op;
				op += strlen((char*)op);
				continue;
			} else if (opcode == BIND_OPCODE_DO_BIND && bindOp.dylibOrdinal == libclangOrdinal) {
				if (importer->nimports == sizeof(importer->importedSyms) / sizeof(struct importedSym)) {
					fprintf(stderr, "Skipping %s in %s\n", bindOp.symName, imgName);
					break;
				}
				assert(bindOp.seg == dataIdx);
				
				importer->importedSyms[importer->nimports].name = calloc(strlen(bindOp.symName) + 1, sizeof(char));
				strcpy(importer->importedSyms[importer->nimports].name, bindOp.symName);
//				fprintf(stderr, "%s: %s at 0x%x (0x%x)\n", slash, bindOp.symName, bindOp.offs, dataOffs + bindOp.offs);
				importer->importedSyms[importer->nimports].addr = (void*)((uintptr_t)mh + dataOffs + bindOp.offs);
				importer->nimports++;
			}
			op++;
		}
		
		importers[found] = importer;
		found++;
	}
	
	*nfound = found;
	return KERN_SUCCESS;
}

#define CLANG_PREFIX "/usr/local"

/**
 * FIXME: This is executed before clang queue is scheduled,
 * but it would still be nice to obtain the corresponding lock
 * to ensure no race
 **/
/* FIXME: Are all the libclang imports lazy? */
static kern_return_t replaceLib() {
	static struct libclangImporter* importers[16];
	uint32_t nfound = 0;
	findLibclangImports((void*)importers, &nfound, sizeof(importers) / sizeof(*importers));
	
	if (nfound == 0)
		return KERN_FAILURE;

	libclangHandle = dlopen(CLANG_PREFIX"/lib/libclang.dylib", RTLD_LAZY | RTLD_LOCAL);

	for (uint32_t i = 0; i < nfound; i++)
		for (uint32_t j = 0; j < importers[i]->nimports; j++) {
			char* sym = importers[i]->importedSyms[j].name;
			uintptr_t replace = (uintptr_t)dlsym(libclangHandle, sym + 1);
//			fprintf(stderr, "Replacing %s at 0x%lx with 0x%lx\n", sym, importers[i]->importedSyms[j].addr, replace);
			if (!replace) {
				fprintf(stderr, "Replacement libclang does not have %s\n", sym);
				return KERN_FAILURE;
			}
				
			*(uintptr_t*)(importers[i]->importedSyms[j].addr) = replace;
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
