//! Hardware to interact with:
//!
//! - LCD Screen
//! - Speaker
//! - 5x Neopixels
//! - Light Sensor
//! - 4x Buttons
//! - Navstick
//! - Red LED
//! - Flash Memory
//!
const port = @import("port.zig");

pub const NeopixelColor = @import("neopixel.zig").Color;
pub const Neopixels = @import("neopixel.zig").Group(5);
pub const lcd = @import("lcd.zig");
pub const audio = @import("audio.zig");

// LCD display parameters
// DC: Switch between data and command
// LITE: Backlight
// SCK/CS/MOSI: SPI port
pub const pin_tft_reset = port.pin(.a, 0);
pub const pin_tft_lite = port.pin(.a, 1);
pub const pin_tft_dc = port.pin(.b, 12);
pub const pin_tft_sck = port.pin(.b, 13);
pub const pin_tft_cs = port.pin(.b, 14);
pub const pin_tft_mosi = port.pin(.b, 15);

// DAC output to speaker/Enable pin
pub const pin_speaker = port.pin(.a, 2);
pub const pin_speaker_enable = port.pin(.a, 23);

// Red LED
pub const pin_led = port.pin(.a, 5);

// Light sensor ADC input
pub const pin_light_sensor = port.pin(.a, 6);

// Vcc voltage ADC input
pub const pin_vcc_sensor = port.pin(.a, 7);

// Battery level ADC input
pub const pin_battery_sensor = port.pin(.a, 4);

// 2Megabyte flash chip pins
pub const qspi = [_]port.Pin{
    port.pin(.a, 8),
    port.pin(.a, 9),
    port.pin(.a, 10),
    port.pin(.a, 11),
    port.pin(.b, 10),
    port.pin(.b, 11),
};

// Neopixel input pin. This is used like a shift register.
pub const pin_neopixel = port.pin(.a, 15);

// USB differential pair
pub const @"D-" = port.pin(.a, 24);
pub const @"D+" = port.pin(.a, 25);

// CMSIS Debug bus
pub const SWO = port.pin(.a, 27);
pub const SWCLK = port.pin(.a, 30);
pub const SWDIO = port.pin(.a, 31);

pub const ButtonPoller = struct {
    pub const mask = port.mask(.b, 0x1FF);

    pub fn init() ButtonPoller {
        mask.set_dir(.in);
        return ButtonPoller{};
    }

    pub fn read_from_port(poller: ButtonPoller) Buttons {
        _ = poller;
        const value = mask.read();
        return @bitCast(@as(u9, @truncate(value)));
    }

    pub const Buttons = packed struct(u9) {
        select: u1,
        start: u1,
        a: u1,
        b: u1,
        up: u1,
        down: u1,
        click: u1,
        right: u1,
        left: u1,
    };
};
