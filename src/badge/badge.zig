//! This is firmware for the SYCL badge.
//!
//! The badge image
//! For normal operation, the default app will run. Pressing select will go to
//! the main menu. The default app will display the SYCL logo, users will be
//! able to change the default app.
//!
//! Apps will have the option to to save state to non-volatile memory. This
//! will prompt the user. The user will either exit without saving, save and
//! exit, or cancel.
//!
//! TODO:
//! - USB mass drive
//! - USB CDC logging
const std = @import("std");
const builtin = @import("builtin");

const microzig = @import("microzig");
const cpu = microzig.cpu;
const chip = microzig.chip;
const board = @import("board.zig");
const clocks = @import("clocks.zig");
const timer = @import("timer.zig");
const sercom = @import("sercom.zig");
const adc = @import("adc.zig").num(0);

// direct peripheral access
const SystemControl = chip.peripherals.SystemControl;
const CMCC = chip.peripherals.CMCC;
const NVMCTRL = chip.peripherals.NVMCTRL;
const TC4 = chip.peripherals.TC4;
const MPU = chip.peripherals.MPU;

const cart = @import("cart-system.zig");

const led_pin = board.pin_led;

const lcd = board.lcd;
const ButtonPoller = board.ButtonPoller;
const light_sensor_pin = board.pin_light_sensor;
const audio = board.audio;

const utils = @import("utils.zig");

pub const microzig_options = .{
    .interrupts = .{
        .SVCall = microzig.interrupt.Handler{ .Naked = svcall_handler },
        .PendSV = microzig.interrupt.Handler{ .Naked = svcall_handler },
        .DMAC_DMAC_0 = .{ .C = &lcd.onDone },
        .DMAC_DMAC_1 = .{ .C = &audio.mix },
    },
};

pub const CARTRAM = struct {
    pub const SIZE: usize = 16; // 2^17 = 128kb
    pub const ADDR: usize = 0x20000000;
};

pub const RUNTIMERAM = struct {
    pub const SIZE: usize = 15; // s^16 = 64kb
    pub const ADDR: usize = 0x20020000;
};

pub const FLASH = struct {
    pub const SIZE: usize = 18; // 2^19 = 512 kB
    pub const PAGE_SIZE = 512;
    pub const NB_OF_PAGES = 1024;
    pub const USER_PAGE_SIZE = 512;
    pub const ADDR: usize = 0x00000000;
};

