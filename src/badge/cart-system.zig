const std = @import("std");
const microzig = @import("microzig");
const board = microzig.board;
const audio = @import("audio.zig");
const lcd = @import("lcd.zig");
const timer = @import("timer.zig");
const dma = @import("dma.zig");
pub const api = @import("cart-user.zig");

pub const libcart = struct {
    pub extern var cart_data_start: u8;
    pub extern var cart_data_end: u8;
    pub extern var cart_bss_start: u8;
    pub extern var cart_bss_end: u8;
    pub extern const cart_data_load_start: u8;

    pub extern fn start() void;
    pub extern fn update() void;
};

fn User(comptime T: type) type {
    return extern struct {
        const Self = @This();
        const suffix = switch (@bitSizeOf(T)) {
            8 => "b",
            16 => "h",
            32 => "",
            else => @compileError("User doesn't support " ++ @typeName(T)),
        };

        unsafe: T,

        pub inline fn load(user: *const Self) T {
            return asm ("ldr" ++ suffix ++ "t %[value], [%[pointer]]"
                : [value] "=r" (-> T),
                : [pointer] "r" (&user.unsafe),
            );
        }

        pub inline fn store(user: *Self, value: T) void {
            asm volatile ("str" ++ suffix ++ "t %[value], [%pointer]]"
                :
                : [value] "r" (value),
                  [pointer] "r" (&user.unsafe),
            );
        }
    };
}

pub fn handle_svcall(svid: u32, args: [*]u32) callconv(.C) void {
    switch (svid) {
        1 => disp_set_pixel(args[0], args[1]),
        2 => disp_clear(args[0]),
        3 => disp_set_window(args[0], args[1]),
        4 => disp_write(@ptrFromInt(args[0]), args[1]),
        5 => args[0] = disp_poll_busy(),
        else => {},
    }
}

fn disp_set_pixel(xy: u32, color: u32) callconv(.C) void {
    lcd.set_pixel(xy, @truncate(color));
}

fn disp_clear(color: u32) callconv(.C) void {
    lcd.clear(@truncate(color));
}

fn disp_set_window(x1x2: u32, y1y2: u32) callconv(.C) void {
    lcd.set_window(x1x2, y1y2);
}

fn disp_write(buf: *anyopaque, len: u32) callconv(.C) void {
    lcd.write(@as([*]u8, @ptrCast(buf))[0..len]);
}

fn disp_poll_busy() callconv(.C) u32 {
    if (dma.lcd_poll_done()) {
        return 0;
    } else {
        return 1;
    }
}

fn point(x: usize, y: usize, color: api.DisplayColor) void {
    api.framebuffer[y * api.screen_width + x] = color;
}

fn pointUnclipped(x: i32, y: i32, color: api.DisplayColor) void {
    if (x >= 0 and x < api.screen_width and y >= 0 and y < api.screen_height) {
        point(@intCast(x), @intCast(y), color);
    }
}

