#!/usr/bin/env python3
"""Generate VulkanGlass.xcodeproj from the Swift sources. No Ruby."""

from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "VulkanGlass"
TEST_DIR = ROOT / "VulkanGlassTests"
QUICK_LOOK_DIR = ROOT / "VulkanGlassQuickLook"
PROJECT_DIR = ROOT / "VulkanGlass.xcodeproj"

# Extension-safe renderer boundary. These files are compiled into both the app
# and Quick Look targets, so they must not depend on other VulkanGlass sources.
# Add every new renderer dependency here; the aggregate build compiles the
# extension, and all extension-owned Swift files are also compiled into tests.
QUICK_LOOK_SHARED_SOURCES = (
    "CodeHighlight.swift",
    "GFM.swift",
    "MarkdownPreviewView.swift",
    "SemanticHTML.swift",
    "Theme.swift",
)


def pid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


def main() -> None:
    swift_files = sorted(p for p in SOURCE_DIR.glob("*.swift"))
    test_files = sorted(p for p in TEST_DIR.glob("*.swift"))
    quick_look_files = sorted(p for p in QUICK_LOOK_DIR.glob("*.swift"))
    asset_dir = SOURCE_DIR / "Assets.xcassets"

    ids = {
        "project": pid("project"),
        "target": pid("target"),
        "sources": pid("sources-phase"),
        "resources": pid("resources-phase"),
        "frameworks": pid("frameworks-phase"),
        "product": pid("product"),
        "group_root": pid("group-root"),
        "group_src": pid("group-src"),
        "group_products": pid("group-products"),
        "config_list_project": pid("xc-list-project"),
        "config_list_target": pid("xc-list-target"),
        "debug_project": pid("xc-debug-project"),
        "release_project": pid("xc-release-project"),
        "debug_target": pid("xc-debug-target"),
        "release_target": pid("xc-release-target"),
        "info": pid("file-info-plist"),
        "entitlements": pid("file-entitlements"),
        "assets": pid("file-assets"),
        "assets_build": pid("build-assets"),
        "test_target": pid("test-target"),
        "test_sources": pid("test-sources-phase"),
        "test_frameworks": pid("test-frameworks-phase"),
        "test_product": pid("test-product"),
        "group_tests": pid("group-tests"),
        "config_list_test": pid("xc-list-test"),
        "debug_test": pid("xc-debug-test"),
        "release_test": pid("xc-release-test"),
        "target_proxy": pid("test-target-proxy"),
        "target_dependency": pid("test-target-dependency"),
        "quick_look_target": pid("quick-look-target"),
        "quick_look_sources": pid("quick-look-sources-phase"),
        "quick_look_frameworks": pid("quick-look-frameworks-phase"),
        "quick_look_product": pid("quick-look-product"),
        "quick_look_group": pid("quick-look-group"),
        "quick_look_info": pid("quick-look-info-plist"),
        "quick_look_entitlements": pid("quick-look-entitlements"),
        "quick_look_embed": pid("quick-look-embed-phase"),
        "quick_look_embed_build": pid("quick-look-embed-build"),
        "quick_look_config_list": pid("quick-look-config-list"),
        "quick_look_debug": pid("quick-look-debug"),
        "quick_look_release": pid("quick-look-release"),
        "quick_look_target_proxy": pid("quick-look-target-proxy"),
        "quick_look_target_dependency": pid("quick-look-target-dependency"),
    }

    file_entries = []
    build_files = []
    source_refs = []
    for path in swift_files:
        ref = pid(f"file-{path.name}")
        build = pid(f"build-{path.name}")
        ids[path.name] = ref
        file_entries.append(
            f"\t\t{ref} /* {path.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path.name}; sourceTree = \"<group>\"; }};"
        )
        build_files.append(
            f"\t\t{build} /* {path.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {path.name} */; }};"
        )
        source_refs.append(f"\t\t\t\t{build} /* {path.name} in Sources */,")

    quick_look_file_entries = []
    quick_look_source_refs = []
    for name in QUICK_LOOK_SHARED_SOURCES:
        if name not in ids:
            raise SystemExit(f"Quick Look shared source not found: {SOURCE_DIR / name}")
        build = pid(f"quick-look-build-shared-{name}")
        build_files.append(
            f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ids[name]} /* {name} */; }};"
        )
        quick_look_source_refs.append(f"\t\t\t\t{build} /* {name} in Sources */,")

    for path in quick_look_files:
        ref = pid(f"quick-look-file-{path.name}")
        build = pid(f"quick-look-build-{path.name}")
        ids[f"quick-look-{path.name}"] = ref
        quick_look_file_entries.append(
            f"\t\t{ref} /* {path.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path.name}; sourceTree = \"<group>\"; }};"
        )
        build_files.append(
            f"\t\t{build} /* {path.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {path.name} */; }};"
        )
        quick_look_source_refs.append(f"\t\t\t\t{build} /* {path.name} in Sources */,")

    test_file_entries = []
    test_build_files = []
    test_source_refs = []
    for path in test_files:
        ref = pid(f"test-file-{path.name}")
        build = pid(f"test-build-{path.name}")
        ids[f"test-{path.name}"] = ref
        test_file_entries.append(
            f"\t\t{ref} /* {path.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path.name}; sourceTree = \"<group>\"; }};"
        )
        test_build_files.append(
            f"\t\t{build} /* {path.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {path.name} */; }};"
        )
        test_source_refs.append(f"\t\t\t\t{build} /* {path.name} in Sources */,")

    for path in quick_look_files:
        ref = ids[f"quick-look-{path.name}"]
        build = pid(f"test-build-quick-look-{path.name}")
        test_build_files.append(
            f"\t\t{build} /* {path.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {path.name} */; }};"
        )
        test_source_refs.append(f"\t\t\t\t{build} /* {path.name} in Sources */,")

    objects = []
    objects.extend(build_files)
    objects.extend(test_build_files)
    objects.append(
        f"\t\t{ids['assets_build']} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ids['assets']} /* Assets.xcassets */; }};"
    )
    objects.append(
        f"\t\t{ids['quick_look_embed_build']} /* VulkanGlassQuickLook.appex in Embed App Extensions */ = {{isa = PBXBuildFile; fileRef = {ids['quick_look_product']} /* VulkanGlassQuickLook.appex */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};"
    )

    objects.append(
        f"""\t\t{ids['frameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
        }};"""
    )
    objects.append(
        f"""\t\t{ids['test_frameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['quick_look_frameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};"""
    )

    children = "\n".join(f"\t\t\t\t{ids[p.name]} /* {p.name} */," for p in swift_files)
    objects.append(
        f"""\t\t{ids['group_src']} /* VulkanGlass */ = {{
			isa = PBXGroup;
			children = (
{children}
				{ids['info']} /* Info.plist */,
				{ids['entitlements']} /* VulkanGlass.entitlements */,
				{ids['assets']} /* Assets.xcassets */,
			);
			path = VulkanGlass;
			sourceTree = "<group>";
        }};"""
    )
    quick_look_children = "\n".join(
        f"\t\t\t\t{ids[f'quick-look-{p.name}']} /* {p.name} */,"
        for p in quick_look_files
    )
    objects.append(
        f"""\t\t{ids['quick_look_group']} /* VulkanGlassQuickLook */ = {{
			isa = PBXGroup;
			children = (
{quick_look_children}
				{ids['quick_look_info']} /* Info.plist */,
				{ids['quick_look_entitlements']} /* VulkanGlassQuickLook.entitlements */,
			);
			path = VulkanGlassQuickLook;
			sourceTree = "<group>";
		}};"""
    )
    test_children = "\n".join(f"\t\t\t\t{ids[f'test-{p.name}']} /* {p.name} */," for p in test_files)
    objects.append(
        f"""\t\t{ids['group_tests']} /* VulkanGlassTests */ = {{
			isa = PBXGroup;
			children = (
{test_children}
			);
			path = VulkanGlassTests;
			sourceTree = "<group>";
		}};"""
    )
    objects.append(
        f"""\t\t{ids['group_products']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{ids['product']} /* VulkanGlass.app */,
				{ids['quick_look_product']} /* VulkanGlassQuickLook.appex */,
				{ids['test_product']} /* VulkanGlassTests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		}};"""
    )
    objects.append(
        f"""\t\t{ids['group_root']} = {{
			isa = PBXGroup;
			children = (
				{ids['group_src']} /* VulkanGlass */,
				{ids['quick_look_group']} /* VulkanGlassQuickLook */,
				{ids['group_tests']} /* VulkanGlassTests */,
				{ids['group_products']} /* Products */,
			);
			sourceTree = "<group>";
		}};"""
    )

    objects.extend(file_entries)
    objects.extend(quick_look_file_entries)
    objects.extend(test_file_entries)
    objects.append(
        f"\t\t{ids['product']} /* VulkanGlass.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = VulkanGlass.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    objects.append(
        f"\t\t{ids['test_product']} /* VulkanGlassTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = VulkanGlassTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    objects.append(
        f"\t\t{ids['quick_look_product']} /* VulkanGlassQuickLook.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = VulkanGlassQuickLook.appex; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    objects.append(
        f"\t\t{ids['info']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};"
    )
    objects.append(
        f"\t\t{ids['entitlements']} /* VulkanGlass.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = VulkanGlass.entitlements; sourceTree = \"<group>\"; }};"
    )
    objects.append(
        f"\t\t{ids['assets']} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};"
    )
    objects.append(
        f"\t\t{ids['quick_look_info']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};"
    )
    objects.append(
        f"\t\t{ids['quick_look_entitlements']} /* VulkanGlassQuickLook.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = VulkanGlassQuickLook.entitlements; sourceTree = \"<group>\"; }};"
    )

    objects.append(
        f"""\t\t{ids['sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(source_refs)}
			);
			runOnlyForDeploymentPostprocessing = 0;
        }};"""
    )
    objects.append(
        f"""\t\t{ids['test_sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(test_source_refs)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['quick_look_sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(quick_look_source_refs)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['resources']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{ids['assets_build']} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['quick_look_embed']} /* Embed App Extensions */ = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 13;
			files = (
				{ids['quick_look_embed_build']} /* VulkanGlassQuickLook.appex in Embed App Extensions */,
			);
			name = "Embed App Extensions";
			runOnlyForDeploymentPostprocessing = 0;
		}};"""
    )

    objects.append(
        f"""\t\t{ids['target']} /* VulkanGlass */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['config_list_target']} /* Build configuration list for PBXNativeTarget "VulkanGlass" */;
			buildPhases = (
				{ids['sources']} /* Sources */,
				{ids['frameworks']} /* Frameworks */,
				{ids['resources']} /* Resources */,
				{ids['quick_look_embed']} /* Embed App Extensions */,
			);
			buildRules = (
			);
			dependencies = (
				{ids['quick_look_target_dependency']} /* PBXTargetDependency */,
			);
			name = VulkanGlass;
			productName = VulkanGlass;
			productReference = {ids['product']} /* VulkanGlass.app */;
			productType = "com.apple.product-type.application";
        }};"""
    )
    objects.append(
        f"""\t\t{ids['quick_look_target_proxy']} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {ids['project']} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {ids['quick_look_target']};
			remoteInfo = VulkanGlassQuickLook;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['quick_look_target_dependency']} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {ids['quick_look_target']} /* VulkanGlassQuickLook */;
			targetProxy = {ids['quick_look_target_proxy']} /* PBXContainerItemProxy */;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['quick_look_target']} /* VulkanGlassQuickLook */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['quick_look_config_list']} /* Build configuration list for PBXNativeTarget "VulkanGlassQuickLook" */;
			buildPhases = (
				{ids['quick_look_sources']} /* Sources */,
				{ids['quick_look_frameworks']} /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = VulkanGlassQuickLook;
			productName = VulkanGlassQuickLook;
			productReference = {ids['quick_look_product']} /* VulkanGlassQuickLook.appex */;
			productType = "com.apple.product-type.app-extension";
		}};"""
    )
    objects.append(
        f"""\t\t{ids['target_proxy']} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {ids['project']} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {ids['target']};
			remoteInfo = VulkanGlass;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['target_dependency']} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {ids['target']} /* VulkanGlass */;
			targetProxy = {ids['target_proxy']} /* PBXContainerItemProxy */;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['test_target']} /* VulkanGlassTests */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['config_list_test']} /* Build configuration list for PBXNativeTarget "VulkanGlassTests" */;
			buildPhases = (
				{ids['test_sources']} /* Sources */,
				{ids['test_frameworks']} /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
				{ids['target_dependency']} /* PBXTargetDependency */,
			);
			name = VulkanGlassTests;
			productName = VulkanGlassTests;
			productReference = {ids['test_product']} /* VulkanGlassTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		}};"""
    )

    objects.append(
        f"""\t\t{ids['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
			}};
			buildConfigurationList = {ids['config_list_project']} /* Build configuration list for PBXProject "VulkanGlass" */;
			compatibilityVersion = "Xcode 15.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {ids['group_root']};
			productRefGroup = {ids['group_products']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ids['target']} /* VulkanGlass */,
				{ids['quick_look_target']} /* VulkanGlassQuickLook */,
				{ids['test_target']} /* VulkanGlassTests */,
			);
		}};"""
    )

    project_build = """
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
				SWIFT_VERSION = 5.0;
"""
    objects.append(
        f"""\t\t{ids['debug_project']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{project_build}
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['release_project']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{project_build}
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			}};
			name = Release;
		}};"""
    )

    target_settings = f"""
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
                CODE_SIGN_ENTITLEMENTS = VulkanGlass/VulkanGlass.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				CODE_SIGNING_ALLOWED = YES;
				CODE_SIGNING_REQUIRED = YES;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = NO;
				ENABLE_DEBUG_DYLIB = NO;
				ENABLE_TESTABILITY = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = VulkanGlass/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
				MARKETING_VERSION = 0.2.1;
				PRODUCT_BUNDLE_IDENTIFIER = app.vulkanglass.desktop;
				PRODUCT_NAME = VulkanGlass;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_STRICT_CONCURRENCY = targeted;
"""
    objects.append(
        f"""\t\t{ids['debug_target']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{target_settings}			}};
			name = Debug;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['release_target']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{target_settings}			}};
			name = Release;
        }};"""
    )

    quick_look_settings = """
				APPLICATION_EXTENSION_API_ONLY = YES;
				CODE_SIGN_ENTITLEMENTS = VulkanGlassQuickLook/VulkanGlassQuickLook.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				CODE_SIGNING_ALLOWED = YES;
				CODE_SIGNING_REQUIRED = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_APP_SANDBOX = YES;
				ENABLE_DEBUG_DYLIB = NO;
				ENABLE_USER_SELECTED_FILES = readonly;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = VulkanGlassQuickLook/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks";
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = app.vulkanglass.desktop.quicklook;
				PRODUCT_MODULE_NAME = VulkanGlassQuickLook;
				PRODUCT_NAME = VulkanGlassQuickLook;
				SKIP_INSTALL = YES;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_STRICT_CONCURRENCY = targeted;
"""
    objects.append(
        f"""\t\t{ids['quick_look_debug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{quick_look_settings}			}};
			name = Debug;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['quick_look_release']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{quick_look_settings}			}};
			name = Release;
		}};"""
    )

    test_settings = """
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGNING_ALLOWED = NO;
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = app.vulkanglass.desktop.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) QUICK_LOOK_CONTROLLER_TESTING";
				SWIFT_VERSION = 5.0;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/VulkanGlass.app/Contents/MacOS/VulkanGlass";
"""
    objects.append(
        f"""\t\t{ids['debug_test']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{test_settings}			}};
			name = Debug;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['release_test']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{test_settings}			}};
			name = Release;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['config_list_project']} /* Build configuration list for PBXProject "VulkanGlass" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['debug_project']} /* Debug */,
				{ids['release_project']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['config_list_target']} /* Build configuration list for PBXNativeTarget "VulkanGlass" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['debug_target']} /* Debug */,
				{ids['release_target']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
        }};"""
    )
    objects.append(
        f"""\t\t{ids['quick_look_config_list']} /* Build configuration list for PBXNativeTarget "VulkanGlassQuickLook" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['quick_look_debug']} /* Debug */,
				{ids['quick_look_release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		}};"""
    )
    objects.append(
        f"""\t\t{ids['config_list_test']} /* Build configuration list for PBXNativeTarget "VulkanGlassTests" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['debug_test']} /* Debug */,
				{ids['release_test']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		}};"""
    )

    pbx = """// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{
{}
	}};
	rootObject = {} /* Project object */;
}}
""".format("\n".join(objects), ids["project"])

    PROJECT_DIR.mkdir(exist_ok=True)
    (PROJECT_DIR / "project.pbxproj").write_text(pbx)
    scheme_dir = PROJECT_DIR / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    (scheme_dir / "VulkanGlass.xcscheme").write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['target']}" BuildableName="VulkanGlass.app" BlueprintName="VulkanGlass" ReferencedContainer="container:VulkanGlass.xcodeproj"/>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['test_target']}" BuildableName="VulkanGlassTests.xctest" BlueprintName="VulkanGlassTests" ReferencedContainer="container:VulkanGlass.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
         <TestableReference skipped="NO">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['test_target']}" BuildableName="VulkanGlassTests.xctest" BlueprintName="VulkanGlassTests" ReferencedContainer="container:VulkanGlass.xcodeproj"/>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['target']}" BuildableName="VulkanGlass.app" BlueprintName="VulkanGlass" ReferencedContainer="container:VulkanGlass.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids['target']}" BuildableName="VulkanGlass.app" BlueprintName="VulkanGlass" ReferencedContainer="container:VulkanGlass.xcodeproj"/>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
"""
    )
    print(f"Wrote {PROJECT_DIR / 'project.pbxproj'} with {len(swift_files)} Swift files")
    _ = asset_dir  # created separately


if __name__ == "__main__":
    main()
