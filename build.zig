const std = @import("std");
const Build = std.Build;

const MicroZig = @import("microzig/build");
const atsam = @import("microzig/bsp/microchip/atsam");

fn sycl_badge_microzig_target() MicroZig.Target {
    var atsamd51j19_chip_with_fpu = atsam.chips.atsamd51j19.chip;
    atsamd51j19_chip_with_fpu.cpu.target.cpu_features_add = std.Target.arm.featureSet(&.{.vfp4d16sp});
    atsamd51j19_chip_with_fpu.cpu.target.abi = .eabihf;
    return .{
        .preferred_format = .elf,
        .chip = atsamd51j19_chip_with_fpu,
        .linker_script = .{ .path = "src/badge/samd51j19a.ld" },
    };
}

const carts = .{
    "carts/feature-test/feature-test.json",
    "carts/blobs/blobs.json",
    "carts/plasma/plasma.json",
    "carts/zeroman/zeroman.json",
    "carts/metalgear-timer/metalgear-timer.json",
};

pub fn build(b: *Build) !void {
    const mz = MicroZig.init(b, .{});
    const optimize = b.standardOptimizeOption(.{});

    inline for (carts) |cart| {
        _ = try Cart.create(
            b,
            .{
                .optimize = optimize,
                .manifest = cart,
                .micro_zig = mz,
            },
        );
    }

    const font_export_step = b.step("generate-font.ts", "convert src/badge/font.zig to simulator/src/font.ts");
    font_export_step.makeFn = struct {
        fn make(_: *std.Build.Step, _: *std.Progress.Node) anyerror!void {
            const font = @embedFile("src/badge/font.dat");
            var file = try std.fs.cwd().createFile("src/simulator/src/font.ts", .{});
            try file.writer().writeAll("export const FONT = Uint8Array.of(\n");
            for (font, 0..) |char, i| {
                try file.writer().writeAll("   ");
                try file.writer().print(" 0x{X:0>2},", .{char});
                if (i % 8 == 7) {
                    try file.writer().writeByte('\n');
                }
            }
            try file.writer().writeAll(");\n");
            file.close();
        }
    }.make;
}

