export fn disp_set_pixel(
    xy: u32,
    color: u32,
) void {
    asm volatile (" svc #1"
        :
        : [xy] "{r0}" (xy),
          [color] "{r1}" (color),
        : "r0", "r1", "memory"
    );
}

export fn disp_clear(
    color: u32,
) void {
    asm volatile (" svc #2"
        :
        : [color] "{r0}" (color),
        : "r0", "memory"
    );
}

export fn disp_set_window(
    x1x2: u32,
    y1y2: u32,
) void {
    asm volatile (" svc #3"
        :
        : [x1x2] "{r0}" (x1x2),
          [y1y2] "{r1}" (y1y2),
        : "r0", "r1", "memory"
    );
}

export fn disp_write(
    buf: *anyopaque,
    len: u32,
) void {
    asm volatile (" svc #4"
        :
        : [buf] "{r0}" (buf),
          [len] "{r1}" (len),
        : "r0", "r1", "memory"
    );
}

export fn disp_poll_busy() u32 {
    return asm volatile (" svc #5"
        : [ret] "={r0}" (-> u32),
        :
        : "r0", "memory"
    );
}
