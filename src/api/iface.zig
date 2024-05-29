const std = @import("std");
comptime {
    if (!@import("builtin").target.isWasm()) {
        _ = @import("iface-badge.zig");
    }
}

pub extern fn disp_set_pixel(
    xy: u32,
    color: u32,
) void;

pub extern fn disp_clear(
    color: u32,
) void;

pub extern fn disp_set_window(
    x1x2: u32,
    y1y2: u32,
) void;

pub extern fn disp_write(
    buf: *anyopaque,
    len: u32,
) void;

pub extern fn disp_poll_busy() u32;
