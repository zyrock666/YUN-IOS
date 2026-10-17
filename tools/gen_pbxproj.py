#!/usr/bin/env python3
"""生成 YunX-iOS 的 Xcode 工程文件（project.pbxproj）。

手写 pbxproj 的 UUID 极易写重，所以这里用「路径 -> 稳定 24 位 hex UUID」的
确定性映射统一生成；源文件列表由脚本扫描磁盘得出，新增 Swift 文件后重跑即可。
"""
import os, sys, hashlib

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
SRC_DIRS = ["YunX"]

def uid(key: str) -> str:
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()

def walk_sources():
    out = []
    for d in SRC_DIRS:
        for dirpath, _, files in os.walk(os.path.join(ROOT, d)):
            for f in sorted(files):
                if f.endswith((".swift", ".plist", ".xcassets", ".json", ".ttf")):
                    if f == "Info.plist":
                        continue  # Info.plist 通过 build setting 引用，不进 Resources
                    out.append(os.path.relpath(os.path.join(dirpath, f), ROOT))
    return sorted(out)

PRODUCT = "YunX"
BUNDLE_ID = "com.yunx.ios"
DEPLOY = "16.0"

files = walk_sources()
project_uid = uid("project")
main_group_uid = uid("maingroup")
products_group_uid = uid("productsgroup")
app_target_uid = uid("target:app")
app_product_uid = uid("product:app")
app_sources_phase = uid("phase:sources")
app_frameworks_phase = uid("phase:frameworks")
app_resources_phase = uid("phase:resources")
build_cfg_list_project = uid("cfglist:project")
build_cfg_list_target = uid("cfglist:target")
cfg_proj_debug = uid("cfg:project:debug")
cfg_proj_release = uid("cfg:project:release")
cfg_tgt_debug = uid("cfg:target:debug")
cfg_tgt_release = uid("cfg:target:release")

# 分组：按目录层级归组
groups = {}
file_refs = []
build_files = []

for path in files:
    parts = path.split(os.sep)
    dir_key = os.sep.join(parts[:-1]) if len(parts) > 1 else ""
    groups.setdefault(dir_key, []).append(path)
    file_refs.append((uid("fileref:" + path), path, parts[-1]))
    if path.endswith(".swift"):
        build_files.append((uid("buildfile:" + path), path))

def fmt_group_tree():
    """输出所有 PBXGroup。"""
    lines = []
    lines.append(f'\t\t{main_group_uid} /* YunX */ = {{isa = PBXGroup; children = (')
    # 根组下按一级目录列出（YunX）
    lines.append(f'\t\t\t{uid("group:YunX")} /* YunX */,')
    lines.append(f'\t\t\t{products_group_uid} /* Products */,')
    lines.append('\t\t); sourceTree = "<group>"; };')
    lines.append('\t\t')  # 占位，下面统一 append
    lines = [l for l in lines if l != '\t\t']

    # 目录组（自底向上保证父组已存在也行，因为只是引用）
    all_dir_keys = sorted({k for k in groups if k != ""}, key=lambda s: s.count(os.sep))
    for dk in all_dir_keys:
        g = uid("group:" + dk)
        name = os.path.basename(dk)
        children = []
        for (fr, path, base) in file_refs:
            if os.sep.join(path.split(os.sep)[:-1]) == dk:
                children.append(f'{fr} /* {base} */')
        for sub in all_dir_keys:
            if os.path.dirname(sub) == dk:
                children.append(f'{uid("group:" + sub)} /* {os.path.basename(sub)} */')
        body = ",\n".join('\t\t\t\t' + c for c in children)
        lines.append(f'\t\t{g} /* {name} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{body},\n\t\t\t);\n\t\t\tpath = {name};\n\t\t\tsourceTree = "<group>";\n\t\t}};')

    # YunX 根组（位于 ROOT 下，path = YunX）
    lines.append(f'\t\t{uid("group:YunX")} /* YunX */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' +
                 ",\n".join('\t\t\t\t' + f'{uid("group:" + sub)} /* {os.path.basename(sub)} */'
                           for sub in all_dir_keys if os.path.dirname(sub) == "YunX") +
                 ',\n\t\t\t);\n\t\t\tpath = YunX;\n\t\t\tsourceTree = "<group>";\n\t\t};')
    return "\n".join(lines)

