const std = @import("std");
pub const iface = @import("iface.zig");

pub const NeopixelColor = extern struct { g: u8, r: u8, b: u8 };
pub const neopixels: *[5]NeopixelColor = @ptrFromInt(0x20020000 + 0x08);

/// RGB565, high color
pub const DisplayColor = packed struct(u16) {
    g1: u3,
    b: u5,
    r: u5,
    g2: u3,

    pub inline fn new(r: u8, g: u8, b: u8) DisplayColor {
        return DisplayColor{
            .b = @truncate(b),
            .r = @truncate(r),
            .g1 = @truncate(g),
            .g2 = @truncate(g >> 3),
        };
    }
};

pub const Region = extern struct {
    x1: u16 = 0,
    y1: u16 = 0,
    x2: u16 = 160,
    y2: u16 = 128,
};

var buf1: [160]DisplayColor = undefined;
var buf2: [160]DisplayColor = undefined;

pub fn Shader(FieldVal: type, function: *const fn (
    shader: FieldVal,
    region: *const Region,
    buffer: []DisplayColor,
    i: u16,
) void) type {
    return packed struct {
        fcn: *const Function,
        next: ?*anyopaque,
        value: FieldVal,

        pub const Function: type = fn (
            shader: FieldVal,
            region: *const Region,
            buffer: []DisplayColor,
            i: u16,
        ) void;

        pub fn create(baseValue: FieldVal) @This() {
            return @This(){
                .fcn = function,
                .next = null,
                .value = baseValue,
            };
        }

        pub fn render(shader: @This(), region: *const Region) void {
            iface.disp_set_window((@as(u32, @intCast(region.x1)) << 16) | region.x2, (@as(u32, @intCast(region.y1)) << 16) | region.y2);
            const bufSize = region.x2 - region.x1;
            var onBuf1 = true;
            for (0..region.y2 - region.y1) |yval| {
                while (iface.disp_poll_busy() != 0) {}
                if (onBuf1) {
                    shader.fcn(shader.value, region, &buf1, @intCast(yval));
                    iface.disp_write(&buf1, bufSize);
                } else {
                    shader.fcn(shader.value, region, &buf2, @intCast(yval));
                    iface.disp_write(&buf2, bufSize);
                }
                onBuf1 = !onBuf1;
            }
        }
    };
}
