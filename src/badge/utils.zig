//adafruit/uf2-samdx1:lib/cmsis/CMSIS/Include/core_cm7.h
fn NVIC_SystemReset() noreturn {
    microzig.cpu.dsb();
    microzig.cpu.peripherals.SCB.AIRCR.write(.{
        .reserved1 = 0,
        .VECTCLRACTIVE = 0,
        .SYSRESETREQ = 1,
        .reserved15 = 0,
        .ENDIANESS = 0,
        .VECTKEY = 0x5FA,
    });
    microzig.cpu.dsb();
    microzig.hang();
}

const microzig = @import("microzig");
const std = @import("std");