pub fn svcall_handler() callconv(.Naked) noreturn {
    asm volatile (
    // Grab the svc #
        \\ MRS     R0,PSP
        \\ LDR     R0,[R0,#24]
        \\ LDRH    R0,[R0,#-2]
        \\ BICS    R0,R0,#0xFF00
        // Skip exit handler if svc not #0
        \\ CMP R0,#0
        \\ BNE handle_svc
        // Also skip exit handler if not called from badge.zig (todo)
        // Switch to main stack and privilidged mode
        \\ mrs r0, control
        \\ bic r0, r0, #0b01
        \\ msr control, r0
        \\ isb
        \\ bx lr
        \\handle_svc:
        \\ PUSH {LR}
        \\ mrs R1, PSP
        \\ bl %[handle_svcall:P]
        \\ POP {LR}
        \\ bx LR
        :
        : [handle_svcall] "X" (&cart.handle_svcall),
        : "r0", "r1"
    );
}

fn call_cart(fcn: *const fn () callconv(.C) void) void {
    asm volatile (
        \\ mrs r1, control
        \\ orr r1, r1, #0b11
        \\ msr control, r1
        \\ isb
        ::: "r1");
    fcn();

    asm volatile (
        \\ svc #0
        \\ mrs r1, control
        \\ bic r1, r1, #0b11
        \\ msr control, r1
        \\ isb
        ::: "r1");
}

pub fn main() !void {
    // Enable safety traps
    SystemControl.CCR.modify(.{
        // Allows An exception to be thrown from the svcall handler to return to either os/app code
        .NONBASETHRDENA = 1,
        // Unprivelidged code can trigger a SWI manually
        .USERSETMPEND = 1,
        // Unaligned word or halfword access does NOT cause a lockup
        .UNALIGN_TRP = .{ .value = .VALUE_0 },
        // Divide by zero causes a lock up
        .DIV_0_TRP = 1,
        // Precice data acess fault does NOT cause a lockup
        .BFHFNMIGN = 1,
        // Stack is aligned to 8-byte boundaries
        .STKALIGN = .{ .value = .VALUE_1 },
    });
    // Enable FPU access.
    SystemControl.CPACR.write(.{
        .reserved20 = 0,
        .CP10 = .{ .value = .FULL },
        .CP11 = .{ .value = .FULL },
        .padding = 0,
    });

    clocks.mclk.set_ahb_mask(.{
        .CMCC = .enabled,
        .DMAC = .enabled,
    });
    CMCC.CTRL.write(.{
        .CEN = 1,
        .padding = 0,
    });

    NVMCTRL.CTRLA.modify(.{ .AUTOWS = 1 });
    clocks.gclk.reset_blocking();
    microzig.cpu.dmb();

    // Set up Process Stack Pointer
    asm volatile (
        \\ MOV  r0, #0xFFFF
        \\ MOVT r0, #0x2001
        \\ MSR psp, r0
        ::: "r0");

    // GCLK0 feeds the CPU so put it on OSCULP32K for now
    clocks.gclk.enable_generator(.GCLK0, .OSCULP32K, .{});

    // Enable the first chain of clock generators:
    //
    // FDLL (48MHz) => GCLK2 (1MHz) => DPLL0 (120MHz) => GCLK0 (120MHz)
    //                              => ADC0 (1MHz)
    //                              => TC0 (1MHz)
    //                              => TC1 (1MHz)
    //
    clocks.gclk.enable_generator(.GCLK2, .DFLL, .{
        .divsel = .DIV1,
        .div = 48,
    });

    const dpll0_factor = 1;
    clocks.enable_dpll(0, .GCLK2, .{
        .factor = dpll0_factor,
        .input_freq_hz = 1_000_000,
        .output_freq_hz = 120_000_000,
    });

    clocks.gclk.set_peripheral_clk_gen(.GCLK_ADC0, .GCLK2);
    clocks.gclk.set_peripheral_clk_gen(.GCLK_TC0_TC1, .GCLK2);
    clocks.gclk.enable_generator(.GCLK0, .DPLL0, .{
        .divsel = .DIV1,
        .div = dpll0_factor,
    });

    // The second chain of clock generators:
    //
    // FDLL (48MHz) => GCLK1 (76.8KHz) => DPLL1 (8.467MHz) => GCLK3 (8.467MHz) => TC4 (8.467MHz)
    //

    // The we use GCLK1 here because it's able to divide much more than the
    // other generators, the other generators max out at 512
    clocks.gclk.enable_generator(.GCLK1, .DFLL, .{
        .divsel = .DIV1,
        .div = 625,
    });

    const dpll1_factor = 12;
    clocks.enable_dpll(1, .GCLK1, .{
        .factor = dpll1_factor,
        .input_freq_hz = 76_800,
        .output_freq_hz = 8_467_200,
    });

    clocks.gclk.enable_generator(.GCLK3, .DPLL1, .{
        .divsel = .DIV1,
        .div = dpll1_factor,
    });
    clocks.gclk.set_peripheral_clk_gen(.GCLK_TC4_TC5, .GCLK3);
    clocks.gclk.set_peripheral_clk_gen(.GCLK_SERCOM4_CORE, .GCLK0);

    clocks.mclk.set_apb_mask(.{
        .ADC0 = .enabled,
        .TC0 = .enabled,
        .TC1 = .enabled,
        .TC4 = .enabled,
        .SERCOM4 = .enabled,
        .TC5 = .enabled,
        .DAC = .enabled,
        .EVSYS = .enabled,
    });

    timer.init();
    audio.init();

    // Light sensor adc
    light_sensor_pin.set_mux(.B);

    const state = clocks.get_state();
    const freqs = clocks.Frequencies.get(state);
    _ = freqs;
    lcd.init();

    const neopixels = board.Neopixels.init(board.pin_neopixel);
    adc.init();
    const poller = ButtonPoller.init();
    led_pin.set_dir(.out);

    @memset(@as(*[0xA01E]u8, @ptrFromInt(0x20020000)), 0);
    cart.api.neopixels.* = .{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
    };

    // fill .bss with zeroes
    {
        const bss_start: [*]u8 = @ptrCast(&cart.libcart.cart_bss_start);
        const bss_end: [*]u8 = @ptrCast(&cart.libcart.cart_bss_end);
        const bss_len = @intFromPtr(bss_end) - @intFromPtr(bss_start);

        @memset(bss_start[0..bss_len], 0);
    }

    // load .data from flash
    {
        const data_start: [*]u8 = @ptrCast(&cart.libcart.cart_data_start);
        const data_end: [*]u8 = @ptrCast(&cart.libcart.cart_data_end);
        const data_len = @intFromPtr(data_end) - @intFromPtr(data_start);
        const data_src: [*]const u8 = @ptrCast(&cart.libcart.cart_data_load_start);

        @memcpy(data_start[0..data_len], data_src[0..data_len]);
    }

    // Call start() on cart
    call_cart(&cart.libcart.start);

    while (true) {
        const light_reading = adc.single_shot_blocking(.AIN6);
        cart.api.light_level.* = @intCast(light_reading);

        const buttons = poller.read_from_port();
        cart.api.controls.* = .{
            .start = buttons.start == 1,
            .select = buttons.select == 1,
            .a = buttons.a == 1,
            .b = buttons.b == 1,
            .click = buttons.click == 1,
            .up = buttons.up == 1,
            .down = buttons.down == 1,
            .left = buttons.left == 1,
            .right = buttons.right == 1,
        };

        call_cart(&cart.libcart.update);
        var pixels: [5]board.NeopixelColor = undefined;
        for (&pixels, cart.api.neopixels) |*local, pixel|
            local.* = .{
                .r = pixel.r,
                .g = pixel.g,
                .b = pixel.b,
            };

        neopixels.write(&pixels);
    }
}
