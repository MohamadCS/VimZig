pub const Vimz = @import("app.zig");
pub const App = @import("app.zig").App;
pub const StatusLine = @import("status_line.zig").StatusLine;
const std = @import("std");

const Api = @This();


pub fn getMode() !Vimz.Mode {
    const app = try App.getInstance();
    return app.mode;
}

pub fn setMode(mode: Vimz.Mode) !void {
    var app = try App.getInstance();
    app.mode = mode;
}

pub fn getRelCursorState() !Vimz.CursorState {
    const app = try App.getInstance();
    return app.cursor;
}

pub fn getAbsCursorState() !Vimz.CursorState {
    const app = try App.getInstance();
    return Vimz.CursorState{
        .col = @intCast(app.cursor.col + app.left),
        .row = @intCast(app.cursor.row + app.top)
    };
}

pub fn getAllocator() !std.mem.Allocator {
    const app = try App.getInstance();
    return app.allocator;
}

pub fn addStatusLineComp(comp: StatusLine.Component, pos: StatusLine.Position) !void {
    var app = try App.getInstance();
    try app.statusLine.addComp(comp, pos);
}
