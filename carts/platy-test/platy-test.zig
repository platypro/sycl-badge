const std = @import("std");
const sdk = @import("sdk");

export fn start() callconv(.C) void {}

const MyShaderValue = packed struct {};
const MyShader = sdk.Shader(MyShaderValue, myShaderFunc);

fn myShaderFunc(
    shader: MyShaderValue,
    region: *const sdk.Region,
    buffer: []sdk.DisplayColor,
    i: u16,
) void {
    _ = shader;
    _ = region;
    _ = i;
    @memset(buffer, sdk.DisplayColor.new(0, 0, 0));
}

export fn update() callconv(.C) void {
    const shader = MyShader.create(.{});
    shader.render(&.{});
}