fn blit(
    sprite: [*]const User(api.DisplayColor),
    dst_x: i32,
    dst_y: i32,
    rest: *const extern struct {
        width: User(u32),
        height: User(u32),
        src_x: User(u32),
        src_y: User(u32),
        stride: User(u32),
        flags: User(api.BlitOptions.Flags),
    },
) callconv(.C) void {
    const width = rest.width.load();
    const height = rest.height.load();
    const src_x = rest.src_x.load();
    const src_y = rest.src_y.load();
    const stride = rest.stride.load();
    const flags = rest.flags.load();

    const signed_width: i32 = @intCast(width);
    const signed_height: i32 = @intCast(height);

    // Clip rectangle to screen
    const flip_x, const clip_x_min: u32, const clip_y_min: u32, const clip_x_max: u32, const clip_y_max: u32 =
        if (flags.rotate) .{
        !flags.flip_x,
        @intCast(@max(0, dst_y) - dst_y),
        @intCast(@max(0, dst_x) - dst_x),
        @intCast(@min(signed_width, @as(i32, @intCast(api.screen_height)) - dst_y)),
        @intCast(@min(signed_height, @as(i32, @intCast(api.screen_width)) - dst_x)),
    } else .{
        flags.flip_x,
        @intCast(@max(0, dst_x) - dst_x),
        @intCast(@max(0, dst_y) - dst_y),
        @intCast(@min(signed_width, @as(i32, @intCast(api.screen_width)) - dst_x)),
        @intCast(@min(signed_height, @as(i32, @intCast(api.screen_height)) - dst_y)),
    };

    for (clip_y_min..clip_y_max) |y| {
        for (clip_x_min..clip_x_max) |x| {
            const signed_x: i32 = @intCast(x);
            const signed_y: i32 = @intCast(y);

            // Calculate sprite target coords
            const tx: u32 = @intCast(dst_x + (if (flags.rotate) signed_y else signed_x));
            const ty: u32 = @intCast(dst_y + (if (flags.rotate) signed_x else signed_y));

            // Calculate sprite source coords
            const sx = src_x + @as(u32, @intCast((if (flip_x) signed_width - signed_x - 1 else signed_x)));
            const sy = src_y + @as(u32, @intCast((if (flags.flip_y) signed_height - signed_y - 1 else signed_y)));

            const index = sy * stride + sx;

            point(tx, ty, sprite[index].load());
        }
    }
}

fn line(
    x_1: i32,
    y_1: i32,
    x_2: i32,
    rest: *const extern struct {
        y_2: User(i32),
        color: User(api.DisplayColor),
    },
) callconv(.C) void {
    var x0 = x_1;
    const x1 = x_2;
    var y0 = y_1;
    const y1 = rest.y_2.load();
    const color = rest.color.load();
    const dx: i32 = @intCast(@abs(x1 - x0));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -@as(i32, @intCast(@abs(y1 - y0)));
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;

    while (true) {
        pointUnclipped(x0, y0, color);

        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            if (x0 == x1) break;
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            if (y0 == y1) break;
            err += dx;
            y0 += sy;
        }
    }
}

fn oval(
    x: i32,
    y: i32,
    width: u32,
    rest: *const extern struct {
        height: User(u32),
        stroke_color: User(api.DisplayColor.Optional),
        fill_color: User(api.DisplayColor.Optional),
    },
) callconv(.C) void {
    const height = rest.height.load();
    const stroke_color = rest.stroke_color.load();
    const fill_color = rest.fill_color.load();

    const signed_width: i32 = @intCast(width);
    const signed_height: i32 = @intCast(height);

    var a = signed_width - 1;
    const b = signed_height - 1;
    var b1 = @rem(b, 2); // Compensates for precision loss when dividing

    var north = y + @divFloor(signed_height, 2); // Precision loss here
    var west = x;
    var east = x + signed_width - 1;
    var south = north - b1; // Compensation here. Moves the bottom line up by
    // one (overlapping the top line) for even heights

    const a2 = a * a;
    const b2 = b * b;

    // Error increments. Also known as the decision parameters
    var dx = 4 * (1 - a) * b2;
    var dy = 4 * (b1 + 1) * a2;

    // Error of 1 step
    var err = dx + dy + b1 * a2;

    a = 8 * a2;
    b1 = 8 * b2;

    while (true) {
        if (stroke_color.unwrap()) |sc| {
            pointUnclipped(east, north, sc); // I. Quadrant
            pointUnclipped(west, north, sc); // II. Quadrant
            pointUnclipped(west, south, sc); // III. Quadrant
            pointUnclipped(east, south, sc); // IV. Quadrant
        }

        const oval_start = west + 1;
        const len = east - oval_start;

        if (fill_color != .none and len > 0) { // Only draw fill if the length from west to east is not 0
            hline(oval_start, north, @intCast(east - oval_start), fill_color.unwrap().?); // I and III. Quadrant
            hline(oval_start, south, @intCast(east - oval_start), fill_color.unwrap().?); // II and IV. Quadrant
        }

        const err2 = 2 * err;

        if (err2 <= dy) {
            // Move vertical scan
            north += 1;
            south -= 1;
            dy += a;
            err += dy;
        }

        if (err2 >= dx or err2 > dy) {
            // Move horizontal scan
            west += 1;
            east -= 1;
            dx += b1;
            err += dx;
        }

        if (!(west <= east)) break;
    }

    if (stroke_color.unwrap()) |sc| {
        // Make sure north and south have moved the entire way so top/bottom aren't missing
        while (north - south < signed_height) {
            pointUnclipped(west - 1, north, sc); // II. Quadrant
            pointUnclipped(east + 1, north, sc); // I. Quadrant
            north += 1;
            pointUnclipped(west - 1, south, sc); // III. Quadrant
            pointUnclipped(east + 1, south, sc); // IV. Quadrant
            south -= 1;
        }
    }
}