group_tree = fmt_group_tree()

def fmt_file_refs():
    out = []
    for (fr, path, base) in file_refs:
        if base.endswith(".swift"):
            t = "sourcecode.swift"
        elif base.endswith(".plist") or base.endswith(".json"):
            t = "text.plist.json" if base.endswith(".plist") else "text.json"
        elif base.endswith(".xcassets"):
            t = "folder.assetcatalog"
        else:
            t = "file"
        out.append(f'\t\t{fr} /* {base} */ = {{isa = PBXFileReference; lastKnownFileType = {t}; path = {base}; sourceTree = "<group>"; }};')
    out.append(f'\t\t{app_product_uid} /* {PRODUCT}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PRODUCT}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    return "\n".join(out)

products_group = f'''\t\t{products_group_uid} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{app_product_uid} /* {PRODUCT}.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};'''

build_files_section = "\n".join(
    f'\t\t{bf} /* {os.path.basename(p)} in Sources */ = {{isa = PBXBuildFile; fileRef = {uid("fileref:" + p)} /* {os.path.basename(p)} */; }};'
    for (bf, p) in build_files)

sources_entries = "\n".join(
    f'\t\t\t\t{bf} /* {os.path.basename(p)} in Sources */,' for (bf, p) in build_files)

resource_files = [p for p in files if p.endswith(".xcassets")]
# 资源也走 build file，避免 fileRef 未参与构建
resource_build_files = [(uid("rbuildfile:" + p), p) for p in resource_files]
resource_build_section = "\n".join(
    f'\t\t{rb} /* {os.path.basename(p)} in Resources */ = {{isa = PBXBuildFile; fileRef = {uid("fileref:" + p)} /* {os.path.basename(p)} */; }};'
    for (rb, p) in resource_build_files)
resource_entries = "\n".join(
    f'\t\t\t\t{rb} /* {os.path.basename(p)} in Resources */,' for (rb, p) in resource_build_files)

common_build_settings = f'''COMMON = '''
pbxproj = f'''// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{build_files_section}
{resource_build_section}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{fmt_file_refs()}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{app_frameworks_phase} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
{group_tree}

{products_group}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{app_target_uid} /* {PRODUCT} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {build_cfg_list_target} /* Build configuration list for PBXNativeTarget "{PRODUCT}" */;
			buildPhases = (
				{app_sources_phase} /* Sources */,
				{app_frameworks_phase} /* Frameworks */,
				{app_resources_phase} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = {PRODUCT};
			productName = {PRODUCT};
			productReference = {app_product_uid} /* {PRODUCT}.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{project_uid} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {{
					{app_target_uid} = {{
						CreatedOnToolsVersion = 15.0;
					}};
				}};
			}};
			buildConfigurationList = {build_cfg_list_project} /* Build configuration list for PBXProject "{PRODUCT}" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = "zh-Hans";
			hasScannedForEncodings = 0;
			knownRegions = (
				"zh-Hans",
				Base,
			);
			mainGroup = {main_group_uid};
			productRefGroup = {products_group_uid} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{app_target_uid} /* {PRODUCT} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{app_resources_phase} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{resource_entries}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{app_sources_phase} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{sources_entries}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{cfg_proj_debug} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				IPHONEOS_DEPLOYMENT_TARGET = {DEPLOY};
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{cfg_proj_release} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				IPHONEOS_DEPLOYMENT_TARGET = {DEPLOY};
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{cfg_tgt_debug} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = YunX/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{cfg_tgt_release} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = YunX/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{build_cfg_list_project} /* Build configuration list for PBXProject "{PRODUCT}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{cfg_proj_debug} /* Debug */,
				{cfg_proj_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{build_cfg_list_target} /* Build configuration list for PBXNativeTarget "{PRODUCT}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{cfg_tgt_debug} /* Debug */,
				{cfg_tgt_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {project_uid} /* Project object */;
}}
'''
# 清理未使用的占位变量
pbxproj = pbxproj.replace("COMMON = ", "")
out_dir = os.path.join(ROOT, f"{PRODUCT}.xcodeproj")
os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "project.pbxproj"), "w", encoding="utf-8") as fh:
    fh.write(pbxproj)
print(f"wrote {out_dir}/project.pbxproj  ({len(files)} files, {len(build_files)} swift)")
