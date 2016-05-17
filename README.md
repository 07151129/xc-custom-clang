clang-custom
========

A plugin for Xcode to use arbitrary clang binaries.

- Adds custom clang compiler definition to build options
- Optionally, replaces "Default compiler" definition
- Optionally, replaces toolchain's libclang with provided libclang

#### Installation

1. In `Clang custom.template` for each `Options` key, replace `DefaultValue` of `CLANG_PREFIX` with clang installation prefix.
2. Build the plugin. Add your Xcode `DVTPlugInCompatibilityUUID` to `DVTPlugInCompatibilityUUIDs` array in `Info.plist`.
3. If needed, adjust values of `PBSReplaceDefault` and `PBSReplaceLibclang` in `Info.plist`.
4. Install the plugin (e.g. to `~/Library/Application\ Support/Developer/Shared/Xcode/Plug-ins`).

Observe value of `c` in `Plugin.m` after building the project with the plugin installed. It should be set to the provided
clang version.

#### Caveats

- Libraries like `libarc_lite` have to be copied to `lib` directory in clang prefix from Xcode toolchain.
- `libclang` replacement might not work well with your Xcode version. 