fn rect(
    x: i32,
    y: i32,
    width: u32,
    rest: *const extern struct {
        height: User(u32),
        stroke_color: User(api.DisplayColor.Optional),
        fill_color: User(api.DisplayColor.Optional),
    },
) callconv(.C) void {
    const height = rest.height.load();
    const stroke_color = rest.stroke_color.load().unwrap();
    const fill_color = rest.fill_color.load().unwrap();

    if (stroke_color) |sc| {
        hline(x, y, width, sc);
        hline(x, y + @as(i32, @intCast(height)), width + 1, sc);

        vline(x, y, height, sc);
        vline(x + @as(i32, @intCast(width)), y, height, sc);
    }

    if (fill_color) |fc| {
        for (@as(u32, @intCast(y)) + 1..@as(u32, @intCast(y)) + height) |yy| {
            hline(x + 1, @intCast(yy), width - 1, fc);
        }
    }
}

const font = @embedFile("font.dat");

fn text(
    str_ptr: [*]const User(u8),
    str_len: usize,
    x: i32,
    rest: *const extern struct {
        y: User(i32),
        text_color: User(api.DisplayColor.Optional),
        background_color: User(api.DisplayColor.Optional),
    },
) callconv(.C) void {
    // const str = str_ptr[0].load();
    const y = rest.y.load();
    const text_color = rest.text_color.load();
    const background_color = rest.background_color.load();

    const colors = &[_]api.DisplayColor.Optional{ text_color, background_color };

    var char_x_offset = x;
    var char_y_offset = y;

    for (0..str_len) |char_idx| {
        const char = str_ptr[char_idx].load();

        if (char == 10) {
            char_y_offset += 8;
            char_x_offset = x;
        } else if (char >= 32 and char <= 255) {
            const base = (@as(usize, char) - 32) * 64;
            for (0..8) |y_offset| {
                const dst_y = char_y_offset + @as(i32, @intCast(y_offset));
                for (0..8) |x_offset| {
                    const dst_x = char_x_offset + @as(i32, @intCast(x_offset));

                    const color = colors[std.mem.readPackedIntNative(u1, font, base + y_offset * 8 + (7 - x_offset))];
                    if (color.unwrap()) |dc| {
                        // TODO: this is slow; check bounds once instead
                        pointUnclipped(dst_x, dst_y, dc);
                    }
                }
            }

            char_x_offset += 8;
        } else {
            char_x_offset += 8;
        }
    }
}

fn hline(
    x: i32,
    y: i32,
    len: u32,
    color: api.DisplayColor,
) callconv(.C) void {
    if (y < 0 or y >= api.screen_height) return;

    const clamped_x: u32 = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(api.screen_width - 1))));
    const clamped_len = @min(clamped_x + len, api.screen_width) - clamped_x;

    const y_offset = api.screen_width * @as(u32, @intCast(y));
    @memset(api.framebuffer[y_offset + clamped_x ..][0..clamped_len], color);
}

fn vline(
    x: i32,
    y: i32,
    len: u32,
    color: api.DisplayColor,
) callconv(.C) void {
    if (y + @as(i32, @intCast(len)) <= 0 or x < 0 or x >= @as(i32, @intCast(api.screen_width))) return;

    const start_y: u32 = @intCast(@max(0, y));
    const end_y: u32 = @intCast(@min(api.screen_height, y + @as(i32, @intCast(len))));

    for (start_y..end_y) |yy| {
        point(@intCast(x), yy, color);
    }
}

