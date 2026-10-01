// UTM QEMU's public embedding ABI, pinned to UTM v5.0.5 (b6f7475).
// Pinned runtime libraries are packaged inside Astra's own app bundle.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach-o/dyld.h>
#import <Foundation/Foundation.h>
#include "AstraPlatform.h"

extern char **environ;

static NSString *astra_runtime_library(NSString *name) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *buffer = malloc(size);
    if (!buffer || _NSGetExecutablePath(buffer, &size) != 0) { free(buffer); return nil; }
    NSURL *executable = [NSURL fileURLWithFileSystemRepresentation:buffer isDirectory:NO relativeToURL:nil];
    free(buffer);
    NSURL *contents = executable.URLByResolvingSymlinksInPath.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    return [[contents URLByAppendingPathComponent:@"Frameworks" isDirectory:YES] URLByAppendingPathComponent:name].path;
}

static void *astra_open_runtime(NSString *name) {
    NSString *path = astra_runtime_library(name);
    void *handle = path ? dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL) : NULL;
    if (!handle) fprintf(stderr, "Astra bundled runtime: %s\n", path ? dlerror() : "Cannot locate the application bundle.");
    return handle;
}

int main(int argc, char **argv) {
    (void)astra_poll_interposer_anchor();
    if (argc == 2 && strcmp(argv[1], "--astra-runtime-check") == 0) {
        @autoreleasepool {
            void *qemu = astra_open_runtime(@"qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu");
            void *tpm = astra_open_runtime(@"swtpm.0.framework/swtpm.0");
            if (!qemu || !tpm || !dlsym(qemu, "qemu_init") || !dlsym(qemu, "qemu_main_loop") ||
                !dlsym(qemu, "qemu_cleanup") || !dlsym(tpm, "swtpm_main")) return 78;
            NSMutableArray *images = [NSMutableArray array];
            for (uint32_t i = 0; i < _dyld_image_count(); i++) {
                const char *name = _dyld_get_image_name(i);
                if (name) [images addObject:@(name)];
            }
            NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"result": @"PASS", @"loaded_images": images,
                @"vm_started": @NO} options:NSJSONWritingPrettyPrinted error:nil];
            fwrite(data.bytes, 1, data.length, stdout);
            return 0;
        }
    }
    NSMutableArray<NSURL *> *scopes __attribute__((objc_precise_lifetime)) = [NSMutableArray array];
    for (NSString *key in @[@"ASTRA_VM_BOOKMARK", @"ASTRA_RUNTIME_BOOKMARK", @"ASTRA_INSTALL_ISO_BOOKMARK"]) {
        const char *value = getenv(key.UTF8String);
        if (!value) continue;
        @autoreleasepool {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:@(value) options:0];
            BOOL stale = NO;
            NSError *error = nil;
            // IPC bookmarks carry the granted access to a different helper identity.
            // App-scoped persistent bookmarks cannot be resolved by another app ID.
            NSURL *url = [NSURL URLByResolvingBookmarkData:data options:0
                relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
            if (!url) { fprintf(stderr, "Astra file access could not be restored: %s\n", error.localizedDescription.UTF8String); return 78; }
            [url startAccessingSecurityScopedResource];
            [scopes addObject:url];
        }
    }
    if (argc == 2 && (strcmp(argv[1], "--astra-paths") == 0 || strcmp(argv[1], "--astra-new-runtime") == 0)) {
        @autoreleasepool {
            NSURL *group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.local.astra"];
            if (!group) { fprintf(stderr, "Astra shared runtime container is unavailable.\n"); return 78; }
            NSURL *runtime = [group URLByAppendingPathComponent:@"Runtime" isDirectory:YES];
            if (strcmp(argv[1], "--astra-new-runtime") == 0) {
                runtime = [runtime URLByAppendingPathComponent:[NSUUID.UUID.UUIDString substringToIndex:8] isDirectory:YES];
            }
            NSError *error = nil;
            if (![NSFileManager.defaultManager createDirectoryAtURL:runtime withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
                fprintf(stderr, "Astra runtime: %s\n", error.localizedDescription.UTF8String); return 78;
            }
            NSDictionary *paths = @{ @"temporary_directory": runtime.path };
            NSData *data = [NSJSONSerialization dataWithJSONObject:paths options:0 error:nil];
            fwrite(data.bytes, 1, data.length, stdout);
            return 0;
        }
    }
    @autoreleasepool {
        // virglrenderer allocates its anonymous shared files through TMPDIR.
        // Use the engine's own sandbox container, as UTM's public runner does.
        if (setenv("TMPDIR", NSFileManager.defaultManager.temporaryDirectory.path.UTF8String, 1) != 0) {
            perror("Astra engine temporary directory");
            return 78;
        }
    }
    if (argc > 2 && strcmp(argv[1], "--swtpm") == 0) {
        void *tpm = astra_open_runtime(@"swtpm.0.framework/swtpm.0");
        if (!tpm) { fprintf(stderr, "Astra TPM: %s\n", dlerror()); return 78; }
        int (*entry)(int, const char **, const char *, const char *) = dlsym(tpm, "swtpm_main");
        if (!entry) { fprintf(stderr, "Astra TPM: incompatible swtpm embedding ABI.\n"); return 78; }
        return entry(argc - 2, (const char **)(argv + 2), "swtpm", "socket");
    }
    void *handle = astra_open_runtime(@"qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu");
    if (!handle) {
        fprintf(stderr, "Astra engine: %s\n", dlerror());
        return 78;
    }
    int (*initialize)(int, const char **, const char **) = dlsym(handle, "qemu_init");
    void (*run)(void) = dlsym(handle, "qemu_main_loop");
    void (*cleanup)(void) = dlsym(handle, "qemu_cleanup");
    if (!initialize || !run || !cleanup) {
        fprintf(stderr, "Astra engine: bundled QEMU has an incompatible embedding ABI.\n");
        return 78;
    }
    int status = initialize(argc, (const char **)argv, (const char **)environ);
    if (status) return status;
    run();
    cleanup();
    return 0;
}