pub const Cart = struct {
    fw: *MicroZig.Firmware,
    wasm: *Build.Step.Compile,
    cart_lib: *Build.Step.Compile,

    options: CreateOptions,
    manifest: Manifest,

    pub const CreateOptions = struct {
        optimize: std.builtin.OptimizeMode,
        manifest: []const u8,
        micro_zig: *MicroZig,
    };

    const Manifest = struct {
        author_name: []const u8 = "Anonymous",
        author_handle: []const u8 = "anonymous",
        cart_title: []const u8 = "Cartridge",
        description: []const u8 = "No Description",
        source_file: []const u8 = "cart.zig",
        graphics_assets: []GraphicsAsset = &.{},
    };

    const GraphicsAsset = struct {
        name: []const u8 = "",
        path: []const u8 = "asset.png",
        bits: u32 = 2,
        transparency: bool = false,
    };

    fn find_watch_exe(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.InstallArtifact {
        var watch_install: ?*std.Build.Step.InstallArtifact = null;
        for (b.install_tls.step.dependencies.items) |item| {
            if (std.mem.eql(u8, "install watch", item.name)) {
                watch_install = item.cast(std.Build.Step.InstallArtifact);
            }
        }

        // If watch binary has not been built, build it!
        if (watch_install == null) {
            const ws_dep = b.dependency("ws", .{});
            const mime_dep = b.dependency("mime", .{});

            const watch_compile = b.addExecutable(.{
                .name = "watch",
                .root_source_file = .{ .path = "util/watch/watch.zig" },
                .target = b.host,
                .optimize = optimize,
            });
            watch_compile.root_module.addImport("ws", ws_dep.module("websocket"));
            watch_compile.root_module.addImport("mime", mime_dep.module("mime"));

            if (b.host.result.os.tag == .macos) {
                watch_compile.linkFramework("CoreFoundation");
                watch_compile.linkFramework("CoreServices");
            }

            watch_install = b.addInstallArtifact(watch_compile, .{ .dest_dir = .disabled });

            b.getInstallStep().dependOn(&watch_install.?.step);
        }
        return watch_install.?;
    }

    fn find_resource_exe(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.InstallArtifact {
        var resource_install: ?*std.Build.Step.InstallArtifact = null;
        for (b.install_tls.step.dependencies.items) |item| {
            if (std.mem.eql(u8, "install rescompiler", item.name)) {
                resource_install = item.cast(std.Build.Step.InstallArtifact);
            }
        }

        // If resource compiler has not been built, build it!
        if (resource_install == null) {
            const resource_compile = b.addExecutable(.{
                .name = "rescompiler",
                .root_source_file = .{ .path = "util/rescompiler.zig" },
                .target = b.host,
                .optimize = optimize,
                .link_libc = true,
            });
            resource_compile.root_module.addImport("zigimg", b.dependency("zigimg", .{}).module("zigimg"));
            resource_install = b.addInstallArtifact(resource_compile, .{ .dest_dir = .disabled });
            b.getInstallStep().dependOn(&resource_install.?.step);
        }
        return resource_install.?;
    }

    pub fn create(b: *std.Build, options: CreateOptions) !*Cart {
        // Collect utility binaries
        const watch_exe = find_watch_exe(b, options.optimize);
        const resource_exe = find_resource_exe(b, options.optimize);

        // Read json file
        const config_file_location = options.manifest;
        var file = try std.fs.openFileAbsolute(b.pathFromRoot(config_file_location), .{});
        defer file.close();

        const fileContents = try file.readToEndAlloc(b.allocator, 65536);
        defer b.allocator.free(fileContents);

        const manifest_dir_opt = std.fs.path.dirname(options.manifest);
        const manifest_dir = if (manifest_dir_opt == null) "" else manifest_dir_opt.?;

        const manifest = try std.json.parseFromSlice(
            Manifest,
            b.allocator,
            fileContents,
            .{ .ignore_unknown_fields = true },
        );
        const cart_source_file = try std.fs.path.join(
            b.allocator,
            &.{
                manifest_dir,
                manifest.value.source_file,
            },
        );
        defer b.allocator.free(cart_source_file);

        // Check if cart-api module has been built
        var cart_module = b.modules.get("cart-api");

        // If not build it
        if (cart_module == null) {
            cart_module = b.addModule("cart-api", .{ .root_source_file = .{ .path = "src/badge/cart-user.zig" } });
        }

        // Build wasm (Runs on PC for the Emulator)
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        });

        const wasm = b.addExecutable(.{
            .name = manifest.value.cart_title,
            .root_source_file = .{ .path = cart_source_file },
            .target = wasm_target,
            .optimize = options.optimize,
        });

        wasm.entry = .disabled;
        wasm.import_memory = true;
        wasm.initial_memory = 64 * 65536;
        wasm.max_memory = 64 * 65536;
        wasm.stack_size = 14752;
        wasm.global_base = 160 * 128 * 2 + 0x1e;

        wasm.rdynamic = true;
        wasm.root_module.addImport("cart-api", cart_module.?);

        // Build cart
        const sycl_badge_target =
            b.resolveTargetQuery(sycl_badge_microzig_target().chip.cpu.target);

        const cart_lib_name = try std.fmt.allocPrint(
            b.allocator,
            "{s}-cart",
            .{manifest.value.cart_title},
        );
        defer b.allocator.free(cart_lib_name);
        const cart_lib = b.addStaticLibrary(.{
            .name = cart_lib_name,
            .root_source_file = .{ .path = cart_source_file },
            .target = sycl_badge_target,
            .optimize = options.optimize,
            .link_libc = false,
            .single_threaded = true,
            .use_llvm = true,
            .use_lld = true,
            .strip = false,
        });
        cart_lib.root_module.addImport("cart-api", cart_module.?);
        cart_lib.linker_script = std.Build.LazyPath{ .path = "src/badge/cart.ld" };

        const fw = options.micro_zig.add_firmware(b, .{
            .name = manifest.value.cart_title,
            .target = sycl_badge_microzig_target(),
            .optimize = options.optimize,
            .root_source_file = .{ .path = "src/badge/badge.zig" },
            .linker_script = .{ .path = "src/badge/cart.ld" },
        });
        fw.artifact.linkLibrary(cart_lib);

        // Create cart object
        const result: *Cart = b.allocator.create(Cart) catch @panic("OOM");
        result.* = .{
            .wasm = wasm,
            .fw = fw,
            .cart_lib = cart_lib,
            .options = options,
            .manifest = manifest.value,
        };

        // Install cart
        const install_artifact_step = b.addInstallArtifact(result.*.wasm, .{});
        b.getInstallStep().dependOn(&install_artifact_step.step);
        result.*.options.micro_zig.install_firmware(b, result.*.fw, .{ .format = .elf });
        result.*.options.micro_zig.install_firmware(b, result.*.fw, .{ .format = .{ .uf2 = .SAMD51 } });
        b.installArtifact(result.*.wasm);

        // Compile resources (if applicable)
        const gen_gfx = b.addRunArtifact(resource_exe.artifact);
        for (manifest.value.graphics_assets) |asset| {
            var intvalbuf: [14]u8 = undefined;
            gen_gfx.addArg("-i");
            const path = try std.fs.path.join(b.allocator, &.{ manifest_dir, asset.path });
            defer b.allocator.free(path);
            gen_gfx.addFileArg(b.path(path));
            gen_gfx.addArg(try std.fmt.bufPrint(&intvalbuf, "{}", .{asset.bits}));
            gen_gfx.addArg(try std.fmt.bufPrint(&intvalbuf, "{}", .{asset.transparency}));
        }

        gen_gfx.addArg("-o");
        const gfx_zig = gen_gfx.addOutputFileArg("gfx.zig");

        const gfx_mod = b.addModule("gfx", .{
            .root_source_file = gfx_zig,
            .optimize = options.optimize,
        });
        gfx_mod.addImport("cart-api", cart_module.?);

        // Link created gfx module into executables
        wasm.step.dependOn(&gen_gfx.step);
        wasm.root_module.addImport("gfx", gfx_mod);
        cart_lib.root_module.addImport("gfx", gfx_mod);

        // Add watcher run target for this cart
        const watch_run = b.addRunArtifact(watch_exe.artifact);
        watch_run.step.dependOn(&watch_exe.step);
        watch_run.addArgs(&.{ "serve", b.graph.zig_exe });

        const cart_source_path = std.fs.path.dirname(cart_source_file);
        watch_run.addArgs(&.{ "--input-dir", b.path(cart_source_path.?).getPath(b) });
        watch_run.addArgs(&.{ "--input-dir", b.pathFromRoot("src") });
        watch_run.addArgs(&.{ "--cart", b.getInstallPath(install_artifact_step.dest_dir.?, install_artifact_step.dest_sub_path) });

        return result;
    }
};