fn tone(
    frequency: u32,
    duration: u32,
    volume: u32,
    flags: api.ToneOptions.Flags,
) callconv(.C) void {
    const start_frequency: u16 = @truncate(frequency >> 0);
    const end_frequency = switch (@as(u16, @truncate(frequency >> 16))) {
        0 => start_frequency,
        else => |end_frequency| end_frequency,
    };
    const sustain_time: u8 = @truncate(duration >> 0);
    const release_time: u8 = @truncate(duration >> 8);
    const decay_time: u8 = @truncate(duration >> 16);
    const attack_time: u8 = @truncate(duration >> 24);
    const total_time = @as(u10, attack_time) + decay_time + sustain_time + release_time;
    const sustain_volume: u8 = @truncate(volume >> 0);
    const peak_volume = switch (@as(u8, @truncate(volume >> 8))) {
        0 => 100,
        else => |attack_volume| attack_volume,
    };

    var state: audio.Channel = .{
        .duty = 0,
        .phase = 0,
        .phase_step = 0,
        .phase_step_step = 0,

        .duration = 0,
        .attack_duration = 0,
        .decay_duration = 0,
        .sustain_duration = 0,
        .release_duration = 0,

        .volume = 0,
        .volume_step = 0,
        .peak_volume = 0,
        .sustain_volume = 0,
        .attack_volume_step = 0,
        .decay_volume_step = 0,
        .release_volume_step = 0,
    };

    const start_phase_step = @mulWithOverflow((1 << 32) / 44100, @as(u31, start_frequency));
    const end_phase_step = @mulWithOverflow((1 << 32) / 44100, @as(u31, end_frequency));
    if (start_phase_step[1] != 0 or end_phase_step[1] != 0) return;
    state.phase_step = start_phase_step[0];
    state.phase_step_step = @divTrunc(@as(i32, end_phase_step[0]) - start_phase_step[0], @as(u20, total_time) * @divExact(44100, 60));

    state.attack_duration = @as(u18, attack_time) * @divExact(44100, 60);
    state.decay_duration = @as(u18, decay_time) * @divExact(44100, 60);
    state.sustain_duration = @as(u18, sustain_time) * @divExact(44100, 60);
    state.release_duration = @as(u18, release_time) * @divExact(44100, 60);

    state.peak_volume = @as(u29, peak_volume) << 21;
    state.sustain_volume = @as(u29, sustain_volume) << 21;
    if (state.attack_duration > 0) {
        state.attack_volume_step = @divTrunc(@as(i32, state.peak_volume) - 0, state.attack_duration);
    }
    if (state.decay_duration > 0) {
        state.decay_volume_step = @divTrunc(@as(i32, state.sustain_volume) - state.peak_volume, state.decay_duration);
    }
    if (state.release_duration > 0) {
        state.release_volume_step = @divTrunc(@as(i32, 0) - state.sustain_volume, state.release_duration);
    }

    switch (flags.channel) {
        .pulse1, .pulse2 => {
            state.duty = switch (flags.duty_cycle) {
                .@"1/8" => (1 << 32) / 8,
                .@"1/4" => (1 << 32) / 4,
                .@"1/2" => (1 << 32) / 2,
                .@"3/4" => (3 << 32) / 4,
            };
        },
        .triangle => {
            state.duty = (1 << 32) / 2;
        },
        .noise => {
            state.duty = (1 << 32) / 2;
        },
    }

    audio.set_channel(@intFromEnum(flags.channel), state);
}

fn read_flash(
    offset: u32,
    dst_ptr: [*]User(u8),
    dst_len: usize,
) callconv(.C) u32 {
    const dst = dst_ptr[0..dst_len];

    _ = offset;
    _ = dst;

    return 0;
}

fn write_flash_page(
    page: u16,
    src: *const [api.flash_page_size]User(u8),
) callconv(.C) void {
    _ = page;
    _ = src;
}

fn trace(
    str_ptr: [*]const User(u8),
    str_len: usize,
) callconv(.C) void {
    _ = str_len;
    _ = str_ptr;
}
