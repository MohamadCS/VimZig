const std = @import("std");
const vaxis = @import("vaxis");
const utils = @import("utils.zig");
const Logger = @import("logger.zig").Logger;
const target = @import("builtin").target;

pub const Theme = @import("theme.zig");
pub const Comps = @import("components.zig");
pub const Editor = @import("editor.zig").Editor;
pub const Types = @import("types.zig");
pub const StatusLine = @import("status_line.zig").StatusLine;

const Vimz = @This();

const Allocator = std.mem.Allocator;

// Devide to App and State
pub const App = struct {
    tty: vaxis.Tty,

    vx: vaxis.Vaxis,

    allocator: Allocator,

    theme: Theme,

    quit: bool,

    loop: vaxis.Loop(Types.Event) = undefined,

    editor: Editor,

    statusLine: StatusLine,

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const Self = @This();

    fn init() !Self {
        const allocator = App.gpa.allocator();
        return Self{
            .allocator = allocator,
            .tty = try vaxis.Tty.init(),
            .vx = try vaxis.init(allocator, .{}),
            .quit = false,
            .statusLine = try StatusLine.init(allocator),
            .theme = .{},
            .editor = try Editor.init(allocator),
        };
    }

    // Singleton for simplicity.
    // Find a better way later.
    var instance: ?Self = null;
    pub fn getInstance() !*Self {
        if (App.instance) |*app| {
            return app;
        }

        App.instance = try App.init();
        return &App.instance.?;
    }

    pub fn deinit(self: *Self) void {
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
        self.statusLine.deinit();
        self.editor.deinit();

        const deinit_status = App.gpa.deinit();
        if (deinit_status == .leak) {}
    }

    fn updateDims(self: *Self) !void {
        const win = self.vx.window();

        self.editor.wins_opts.win = .{
            .x_off = 0,
            .y_off = 0,
            .width = win.width,
            .height = win.height - 2,
        };

        try self.editor.updateDims();

        self.statusLine.win_opts = .{
            .x_off = 0,
            .y_off = win.height - 2,
            .height = 1,
            .width = win.width,
        };
    }

    fn draw(self: *Self) !void {
        const win = self.vx.window();

        win.clear();

        var status_line_win = win.child(self.statusLine.win_opts);
        var editor_win = win.child(self.editor.wins_opts.win);

        try self.statusLine.draw(&status_line_win);
        try self.editor.draw(&editor_win);
    }

    fn handleEvent(self: *Self, event: Types.Event) !void {
        switch (event) {
            .winsize => |ws| {
                try self.vx.resize(self.allocator, self.tty.anyWriter(), ws);
            },
            .key_press => |key| {
                // For some reason, vaxis enters with this key pressed
                if (key.codepoint == vaxis.Key.f3) {
                    return;
                }
                try self.editor.handleInput(key);
            },
            .mouse => |mouse| {
                try self.editor.handleMouseEvent(mouse);
            },
            .refresh_status_line => {},
        }
    }

    fn update(self: *Self) !void {
        try self.updateDims();
        try self.editor.update();
    }

    pub fn enqueueEvent(self: *Self, event: Types.Event) !void {
        self.loop.postEvent(event);
    }

    pub fn run(self: *Self) !void {
        self.loop = vaxis.Loop(Types.Event){
            .tty = &self.tty,
            .vaxis = &self.vx,
        };

        // its seems that this has better performence than anyWriter().
        var buffered_writer = self.tty.bufferedWriter();
        const writer = buffered_writer.writer().any();

        // Loop Setup
        //
        try self.loop.init();
        try self.loop.start();

        defer self.loop.stop();

        // Settings
        try self.vx.enterAltScreen(writer);
        try self.vx.queryTerminal(writer, 0.1 * std.time.ns_per_s);
        try self.vx.setTerminalBackgroundColor(writer, self.theme.bg.rgb);
        try self.vx.setTerminalForegroundColor(writer, self.theme.fg.rgb);
        try self.vx.setTerminalCursorColor(writer, self.theme.cursor.rgb);

        try self.statusLine.setup();
        try self.editor.setup();

        while (!self.quit) {
            self.loop.pollEvent();

            // If there is some event, then handle it
            while (self.loop.tryEvent()) |event| {
                try self.handleEvent(event);
            }

            try self.update();

            try self.draw();

            self.vx.queueRefresh();

            try self.vx.render(writer);

            try buffered_writer.flush();
        }
    }
};
