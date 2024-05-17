const std = @import("std");
const sycl_badge = @import("sycl_badge");

pub const author_name = "Auguste Rame, Matt Knight, Marcus Ramse";
pub const author_handle = "SuperAuguste, mattnite, JerwuQu";
pub const cart_title = "feature-test";
pub const description = "A helpful kitchen timer in the style of Metal Gear Solid";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const sycl_badge_dep = b.dependency("sycl_badge", .{});

    const cart = sycl_badge.add_cart(sycl_badge_dep, b, .{
        .name = "feature-test",
        .optimize = optimize,
        .root_source_file = b.path("src/feature-test.zig"),
    });
    cart.install(b);
}
