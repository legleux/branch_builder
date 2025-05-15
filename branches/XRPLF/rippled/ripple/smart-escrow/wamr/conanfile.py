import os
import shutil

from conan import ConanFile
from conan.tools.cmake import CMake, CMakeToolchain, CMakeDeps, cmake_layout
from conan.tools.files import copy, apply_conandata_patches, export_conandata_patches
from conan.tools.files import download, unzip, check_sha1
from conan.tools.scm import Git

class WamrConan(ConanFile):
    name = "wamr"
    version = "2.2.0"
    license = "Apache License v2.0"
    url = "https://github.com/bytecodealliance/wasm-micro-runtime"
    description = "WebAssembly Micro Runtime"
    package_type = "library"

    settings = "os", "compiler", "build_type", "arch"

    options = {
        "shared": [True, False],
        "fPIC": [True, False],
    }

    default_options = {
        "shared": False,
        "fPIC": True,
    }

    generators = "CMakeDeps"

    def export_sources(self):
        export_conandata_patches(self)

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def layout(self):
        cmake_layout(self, src_folder="src")

    def source(self):
        version="c883fafead005e87ad3122b05409886f507c1cb0"
        git = Git(self)
        git.clone(url=self.url, target=".")
        git.checkout(commit=version)

    def generate(self):
        tc = CMakeToolchain(self)
        tc.variables["WAMR_BUILD_INTERP"] = 1
        tc.variables["WAMR_BUILD_FAST_INTERP"] = 1
        tc.variables["WAMR_BUILD_INSTRUCTION_METERING"] = 1
        tc.variables["WAMR_BUILD_AOT"] = 0
        tc.variables["WAMR_BUILD_JIT"] = 0
        tc.variables["WAMR_BUILD_FAST_JIT"] = 0
        tc.variables["WAMR_DISABLE_HW_BOUND_CHECK"] = 1
        tc.variables["WAMR_DISABLE_STACK_HW_BOUND_CHECK"] = 0
        tc.generate()

    def build(self):
        apply_conandata_patches(self)
        cmake = CMake(self)
        cmake.configure()
        print(self.generators_folder)
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.libs = ["iwasm"]
        # self.cpp_info.set_property("cmake_file_name", "wamr")
        # self.cpp_info.set_property("cmake_target_name", "wamr")
